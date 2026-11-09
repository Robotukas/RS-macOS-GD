// Process-global registry of the dext (receiver-takeover plan 4.3): typed wrappers over Core/GDHubRegistryCore.c.
//
// Rules this file keeps:
//  - It calls no method of GDHubVirtualHID, GDHubVirtualHIDUserClient or GDHubVirtualPad except where a function
//    below says so (Terminate on an object it was handed, outside any lock; accessors that read an ivar of an object
//    the caller has retained). The registry lock is private to the core, so no RPC can run under it.
//  - Every Copy function returns +1. The registry's own reference keeps the object alive until the pointer is cleared
//    under the same lock, so the retain in the accessor can never race the final release.
#include "GDHubInternal.h"
#include "GDHubVirtualHID.h"
#include "GDHubVirtualHIDUserClient.h"
#include "GDHubVirtualPad.h"
#include "GDHubReceiverTap.h"

static void * opLockNew(void)               { return IOLockAlloc(); }
static void   opLockFree(void * l)          { IOLockFree(static_cast<IOLock *>(l)); }
static void   opLock(void * l)              { IOLockLock(static_cast<IOLock *>(l)); }
static void   opUnlock(void * l)            { IOLockUnlock(static_cast<IOLock *>(l)); }
static void   opRetain(void * o)            { static_cast<OSObject *>(o)->retain(); }
static void   opRelease(void * o)           { static_cast<OSObject *>(o)->release(); }

static const gdhr_ops kOps = { opLockNew, opLockFree, opLock, opUnlock, opRetain, opRelease };
static gdhr           sRegistry;            // constant-initialised (all zero); the lock is installed on first use

gdhr * GDHubReg(void)
{
    return gdhr_ensure(&sRegistry, &kOps) ? &sRegistry : nullptr;
}

// The hot accessor (every post). The pad slot only ever holds a GDHubVirtualPad (gdhr_pad_started is called from its
// handleStart and from nowhere else), so a static downcast replaces the per-post metaclass walk of OSDynamicCast.
GDHubVirtualPad * GDHubCopyPad(void)
{
    return static_cast<GDHubVirtualPad *>(static_cast<OSObject *>(gdhr_copy_pad(GDHubReg())));
}

GDHubVirtualHID * GDHubCopyRoot(void)
{
    return OSDynamicCast(GDHubVirtualHID, static_cast<OSObject *>(gdhr_copy_root(GDHubReg())));
}

GDHubVirtualHIDUserClient * GDHubCopyOwner(uint64_t * gen)
{
    return OSDynamicCast(GDHubVirtualHIDUserClient, static_cast<OSObject *>(gdhr_copy_owner(GDHubReg(), gen)));
}

OSData * GDHubCopyPadSpec(void)
{
    return OSDynamicCast(OSData, static_cast<OSObject *>(gdhr_pad_copy_spec(GDHubReg())));
}

uint64_t GDHubClaimOwner(GDHubVirtualHIDUserClient * uc)
{
    return gdhr_claim_owner(GDHubReg(), static_cast<OSObject *>(uc));
}

void GDHubTerminateAndRelease(OSObject * service)
{
    if (!service) return;
    IOService * s = OSDynamicCast(IOService, service);
    if (s) s->Terminate(0);                      // asynchronous; the object's own Stop runs later on its own queue
    service->release();
}

void GDHubReleaseOwner(GDHubVirtualHIDUserClient * uc)
{
    // The core hands back the owner's pad if it is still registered ("no pad outlives its owner"); terminate it here,
    // outside the registry lock.
    OSObject * left = static_cast<OSObject *>(gdhr_release_owner(GDHubReg(), static_cast<OSObject *>(uc)));
    GDHubPokeTap();                       // the core reset the desired state to INERT with the owner; the tap closes the interface (rule C)
    if (left) {
        GDLog("owner released with a pad still registered: terminating it");
        gdhr_ctr_add(GDHubReg(), GDHR_CTR_PAD_DESTROYS, 1);
        GDHubTerminateAndRelease(left);
    }
}

// A GDH_SYNC call whose target queue was already on this thread's queue stack: an inline nested call, counted in
// syncInline and logged once per call site (`seenOnce` is that call site's static flag).
void GDHubSyncInline(const char * what, uint32_t * seenOnce)
{
    gdhr_ctr_add(GDHubReg(), GDHR_CTR_SYNC_INLINE, 1);
    if (__atomic_exchange_n(seenOnce, 1u, __ATOMIC_RELAXED) == 0) GDLog("sync inline (first at this site): %{public}s runs on the target's queue", what);
}

// ---------------------------------------------------------------------------------------------------------------
// Topology probe. Queue objects are identified by a process-local index in first-seen order (1..14; 15 = table full); the
// pointers are used for equality only, never dereferenced here.

uint32_t GDHubQueueIndex(IODispatchQueue * q)
{
    static void * sSeen[14];
    if (!q) return 0;
    for (uint32_t i = 0; i < 14; i++) {
        void * cur = __atomic_load_n(&sSeen[i], __ATOMIC_ACQUIRE);
        if (cur == nullptr) {
            void * expected = nullptr;
            if (__atomic_compare_exchange_n(&sSeen[i], &expected, (void *)q, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) return i + 1;
            cur = expected;
        }
        if (cur == (void *)q) return i + 1;
    }
    return 15;
}

// OnQueue() of the root, user-client and pad queues on this thread right now. `own` is the caller's own queue (its object
// may not be registered yet); the others come from the registry as +1 copies.
static uint32_t probeBits(int ownWhich, IODispatchQueue * ownQueue)
{
    uint32_t bits = 0;
    IODispatchQueue * q;
    GDHubVirtualHID * root = ownWhich == GDHR_Q_ROOT ? nullptr : GDHubCopyRoot();
    q = ownWhich == GDHR_Q_ROOT ? ownQueue : GDHubRootQueue(root);
    if (q && q->OnQueue()) bits |= GDHR_PROBE_ROOT;
    if (root) root->release();
    GDHubVirtualHIDUserClient * uc = ownWhich == GDHR_Q_UC ? nullptr : GDHubCopyOwner(nullptr);
    q = ownWhich == GDHR_Q_UC ? ownQueue : GDHubUCQueue(uc);
    if (q && q->OnQueue()) bits |= GDHR_PROBE_UC;
    if (uc) uc->release();
    GDHubVirtualPad * pad = ownWhich == GDHR_Q_PAD ? nullptr : GDHubCopyPad();
    q = ownWhich == GDHR_Q_PAD ? ownQueue : GDHubPadQueue(pad);
    if (q && q->OnQueue()) bits |= GDHR_PROBE_PAD;
    if (pad) pad->release();
    return bits;
}

static void probeLog(const char * where, uint32_t bits)
{
    gdhr * r = GDHubReg();
    // Worst case 134 characters by the generic estimator (a string counted as 24, six %u at 10); about 71 in practice.
    GDLog("topo %{public}s: rootq=%u ucq=%u padq=%u onq root/uc/pad=%u/%u/%u", where, gdhr_queue_idx(r, GDHR_Q_ROOT),
          gdhr_queue_idx(r, GDHR_Q_UC), gdhr_queue_idx(r, GDHR_Q_PAD), (bits & GDHR_PROBE_ROOT) != 0,
          (bits & GDHR_PROBE_UC) != 0, (bits & GDHR_PROBE_PAD) != 0);
}

void GDHubProbeStart(const char * where, int which, IODispatchQueue * ownQueue)
{
    gdhr_set_queue_idx(GDHubReg(), which, GDHubQueueIndex(ownQueue));
    probeLog(where, probeBits(which, ownQueue));
}

void GDHubProbeFirst(int probe, const char * where, int which, IODispatchQueue * ownQueue)
{
    gdhr * r = GDHubReg();
    if (gdhr_probe_get(r, probe) != 0) return;                         // the only per-call cost: one relaxed load
    uint32_t bits = probeBits(which, ownQueue);
    if (gdhr_probe_once(r, probe, bits)) probeLog(where, bits);
}

// Called from the root's queue (selector 9, user client Stop). The tap and its queue are +1 copies; the block owns the tap
// reference and releases it on the tap's queue. DispatchAsync (IODispatchQueue.iig:132-133) never waits.
void GDHubPokeTap(void)
{
    void * q = nullptr;
    OSObject * t = static_cast<OSObject *>(gdhr_copy_tap(GDHubReg(), &q));
    IODispatchQueue * queue = static_cast<IODispatchQueue *>(q);
    if (!t || !queue) {
        if (t) t->release();
        if (queue) queue->release();
        return;
    }
    GDHubReceiverTap * tap = static_cast<GDHubReceiverTap *>(t);
    queue->DispatchAsync(^{
        GDHubTapApply(tap);
        tap->release();
    });
    queue->release();
}

void GDHubTerminateTap(void)
{
    void * q = nullptr;
    OSObject * t = static_cast<OSObject *>(gdhr_copy_tap(GDHubReg(), &q));
    if (q) static_cast<OSObject *>(q)->release();
    GDHubTerminateAndRelease(t);          // asynchronous: the tap's own Stop closes the interface
}

size_t GDHubBuildStatus2(uint8_t * buf, size_t cap)
{
    gdhr * r = GDHubReg();
    gdhr_snap snap;
    gdhr_snapshot(r, &snap);
    gdh_summary hop = {}, hr = {};
    uint32_t windows = 0;
    GDHubVirtualPad * pad = GDHubCopyPad();
    if (pad) {
        GDHubPadReadMeter(pad, &hop, &hr, &windows);
        pad->release();
    }
    gdh_summary k2d = {};
    gdh_status2_extra extra = {};
    uint32_t tapWindows = 0;
    void * q = nullptr;
    GDHubReceiverTap * tap = static_cast<GDHubReceiverTap *>(static_cast<OSObject *>(gdhr_copy_tap(r, &q)));
    if (q) static_cast<OSObject *>(q)->release();
    if (tap) {
        GDHubTapReadMeter(tap, &extra.xlate, &k2d, &tapWindows);
        extra.haveParity = GDHubTapReadParity(tap, &extra.parity) ? 1 : 0;
        tap->release();
    }
    return gdh_status2_pack(buf, cap, &snap, &hop, &hr, windows, &k2d, &extra);
}
