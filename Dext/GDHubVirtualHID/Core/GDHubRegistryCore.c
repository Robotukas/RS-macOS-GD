/*
 * Registry state machine (plan receiver-takeover §4.3), see GDHubDextCore.h.
 *
 * Locking discipline, the whole file:
 *  - One lock, installed by compare-and-swap. It protects the pointer fields and nothing else.
 *  - Inside a critical section the only calls out are ops->retain (an atomic increment, never blocking, never
 *    re-entering the registry). Releases happen after the unlock.
 *  - A +1 accessor retains under the lock. That is safe because the registry's own reference keeps the object alive
 *    until the same lock has been taken to clear the pointer.
 *  - Hot words (padSource, desiredState, counters, identity) are accessed with relaxed or acquire/release atomics and
 *    never need the lock.
 */
#include "GDHubDextCore.h"

#define ATOMIC_LOAD(p)     __atomic_load_n((p), __ATOMIC_ACQUIRE)
#define ATOMIC_STORE(p, v) __atomic_store_n((p), (v), __ATOMIC_RELEASE)

static inline int ready(const gdhr *r)
{
    return r && ATOMIC_LOAD(&r->ready);
}

#define LOCK(r)   (r)->ops->lock((r)->lock)
#define UNLOCK(r) (r)->ops->unlock((r)->lock)

static inline void rel(gdhr *r, void *obj)
{
    if (obj) r->ops->release(obj);
}

int gdhr_ensure(gdhr *r, const gdhr_ops *ops)
{
    if (!r || !ops) return 0;
    if (ATOMIC_LOAD(&r->ready)) return 1;
    void *mine = ops->lock_new();
    if (!mine) return 0;
    void *expected = 0;
    if (__atomic_compare_exchange_n(&r->lock, &expected, mine, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        r->ops = ops;
        ATOMIC_STORE(&r->ready, 1);
        return 1;
    }
    ops->lock_free(mine);
    while (!ATOMIC_LOAD(&r->ready)) { /* the winner is two stores from done */ }
    return 1;
}

void gdhr_set_identity(gdhr *r, uint64_t nonce, uint32_t build, uint32_t pid)
{
    if (!ready(r)) return;
    __atomic_store_n(&r->build, build, __ATOMIC_RELAXED);
    __atomic_store_n(&r->pid, pid, __ATOMIC_RELAXED);
    ATOMIC_STORE(&r->nonce, nonce);
}

/* ------------------------------------------------------------------------------------------------------------- */
/* Root */

int gdhr_register_root(gdhr *r, void *root)
{
    if (!ready(r) || !root) return 0;
    void *old = 0;
    r->ops->retain(root);                       /* retain before publishing; undone below if it was already there */
    LOCK(r);
    if (r->root == root) { UNLOCK(r); rel(r, root); return 0; }
    old = r->root;
    r->root = root;
    UNLOCK(r);
    rel(r, old);
    return old != 0;
}

void gdhr_unregister_root(gdhr *r, void *root)
{
    if (!ready(r)) return;
    void *old = 0;
    LOCK(r);
    if (r->root == root) { old = r->root; r->root = 0; }
    UNLOCK(r);
    rel(r, old);
}

void *gdhr_copy_root(gdhr *r)
{
    if (!ready(r)) return 0;
    LOCK(r);
    void *p = r->root;
    if (p) r->ops->retain(p);
    UNLOCK(r);
    return p;
}

/* ------------------------------------------------------------------------------------------------------------- */
/* Pad slot helpers (lock held) */

static void map_clear_locked(gdhr *r);

/* Empties the slot. The registry's references move to the caller through *specOut and the return value. */
static void *take_locked(gdhr *r, void **specOut)
{
    ATOMIC_STORE(&r->padSource, GDHR_SRC_NONE);      /* first: nothing new is accepted from here on */
    void *pad = r->pad;
    *specOut = r->padSpec;
    r->pad = 0;
    r->padSpec = 0;
    r->padSpecCrc = 0;
    r->padGen = 0;
    r->padState = GDHR_PAD_NONE;
    map_clear_locked(r);                                 /* the mapping targeted this pad's spec: it goes with the pad */
    return pad;
}

/* ------------------------------------------------------------------------------------------------------------- */
/* Owner */

uint64_t gdhr_claim_owner(gdhr *r, void *uc)
{
    if (!ready(r) || !uc) return 0;
    uint64_t gen = 0;
    LOCK(r);
    if (!r->owner) {
        r->ops->retain(uc);
        r->owner = uc;
        gen = r->ownerGen = ++r->genSeq;
    } else if (r->owner == uc) {
        gen = r->ownerGen;
    }
    UNLOCK(r);
    return gen;
}

void *gdhr_release_owner(gdhr *r, void *uc)
{
    if (!ready(r)) return 0;
    void *oldOwner = 0, *pad = 0, *spec = 0;
    LOCK(r);
    if (r->owner && r->owner == uc) {
        uint64_t gen = r->ownerGen;
        oldOwner = r->owner;
        r->owner = 0;
        r->ownerGen = 0;
        ATOMIC_STORE(&r->desiredState, GDH_FWD_INERT);       /* nothing keeps counting for a dead owner (T4 rule C) */
        map_clear_locked(r);                                 /* and no mapping outlives its owner (T5 rule C) */
        if (r->padState != GDHR_PAD_NONE && r->padGen == gen) pad = take_locked(r, &spec);
    }
    UNLOCK(r);
    rel(r, spec);
    rel(r, oldOwner);
    return pad;
}

void *gdhr_copy_owner(gdhr *r, uint64_t *gen)
{
    if (gen) *gen = 0;
    if (!ready(r)) return 0;
    LOCK(r);
    void *p = r->owner;
    if (p) { r->ops->retain(p); if (gen) *gen = r->ownerGen; }
    UNLOCK(r);
    return p;
}

/* ------------------------------------------------------------------------------------------------------------- */
/* Pad slot */

int gdhr_pad_stage(gdhr *r, uint64_t gen, void *spec, uint32_t specCrc)
{
    if (!ready(r)) return GDHR_E_STATE;
    if (!spec || !gen) return GDHR_E_ARG;
    int rc;
    LOCK(r);
    if (!r->owner || r->ownerGen != gen) rc = GDHR_E_NOT_OWNER;
    else if (r->padState != GDHR_PAD_NONE) rc = GDHR_E_BUSY;
    else {
        r->ops->retain(spec);
        r->padSpec = spec;
        r->padSpecCrc = specCrc;
        r->padGen = gen;
        r->padState = GDHR_PAD_STAGED;
        rc = GDHR_OK;
    }
    UNLOCK(r);
    return rc;
}

int gdhr_pad_unstage(gdhr *r, uint64_t gen)
{
    if (!ready(r)) return GDHR_E_STATE;
    void *spec = 0;
    int rc = GDHR_OK;
    LOCK(r);
    if (r->padState == GDHR_PAD_STAGED) {
        if (r->padGen != gen) rc = GDHR_E_NOT_OWNER;
        else { void *none = take_locked(r, &spec); (void)none; }
    }
    UNLOCK(r);
    rel(r, spec);
    return rc;
}

int gdhr_pad_begin_create(gdhr *r, uint64_t gen)
{
    if (!ready(r)) return GDHR_E_STATE;
    int rc;
    LOCK(r);
    if (!r->owner || r->ownerGen != gen || r->padGen != gen) rc = (r->padState == GDHR_PAD_NONE) ? GDHR_E_STATE : GDHR_E_NOT_OWNER;
    else if (r->padState != GDHR_PAD_STAGED) rc = GDHR_E_STATE;
    else { r->padState = GDHR_PAD_CREATING; rc = GDHR_OK; }
    UNLOCK(r);
    return rc;
}

void *gdhr_pad_copy_spec(gdhr *r)
{
    if (!ready(r)) return 0;
    LOCK(r);
    void *p = 0;
    if (r->padState == GDHR_PAD_CREATING || r->padState == GDHR_PAD_LIVE) {
        p = r->padSpec;
        if (p) r->ops->retain(p);
    }
    UNLOCK(r);
    return p;
}

int gdhr_pad_started(gdhr *r, void *pad)
{
    if (!ready(r) || !pad) return GDHR_E_STATE;
    int rc;
    LOCK(r);
    if (r->padState != GDHR_PAD_CREATING || r->pad) rc = GDHR_E_STATE;
    else {
        r->ops->retain(pad);
        r->pad = pad;
        r->padState = GDHR_PAD_LIVE;
        ATOMIC_STORE(&r->padSource, GDHR_SRC_UC);
        rc = GDHR_OK;
    }
    UNLOCK(r);
    return rc;
}

void gdhr_pad_stopped(gdhr *r, void *pad)
{
    if (!ready(r)) return;
    void *old = 0, *spec = 0;
    LOCK(r);
    if (r->pad && r->pad == pad) old = take_locked(r, &spec);
    UNLOCK(r);
    rel(r, spec);
    rel(r, old);
}

void *gdhr_pad_take(gdhr *r, uint64_t gen, int *rc)
{
    if (rc) *rc = GDHR_OK;
    if (!ready(r)) { if (rc) *rc = GDHR_E_STATE; return 0; }
    void *pad = 0, *spec = 0;
    LOCK(r);
    if (r->padState != GDHR_PAD_NONE) {
        if (gen && r->padGen != gen) { if (rc) *rc = GDHR_E_NOT_OWNER; }
        else pad = take_locked(r, &spec);
    }
    UNLOCK(r);
    rel(r, spec);
    return pad;
}

int gdhr_pad_is(gdhr *r, void *pad)
{
    if (!ready(r) || !pad) return 0;
    LOCK(r);
    int yes = (r->padState == GDHR_PAD_LIVE && r->pad == pad);
    UNLOCK(r);
    return yes;
}

int gdhr_pad_classify(gdhr *r, void *pad, uint64_t gen)
{
    if (!ready(r)) return GDHR_CLS_NONE;
    int cls = GDHR_CLS_NONE;
    LOCK(r);
    if (pad && r->padState == GDHR_PAD_LIVE && r->pad == pad) cls = GDHR_CLS_LIVE;
    else if (r->padState == GDHR_PAD_CREATING && r->padGen == gen && r->ownerGen == gen) cls = GDHR_CLS_CREATING;
    UNLOCK(r);
    return cls;
}

void *gdhr_copy_pad(gdhr *r)
{
    if (!ready(r)) return 0;
    LOCK(r);
    void *p = r->pad;
    if (p) r->ops->retain(p);
    UNLOCK(r);
    return p;
}

uint32_t gdhr_pad_state(gdhr *r)
{
    if (!ready(r)) return GDHR_PAD_NONE;
    LOCK(r);
    uint32_t s = r->padState;
    UNLOCK(r);
    return s;
}

/* ------------------------------------------------------------------------------------------------------------- */
/* Atomic words */

uint32_t gdhr_pad_source(const gdhr *r)
{
    return r ? ATOMIC_LOAD(&r->padSource) : GDHR_SRC_NONE;
}

uint32_t gdhr_desired_state(const gdhr *r)
{
    return r ? ATOMIC_LOAD(&r->desiredState) : 0;
}

void gdhr_ctr_add(gdhr *r, int id, uint64_t n)
{
    if (r && id >= 0 && id < GDHR_CTR_COUNT) __atomic_fetch_add(&r->counters[id], n, __ATOMIC_RELAXED);
}

uint64_t gdhr_ctr_get(const gdhr *r, int id)
{
    return (r && id >= 0 && id < GDHR_CTR_COUNT) ? __atomic_load_n(&r->counters[id], __ATOMIC_RELAXED) : 0;
}

/* ------------------------------------------------------------------------------------------------------------- */
/* Receiver tap (T4) */

int gdhr_register_tap(gdhr *r, void *tap, void *queue, uint32_t pid, uint32_t *desired)
{
    if (desired) *desired = GDH_FWD_INERT;
    if (!ready(r) || !tap || !queue) return 0;
    void *oldTap = 0, *oldQueue = 0;
    r->ops->retain(tap);
    r->ops->retain(queue);
    LOCK(r);
    oldTap = r->tap;
    oldQueue = r->tapQueue;
    r->tap = tap;
    r->tapQueue = queue;
    ATOMIC_STORE(&r->tapOpened, 0);
    ATOMIC_STORE(&r->tapApplied, GDH_FWD_INERT);
    ATOMIC_STORE(&r->tapTranslating, 0);
    ATOMIC_STORE(&r->tapAppliedRevision, 0);
    ATOMIC_STORE(&r->tapPowered, 1);
    ATOMIC_STORE(&r->tapPid, pid);
    ATOMIC_STORE(&r->tapPresent, 1);
    if (desired) *desired = ATOMIC_LOAD(&r->desiredState);
    UNLOCK(r);
    rel(r, oldTap);
    rel(r, oldQueue);
    return oldTap != 0;
}

void gdhr_unregister_tap(gdhr *r, void *tap)
{
    if (!ready(r)) return;
    void *oldTap = 0, *oldQueue = 0;
    LOCK(r);
    if (r->tap && r->tap == tap) {
        oldTap = r->tap;
        oldQueue = r->tapQueue;
        r->tap = 0;
        r->tapQueue = 0;
        ATOMIC_STORE(&r->tapPresent, 0);
        ATOMIC_STORE(&r->tapOpened, 0);
        ATOMIC_STORE(&r->tapApplied, GDH_FWD_INERT);
        ATOMIC_STORE(&r->tapTranslating, 0);
        ATOMIC_STORE(&r->tapAppliedRevision, 0);
    }
    UNLOCK(r);
    rel(r, oldTap);
    rel(r, oldQueue);
}

void *gdhr_copy_tap(gdhr *r, void **queueOut)
{
    if (queueOut) *queueOut = 0;
    if (!ready(r)) return 0;
    LOCK(r);
    void *t = r->tap;
    if (t) {
        r->ops->retain(t);
        if (r->tapQueue) { r->ops->retain(r->tapQueue); if (queueOut) *queueOut = r->tapQueue; else rel(r, r->tapQueue); }
    }
    UNLOCK(r);
    return t;
}

int gdhr_tap_is(gdhr *r, void *tap)
{
    if (!ready(r) || !tap) return 0;
    LOCK(r);
    int yes = (r->tap == tap);
    UNLOCK(r);
    return yes;
}

void gdhr_tap_publish(gdhr *r, void *tap, uint32_t opened, uint32_t applied)
{
    if (!ready(r)) return;
    LOCK(r);
    if (r->tap && r->tap == tap) {
        ATOMIC_STORE(&r->tapOpened, opened);
        ATOMIC_STORE(&r->tapApplied, applied);
    }
    UNLOCK(r);
}

void gdhr_tap_set_power(gdhr *r, void *tap, uint32_t powered, uint32_t flags)
{
    if (!ready(r)) return;
    LOCK(r);
    if (r->tap && r->tap == tap) {
        ATOMIC_STORE(&r->tapPowered, powered);
        ATOMIC_STORE(&r->tapLastPowerFlags, flags);
    }
    UNLOCK(r);
}

void gdhr_set_desired(gdhr *r, uint32_t state)
{
    if (r) ATOMIC_STORE(&r->desiredState, state);
}

/* ------------------------------------------------------------------------------------------------------------- */
/* T5: the mapping handoff. Writers hold the registry lock; the tap reads lock-free (seqlock). */

static void map_store_locked(gdhr *r, const void *bytes, uint32_t len, uint32_t revision, uint32_t crc)
{
    uint32_t seq = __atomic_load_n(&r->mapSeq, __ATOMIC_RELAXED);        /* even: only writers change it, and they hold the lock */
    uint32_t i;
    const unsigned char *src = (const unsigned char *)bytes;
    __atomic_store_n(&r->mapSeq, seq + 1, __ATOMIC_RELAXED);             /* odd: a write is in progress */
    __atomic_thread_fence(__ATOMIC_RELEASE);
    for (i = 0; i < GDH_MAP_WORDS; i++) {
        uint64_t w = 0;
        uint32_t k;
        for (k = 0; k < 8; k++) {
            uint32_t at = i * 8 + k;
            if (src && at < len) w |= (uint64_t)src[at] << (8 * k);
        }
        __atomic_store_n(&r->mapWords[i], w, __ATOMIC_RELAXED);
    }
    __atomic_store_n(&r->mapLen, len, __ATOMIC_RELAXED);
    __atomic_store_n(&r->mapRevision, revision, __ATOMIC_RELAXED);
    __atomic_store_n(&r->mapSpecCrc, crc, __ATOMIC_RELAXED);
    __atomic_store_n(&r->mapSeq, seq + 2, __ATOMIC_RELEASE);             /* even again: the new content is complete */
}

static void map_clear_locked(gdhr *r)
{
    if (__atomic_load_n(&r->mapLen, __ATOMIC_RELAXED) == 0) return;      /* nothing to drop: no needless change of mapSeq */
    map_store_locked(r, 0, 0, 0, 0);
}

int gdhr_map_publish(gdhr *r, void *uc, const void *bytes, uint32_t len, uint32_t revision, uint32_t specCrc)
{
    if (!ready(r) || !uc || !bytes) return GDHR_E_STATE;
    if (len == 0 || len > GDH_MAP_MAX) return GDHR_E_SIZE;
    int rc;
    LOCK(r);
    if (!r->owner || r->owner != uc) rc = GDHR_E_NOT_OWNER;
    else if (r->padState != GDHR_PAD_LIVE) rc = GDHR_E_NO_PAD;
    else if (r->padSpecCrc != specCrc) rc = GDHR_E_SPEC;
    else { map_store_locked(r, bytes, len, revision, specCrc); rc = GDHR_OK; }
    UNLOCK(r);
    return rc;
}

void gdhr_map_clear(gdhr *r)
{
    if (!ready(r)) return;
    LOCK(r);
    map_clear_locked(r);
    UNLOCK(r);
}

uint32_t gdhr_map_seq(const gdhr *r)
{
    return r ? __atomic_load_n(&r->mapSeq, __ATOMIC_ACQUIRE) : 0;
}

int gdhr_map_read(const gdhr *r, void *out, uint32_t cap, uint32_t *len, uint32_t *seq, uint32_t *revision, uint32_t *specCrc)
{
    int tries;
    if (!r || !out) return 0;
    for (tries = 0; tries < 4; tries++) {
        uint32_t s1 = __atomic_load_n(&r->mapSeq, __ATOMIC_ACQUIRE);
        if (s1 & 1u) continue;
        uint32_t n = __atomic_load_n(&r->mapLen, __ATOMIC_RELAXED);
        uint32_t rev = __atomic_load_n(&r->mapRevision, __ATOMIC_RELAXED);
        uint32_t crc = __atomic_load_n(&r->mapSpecCrc, __ATOMIC_RELAXED);
        uint32_t i;
        unsigned char *dst = (unsigned char *)out;
        uint32_t take = n <= cap ? n : cap;
        for (i = 0; i * 8 < take; i++) {
            uint64_t w = __atomic_load_n(&r->mapWords[i], __ATOMIC_RELAXED);
            uint32_t k;
            for (k = 0; k < 8 && i * 8 + k < take; k++) dst[i * 8 + k] = (unsigned char)(w >> (8 * k));
        }
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        if (__atomic_load_n(&r->mapSeq, __ATOMIC_RELAXED) == s1) {
            if (n > cap) return 0;                                       /* cannot happen for a mapping we published; never trust it */
            if (len) *len = n;
            if (seq) *seq = s1;
            if (revision) *revision = rev;
            if (specCrc) *specCrc = crc;
            return 1;
        }
    }
    return 0;
}

int gdhr_selftest_begin(gdhr *r)
{
    uint32_t expected = GDHR_SELFTEST_NOT_RUN;
    if (!r) return 0;
    return __atomic_compare_exchange_n(&r->selfTest, &expected, GDHR_SELFTEST_RUNNING, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
}

void gdhr_selftest_finish(gdhr *r, int pass)
{
    if (r) __atomic_store_n(&r->selfTest, pass ? GDHR_SELFTEST_PASS : GDHR_SELFTEST_FAIL, __ATOMIC_RELEASE);
}

uint32_t gdhr_selftest_get(const gdhr *r)
{
    return r ? __atomic_load_n(&r->selfTest, __ATOMIC_ACQUIRE) : GDHR_SELFTEST_NOT_RUN;
}

int gdhr_is_owner(gdhr *r, void *uc)
{
    int is;
    if (!ready(r) || !uc) return 0;
    LOCK(r);
    is = (r->owner && r->owner == uc) ? 1 : 0;
    UNLOCK(r);
    return is;
}

void gdhr_tap_publish_xlate(gdhr *r, void *tap, uint32_t appliedRevision, uint32_t translating)
{
    if (!ready(r)) return;
    LOCK(r);
    if (r->tap && r->tap == tap) {
        ATOMIC_STORE(&r->tapAppliedRevision, appliedRevision);
        ATOMIC_STORE(&r->tapTranslating, translating);
    }
    UNLOCK(r);
}

int gdhr_set_desired_if_owner(gdhr *r, void *uc, uint32_t state)
{
    if (!ready(r) || !uc) return GDHR_E_STATE;
    int rc;
    LOCK(r);
    if (r->owner && r->owner == uc) { ATOMIC_STORE(&r->desiredState, state); rc = GDHR_OK; }
    else rc = GDHR_E_NOT_OWNER;
    UNLOCK(r);
    return rc;
}

void gdhr_set_last_error(gdhr *r, uint32_t err)
{
    if (r) __atomic_store_n(&r->lastError, err, __ATOMIC_RELAXED);
}

void gdhr_set_terminating(gdhr *r)
{
    if (r) ATOMIC_STORE(&r->terminating, 1);
}

void gdhr_clear_terminating(gdhr *r)
{
    if (r) ATOMIC_STORE(&r->terminating, 0);
}

uint32_t gdhr_terminating(const gdhr *r)
{
    return r ? ATOMIC_LOAD(&r->terminating) : 0;
}

int gdh_fwd_validate(uint64_t state, uint64_t flags)
{
    if (flags != 0) return 1;
    return (state == GDH_FWD_INERT || state == GDH_FWD_COUNT || state == GDH_FWD_SHADOW) ? 0 : 1;
}

int gdh_tap_decide(uint32_t desired, uint32_t opened, uint32_t powered, uint32_t stopping, uint32_t retryDue)
{
    int armed = (desired == GDH_FWD_COUNT || desired == GDH_FWD_SHADOW);     /* the interface is open in COUNT and in SHADOW */
    if (stopping) return opened ? GDH_TAP_CLOSE : GDH_TAP_NONE;
    if (opened) return armed ? GDH_TAP_NONE : GDH_TAP_CLOSE;
    if (armed && powered && retryDue) return GDH_TAP_OPEN;
    return GDH_TAP_NONE;
}

int gdh_tap_fast_tick(uint32_t desired, uint32_t opened, uint32_t powered, uint32_t stopping, uint32_t terminating)
{
    if (terminating) return 1;
    return gdh_tap_decide(desired, opened, powered, stopping, 1) != GDH_TAP_NONE;
}

int gdh_pool_find(const gdh_pool *p, const void *report)
{
    int i;
    if (!p || !report) return -1;
    for (i = 0; i < GDH_POOL_SLOTS; i++) if (p->buf[i] == report) return i;
    return -1;
}

void gdh_pool_set(gdh_pool *p, int slot, void *buf)
{
    if (p && slot >= 0 && slot < GDH_POOL_SLOTS) { p->buf[slot] = buf; p->inPool[slot] = 0; }
}

void gdh_pool_delivered(gdh_pool *p, int slot)
{
    if (p && slot >= 0 && slot < GDH_POOL_SLOTS) p->inPool[slot] = 0;
}

void gdh_pool_added(gdh_pool *p, int slot)
{
    if (p && slot >= 0 && slot < GDH_POOL_SLOTS && p->buf[slot]) p->inPool[slot] = 1;
}

int gdh_pool_next_missing(const gdh_pool *p, int from)
{
    int i;
    if (!p) return -1;
    for (i = from < 0 ? 0 : from; i < GDH_POOL_SLOTS; i++) if (p->buf[i] && !p->inPool[i]) return i;
    return -1;
}

int gdh_pool_reset(gdh_pool *p, void *old[GDH_POOL_SLOTS])
{
    int i, n = 0;
    if (!p) return 0;
    for (i = 0; i < GDH_POOL_SLOTS; i++) {
        if (p->buf[i]) { if (old) old[n] = p->buf[i]; n++; }
        p->buf[i] = 0;
        p->inPool[i] = 0;
    }
    p->ready = 0;
    return n;
}

void gdhr_set_queue_idx(gdhr *r, int which, uint32_t idx)
{
    if (r && which >= 0 && which < 4) __atomic_store_n(&r->queueIdx[which], idx, __ATOMIC_RELAXED);
}

uint32_t gdhr_queue_idx(const gdhr *r, int which)
{
    return (r && which >= 0 && which < 4) ? __atomic_load_n(&r->queueIdx[which], __ATOMIC_RELAXED) : 0;
}

uint32_t gdhr_topology(const gdhr *r)
{
    uint32_t root = gdhr_queue_idx(r, GDHR_Q_ROOT), uc = gdhr_queue_idx(r, GDHR_Q_UC), pad = gdhr_queue_idx(r, GDHR_Q_PAD);
    uint32_t t = 0;
    if (uc && root)  { t |= GDHR_TOPO_UC_EQ_ROOT << GDHR_TOPO_KNOWN_SHIFT;  if (uc == root)  t |= GDHR_TOPO_UC_EQ_ROOT; }
    if (pad && root) { t |= GDHR_TOPO_PAD_EQ_ROOT << GDHR_TOPO_KNOWN_SHIFT; if (pad == root) t |= GDHR_TOPO_PAD_EQ_ROOT; }
    if (pad && uc)   { t |= GDHR_TOPO_PAD_EQ_UC << GDHR_TOPO_KNOWN_SHIFT;   if (pad == uc)   t |= GDHR_TOPO_PAD_EQ_UC; }
    return t;
}

uint32_t gdhr_probe_get(const gdhr *r, int which)
{
    return (r && which >= 0 && which < 2) ? __atomic_load_n(&r->probe[which], __ATOMIC_RELAXED) : 0;
}

int gdhr_probe_once(gdhr *r, int which, uint32_t bits)
{
    if (!r || which < 0 || which > 1) return 0;
    uint32_t expected = 0;
    return __atomic_compare_exchange_n(&r->probe[which], &expected, (bits & 0x7Fu) | GDHR_PROBE_VALID, 0,
                                       __ATOMIC_RELAXED, __ATOMIC_RELAXED);
}

void gdhr_snapshot(gdhr *r, gdhr_snap *out)
{
    int i;
    for (i = 0; i < (int)sizeof(*out); i++) ((unsigned char *)out)[i] = 0;
    if (!ready(r)) return;
    out->nonce = ATOMIC_LOAD(&r->nonce);
    out->build = __atomic_load_n(&r->build, __ATOMIC_RELAXED);
    out->pid = __atomic_load_n(&r->pid, __ATOMIC_RELAXED);
    out->desiredState = gdhr_desired_state(r);
    out->topology = gdhr_topology(r);
    out->tapPresent = ATOMIC_LOAD(&r->tapPresent);
    out->tapOpened = ATOMIC_LOAD(&r->tapOpened);
    out->tapApplied = ATOMIC_LOAD(&r->tapApplied);
    out->tapPowered = ATOMIC_LOAD(&r->tapPowered);
    out->tapPid = ATOMIC_LOAD(&r->tapPid);
    out->tapLastPowerFlags = ATOMIC_LOAD(&r->tapLastPowerFlags);
    out->lastError = __atomic_load_n(&r->lastError, __ATOMIC_RELAXED);
    out->selfTest = gdhr_selftest_get(r);
    out->tapTranslating = ATOMIC_LOAD(&r->tapTranslating);
    out->appliedRevision = ATOMIC_LOAD(&r->tapAppliedRevision);
    out->hasMap = __atomic_load_n(&r->mapLen, __ATOMIC_RELAXED) != 0;
    out->acceptedRevision = out->hasMap ? __atomic_load_n(&r->mapRevision, __ATOMIC_RELAXED) : 0;
    out->acceptedSpecCrc = out->hasMap ? __atomic_load_n(&r->mapSpecCrc, __ATOMIC_RELAXED) : 0;
    out->probeExt = gdhr_probe_get(r, GDHR_PROBE_EXT);
    out->probePad = gdhr_probe_get(r, GDHR_PROBE_SUBMIT);
    out->padSource = gdhr_pad_source(r);
    LOCK(r);
    out->padState = r->padState;
    out->padSpecCrc = r->padSpecCrc;
    out->ownerPresent = r->owner != 0;
    out->rootPresent = r->root != 0;
    UNLOCK(r);
    for (i = 0; i < GDHR_CTR_COUNT; i++) out->counters[i] = gdhr_ctr_get(r, i);
}
