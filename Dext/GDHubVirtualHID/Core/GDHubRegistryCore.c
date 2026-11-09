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

void gdhr_snapshot(gdhr *r, gdhr_snap *out)
{
    int i;
    for (i = 0; i < (int)sizeof(*out); i++) ((unsigned char *)out)[i] = 0;
    if (!ready(r)) return;
    out->nonce = ATOMIC_LOAD(&r->nonce);
    out->build = __atomic_load_n(&r->build, __ATOMIC_RELAXED);
    out->pid = __atomic_load_n(&r->pid, __ATOMIC_RELAXED);
    out->desiredState = gdhr_desired_state(r);
    out->padSource = gdhr_pad_source(r);
    LOCK(r);
    out->padState = r->padState;
    out->padSpecCrc = r->padSpecCrc;
    out->ownerPresent = r->owner != 0;
    out->rootPresent = r->root != 0;
    UNLOCK(r);
    for (i = 0; i < GDHR_CTR_COUNT; i++) out->counters[i] = gdhr_ctr_get(r, i);
}
