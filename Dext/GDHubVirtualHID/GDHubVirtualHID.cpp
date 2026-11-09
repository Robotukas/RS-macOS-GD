// Root IOService of the GDHub virtual HID dext (design §3.4).
// D2: NewUserClient creates GDHubVirtualHIDUserClient; the single authorized owner is tracked in the registry.
// T3: the root owns the pad. CreatePad/DestroyPad run on the root's queue; the pad's provider is the root, so it
// survives a user client only if someone chooses to keep it (T3 does not: the user client destroys it, G5).
#include "GDHubInternal.h"
#include "GDHubVirtualHID.h"
#include "GDHubVirtualHIDUserClient.h"
#include "GDHubVirtualPad.h"

struct GDHubVirtualHID_IVars {
    IODispatchQueue * queue;     // retained copy of this service's default queue (for GDH_SYNC at call sites)
    IOTimerDispatchSource * orphanTimer;   // T7: fires GDH_ORPHAN_MS after a pinned owner left; created in Start, armed on the root's queue
    OSAction * orphanAction;
    bool stopped;                // atomic: set first thing in Stop
};

bool GDHubVirtualHID::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(GDHubVirtualHID_IVars, 1);
    return ivars != nullptr;
}

void GDHubVirtualHID::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->orphanAction);
        OSSafeReleaseNULL(ivars->orphanTimer);
        OSSafeReleaseNULL(ivars->queue);
    }
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
    // The orphan timer exists from the start (nothing is armed until a pinned owner leaves). A failure here only loses the
    // 30 s cleanup, never the root: the pad would then wait for RELEASE_PAD, the next owner or the process end.
    if (ivars->queue && IOTimerDispatchSource::Create(ivars->queue, &ivars->orphanTimer) == kIOReturnSuccess &&
        CreateActionOrphanFired(0, &ivars->orphanAction) == kIOReturnSuccess &&
        ivars->orphanTimer->SetHandler(ivars->orphanAction) == kIOReturnSuccess) {
        ivars->orphanTimer->SetEnable(true);
    } else {
        GDLog("root start: orphan timer not available");
        OSSafeReleaseNULL(ivars->orphanAction);
        OSSafeReleaseNULL(ivars->orphanTimer);
    }
    gdhr_set_identity(reg, mach_absolute_time(), (uint32_t)GDHUB_DEXT_BUILD, (uint32_t)getpid());
    if (gdhr_register_root(reg, static_cast<OSObject *>(this))) GDLog("root start: replaced a stale root in the registry");
    kr = RegisterService();
    if (kr != kIOReturnSuccess) {
        gdhr_unregister_root(reg, static_cast<OSObject *>(this));      // Start fails: Stop will not run, so undo here
        // The action retains its target (this root) until it is cancelled: without the cancel a failed Start would leak the root.
        if (ivars->orphanTimer) ivars->orphanTimer->SetEnable(false);
        if (ivars->orphanAction) ivars->orphanAction->Cancel(^{});
        OSSafeReleaseNULL(ivars->orphanAction);
        OSSafeReleaseNULL(ivars->orphanTimer);
        GDLog("root start: RegisterService 0x%x", (unsigned)kr);
        return kr;
    }
    GDLog("root start build %u pid=%d", (unsigned)GDHUB_DEXT_BUILD, (int)getpid());
    return kIOReturnSuccess;
}

kern_return_t IMPL(GDHubVirtualHID, Stop)
{
    GDLog("root stop");
    __atomic_store_n(&ivars->stopped, true, __ATOMIC_RELAXED);
    // Children are normally stopped before their provider; this catches a pad that is still registered (belt and braces).
    int rc = 0;
    OSObject * pad = static_cast<OSObject *>(gdhr_pad_take(GDHubReg(), 0, &rc));
    if (pad) {
        GDLog("root stop: terminating the registered pad");
        gdhr_ctr_add(GDHubReg(), GDHR_CTR_PAD_DESTROYS, 1);
        GDHubTerminateAndRelease(pad);
    }
    // The tap is not a child of the root, but the process cannot exit while it is alive (IOUserServerOneProcess): end it too.
    gdhr_set_terminating(GDHubReg());
    GDHubTerminateTap();
    gdhr_unregister_root(GDHubReg(), static_cast<OSObject *>(this));
    if (!ivars->orphanTimer) return Stop(provider, SUPERDISPATCH);
    // The timer's cancel callout dereferences the timer's ivars: hold ourselves and finish the super Stop from the handler
    // (the same documented pattern as the user client and the tap).
    ivars->orphanTimer->SetEnable(false);
    this->retain();
    ivars->orphanTimer->Cancel(^{
        if (ivars->orphanAction) ivars->orphanAction->Cancel(^{});
        Stop(provider, SUPERDISPATCH);
        this->release();
    });
    return kIOReturnSuccess;
}

static uint64_t nsToTicksRoot(uint64_t ns)
{
    mach_timebase_info_data_t tb = {0, 0};
    mach_timebase_info(&tb);
    return tb.numer == 0 ? ns : ns * tb.denom / tb.numer;
}

// Arms (or re-arms) the orphan timer. Root queue only. When it fires is decided by one pure function (gdh_orphan_arm_time): with a
// client connected as owner at most every 30 s (a timer that fires at once and cannot remove the pad would loop on this queue;
// the client has 30 s past the deadline to adopt, replace or release the pad, and then the forced removal takes it:
// gdh_orphan_owner_overstay), otherwise the later of the registry's deadline and now + `graceTicks`. Callers: a pinned owner leaving
// (grace 0: the 30 s deadline), an owner leaving without having adopted an orphan (grace 5 s: the pad's deadline may be long past and
// the next owner, usually a restarting engine, gets a moment), and the timer itself when the deadline moved.
static void armOrphan(GDHubVirtualHID * root, uint64_t graceTicks)
{
    auto iv = root->ivars;
    if (!iv->orphanTimer || __atomic_load_n(&iv->stopped, __ATOMIC_RELAXED)) return;
    gdhr * reg = GDHubReg();
    uint64_t at = gdh_orphan_arm_time(gdhr_pad_orphaned(reg), gdhr_owner_present(reg), gdhr_orphan_deadline(reg), mach_absolute_time(), graceTicks,
                                      nsToTicksRoot((uint64_t)GDH_ORPHAN_MS * 1000000ull));
    if (at == 0) return;
    iv->orphanTimer->WakeAtTime(kIOTimerClockMachAbsoluteTime, at, 1000000);                // 1 ms is plenty for a 30 s timer
}

void GDHubOrphanArm(uint64_t graceNs)
{
    GDHubVirtualHID * root = GDHubCopyRoot();
    IODispatchQueue * q = root ? GDHubRootQueue(root) : nullptr;
    if (!root || !q) { if (root) root->release(); return; }
    uint64_t grace = nsToTicksRoot(graceNs);
    q->DispatchAsync(^{                       // the timer is armed on its own queue; the block owns the root reference
        armOrphan(root, grace);
        root->release();
    });
}

// The pad nobody drives or owns any more goes through the same steps as every destroy: source UC, neutral, INERT, destroy.
static void orphanDestroy(const char * why, bool force)
{
    gdhr * reg = GDHubReg();
    GDHubVirtualPad * pad = GDHubCopyPad();
    if (pad) {
        GDH_SYNC(GDHR_RANK_ROOT, GDHR_RANK_PAD, GDHubPadQueue(pad), "postNeutralFrom(orphan)");
        pad->postNeutralFrom(GDHUB_PADSRC_UC, 0, GDHUB_NEUTRAL_ORPHAN);
        pad->release();
    }
    GDHubPokeTap();                                         // INERT: the tap closes the interface
    // `force`: the callers that remove an orphan on purpose (selector 1, selector 12 with another spec, RELEASE_PAD) run with a client
    // connected as owner, and that client never owned this pad, so the plain finish (which needs no owner) would leave it in place.
    OSObject * left = static_cast<OSObject *>(force ? gdhr_orphan_force_finish(reg) : gdhr_orphan_finish(reg));
    if (left) {
        GDLog("orphan: %{public}s: the unowned pinned pad is removed", why);
        gdhr_ctr_add(reg, GDHR_CTR_PAD_DESTROYS, 1);
        GDHubTerminateAndRelease(left);
    }
}

void GDHubOrphanForceDestroy(const char * why)
{
    if (gdhr_orphan_force_begin(GDHubReg())) orphanDestroy(why, true);
}

void IMPL(GDHubVirtualHID, OrphanFired)
{
    (void)action; (void)time;
    if (__atomic_load_n(&ivars->stopped, __ATOMIC_RELAXED)) return;
    gdhr * reg = GDHubReg();
    uint64_t now = mach_absolute_time();
    if (gdhr_orphan_begin(reg, now)) orphanDestroy("30 s without an owner", false);
    else if (gdh_orphan_owner_overstay(gdhr_pad_orphaned(reg), gdhr_owner_present(reg), gdhr_orphan_deadline(reg), now,
                                       nsToTicksRoot((uint64_t)GDH_ORPHAN_MS * 1000000ull)))
        GDHubOrphanForceDestroy("a client has been connected for 30 s past the deadline without adopting the pad");   // logs once, in orphanDestroy
    else armOrphan(this, 0);        // not due yet (the deadline moved), or a client is connected: look again 30 s on
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
