/*
 * GDHubDextCore: the DriverKit-free parts of the dext, compiled twice: into the dext (Xcode) and into the SwiftPM
 * target of the same name, where Tests/GDHubTests exercises them. Plain C99 over <stdint.h> and compiler atomic
 * builtins; no libc calls. Objects are opaque `void *` that the caller can retain and release through `gdhr_ops`.
 *
 *   1. Registry state machine (plan receiver-takeover §4.3): the process-global table of the owner user client and
 *      the pad slot, with +1 accessors, "release only after unlocking", and the atomic words.
 *   2. Meter (plan §9.1): fixed-bucket histograms for `hop` and `hr`, 10 s windows, a seqlock-published summary.
 *   3. GDHubStatus2 packer and CRC-32.
 */
#ifndef GDHubDextCore_h
#define GDHubDextCore_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------------------------------------------
 * Call-order ranks (plan §4.2). A synchronous cross-object call goes from a lower to a higher rank only.
 */
#define GDHR_RANK_UC    1
#define GDHR_RANK_ROOT  2
#define GDHR_RANK_TAP   3    /* T4 */
#define GDHR_RANK_PAD   4

/* Pad source word: who may post. T3 uses NONE and UC only (same values as GDHUB_PADSRC_* in GDHubProtocol.h). */
#define GDHR_SRC_NONE   0
#define GDHR_SRC_UC     1
#define GDHR_SRC_TAP    2

/* Pad slot states. NONE -> STAGED (user client staged the spec) -> CREATING (root is inside Create) -> LIVE (the pad
 * registered itself at the end of handleStart). Any state returns to NONE through take/abort/stopped. */
#define GDHR_PAD_NONE      0
#define GDHR_PAD_STAGED    1
#define GDHR_PAD_CREATING  2
#define GDHR_PAD_LIVE      3

/* Results. */
#define GDHR_OK          0
#define GDHR_E_BUSY      1   /* the slot is not free */
#define GDHR_E_NOT_OWNER 2   /* stale or missing owner generation */
#define GDHR_E_STATE     3   /* wrong state for this transition (or the registry is not ready) */
#define GDHR_E_ARG       4

enum gdhr_counter {
    GDHR_CTR_UC_POSTS = 0,       /* input reports handed to the HID stack for source UC */
    GDHR_CTR_UC_REJECTED,        /* submissions the pad refused (stopping, wrong source, no pad) */
    GDHR_CTR_NEUTRAL_POSTS,      /* postNeutralFrom calls that reached the pad */
    GDHR_CTR_POST_ERRORS,        /* handleReport returned an error */
    GDHR_CTR_SYNC_VIOLATIONS,    /* GDH_SYNC found a call-order violation */
    GDHR_CTR_PAD_CREATES,
    GDHR_CTR_PAD_DESTROYS,
    GDHR_CTR_CREATE_FAILS,
    GDHR_CTR_OUTPUTS_SEEN,       /* host output reports (setReport) that arrived at the pad */
    GDHR_CTR_OUTPUTS_NO_OWNER,   /* ... of which there was no owner client to deliver them to */
    GDHR_CTR_CREATE_EARLY,       /* Create returned before the pad's Start registered it */
    GDHR_CTR_COUNT
};

/* Everything the registry needs from its environment. In the dext: IOLock and OSObject::retain/release. */
typedef struct gdhr_ops {
    void *(*lock_new)(void);              /* NULL on failure */
    void  (*lock_free)(void *lock);
    void  (*lock)(void *lock);
    void  (*unlock)(void *lock);
    void  (*retain)(void *object);        /* must not block and must not call back into the registry */
    void  (*release)(void *object);       /* called only after the registry lock has been dropped */
} gdhr_ops;

typedef struct gdhr {
    void           *lock;                 /* installed once by compare-and-swap */
    uint32_t        ready;                /* set after `ops` is stored */
    const gdhr_ops *ops;
    /* guarded by `lock` */
    void           *root;                 /* retained */
    void           *owner;                /* retained user client */
    uint64_t        ownerGen;             /* 0 when there is no owner */
    uint64_t        genSeq;
    uint32_t        padState;
    void           *pad;                  /* retained, LIVE only */
    void           *padSpec;              /* retained, STAGED..LIVE */
    uint32_t        padSpecCrc;
    uint64_t        padGen;               /* owner generation that staged the pad */
    /* atomic words (any thread, no lock) */
    uint32_t        padSource;
    uint32_t        desiredState;         /* T3: always INERT (0) */
    uint64_t        nonce;
    uint32_t        build, pid;
    uint64_t        counters[GDHR_CTR_COUNT];
} gdhr;

typedef struct gdhr_snap {
    uint64_t nonce;
    uint32_t build, pid;
    uint32_t desiredState, padSource, padState, padSpecCrc;
    uint32_t ownerPresent, rootPresent;
    uint64_t counters[GDHR_CTR_COUNT];
} gdhr_snap;

/* Idempotent and thread-safe: installs the lock by compare-and-swap (the loser frees its own lock and waits for the
 * winner's two stores). Returns 0 only if no lock could be allocated; every other function then returns an error. */
int gdhr_ensure(gdhr *r, const gdhr_ops *ops);

void gdhr_set_identity(gdhr *r, uint64_t nonce, uint32_t build, uint32_t pid);

/* Root. Registering a different root replaces (and releases) the old one; unregistering ignores a stale root. */
int   gdhr_register_root(gdhr *r, void *root);       /* 1 = replaced another root */
void  gdhr_unregister_root(gdhr *r, void *root);
void *gdhr_copy_root(gdhr *r);                       /* +1 or NULL */

/* Owner user client. Returns the owner generation (> 0), or 0 when another client owns it. Idempotent for the owner. */
uint64_t gdhr_claim_owner(gdhr *r, void *uc);
/* Drops the owner if `uc` is it. If the owner's pad is still registered it is taken as well and returned (+1): the
 * caller terminates it. Keeps "no pad outlives its owner" inside one critical section. */
void *gdhr_release_owner(gdhr *r, void *uc);
void *gdhr_copy_owner(gdhr *r, uint64_t *gen);       /* +1 or NULL */

/* Pad slot. `gen` is the owner generation returned by gdhr_claim_owner. */
int   gdhr_pad_stage(gdhr *r, uint64_t gen, void *spec, uint32_t specCrc);   /* NONE -> STAGED, retains spec */
int   gdhr_pad_unstage(gdhr *r, uint64_t gen);                               /* STAGED -> NONE (idempotent) */
int   gdhr_pad_begin_create(gdhr *r, uint64_t gen);                          /* STAGED -> CREATING */
void *gdhr_pad_copy_spec(gdhr *r);                                           /* +1 or NULL (CREATING, LIVE) */
int   gdhr_pad_started(gdhr *r, void *pad);                                  /* CREATING -> LIVE, retains pad, source UC */
void  gdhr_pad_stopped(gdhr *r, void *pad);                                  /* LIVE (this pad) -> NONE */
/* Destroy: source NONE first, then the pointer is cleared; returns the pad (+1, the registry's own reference moves to
 * the caller) or NULL. `gen` 0 takes whatever is there (root Stop, abort paths); otherwise a stale generation yields
 * GDHR_E_NOT_OWNER in *rc and leaves the slot alone. Any state returns to NONE. */
void *gdhr_pad_take(gdhr *r, uint64_t gen, int *rc);
int   gdhr_pad_is(gdhr *r, void *pad);                                       /* 1 if LIVE and this pad */
/* What the root finds after Create returned, decided in one critical section: LIVE (this pad registered), CREATING
 * (the slot is still CREATING for owner generation `gen`: the pad has not registered yet), or NONE (the slot is empty,
 * or belongs to another generation or another pad: the pad's start was refused or failed). */
#define GDHR_CLS_NONE      0
#define GDHR_CLS_LIVE      1
#define GDHR_CLS_CREATING  2
int   gdhr_pad_classify(gdhr *r, void *pad, uint64_t gen);
void *gdhr_copy_pad(gdhr *r);                                                /* +1 or NULL */
uint32_t gdhr_pad_state(gdhr *r);

/* Atomic words and counters (lock-free). */
uint32_t gdhr_pad_source(const gdhr *r);
uint32_t gdhr_desired_state(const gdhr *r);
void     gdhr_ctr_add(gdhr *r, int id, uint64_t n);
uint64_t gdhr_ctr_get(const gdhr *r, int id);
void     gdhr_snapshot(gdhr *r, gdhr_snap *out);

/* ---------------------------------------------------------------------------------------------------------------
 * Meter (plan §9.1). 61 bounded buckets: edges at 1, 2, 3, 5, 8, 12, 18 and 25 us (so a p50 of a few microseconds
 * can be told from 25), then 39 x 25 us up to 1 ms, 10 x 100 us up to 2 ms, then 3, 5, 10 and 20 ms; one overflow
 * bucket (62 in all). One writer (the pad's queue); any thread may read the published summary of the last completed
 * window. The mean is exact (sum of the samples, not of bucket edges).
 */
#define GDH_HIST_BUCKETS 62

typedef struct gdh_hist {
    uint32_t counts[GDH_HIST_BUCKETS];
    uint64_t n, sumTicks, maxTicks;
} gdh_hist;

typedef struct gdh_summary {
    uint32_t count, p50Ns, p99Ns, maxNs, meanNs;
} gdh_summary;

typedef struct gdh_meter {
    uint32_t numer, denom;                /* mach_timebase_info: ns = ticks * numer / denom */
    uint64_t windowTicks, windowStart;
    uint64_t edgeTicks[GDH_HIST_BUCKETS - 1];
    gdh_hist hop, hr;                     /* current window, writer only */
    uint32_t seq;                         /* seqlock around the published fields */
    gdh_summary pubHop, pubHr;
    uint32_t pubWindows;
} gdh_meter;

void     gdh_meter_init(gdh_meter *m, uint32_t numer, uint32_t denom, uint64_t windowMs);
/* Records one post. `hasHop` is 0 for posts without a source stamp. Returns 1 when this sample closed a window (the
 * summary of that window is then readable and worth one log line). `hrTicks` and `hopTicks` are tick differences. */
int      gdh_meter_sample(gdh_meter *m, uint64_t nowTicks, int hasHop, uint64_t hopTicks, uint64_t hrTicks);
/* Consistent copy of the last completed window; 0 if a writer kept it busy for 8 tries. */
int      gdh_meter_read(const gdh_meter *m, gdh_summary *hop, gdh_summary *hr, uint32_t *windows);
void     gdh_hist_summarize(const gdh_hist *h, const gdh_meter *m, gdh_summary *out);
uint64_t gdh_ticks_to_ns(const gdh_meter *m, uint64_t ticks);

/* CRC-32 (IEEE 802.3, reflected, init and final xor 0xFFFFFFFF): the same value as gdx_crc32 in Shared/GDHubXlate.c. */
uint32_t gdh_crc32(const uint8_t *p, size_t len);

/* GDHubStatus2 v1, T3 subset (layout and offsets: GDHubProtocol.h). Writes the whole structure when `cap` allows and
 * returns its size, or 0 when `cap` is smaller than 8 (version, size and build always fit). With a smaller `cap`
 * the first `cap` bytes are written and `cap` is returned. */
size_t gdh_status2_pack(uint8_t *buf, size_t cap, const gdhr_snap *s,
                        const gdh_summary *hop, const gdh_summary *hr, uint32_t meterWindows);

#ifdef __cplusplus
}
#endif
#endif
