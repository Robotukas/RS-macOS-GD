// User client of the GDHub virtual HID dext (design §3.4, §3.5, §3.9, §3.10, §3.11).
// D2: hello, heartbeat, registerOutput (stores the completion only), getStatus, Team ID check, single-owner claim,
// watchdog timer. D3: createDevice, destroyDevice, postReport, postNeutral, watchdog neutral reports, teardown of the
// children, and the DEBUG-only devTerminate selector.
#include "GDHubInternal.h"
#include "GDHubVirtualHID.h"
#include "GDHubVirtualHIDUserClient.h"
#include "GDHubVirtualPad.h"

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

// Compares an entitlement value held as an OSString. OSDictionaryGetStringValue returned a string that was not
// reliably NUL-terminated here ("...gdhub-"), so strcmp is never used: compare the OSString by length and bytes.
static bool entitlementEquals(OSDictionary * e, const char * key, const char * want, bool * present)
{
    OSString * v = OSDynamicCast(OSString, e->getObject(key));
    *present = (v != nullptr);
    if (!v) return false;
    size_t wantLen = strlen(want);
    if (v->getLength() != wantLen) return false;
    const char * got = v->getCStringNoCopy();
    return got && memcmp(got, want, wantLen) == 0;
}

static bool callerIsGDHub(GDHubVirtualHIDUserClient * self)
{
    OSDictionary * e = nullptr;
    if (self->CopyClientEntitlements(&e) != kIOReturnSuccess || !e) {
        GDLog("hello: caller has no entitlements");
        return false;
    }
    bool teamPresent = false, appPresent = false;
    bool teamOK = entitlementEquals(e, "com.apple.developer.team-identifier", GDHUB_TEAM_ID, &teamPresent);
    bool appOK  = entitlementEquals(e, "com.apple.application-identifier", GDHUB_APP_ID, &appPresent);
    bool ok = teamOK && (!appPresent || appOK);
    if (!ok) {
        OSString * t = OSDynamicCast(OSString, e->getObject("com.apple.developer.team-identifier"));
        OSString * a = OSDynamicCast(OSString, e->getObject("com.apple.application-identifier"));
        GDLog("hello: caller check failed: team present=%d len=%u ok=%d (want len %u); app present=%d len=%u ok=%d (want len %u)",
              (int)teamPresent, (unsigned)(t ? t->getLength() : 0), (int)teamOK, (unsigned)strlen(GDHUB_TEAM_ID),
              (int)appPresent, (unsigned)(a ? a->getLength() : 0), (int)appOK, (unsigned)strlen(GDHUB_APP_ID));
    }
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
    a->scalarOutput[2] = GDHUB_CAP_PAD;     // capabilities: keyboard and pointer arrive in D8
    a->scalarOutputCount = 3;
    GDLog("hello: app protocol %llu build %llu, dext protocol %u build %u, protocolOK=%d",
          a->scalarInput[0], a->scalarInput[1], (unsigned)GDHUB_PROTOCOL_VERSION, (unsigned)GDHUB_DEXT_BUILD,
          (int)iv->protocolOK);
    return kIOReturnSuccess;
}

// ---------------------------------------------------------------------------------------------------------------
// D3: device handlers. All run on the user client's default queue (ExternalMethod queue = watchdog queue).

// Structure input arrives as an OSData, or (large structures) as a memory descriptor with structureInput == NULL.
// `*map` must be released by the caller when non-null.
static kern_return_t structureBytes(IOUserClientMethodArguments * a, const uint8_t ** bytes, size_t * len, IOMemoryMap ** map)
{
    *map = nullptr; *bytes = nullptr; *len = 0;
    if (a->structureInput) {
        *bytes = (const uint8_t *)a->structureInput->getBytesNoCopy();
        *len = a->structureInput->getLength();
        return kIOReturnSuccess;
    }
    if (a->structureInputDescriptor) {
        kern_return_t kr = a->structureInputDescriptor->CreateMapping(0, 0, 0, 0, 0, map);
        if (kr != kIOReturnSuccess || !*map) return kr != kIOReturnSuccess ? kr : kIOReturnError;
        *bytes = (const uint8_t *)(*map)->GetAddress();
        *len = (size_t)(*map)->GetLength();
        return kIOReturnSuccess;
    }
    return kIOReturnBadArgument;
}

// Posts one input report of `slot` through its postBuffer. Caller has checked that the device exists.
static kern_return_t postBytes(GDHubVirtualHIDUserClient * uc, uint32_t slot, const uint8_t * bytes, uint32_t length)
{
    auto iv = uc->ivars;
    IOBufferMemoryDescriptor * buf = iv->postBuffer[slot];
    if (!iv->device[slot] || !buf || length == 0 || length > GDHUB_MAX_REPORT) return kIOReturnNotReady;
    IOAddressSegment range = {};
    kern_return_t kr = buf->GetAddressRange(&range);
    if (kr != kIOReturnSuccess || !range.address || range.length < length) return kIOReturnError;
    memcpy((void *)range.address, bytes, length);
    kr = buf->SetLength(length);
    if (kr != kIOReturnSuccess) return kr;
    switch (slot) {
    case GDHUB_SLOT_PAD: {
        GDHubVirtualPad * pad = OSDynamicCast(GDHubVirtualPad, iv->device[slot]);
        return pad ? pad->postReport(buf) : kIOReturnNotReady;
    }
    default:
        return kIOReturnUnsupported;      // keyboard / pointer: D8
    }
}

static kern_return_t postNeutralReports(GDHubVirtualHIDUserClient * uc, uint32_t slot)
{
    auto iv = uc->ivars;
    if (!iv->device[slot] || !iv->spec[slot]) return kIOReturnNotReady;
    kern_return_t result = kIOReturnSuccess;
    uint32_t count = GDHubSpecInputCount(iv->spec[slot]);
    for (uint32_t i = 0; i < count; i++) {
        uint32_t len = 0;
        const uint8_t * bytes = GDHubSpecNeutral(iv->spec[slot], i, &len);
        if (!bytes || len == 0) continue;
        kern_return_t kr = postBytes(uc, slot, bytes, len);
        if (kr != kIOReturnSuccess) result = kr;
    }
    return result;
}

static kern_return_t sCreateDevice(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference;
    auto uc = OSRequiredCast(GDHubVirtualHIDUserClient, target);
    auto iv = uc->ivars;
    const uint8_t * bytes = nullptr; size_t len = 0; IOMemoryMap * map = nullptr;
    kern_return_t kr = structureBytes(a, &bytes, &len, &map);
    if (kr != kIOReturnSuccess) { GDLog("createDevice: no structure input (0x%x)", (unsigned)kr); return kIOReturnBadArgument; }

    kr = GDHubSpecValidate(bytes, len);
    if (kr != kIOReturnSuccess) { if (map) map->release(); return kIOReturnBadArgument; }
    uint32_t slot = bytes[GDHUB_SPEC_OFF_SLOT];
    if (slot != GDHUB_SLOT_PAD) {
        GDLog("createDevice: slot %u is not built yet", slot);
        if (map) map->release();
        return kIOReturnUnsupported;
    }
    if (iv->device[slot]) { if (map) map->release(); return kIOReturnBusy; }

    OSData * spec = OSData::withBytes(bytes, (uint32_t)len);
    unsigned vid = (unsigned)(bytes[GDHUB_SPEC_OFF_VENDOR] | (bytes[GDHUB_SPEC_OFF_VENDOR + 1] << 8));
    unsigned pid = (unsigned)(bytes[GDHUB_SPEC_OFF_PRODUCT] | (bytes[GDHUB_SPEC_OFF_PRODUCT + 1] << 8));
    if (map) map->release();
    if (!spec) return kIOReturnNoMemory;

    if (!iv->postBuffer[slot]) {
        kr = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, GDHUB_MAX_REPORT, 0, &iv->postBuffer[slot]);
        if (kr != kIOReturnSuccess) { spec->release(); iv->postBuffer[slot] = nullptr; return kr; }
    }

    // The spec must be stored before Create(): the child reads it in handleStart. Do not hold the lock across Create.
    IOLockLock(iv->lock);
    iv->spec[slot] = spec;
    IOLockUnlock(iv->lock);

    static const char * const kSlotKey[GDHUB_SLOT_COUNT] = { "GDHubPadProperties", "GDHubKeyboardProperties", "GDHubPointerProperties" };
    IOService * child = nullptr;
    kr = uc->Create(uc, kSlotKey[slot], &child);
    if (kr != kIOReturnSuccess || !child) {
        GDLog("createDevice: Create(%{public}s) failed 0x%x", kSlotKey[slot], (unsigned)kr);
        IOLockLock(iv->lock);
        OSData * s = iv->spec[slot]; iv->spec[slot] = nullptr;
        IOLockUnlock(iv->lock);
        if (s) s->release();
        return kr != kIOReturnSuccess ? kr : kIOReturnError;
    }
    iv->device[slot] = child;            // +1 from Create
    GDLog("createDevice: slot %u %04x:%04x created", slot, vid, pid);
    return kIOReturnSuccess;
}

static void dropDevice(GDHubVirtualHIDUserClient * uc, uint32_t slot)
{
    auto iv = uc->ivars;
    IOService * dev = iv->device[slot];
    iv->device[slot] = nullptr;
    if (dev) { dev->Terminate(0); dev->release(); }
    IOLockLock(iv->lock);
    OSData * s = iv->spec[slot]; iv->spec[slot] = nullptr;
    IOLockUnlock(iv->lock);
    if (s) s->release();
}

static kern_return_t sDestroyDevice(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference;
    auto uc = OSRequiredCast(GDHubVirtualHIDUserClient, target);
    uint64_t slot = a->scalarInput[0];
    if (slot >= GDHUB_SLOT_COUNT) return kIOReturnBadArgument;
    if (uc->ivars->device[slot]) {
        GDLog("destroyDevice: slot %llu", slot);
        dropDevice(uc, (uint32_t)slot);
    }
    return kIOReturnSuccess;
}

static kern_return_t sPostReport(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference;
    auto uc = OSRequiredCast(GDHubVirtualHIDUserClient, target);
    auto iv = uc->ivars;
    uint64_t slot = a->scalarInput[0];
    if (slot >= GDHUB_SLOT_COUNT) return kIOReturnBadArgument;
    if (!iv->device[slot] || !iv->spec[slot]) return kIOReturnNotReady;
    const uint8_t * bytes = nullptr; size_t len = 0; IOMemoryMap * map = nullptr;
    kern_return_t kr = structureBytes(a, &bytes, &len, &map);
    if (kr != kIOReturnSuccess) return kIOReturnBadArgument;
    if (len < 1 || len > GDHUB_MAX_REPORT || !GDHubSpecIsDeclaredInput(iv->spec[slot], bytes, (uint32_t)len)) {
        if (map) map->release();
        return kIOReturnBadArgument;
    }
    kr = postBytes(uc, (uint32_t)slot, bytes, (uint32_t)len);
    if (map) map->release();
    if (kr == kIOReturnSuccess) {
        iv->postCount++;
        iv->lastActivity = mach_absolute_time();
        iv->neutralised = false;
    }
    return kr;
}

static kern_return_t sPostNeutral(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference;
    auto uc = OSRequiredCast(GDHubVirtualHIDUserClient, target);
    uint64_t slot = a->scalarInput[0];
    if (slot >= GDHUB_SLOT_COUNT) return kIOReturnBadArgument;
    kern_return_t kr = postNeutralReports(uc, (uint32_t)slot);
    if (kr == kIOReturnSuccess) uc->ivars->lastActivity = mach_absolute_time();
    return kr;
}

// DEBUG-ONLY dev experiment (GDHUB_DEV_TERMINATE, not in the design): terminate the root service so the dext process
// can exit and kernelmanagerd can start a staged replacement build without a reboot. The Team check already ran in
// hello (ExternalMethod gates every other selector on `authorized`).
static kern_return_t sDevTerminate(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference; (void)a;
#if GDHUB_DEV_TERMINATE
    auto uc = OSRequiredCast(GDHubVirtualHIDUserClient, target);
    GDLog("devTerminate: Terminate(0) on the root service (DEBUG-only)");
    kern_return_t kr = uc->ivars->root ? uc->ivars->root->Terminate(0) : kIOReturnNotReady;
    GDLog("devTerminate: Terminate returned 0x%x", (unsigned)kr);
    return kr;
#else
    (void)target;
    return kIOReturnUnsupported;
#endif
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
    /* 1 createDevice   */ { sCreateDevice,   0, 0, kIOUserClientVariableStructureSize, 0, 0 },
    /* 2 destroyDevice  */ { sDestroyDevice,  0, 1, 0,                                 0, 0 },
    /* 3 postReport     */ { sPostReport,     0, 1, kIOUserClientVariableStructureSize, 0, 0 },
    /* 4 postNeutral    */ { sPostNeutral,    0, 1, 0,                                 0, 0 },
    /* 5 heartbeat      */ { sHeartbeat,      0, 0, 0,                                 0, 0 },
    /* 6 registerOutput */ { sRegisterOutput, 1, 0, 0,                                 0, 0 },
    /* 7 getStatus      */ { sGetStatus,      0, 0, 0,                                 5, 0 },
    /* 8 devTerminate   */ { sDevTerminate,   0, 0, 0,                                 0, 0 },   // DEBUG-only
};

// ---------------------------------------------------------------------------------------------------------------

OSData * GDHubUCCopySpec(GDHubVirtualHIDUserClient * uc, uint32_t slot)
{
    if (!uc || !uc->ivars || slot >= GDHUB_SLOT_COUNT) return nullptr;
    IOLockLock(uc->ivars->lock);
    OSData * s = uc->ivars->spec[slot];
    if (s) s->retain();
    IOLockUnlock(uc->ivars->lock);
    return s;
}

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
    ivars->stopped = true;                 // the watchdog handler bails out from now on
    // Children go with the client (§3.9). Terminate is asynchronous; each child's Stop releases its own references.
    for (uint32_t s = 0; s < GDHUB_SLOT_COUNT; s++) {
        IOService * dev = ivars->device[s];
        ivars->device[s] = nullptr;
        if (dev) { dev->Terminate(0); dev->release(); }
        IOLockLock(ivars->lock);
        OSData * sp = ivars->spec[s]; ivars->spec[s] = nullptr;
        IOLockUnlock(ivars->lock);
        if (sp) sp->release();
        OSSafeReleaseNULL(ivars->postBuffer[s]);
    }
    IOLockLock(ivars->lock);
    OSAction * out = ivars->outputAction;
    ivars->outputAction = nullptr;
    IOLockUnlock(ivars->lock);
    if (out) out->release();
    if (ivars->root) GDHubRootRelease(ivars->root, this);
    ivars->ownsRoot = false;

    if (!ivars->timer) return Stop(provider, SUPERDISPATCH);     // Start failed before the timer existed

    // Documented DriverKit pattern: the timer's cancel callout runs after this method returns, and it dereferences the
    // timer's ivars. So hold ourselves (and with us the timer and action that free() releases), disable the timer, and
    // complete Stop only from inside the cancel handler. Calling Stop(SUPERDISPATCH) here lets the object, and its
    // timer, be freed first: that was the TimerDispatchSourceWasCanceled crash.
    ivars->timer->SetEnable(false);
    this->retain();
    ivars->timer->Cancel(^{
        Stop(provider, SUPERDISPATCH);
        this->release();
    });
    return kIOReturnSuccess;
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
    if (ivars->stopped) return;            // Stop is cancelling the timer: do nothing and do not re-arm
    uint64_t now = mach_absolute_time();
    bool anyDevice = false;
    for (uint32_t s = 0; s < GDHUB_SLOT_COUNT; s++) if (ivars->device[s]) anyDevice = true;
    if (anyDevice && !ivars->neutralised && ivars->lastActivity != 0 && now - ivars->lastActivity > ivars->timeoutTicks) {
        for (uint32_t s = 0; s < GDHUB_SLOT_COUNT; s++) if (ivars->device[s]) postNeutralReports(this, s);
        ivars->neutralised = true;
        ivars->watchdogFires++;
        GDLog("watchdog: no activity for more than %u ms, neutral reports posted (fires=%llu)",
              (unsigned)GDHUB_WATCHDOG_TIMEOUT_MS, ivars->watchdogFires);
    }
    ivars->timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, now + ivars->periodTicks, ivars->periodTicks / 10);
}
