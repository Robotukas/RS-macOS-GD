// Root IOService of the GDHub virtual HID dext (design §3.4).
// D2: NewUserClient creates GDHubVirtualHIDUserClient; the single authorized owner is tracked in the registry.
// T3: the root owns the pad. CreatePad/DestroyPad run on the root's queue; the pad's provider is the root, so it
// survives a user client only if someone chooses to keep it (T3 does not: the user client destroys it, G5).
#include "GDHubInternal.h"
#include "GDHubVirtualHID.h"
#include "GDHubVirtualHIDUserClient.h"

struct GDHubVirtualHID_IVars {
    IODispatchQueue * queue;     // retained copy of this service's default queue (for GDH_SYNC at call sites)
};

bool GDHubVirtualHID::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(GDHubVirtualHID_IVars, 1);
    return ivars != nullptr;
}

void GDHubVirtualHID::free()
{
    if (ivars) OSSafeReleaseNULL(ivars->queue);
    IOSafeDeleteNULL(ivars, GDHubVirtualHID_IVars, 1);
    super::free();
}

IODispatchQueue * GDHubRootQueue(GDHubVirtualHID * root)
{
    return (root && root->ivars) ? root->ivars->queue : nullptr;
}

kern_return_t IMPL(GDHubVirtualHID, Start)
{
    kern_return_t kr = Start(provider, SUPERDISPATCH);
    if (kr != kIOReturnSuccess) return kr;
    gdhr * reg = GDHubReg();
    if (!reg) { GDLog("root start: no registry lock"); return kIOReturnNoMemory; }
    if (CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->queue) != kIOReturnSuccess) ivars->queue = nullptr;   // GDH_SYNC just skips
    GDHubProbeStart("root start", GDHR_Q_ROOT, ivars->queue);
    gdhr_set_identity(reg, mach_absolute_time(), (uint32_t)GDHUB_DEXT_BUILD, (uint32_t)getpid());
    if (gdhr_register_root(reg, static_cast<OSObject *>(this))) GDLog("root start: replaced a stale root in the registry");
    kr = RegisterService();
    if (kr != kIOReturnSuccess) {
        gdhr_unregister_root(reg, static_cast<OSObject *>(this));      // Start fails: Stop will not run, so undo here
        GDLog("root start: RegisterService 0x%x", (unsigned)kr);
        return kr;
    }
    GDLog("root start build %u pid=%d", (unsigned)GDHUB_DEXT_BUILD, (int)getpid());
    return kIOReturnSuccess;
}

kern_return_t IMPL(GDHubVirtualHID, Stop)
{
    GDLog("root stop");
    // Children are normally stopped before their provider; this catches a pad that is still registered (belt and braces).
    int rc = 0;
    OSObject * pad = static_cast<OSObject *>(gdhr_pad_take(GDHubReg(), 0, &rc));
    if (pad) {
        GDLog("root stop: terminating the registered pad");
        gdhr_ctr_add(GDHubReg(), GDHR_CTR_PAD_DESTROYS, 1);
        GDHubTerminateAndRelease(pad);
    }
    gdhr_unregister_root(GDHubReg(), static_cast<OSObject *>(this));
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t IMPL(GDHubVirtualHID, NewUserClient)
{
    if (type != GDHUB_USERCLIENT_TYPE) return kIOReturnBadArgument;
    IOService * c = nullptr;
    kern_return_t kr = Create(this, "UserClientProperties", &c);
    if (kr != kIOReturnSuccess) {
        GDLog("NewUserClient: Create failed 0x%x", (unsigned)kr);
        return kr;
    }
    *userClient = OSDynamicCast(IOUserClient, c);
    if (!*userClient) {
        c->release();
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

static kern_return_t fromRegistry(int rc)
{
    switch (rc) {
    case GDHR_OK:          return kIOReturnSuccess;
    case GDHR_E_BUSY:      return kIOReturnBusy;
    case GDHR_E_NOT_OWNER: return kIOReturnNotPermitted;
    case GDHR_E_ARG:       return kIOReturnBadArgument;
    default:               return kIOReturnNotReady;
    }
}

// Runs on the root's default queue. Blocks in Create() while the kernel starts the pad on the pad's queue; the pad's
// handleStart reads the staged spec from the registry and calls nothing else of ours (no cycle: plan 4.2).
// IOService.iig:299-315 does not say whether Create returns before or after the child's Start, so both are handled:
//  - LIVE: the pad registered itself in handleStart before Create returned. Success.
//  - CREATING for this owner: Create returned first. The pad registers itself at the end of handleStart; until then
//    posts are refused (the registry has no pad). Success, and nothing is terminated.
//  - NONE (empty, or another generation or pad): the pad's start was refused or failed. Failure and cleanup.
// A slot stuck in CREATING never wedges anything: destroyDevice (DestroyPad), the user client's Stop (release_owner)
// and this root's Stop all empty it, and a pad that tries to register afterwards is refused by gdhr_pad_started.
kern_return_t IMPL(GDHubVirtualHID, CreatePad)
{
    gdhr * reg = GDHubReg();
    int rc = gdhr_pad_begin_create(reg, ownerGen);
    if (rc != GDHR_OK) { GDLog("CreatePad refused (registry %d)", rc); return fromRegistry(rc); }

    IOService * child = nullptr;
    kern_return_t kr = Create(this, "GDHubPadProperties", &child);
    int cls = (kr == kIOReturnSuccess && child) ? gdhr_pad_classify(reg, static_cast<OSObject *>(child), ownerGen) : GDHR_CLS_NONE;
    if (cls == GDHR_CLS_CREATING) {
        GDLog("CreatePad: Create returned before the pad started");
        gdhr_ctr_add(reg, GDHR_CTR_CREATE_EARLY, 1);
        child->release();                      // Create's +1; the pad now owns its own registration
        return kIOReturnSuccess;
    }
    if (cls != GDHR_CLS_LIVE) {
        GDLog("CreatePad: Create(GDHubPadProperties) failed 0x%x child=%d", (unsigned)kr, (int)(child != nullptr));
        gdhr_ctr_add(reg, GDHR_CTR_CREATE_FAILS, 1);
        // Empty the slot if it is still ours (a stale generation is left alone). A pad that exists but never registered,
        // or that registered and then failed a later Start step, is terminated; Create's +1 is dropped either way.
        GDHubTerminateAndRelease(static_cast<OSObject *>(gdhr_pad_take(reg, ownerGen, &rc)));
        GDHubTerminateAndRelease(child);
        return kr != kIOReturnSuccess ? kr : kIOReturnError;
    }
    child->release();                          // the registry holds its own reference to a started pad
    return kIOReturnSuccess;
}

// Runs on the root's default queue. Order (plan 6.3): padSource = NONE, registry pointer cleared (both inside
// gdhr_pad_take), then Terminate. A destroy without a pad is a successful no-op; a stale generation is refused.
kern_return_t IMPL(GDHubVirtualHID, DestroyPad)
{
    gdhr * reg = GDHubReg();
    int rc = GDHR_OK;
    OSObject * pad = static_cast<OSObject *>(gdhr_pad_take(reg, ownerGen, &rc));
    if (!pad) return fromRegistry(rc);
    gdhr_ctr_add(reg, GDHR_CTR_PAD_DESTROYS, 1);
    GDHubTerminateAndRelease(pad);
    return kIOReturnSuccess;
}
