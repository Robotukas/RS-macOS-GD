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
#define GDHR_E_NO_PAD    5   /* T5: a mapping needs a pad (a LIVE slot) to target */
#define GDHR_E_SPEC      6   /* T5: the mapping targets another spec CRC than the live pad's */
#define GDHR_E_SIZE      7   /* T5: the mapping bytes do not fit the handoff buffer */

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
    GDHR_CTR_SYNC_INLINE,        /* a GDH_SYNC call whose target queue was already on this thread's queue stack (an inline nested call) */
    /* T4: the receiver tap (all written on the tap's queue, so they accumulate across tap instances in this process) */
    GDHR_CTR_TAP_STARTS,         /* tap Start calls that kept the service */
    GDHR_CTR_FRAMES_IN,          /* ReportAvailable calls handled while opened and powered */
    GDHR_CTR_FRAMES_R06,         /* ... of reportID 6 */
    GDHR_CTR_FRAMES_OTHER,       /* ... of any other report ID */
    GDHR_CTR_FRAMES_IGNORED,     /* ReportAvailable calls ignored because the Mac is going to sleep */
    GDHR_CTR_FRAMES_BAD,         /* zero or oversized length */
    GDHR_CTR_POOL_MISS,          /* the report was not one of our pool buffers (a kernel temporary buffer) */
    GDHR_CTR_READD_FAIL,         /* AddReportToPool failed */
    GDHR_CTR_OPEN_FAILURES,      /* Open returned an error */
    GDHR_CTR_POKES_RUN,          /* pokes (DispatchAsync from selector 9 / owner loss) that ran on the tap's queue */
    GDHR_CTR_TICK_APPLIES,       /* Open/Close attempts that the tap's own timer made (a poke would have made them first) */
    GDHR_CTR_CLOSE_FAILURES,     /* Close returned an error */
    GDHR_CTR_REOPENS,            /* Opens after an earlier Close in the same tap instance (each builds a fresh pool) */
    GDHR_CTR_TAP_FREES,          /* tap objects freed: starts == frees + live instances */
    /* T5 (SHADOW): written on the tap's queue, except the two map counters (root queue) */
    GDHR_CTR_FRAMES_TRANSLATED,  /* frames run through the shared translator */
    GDHR_CTR_FRAMES_SKIPPED,     /* SHADOW frames that are not report 6 of 16 bytes (never translated) */
    GDHR_CTR_FRAMES_NOMAP,       /* SHADOW frames seen while no mapping is accepted (counted, not translated) */
    GDHR_CTR_FRAMES_UNMAPPED,    /* SHADOW frames whose bytes could not be read without allocating (never expected) */
    GDHR_CTR_STATES_CHANGED,     /* translated frames after which gdx_step would post (a LIVE tap would have posted) */
    GDHR_CTR_REPORTS_WOULD_POST, /* reports in those posts */
    GDHR_CTR_MAP_ACCEPTED,       /* selector 10 blobs accepted */
    GDHR_CTR_MAP_REFUSED,        /* selector 10 blobs refused (any reason) */
    GDHR_CTR_MAP_SWAPS,          /* times the tap switched to a new mapping */
    GDHR_CTR_COUNT
};

/* Everything the registry needs from its environment. In the dext: IOLock and OSObject::retain/release. */
#define GDH_MAP_MAX    1024                  /* bytes of one validated mapping (sizeof(gdx_map) is about 650) */
#define GDH_MAP_WORDS  (GDH_MAP_MAX / 8)

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
    void           *tap;                  /* T4: retained receiver tap, or NULL (the tap never dereferences the root or the owner) */
    void           *tapQueue;             /* retained default queue of that tap, for DispatchAsync pokes */
    uint32_t        padSpecCrc;
    uint64_t        padGen;               /* owner generation that staged the pad */
    /* atomic words (any thread, no lock) */
    uint32_t        padSource;
    uint32_t        desiredState;         /* T3: always INERT (0) */
    uint64_t        nonce;
    uint32_t        build, pid;
    uint64_t        counters[GDHR_CTR_COUNT];
    /* topology probe (atomic): process-local index of each object's default queue (0 = not seen yet), and the OnQueue()
       bits recorded at the first ExternalMethod and the first submitInput */
    uint32_t        queueIdx[4];
    uint32_t        probe[2];
    /* T4 tap words (atomic). opened/applied/powered belong to the registered tap and are written only through
       gdhr_tap_publish / gdhr_tap_set_power, which ignore a stale tap. */
    uint32_t        tapPresent, tapOpened, tapApplied, tapPowered, tapPid, tapLastPowerFlags, lastError, terminating;
    /* T5. selfTest: 0 not run, 3 running, 1 pass, 2 fail (once per process; a failed self-test keeps SHADOW out). */
    uint32_t        selfTest;
    uint32_t        tapAppliedRevision, tapTranslating;      /* written for the registered tap only (gdhr_tap_publish_xlate) */
    /* The accepted mapping, a seqlock-protected byte buffer: the writer (root queue, serialised by the registry lock) makes
       mapSeq odd, stores the words, makes it even; the tap reads without any lock and retries a torn read. It lives only in
       this process's memory and is dropped with the owner or the pad. mapSeq changes on every publish and every clear. */
    uint32_t        mapSeq, mapLen, mapRevision, mapSpecCrc;
    uint64_t        mapWords[GDH_MAP_WORDS];
} gdhr;

typedef struct gdhr_snap {
    uint64_t nonce;
    uint32_t build, pid;
    uint32_t desiredState, padSource, padState, padSpecCrc;
    uint32_t ownerPresent, rootPresent;
    uint32_t topology, probeExt, probePad;
    uint32_t tapPresent, tapOpened, tapApplied, tapPowered, tapPid, tapLastPowerFlags, lastError;
    uint32_t selfTest, tapTranslating, hasMap, acceptedRevision, acceptedSpecCrc, appliedRevision;
    uint64_t counters[GDHR_CTR_COUNT];
} gdhr_snap;

/* Topology probe. Which of the three queue indices to set: */
#define GDHR_Q_ROOT 0
#define GDHR_Q_UC   1
#define GDHR_Q_PAD  2
#define GDHR_Q_TAP  3      /* index only: not part of the topology flags */
/* gdhr_topology() bits: low nibble = the queues are the same object, high nibble = both sides known (set at their Start) */
#define GDHR_TOPO_UC_EQ_ROOT   0x01u
#define GDHR_TOPO_PAD_EQ_ROOT  0x02u
#define GDHR_TOPO_PAD_EQ_UC    0x04u
#define GDHR_TOPO_KNOWN_SHIFT  4
/* probe bits (OnQueue() of the root, user-client and pad queue); VALID once recorded */
#define GDHR_PROBE_ROOT   0x01u
#define GDHR_PROBE_UC     0x02u
#define GDHR_PROBE_PAD    0x04u
#define GDHR_PROBE_VALID  0x80u
#define GDHR_PROBE_EXT    0     /* first ExternalMethod */
#define GDHR_PROBE_SUBMIT 1     /* first submitInput */
void     gdhr_set_queue_idx(gdhr *r, int which, uint32_t idx);
uint32_t gdhr_queue_idx(const gdhr *r, int which);
uint32_t gdhr_topology(const gdhr *r);
uint32_t gdhr_probe_get(const gdhr *r, int which);                    /* 0 until recorded */
int      gdhr_probe_once(gdhr *r, int which, uint32_t bits);         /* 1 if this call recorded it (first wins) */

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
 * Receiver tap (T4). The armed state (`desiredState`) lives only in this process's memory and starts INERT: a relaunched
 * dext never opens the interface until an owner asks again.
 */
#define GDH_FWD_INERT  0      /* attached, interface NOT opened: no per-frame code */
#define GDH_FWD_COUNT  1      /* opened; counts frames and the kernel-to-driver delay; no translation, nothing posted */
#define GDH_FWD_SHADOW 2      /* T5: opened; translates with the accepted mapping, records a parity sample, posts NOTHING.
                                 Without an accepted mapping (or after a failed self-test) it behaves exactly like COUNT. */

/* Registers the tap and reads the desired state in the same critical section, so no state change can be lost between the
 * two. Returns 1 if it replaced a stale tap (two instances during a re-enumeration). Retains `tap` and `queue`. */
int   gdhr_register_tap(gdhr *r, void *tap, void *queue, uint32_t pid, uint32_t *desired);
void  gdhr_unregister_tap(gdhr *r, void *tap);               /* only if it is the registered tap; clears opened/applied */
void *gdhr_copy_tap(gdhr *r, void **queueOut);               /* +1 tap and +1 queue, or NULL */
int   gdhr_tap_is(gdhr *r, void *tap);
void  gdhr_tap_publish(gdhr *r, void *tap, uint32_t opened, uint32_t applied);   /* ignored for a stale tap */
void  gdhr_tap_set_power(gdhr *r, void *tap, uint32_t powered, uint32_t flags);  /* ignored for a stale tap */
void  gdhr_set_desired(gdhr *r, uint32_t state);
/* Selector 9 stores the state only for the CURRENT owner, under the registry lock, so a late request from a client that is
 * going away cannot land after release_owner reset the state. GDHR_OK, or GDHR_E_NOT_OWNER (and nothing changes). */
int   gdhr_set_desired_if_owner(gdhr *r, void *uc, uint32_t state);
void  gdhr_set_last_error(gdhr *r, uint32_t err);
/* devTerminate in progress: a tap that starts now declines, so no service is left to keep the process alive. */
void  gdhr_set_terminating(gdhr *r);
void  gdhr_clear_terminating(gdhr *r);                       /* devTerminate failed: the process is not ending, taps may attach again */
uint32_t gdhr_terminating(const gdhr *r);

/* Selector 9 argument check: 0 = accepted (INERT, COUNT or SHADOW, no flags), 1 = Unsupported. */
int   gdh_fwd_validate(uint64_t state, uint64_t flags);

/* What the tap's queue does next. The only place that decides when Open is called (rule A): the owner asked for COUNT in
 * this process (desired == COUNT, which only selector 9 sets and owner loss clears), the tap is not stopping, the Mac is
 * not going to sleep, the interface is not open, and the retry timer allows it. */
#define GDH_TAP_NONE   0
#define GDH_TAP_OPEN   1
#define GDH_TAP_CLOSE  2
int   gdh_tap_decide(uint32_t desired, uint32_t opened, uint32_t powered, uint32_t stopping, uint32_t retryDue);
/* Cadence of the tap's timer: 1 = 50 ms (the tap has work to do or is waiting to retry, or the dext is terminating), 0 = 1 s.
 * The poke covers the fast path; the timer is the backstop. */
int   gdh_tap_fast_tick(uint32_t desired, uint32_t opened, uint32_t powered, uint32_t stopping, uint32_t terminating);

/* The tap's report pool bookkeeping (T4 review M3). The slots only record which buffers we own and whether each is in the
 * kernel's pool; creating and releasing the buffers is the caller's job. On Close the whole pool is dropped (gdh_pool_reset)
 * and a fresh one is built at the next Open, so a late report that carries an old buffer matches nothing. */
#define GDH_POOL_SLOTS 8
typedef struct gdh_pool {
    void    *buf[GDH_POOL_SLOTS];
    uint8_t  inPool[GDH_POOL_SLOTS];
    uint32_t ready;                    /* 1 once the buffers of this generation have been built */
} gdh_pool;
int   gdh_pool_find(const gdh_pool *p, const void *report);          /* slot of `report`, or -1; NULL never matches */
void  gdh_pool_set(gdh_pool *p, int slot, void *buf);                 /* records a new buffer in an empty slot */
void  gdh_pool_delivered(gdh_pool *p, int slot);                      /* the kernel took it out of the pool to deliver a report */
void  gdh_pool_added(gdh_pool *p, int slot);                          /* AddReportToPool succeeded */
int   gdh_pool_next_missing(const gdh_pool *p, int from);            /* next slot >= from that holds a buffer not in the pool, or -1 */
int   gdh_pool_reset(gdh_pool *p, void *old[GDH_POOL_SLOTS]);         /* clears every slot, hands back the buffers to release; returns how many */

/* ---------------------------------------------------------------------------------------------------------------
 * T5: the mapping handoff (plan 5.6) and the self-test word.
 */
/* Publishes a validated mapping (opaque bytes: the dext stores a gdx_map) for the tap. Under the registry lock, owner only:
 *   GDHR_E_NOT_OWNER  `uc` is not the current owner        GDHR_E_NO_PAD  no LIVE pad
 *   GDHR_E_SPEC       `specCrc` differs from the live pad's  GDHR_E_SIZE   len is 0 or above GDH_MAP_MAX
 * On success mapSeq moves by 2 and the previous mapping is gone. */
int  gdhr_map_publish(gdhr *r, void *uc, const void *bytes, uint32_t len, uint32_t revision, uint32_t specCrc);
void gdhr_map_clear(gdhr *r);                                 /* drops the mapping (mapSeq moves) */
uint32_t gdhr_map_seq(const gdhr *r);                         /* one acquire load: the per-frame "did the mapping change" test */
/* Lock-free consistent read (tap queue). 1 = *out holds the mapping (or len == 0: none), *seq is its sequence; 0 = the
 * writer was busy for 4 tries, keep what you have and try again next frame. Never blocks, never spins unbounded. */
int  gdhr_map_read(const gdhr *r, void *out, uint32_t cap, uint32_t *len, uint32_t *seq, uint32_t *revision, uint32_t *specCrc);

#define GDHR_SELFTEST_NOT_RUN 0
#define GDHR_SELFTEST_PASS    1
#define GDHR_SELFTEST_FAIL    2
#define GDHR_SELFTEST_RUNNING 3
int      gdhr_selftest_begin(gdhr *r);                        /* 1 = the caller runs it (state NOT_RUN -> RUNNING) */
void     gdhr_selftest_finish(gdhr *r, int pass);
uint32_t gdhr_selftest_get(const gdhr *r);
/* There is no wait: the self-test runs on the root's queue only (selector 9 is the sole caller, and ExternalMethod is serial there),
 * so RUNNING is never seen by a second caller; if it ever were, the caller answers NotReady, never "failed". */
int      gdhr_is_owner(gdhr *r, void *uc);                    /* 1 if `uc` is the current owner (the check that precedes the self-test) */
void     gdhr_tap_publish_xlate(gdhr *r, void *tap, uint32_t appliedRevision, uint32_t translating);  /* ignored for a stale tap */

/* The parity record: the last frame the tap translated, as the stateless gdx_eval + gdx_build output, seqlock-published by
 * its single writer (the tap's queue) for any reader. */
typedef struct gdh_parity_rec {
    uint8_t  frame[16];       /* the raw report 0x06 */
    uint8_t  out01[16];       /* report 0 of the mapping (xbox-bt16: 0x01, 16 bytes) */
    uint8_t  out02[2];        /* report 1 of the mapping (xbox-bt16: 0x02, 2 bytes) */
    uint8_t  pad[6];
    uint64_t timestamp;       /* the kernel timestamp of that frame, ReportAvailable's argument (mach ticks) */
    uint32_t revision;        /* revision of the mapping it was translated with */
    uint32_t count;           /* frames recorded since the tap started: moves with every frame */
} gdh_parity_rec;

typedef struct gdh_parity {
    uint32_t seq;
    uint64_t w[7];            /* the record as words (relaxed atomic stores/loads under the seqlock) */
} gdh_parity;

void gdh_parity_write(gdh_parity *p, const gdh_parity_rec *rec);   /* single writer */
int  gdh_parity_read(const gdh_parity *p, gdh_parity_rec *out);    /* 1 = consistent copy; 0 = writer busy for 8 tries */

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
/* T5 extras of status2 (all optional; zero when absent). */
typedef struct gdh_status2_extra {
    gdh_summary xlate;                /* translate time of the SHADOW core, last 10 s window */
    gdh_parity_rec parity;            /* the last parity record, valid when haveParity */
    uint32_t haveParity;
} gdh_status2_extra;

size_t gdh_status2_pack(uint8_t *buf, size_t cap, const gdhr_snap *s,
                        const gdh_summary *hop, const gdh_summary *hr, uint32_t meterWindows, const gdh_summary *k2d,
                        const gdh_status2_extra *extra);

#ifdef __cplusplus
}
#endif
#endif
