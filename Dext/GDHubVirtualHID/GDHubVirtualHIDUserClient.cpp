// User client of the GDHub virtual HID dext (design §3.4, §3.5, §3.9, §3.10, §3.11).
// D2: hello, heartbeat, registerOutput (stores the completion only), getStatus, Team ID check, single-owner claim,
// watchdog timer. Selectors 1-4 (createDevice ... postNeutral) answer kIOReturnUnsupported until D3.
#include "GDHubInternal.h"
#include "GDHubVirtualHID.h"
#include "GDHubVirtualHIDUserClient.h"

struct GDHubVirtualHIDUserClient_IVars {
    GDHubVirtualHID * root;                         // provider, not retained
    bool authorized, protocolOK, ownsRoot, neutralised, stopped;
    IOLock * lock;                                  // guards spec[], outputAction, outputSeq/Count/Drops
    OSData * spec[GDHUB_SLOT_COUNT];                // retained; immutable while the device exists (D3)
    IOService * device[GDHUB_SLOT_COUNT];           // retained (+1 from Create) (D3)
    IOBufferMemoryDescriptor * postBuffer[GDHUB_SLOT_COUNT];   // capacity GDHUB_MAX_REPORT (D3)
    OSAction * outputAction;                        // retained completion from registerOutput
    uint64_t outputSeq, outputCount, outputDrops, postCount, watchdogFires;
    IODispatchQueue * queue; IOTimerDispatchSource * timer; OSAction * timerAction;
    uint64_t lastActivity, periodTicks, timeoutTicks;
};

// ---------------------------------------------------------------------------------------------------------------
// Team ID check (§3.11)

static bool callerIsGDHub(GDHubVirtualHIDUserClient * self)
{
    OSDictionary * e = nullptr;
    if (self->CopyClientEntitlements(&e) != kIOReturnSuccess || !e) {
        GDLog("hello: caller has no entitlements");
        return false;
    }
    const char * team = OSDictionaryGetStringValue(e, "com.apple.developer.team-identifier");
    const char * app  = OSDictionaryGetStringValue(e, "com.apple.application-identifier");
    bool ok = team && strcmp(team, GDHUB_TEAM_ID) == 0 && (!app || strcmp(app, GDHUB_APP_ID) == 0);
    if (!ok) GDLog("hello: caller team '%{public}s' app '%{public}s'", team ? team : "(none)", app ? app : "(none)");
    e->release();
    return ok;
}

static uint64_t nsToTicks(uint64_t ns)
{
    mach_timebase_info_data_t tb = {0, 0};
    mach_timebase_info(&tb);
    if (tb.numer == 0) return ns;
    return ns * tb.denom / tb.numer;
}

// ---------------------------------------------------------------------------------------------------------------
// Dispatch handlers. The SDK checks counts and sizes (table below) before calling them.

static kern_return_t sHello(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference;
    auto uc = OSRequiredCast(GDHubVirtualHIDUserClient, target);
    auto iv = uc->ivars;
    if (!iv->authorized) {
        if (!callerIsGDHub(uc)) {
            GDLog("hello: refused, caller is not team %{public}s (0x%x)", GDHUB_TEAM_ID, (unsigned)kIOReturnNotPermitted);
            return kIOReturnNotPermitted;
        }
        if (!GDHubRootClaim(iv->root, uc)) {
            GDLog("hello: refused, dext already owned by another client (0x%x)", (unsigned)kIOReturnExclusiveAccess);
            return kIOReturnExclusiveAccess;
        }
        iv->authorized = true;
        iv->ownsRoot = true;
    }
    iv->protocolOK = (a->scalarInput[0] == GDHUB_PROTOCOL_VERSION);
    iv->neutralised = false;
    iv->lastActivity = mach_absolute_time();
    a->scalarOutput[0] = GDHUB_PROTOCOL_VERSION;
    a->scalarOutput[1] = GDHUB_DEXT_BUILD;
    a->scalarOutput[2] = 0;          // capabilities: GDHUB_CAP_PAD arrives with the pad class in D3
    a->scalarOutputCount = 3;
    GDLog("hello: app protocol %llu build %llu, dext protocol %u build %u, protocolOK=%d",
          a->scalarInput[0], a->scalarInput[1], (unsigned)GDHUB_PROTOCOL_VERSION, (unsigned)GDHUB_DEXT_BUILD,
          (int)iv->protocolOK);
    return kIOReturnSuccess;
}

static kern_return_t sNotYet(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)target; (void)reference; (void)a;
    return kIOReturnUnsupported;     // createDevice / destroyDevice / postReport / postNeutral: D3
}

static kern_return_t sHeartbeat(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference; (void)a;
    auto uc = OSRequiredCast(GDHubVirtualHIDUserClient, target);
    uc->ivars->lastActivity = mach_absolute_time();
    return kIOReturnSuccess;
}

static kern_return_t sRegisterOutput(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference;
    auto uc = OSRequiredCast(GDHubVirtualHIDUserClient, target);
    auto iv = uc->ivars;
    OSAction * fresh = a->completion;            // retained by the caller only for the duration of this call
    fresh->retain();
    IOLockLock(iv->lock);
    OSAction * old = iv->outputAction;
    iv->outputAction = fresh;
    IOLockUnlock(iv->lock);
    if (old) old->release();
    GDLog("registerOutput: completion stored");
    return kIOReturnSuccess;
}

static kern_return_t sGetStatus(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference;
    auto uc = OSRequiredCast(GDHubVirtualHIDUserClient, target);
    auto iv = uc->ivars;
    uint64_t mask = 0;
    for (uint32_t s = 0; s < GDHUB_SLOT_COUNT; s++) if (iv->device[s]) mask |= (1ull << s);
    IOLockLock(iv->lock);
    uint64_t outCount = iv->outputCount, outDrops = iv->outputDrops;
    IOLockUnlock(iv->lock);
    a->scalarOutput[0] = mask;
    a->scalarOutput[1] = iv->postCount;
    a->scalarOutput[2] = iv->watchdogFires;
    a->scalarOutput[3] = outCount;
    a->scalarOutput[4] = outDrops;
    a->scalarOutputCount = 5;
    return kIOReturnSuccess;
}

// Positional, in selector order. Columns: function, checkCompletionExists, checkScalarInputCount,
// checkStructureInputSize, checkScalarOutputCount, checkStructureOutputSize.
static const IOUserClientMethodDispatch sMethods[GDHUB_SEL_COUNT] = {
    /* 0 hello          */ { sHello,          0, 2, 0,                                 3, 0 },
    /* 1 createDevice   */ { sNotYet,         0, 0, kIOUserClientVariableStructureSize, 0, 0 },
    /* 2 destroyDevice  */ { sNotYet,         0, 1, 0,                                 0, 0 },
    /* 3 postReport     */ { sNotYet,         0, 1, kIOUserClientVariableStructureSize, 0, 0 },
    /* 4 postNeutral    */ { sNotYet,         0, 1, 0,                                 0, 0 },
    /* 5 heartbeat      */ { sHeartbeat,      0, 0, 0,                                 0, 0 },
    /* 6 registerOutput */ { sRegisterOutput, 1, 0, 0,                                 0, 0 },
    /* 7 getStatus      */ { sGetStatus,      0, 0, 0,                                 5, 0 },
};

// ---------------------------------------------------------------------------------------------------------------

bool GDHubVirtualHIDUserClient::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(GDHubVirtualHIDUserClient_IVars, 1);
    if (!ivars) return false;
    ivars->lock = IOLockAlloc();
    return ivars->lock != nullptr;
}

void GDHubVirtualHIDUserClient::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->timerAction);
        OSSafeReleaseNULL(ivars->timer);
        OSSafeReleaseNULL(ivars->queue);
        OSSafeReleaseNULL(ivars->outputAction);
        for (uint32_t s = 0; s < GDHUB_SLOT_COUNT; s++) {
            OSSafeReleaseNULL(ivars->spec[s]);
            OSSafeReleaseNULL(ivars->device[s]);
            OSSafeReleaseNULL(ivars->postBuffer[s]);
        }
        if (ivars->lock) { IOLockFree(ivars->lock); ivars->lock = nullptr; }
    }
    IOSafeDeleteNULL(ivars, GDHubVirtualHIDUserClient_IVars, 1);
    super::free();
}

kern_return_t IMPL(GDHubVirtualHIDUserClient, Start)
{
    kern_return_t kr = Start(provider, SUPERDISPATCH);
    if (kr != kIOReturnSuccess) return kr;
    ivars->root = OSDynamicCast(GDHubVirtualHID, provider);
    if (!ivars->root) {
        GDLog("client start: provider is not the root");
        return kIOReturnBadArgument;
    }
    ivars->periodTicks  = nsToTicks((uint64_t)GDHUB_WATCHDOG_PERIOD_MS * 1000000ull);
    ivars->timeoutTicks = nsToTicks((uint64_t)GDHUB_WATCHDOG_TIMEOUT_MS * 1000000ull);

    kr = CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->queue);
    if (kr != kIOReturnSuccess) { GDLog("client start: CopyDispatchQueue 0x%x", (unsigned)kr); return kr; }
    kr = IOTimerDispatchSource::Create(ivars->queue, &ivars->timer);
    if (kr != kIOReturnSuccess) { GDLog("client start: timer create 0x%x", (unsigned)kr); return kr; }
    kr = CreateActionWatchdogFired(0, &ivars->timerAction);
    if (kr != kIOReturnSuccess) { GDLog("client start: timer action 0x%x", (unsigned)kr); return kr; }
    kr = ivars->timer->SetHandler(ivars->timerAction);
    if (kr != kIOReturnSuccess) { GDLog("client start: timer handler 0x%x", (unsigned)kr); return kr; }
    ivars->timer->SetEnable(true);
    kr = ivars->timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, mach_absolute_time() + ivars->periodTicks,
                                  ivars->periodTicks / 10);
    if (kr != kIOReturnSuccess) { GDLog("client start: timer arm 0x%x", (unsigned)kr); return kr; }
    GDLog("client start (watchdog armed: period %u ms, timeout %u ms)",
          (unsigned)GDHUB_WATCHDOG_PERIOD_MS, (unsigned)GDHUB_WATCHDOG_TIMEOUT_MS);
    return kIOReturnSuccess;
}

kern_return_t IMPL(GDHubVirtualHIDUserClient, Stop)
{
    GDLog("client stop (owner=%d posts=%llu watchdogFires=%llu)", (int)ivars->ownsRoot, ivars->postCount,
          ivars->watchdogFires);
    ivars->stopped = true;
    if (ivars->timer) ivars->timer->Cancel(^{});
    for (uint32_t s = 0; s < GDHUB_SLOT_COUNT; s++) {
        if (ivars->device[s]) ivars->device[s]->Terminate(0);     // D3 devices
        OSSafeReleaseNULL(ivars->device[s]);
        OSSafeReleaseNULL(ivars->spec[s]);
        OSSafeReleaseNULL(ivars->postBuffer[s]);
    }
    if (ivars->lock) {
        IOLockLock(ivars->lock);
        OSAction * a = ivars->outputAction;
        ivars->outputAction = nullptr;
        IOLockUnlock(ivars->lock);
        if (a) a->release();
    }
    if (ivars->root) GDHubRootRelease(ivars->root, this);
    ivars->ownsRoot = false;
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t GDHubVirtualHIDUserClient::ExternalMethod(uint64_t selector, IOUserClientMethodArguments * arguments,
                                                        const IOUserClientMethodDispatch * dispatch,
                                                        OSObject * target, void * reference)
{
    (void)dispatch; (void)target; (void)reference;
    if (selector >= GDHUB_SEL_COUNT) return kIOReturnBadArgument;
    if (selector != GDHUB_SEL_HELLO) {
        if (!ivars->authorized) return kIOReturnNotPermitted;
        if (!ivars->protocolOK) return kIOReturnUnsupported;
    }
    return super::ExternalMethod(selector, arguments, &sMethods[selector], this, nullptr);
}

void IMPL(GDHubVirtualHIDUserClient, WatchdogFired)
{
    (void)action; (void)time;
    if (ivars->stopped) return;
    uint64_t now = mach_absolute_time();
    // D2: log and flag only. D3 adds "a device exists" to the condition and posts the neutral reports.
    if (!ivars->neutralised && ivars->lastActivity != 0 && now - ivars->lastActivity > ivars->timeoutTicks) {
        ivars->neutralised = true;
        ivars->watchdogFires++;
        GDLog("watchdog: no activity for more than %u ms (fires=%llu)", (unsigned)GDHUB_WATCHDOG_TIMEOUT_MS,
              ivars->watchdogFires);
    }
    ivars->timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, now + ivars->periodTicks, ivars->periodTicks / 10);
}
