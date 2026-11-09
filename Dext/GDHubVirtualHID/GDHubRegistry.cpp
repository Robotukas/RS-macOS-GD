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
    if (left) {
        GDLog("owner released with a pad still registered: terminating it");
        gdhr_ctr_add(GDHubReg(), GDHR_CTR_PAD_DESTROYS, 1);
        GDHubTerminateAndRelease(left);
    }
}

void GDHubSyncViolation(const char * what, uint32_t callerRank, uint32_t targetRank)
{
    gdhr * r = GDHubReg();
    gdhr_ctr_add(r, GDHR_CTR_SYNC_VIOLATIONS, 1);
    uint64_t n = gdhr_ctr_get(r, GDHR_CTR_SYNC_VIOLATIONS);
    if (n <= 8) GDLog("SYNC VIOLATION #%llu: %{public}s from rank %u to rank %u re-enters a queue we are on", n, what, callerRank, targetRank);
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
    return gdh_status2_pack(buf, cap, &snap, &hop, &hr, windows);
}
