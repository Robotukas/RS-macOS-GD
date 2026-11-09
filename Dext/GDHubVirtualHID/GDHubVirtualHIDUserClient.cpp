// User client of the GDHub virtual HID dext (design §3.4, §3.5, §3.9, §3.10, §3.11).
// D2: hello, heartbeat, registerOutput (stores the completion only), getStatus, Team ID check, single-owner claim,
// watchdog timer. D3: createDevice, destroyDevice, postReport, postNeutral, watchdog neutral reports, teardown of the
// children, and the DEBUG-only devTerminate selector.
// T3: the pad belongs to the ROOT. createDevice/destroyDevice call root->CreatePad/DestroyPad; posts go to
// pad->submitInput/postNeutralFrom on the pad found through the registry (+1 for the duration of the call); each input
// report has one fixed-length buffer whose length is set once. Selectors 9 (INERT only) and 11 (status2) are new.
//
// Queue: everything in this file runs on the user client's default queue (rank 1): ExternalMethod, WatchdogFired
// (the timer is created on the same queue), Stop. The only synchronous calls out are root->CreatePad/DestroyPad (rank 2)
// and pad->submitInput/postNeutralFrom (rank 4), each wrapped in GDH_SYNC; Terminate is a kernel call, not a queue entry.
#include "GDHubInternal.h"
#include "GDHubVirtualHID.h"
#include "GDHubVirtualHIDUserClient.h"
#include "GDHubVirtualPad.h"

// The T3 probe (status2 topology flags) will say which queue ExternalMethod, the watchdog and Stop really run on. Until it
// has, the few fields that more than one of them touch are accessed atomically (relaxed: each is a flag or a counter and
// carries no data that needs ordering), so a shared or a separate queue are both correct.
#define ALOAD(x)     __atomic_load_n(&(x), __ATOMIC_RELAXED)
#define ASTORE(x, v) __atomic_store_n(&(x), (v), __ATOMIC_RELAXED)

struct GDHubVirtualHIDUserClient_IVars {
    GDHubVirtualHID * root;                         // provider (retained by DriverKit until Stop), not retained here
    bool authorized, protocolOK, ownsRoot, neutralised, stopped;
    bool padCreated;                                // this client created the pad and has not destroyed it (T3)
    uint64_t ownerGen;                              // generation GDHubClaimOwner returned; 0 until hello
    IOLock * lock;                                  // guards outputAction, outputSeq/Count/Drops (D5 writes them from the pad's queue)
    OSData * spec[GDHUB_SLOT_COUNT];                // retained; this client's copy, used on the UC queue only
    // One buffer per input-table entry of the pad's spec: created once with its length set once (SetLength is a kernel
    // RPC, so it is never called per post), filled with memcpy per post, handed to pad->submitInput.
    IOBufferMemoryDescriptor * inBuf[GDHUB_MAX_INPUT_REPORTS];
    void * inAddr[GDHUB_MAX_INPUT_REPORTS];
    uint32_t inLen[GDHUB_MAX_INPUT_REPORTS];
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

IODispatchQueue * GDHubUCQueue(GDHubVirtualHIDUserClient * uc)
{
    return (uc && uc->ivars) ? uc->ivars->queue : nullptr;
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
        uint64_t gen = GDHubClaimOwner(uc);
        if (gen == 0) {
            GDLog("hello: refused, dext already owned by another client (0x%x)", (unsigned)kIOReturnExclusiveAccess);
            return kIOReturnExclusiveAccess;
        }
        iv->authorized = true;
        iv->ownsRoot = true;
        iv->ownerGen = gen;
    }
    iv->protocolOK = (a->scalarInput[0] == GDHUB_PROTOCOL_VERSION);
    ASTORE(iv->neutralised, false);
    ASTORE(iv->lastActivity, mach_absolute_time());
    a->scalarOutput[0] = GDHUB_PROTOCOL_VERSION;
    a->scalarOutput[1] = GDHUB_DEXT_BUILD;
#if GDHUB_TAP_DECLINE
    a->scalarOutput[2] = GDHUB_CAP_PAD | GDHUB_CAP_ROOT_PAD;                       // a decline build has no tap: no CAP_TAP
#else
    a->scalarOutput[2] = GDHUB_CAP_PAD | GDHUB_CAP_ROOT_PAD | GDHUB_CAP_TAP | GDHUB_CAP_XLATE | GDHUB_CAP_LIVE;       // capabilities: keyboard and pointer arrive in D8
#endif
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

static void dropInputBuffers(GDHubVirtualHIDUserClient_IVars * iv)
{
    for (uint32_t i = 0; i < GDHUB_MAX_INPUT_REPORTS; i++) {
        OSSafeReleaseNULL(iv->inBuf[i]);
        iv->inAddr[i] = nullptr;
        iv->inLen[i] = 0;
    }
}

// One buffer per input-table entry, each with its length set exactly once, here. A failure leaves nothing behind.
static kern_return_t buildInputBuffers(GDHubVirtualHIDUserClient_IVars * iv, OSData * spec)
{
    uint32_t count = GDHubSpecInputCount(spec);
    if (count < 1 || count > GDHUB_MAX_INPUT_REPORTS) return kIOReturnBadArgument;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t len = GDHubSpecSendLength(spec, i);
        IOBufferMemoryDescriptor * b = nullptr;
        kern_return_t kr = len ? IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, len, 0, &b) : kIOReturnBadArgument;
        IOAddressSegment range = {};
        if (kr == kIOReturnSuccess && b) kr = b->SetLength(len);
        if (kr == kIOReturnSuccess && b) kr = b->GetAddressRange(&range);
        if (kr == kIOReturnSuccess && (!range.address || range.length < len)) kr = kIOReturnError;
        if (kr != kIOReturnSuccess || !b) {
            if (b) b->release();
            dropInputBuffers(iv);
            return kr != kIOReturnSuccess ? kr : kIOReturnError;
        }
        iv->inBuf[i] = b;
        iv->inAddr[i] = (void *)range.address;
        iv->inLen[i] = len;
    }
    return kIOReturnSuccess;
}

// Forgets the pad this client created: asks the root to destroy it (rank 1 -> 2), then drops the client's own state.
// If the root call fails, the registry slot is emptied directly (a stale generation still empties nothing).
static kern_return_t postNeutralToPad(GDHubVirtualHIDUserClient * uc, uint32_t reason, uint32_t source = GDHUB_PADSRC_UC);

// The neutral of a source switch is posted from the REGISTRY's pad, whoever the caller is: the switch changed the pad's source, so the
// pad must get its neutral even if this client never created or adopted it (review D4). Nothing waits on the tap.
// The token a user-client neutral carries: none for source UC; for source TAP (the switch and hold neutrals, posted on the tap's
// behalf) the CURRENT tap token, so only a replaced tap instance's own neutral can be stale.
static uint64_t neutralToken(uint32_t source) { return source == GDHUB_PADSRC_TAP ? gdhr_tap_token(GDHubReg()) : 0; }

static kern_return_t postNeutralFromRegistry(uint32_t reason, uint32_t source)
{
    GDHubVirtualPad * pad = GDHubCopyPad();                    // +1 for the duration of the call
    if (!pad) return kIOReturnNotReady;
    GDH_SYNC(GDHR_RANK_UC, GDHR_RANK_PAD, GDHubPadQueue(pad), "postNeutralFrom");
    kern_return_t kr = pad->postNeutralFrom(source, neutralToken(source), reason);
    pad->release();
    return kr;
}

// Leaves LIVE if the tap is driving the pad (plan 6.2, "switch from LIVE"): padSource = UC first (a TAP report still queued on the
// pad's queue is refused from here), then the switch neutral from the UC side. Returns true if the source was TAP.
static bool leaveLive(GDHubVirtualHIDUserClient * uc)
{
    (void)uc;
    if (!gdhr_leave_live(GDHubReg())) return false;
    (void)postNeutralFromRegistry(GDHUB_NEUTRAL_SWITCH, GDHUB_PADSRC_UC);
    return true;
}

static void destroyPad(GDHubVirtualHIDUserClient * uc)
{
    auto iv = uc->ivars;
    // Plan 6.3: padSource = UC, neutral, INERT, then destroy. The result is ignored (there may be no live pad), and nothing waits.
    // INERT is stored only when the pad was LIVE (leaving LIVE is the one case that must not leave the tap running); for COUNT and
    // SHADOW the destroy leaves the armed state alone, as before (the registry returns LIVE to INERT when the pad leaves the slot).
    if (leaveLive(uc)) (void)gdhr_set_desired_if_owner(GDHubReg(), static_cast<OSObject *>(uc), GDH_FWD_INERT);
    else (void)postNeutralToPad(uc, GDHUB_NEUTRAL_UC_REQUEST);
    GDHubPokeTap();
    if (iv->root && iv->ownerGen) {
        GDH_SYNC(GDHR_RANK_UC, GDHR_RANK_ROOT, GDHubRootQueue(iv->root), "DestroyPad");
        kern_return_t kr = iv->root->DestroyPad(iv->ownerGen);
        if (kr != kIOReturnSuccess) {
            GDLog("DestroyPad returned 0x%x: taking the pad directly", (unsigned)kr);
            int rc = 0;
            OSObject * left = static_cast<OSObject *>(gdhr_pad_take(GDHubReg(), iv->ownerGen, &rc));
            if (left) gdhr_ctr_add(GDHubReg(), GDHR_CTR_PAD_DESTROYS, 1);
            GDHubTerminateAndRelease(left);
        }
    }
    GDHubPokeTap();                                     // the slot is empty now: a tap that was LIVE finds INERT
    ASTORE(iv->padCreated, false);
    dropInputBuffers(iv);
    OSSafeReleaseNULL(iv->spec[GDHUB_SLOT_PAD]);
}

// Posts the pad's neutral reports. Used by the postNeutral selector and the watchdog.
static kern_return_t postNeutralToPad(GDHubVirtualHIDUserClient * uc, uint32_t reason, uint32_t source)
{
    if (!ALOAD(uc->ivars->padCreated)) return kIOReturnNotReady;
    GDHubVirtualPad * pad = GDHubCopyPad();                    // +1 for the duration of the call
    if (!pad) return kIOReturnNotReady;
    GDH_SYNC(GDHR_RANK_UC, GDHR_RANK_PAD, GDHubPadQueue(pad), "postNeutralFrom");
    kern_return_t kr = pad->postNeutralFrom(source, neutralToken(source), reason);
    pad->release();
    return kr;
}

// Selectors 1 (createDevice) and 12 (createDevice2, T7). `wantAdopt` is selector 12: a live pinned pad with a byte-identical spec
// becomes this client's (no neutral, no new device, *adopted = 1). Selector 1 knows nothing of adoption: an orphaned pad is
// destroyed and the create goes ahead. A selector-12 caller whose spec differs gets the orphan destroyed and kIOReturnBusy, and
// asks again after the HID gap (the engine waits 400 ms, like the sink's identity switch).
static kern_return_t createCommon(OSObject * target, IOUserClientMethodArguments * a, bool wantAdopt, uint32_t * adopted)
{
    auto uc = OSRequiredCast(GDHubVirtualHIDUserClient, target);
    if (adopted) *adopted = 0;
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
    if (ALOAD(iv->padCreated)) {
        // Still ours, or gone behind our back (the pad stopped on its own)? Only a live registry slot means Busy.
        if (gdhr_pad_state(GDHubReg()) != GDHR_PAD_NONE) { if (map) map->release(); return kIOReturnBusy; }
        GDLog("createDevice: dropping a stale pad record");
        ASTORE(iv->padCreated, false);
        dropInputBuffers(iv);
        OSSafeReleaseNULL(iv->spec[slot]);
    }

    OSData * spec = OSData::withBytes(bytes, (uint32_t)len);
    unsigned vid = (unsigned)(bytes[GDHUB_SPEC_OFF_VENDOR] | (bytes[GDHUB_SPEC_OFF_VENDOR + 1] << 8));
    unsigned pid = (unsigned)(bytes[GDHUB_SPEC_OFF_PRODUCT] | (bytes[GDHUB_SPEC_OFF_PRODUCT + 1] << 8));
    if (map) map->release();
    if (!spec) return kIOReturnNoMemory;

    gdhr * reg = GDHubReg();
    if (gdhr_pad_orphaned(reg)) {
        if (wantAdopt) {
            OSData * live = GDHubCopyPadSpec();
            bool same = live && live->getLength() == spec->getLength() &&
                        memcmp(live->getBytesNoCopy(), spec->getBytesNoCopy(), spec->getLength()) == 0;
            if (live) live->release();
            if (same) {
                // The spec is the pad's own, so the pad is never removed for it. If the adoption does not happen (this client stopped
                // during its own call: E_NOT_OWNER; the orphan went away meanwhile) the caller is told to ask again.
                if (buildInputBuffers(iv, spec) == kIOReturnSuccess) {
                    if (gdhr_pad_adopt(reg, iv->ownerGen, GDHubSpecCRC32(spec)) == GDHR_OK) {
                        iv->spec[slot] = spec;                  // keeps the +1 from withBytes
                        ASTORE(iv->padCreated, true);
                        if (adopted) *adopted = 1;
                        GDLog("createDevice2: slot %u %04x:%04x adopted (source %u)", slot, vid, pid, (unsigned)gdhr_pad_source(reg));
                        return kIOReturnSuccess;
                    }
                    dropInputBuffers(iv);
                }
                spec->release();
                GDLog("createDevice2: adoption of an identical spec did not happen; the pad stays");
                return kIOReturnNotReady;
            }
            spec->release();
            GDHubOrphanForceDestroy("the new owner's spec differs");
            return kIOReturnBusy;
        }
        GDHubOrphanForceDestroy("an old app's createDevice");
    }

    // Fixed-length input buffers first, so a failure here leaves the registry untouched.
    kr = buildInputBuffers(iv, spec);
    if (kr != kIOReturnSuccess) { GDLog("createDevice: input buffers 0x%x", (unsigned)kr); spec->release(); return kr; }

    // Stage the spec in the registry (the pad reads it in handleStart), then ask the root to create the pad. No lock is
    // held across CreatePad: the registry lock is private to the core and released before this call.
    int rc = gdhr_pad_stage(reg, iv->ownerGen, static_cast<OSObject *>(spec), GDHubSpecCRC32(spec));
    if (rc != GDHR_OK) {
        GDLog("createDevice: slot not available (registry %d)", rc);
        dropInputBuffers(iv); spec->release();
        return rc == GDHR_E_BUSY ? kIOReturnBusy : (rc == GDHR_E_NOT_OWNER ? kIOReturnNotPermitted : kIOReturnNotReady);
    }
    GDH_SYNC(GDHR_RANK_UC, GDHR_RANK_ROOT, GDHubRootQueue(iv->root), "CreatePad");
    kr = iv->root->CreatePad(iv->ownerGen);
    if (kr == kIOReturnSuccess && gdhr_pad_state(reg) != GDHR_PAD_LIVE) {
        // CreatePad found Create returned before the pad's Start registered it (the root logs and counts that). Build 18
        // measured that Create waits for Start, so this should not happen. The engine treats a NotReady post as a lost device, so
        // createDevice does not report success for a pad that is not live. Nothing waits here: IOSleep would block this
        // queue, which may be the root's own queue (the probe has not settled that), and the pad's Start might need it.
        GDLog("createDevice: pad not live when CreatePad returned");
        kr = kIOReturnNotReady;
    }
    if (kr != kIOReturnSuccess) {
        GDLog("createDevice: CreatePad failed 0x%x", (unsigned)kr);
        // The slot must be empty whenever createDevice reports failure: even a pad that went LIVE (or is still starting)
        // is taken out and terminated, so the next createDevice cannot find the slot Busy.
        int rc = 0;
        gdhr_pad_unstage(reg, iv->ownerGen);            // no-op unless the root never took the slot
        OSObject * left = static_cast<OSObject *>(gdhr_pad_take(reg, iv->ownerGen, &rc));
        if (left) gdhr_ctr_add(reg, GDHR_CTR_PAD_DESTROYS, 1);
        GDHubTerminateAndRelease(left);
        dropInputBuffers(iv); spec->release();
        return kr;
    }
    iv->spec[slot] = spec;                              // keeps the +1 from withBytes
    ASTORE(iv->padCreated, true);
    GDLog("createDevice: slot %u %04x:%04x created", slot, vid, pid);
    return kIOReturnSuccess;
}

static kern_return_t sCreateDevice(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference;
    return createCommon(target, a, false, nullptr);
}

// Selector 12 (T7, CAP_LIVE). Scalar outputs: adopted, padSource.
static kern_return_t sCreateDevice2(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference;
    uint32_t adopted = 0;
    kern_return_t kr = createCommon(target, a, true, &adopted);
    if (kr != kIOReturnSuccess) return kr;
    a->scalarOutput[0] = adopted;
    a->scalarOutput[1] = gdhr_pad_source(GDHubReg());
    a->scalarOutputCount = 2;
    return kIOReturnSuccess;
}

static kern_return_t sDestroyDevice(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference;
    auto uc = OSRequiredCast(GDHubVirtualHIDUserClient, target);
    uint64_t slot = a->scalarInput[0];
    if (slot >= GDHUB_SLOT_COUNT) return kIOReturnBadArgument;
    if (slot == GDHUB_SLOT_PAD && ALOAD(uc->ivars->padCreated)) {
        GDLog("destroyDevice: slot %llu", slot);
        destroyPad(uc);
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
    if (slot != GDHUB_SLOT_PAD) return iv->spec[slot] ? kIOReturnUnsupported : kIOReturnNotReady;   // keyboard / pointer: D8
    OSData * spec = iv->spec[GDHUB_SLOT_PAD];
    if (!ALOAD(iv->padCreated) || !spec) return kIOReturnNotReady;
    const uint8_t * bytes = nullptr; size_t len = 0; IOMemoryMap * map = nullptr;
    kern_return_t kr = structureBytes(a, &bytes, &len, &map);
    if (kr != kIOReturnSuccess) return kIOReturnBadArgument;
    int idx = (len >= 1 && len <= GDHUB_MAX_REPORT) ? GDHubSpecFindInput(spec, bytes, (uint32_t)len) : -1;
    if (idx < 0 || (uint32_t)idx >= GDHUB_MAX_INPUT_REPORTS || !iv->inBuf[idx] || iv->inLen[idx] != len) {
        if (map) map->release();
        return kIOReturnBadArgument;
    }
    memcpy(iv->inAddr[idx], bytes, len);                          // the buffer's length was set once, at creation
    if (map) map->release();
    GDHubVirtualPad * pad = GDHubCopyPad();                       // +1 for the duration of the call; no lock is held after it
    if (!pad) return kIOReturnNotReady;
    GDH_SYNC(GDHR_RANK_UC, GDHR_RANK_PAD, GDHubPadQueue(pad), "submitInput");
    uint64_t tCall = mach_absolute_time();                        // `hop` starts here
    kr = pad->submitInput(GDHUB_PADSRC_UC, 0, tCall, iv->inBuf[idx], (uint32_t)len);
    pad->release();
    if (kr == kIOReturnSuccess) {
        ASTORE(iv->postCount, ALOAD(iv->postCount) + 1);          // single writer: the ExternalMethod queue
        ASTORE(iv->lastActivity, mach_absolute_time());
        ASTORE(iv->neutralised, false);
    }
    return kr;
}

static kern_return_t sPostNeutral(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference;
    auto uc = OSRequiredCast(GDHubVirtualHIDUserClient, target);
    uint64_t slot = a->scalarInput[0];
    if (slot >= GDHUB_SLOT_COUNT) return kIOReturnBadArgument;
    if (slot != GDHUB_SLOT_PAD) return kIOReturnNotReady;
    gdhr * reg = GDHubReg();
    kern_return_t kr;
    if (gdhr_pad_source(reg) == GDHUB_PADSRC_TAP) {
        // A client that does not own the pad (an orphan it has not adopted) neither holds the tap back nor posts anything: NotReady.
        if (!gdhr_owns_pad(reg, static_cast<OSObject *>(uc))) return kIOReturnNotReady;
        // The tap is driving the pad (plan 6.2). The engine's neutral request (its willSleep, Mac sleep) is honoured as a real guard:
        // the hold is stored FIRST, so the pad refuses any TAP report that reaches its queue after this request, then the neutral is
        // posted with the current source. The hold ends at tap SetPowerState(On), a new tap Start or the next setForwarding(LIVE).
        gdhr_set_hold(reg, 1);
        kr = postNeutralToPad(uc, GDHUB_NEUTRAL_HOLD, GDHUB_PADSRC_TAP);
    } else {
        kr = postNeutralToPad(uc, GDHUB_NEUTRAL_UC_REQUEST);
    }
    if (kr == kIOReturnSuccess) ASTORE(uc->ivars->lastActivity, mach_absolute_time());
    return kr;
}

// DEBUG-ONLY dev experiment (GDHUB_DEV_TERMINATE, not in the design): terminate the root service so the dext process
// can exit and kernelmanagerd can start a staged replacement build without a reboot. The Team check already ran in
// hello (ExternalMethod gates every other selector on `authorized`). T3 order: the pad first, then the root.
static kern_return_t sDevTerminate(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference; (void)a;
#if GDHUB_DEV_TERMINATE
    auto uc = OSRequiredCast(GDHubVirtualHIDUserClient, target);
    GDLog("devTerminate: pad, then the tap, then Terminate(0) on the root service (DEBUG-only)");
    gdhr_set_terminating(GDHubReg());              // a tap that starts from now on declines, so no service keeps the process alive
    if (ALOAD(uc->ivars->padCreated)) destroyPad(uc);
    GDHubTerminateTap();                           // asynchronous; the tap's Stop closes the interface
    kern_return_t kr = uc->ivars->root ? uc->ivars->root->Terminate(0) : kIOReturnNotReady;
    GDLog("devTerminate: Terminate returned 0x%x", (unsigned)kr);
    if (kr != kIOReturnSuccess) {
        // The process is not ending: taps must be allowed to attach again.
        gdhr_clear_terminating(GDHubReg());
        GDLog("devTerminate: failed, terminating flag cleared");
    }
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
    ASTORE(uc->ivars->lastActivity, mach_absolute_time());
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
    if (ALOAD(iv->padCreated) && gdhr_pad_state(GDHubReg()) == GDHR_PAD_LIVE) mask |= (1ull << GDHUB_SLOT_PAD);
    IOLockLock(iv->lock);
    uint64_t outCount = iv->outputCount, outDrops = iv->outputDrops;
    IOLockUnlock(iv->lock);
    a->scalarOutput[0] = mask;
    a->scalarOutput[1] = ALOAD(iv->postCount);
    a->scalarOutput[2] = ALOAD(iv->watchdogFires);
    a->scalarOutput[3] = outCount;
    a->scalarOutput[4] = outDrops;
    a->scalarOutputCount = 5;
    return kIOReturnSuccess;
}

// Selector 9 (T3, T4 adds COUNT; behind CAP_ROOT_PAD, COUNT behind CAP_TAP). Runs on the ROOT's queue (ExternalMethod), so the
// tap is reached by an atomic store of the desired state plus a DispatchAsync poke onto the tap's own queue; the tap's 50 ms
// timer is the backstop. Nothing here waits for the tap, so the call returns before the interface is opened or closed:
// `appliedState` in the reply is what was applied so far, and status2 shows the result. INERT and COUNT only, no flags;
// anything else is kIOReturnUnsupported. Outputs: appliedState, tapPresent, padSource, lastError.
static kern_return_t sSetForwarding(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference;
    auto uc = OSRequiredCast(GDHubVirtualHIDUserClient, target);
    if (gdh_fwd_validate(a->scalarInput[0], a->scalarInput[1]) != 0) return kIOReturnUnsupported;
    gdhr * reg = GDHubReg();
    OSObject * self = static_cast<OSObject *>(uc);
    const uint32_t state = (uint32_t)a->scalarInput[0], flags = (uint32_t)a->scalarInput[1];
    bool noEffect = false;                          // INERT from a client that does not own the pad (see below)
    uint64_t pauseUntil = 0;
#if GDHUB_TAP_DECLINE
    if (state != GDHUB_FWD_INERT || flags != 0) return kIOReturnUnsupported;      // no tap in this build: only INERT exists
#endif
    // The flags are owner-only like everything else here.
    if (flags != 0 && !gdhr_is_owner(reg, self)) return kIOReturnNotPermitted;
    if (flags & GDHUB_FWD_FLAG_RELEASE_PAD) {
        // RELEASE_PAD (with INERT): source UC, neutral, INERT, destroy the pad even if it is pinned and ownerless. A connected owner
        // that never owned the orphan is exactly who asks (the forced finish needs no owner of the pad).
        if (ALOAD(uc->ivars->padCreated)) destroyPad(uc);
        else GDHubOrphanForceDestroy("RELEASE_PAD");
        (void)gdhr_set_desired_if_owner(reg, self, GDH_FWD_INERT);
        GDHubPokeTap();
        goto reply;
    }
    if (flags & GDHUB_FWD_FLAG_DEV_PAUSE_TAP) {
        uint64_t ms = a->scalarInput[2];
        if (ms == 0 || ms > GDH_PAUSE_MAX_MS) return kIOReturnBadArgument;
        if (gdhr_pad_not_ours(reg, self)) return kIOReturnBusy;                    // only the owner of the pad pauses its tap
        pauseUntil = mach_absolute_time() + nsToTicks(ms * 1000000ull);            // stored only after the state request succeeded
    }
    // SHADOW needs a passed self-test (the golden vectors through this build of the core, run once per process). A failed one
    // keeps the tap out of SHADOW for the life of the process.
    // It runs here and nowhere else, for the owner only, on the root's queue; a process that is never asked for SHADOW never
    // executes translator code. A pass or a failure is final for the process; RUNNING (not expected) is "ask again".
    if (a->scalarInput[0] == GDHUB_FWD_SHADOW) {
        if (!gdhr_is_owner(reg, self)) return kIOReturnNotPermitted;
        if (gdhr_pad_not_ours(reg, self)) return kIOReturnBusy;                    // an orphan it has not adopted: not its pad to arm for (Busy, not a refusal: the engine adopts or replaces it)
        uint32_t st = GDHubSelfTestEnsure();
        if (st == GDHR_SELFTEST_RUNNING) return kIOReturnNotReady;
        if (st != GDHR_SELFTEST_PASS) return kIOReturnNotPermitted;
    }
    if (state == GDHUB_FWD_LIVE) {
        // Plan 6.2, "switch to LIVE" (this is the UC side; the tap is reached by the poke only):
        //   1. owner of THIS pad + every precondition + padSource = TAP     (gdhr_live_begin, one critical section)
        //   2. the switch neutral, posted with source TAP        (the pad checks the source on its own queue)
        //   3. desiredState = LIVE, hold cleared                 (gdhr_live_commit)  -> the tap starts submitting
        //   4. poke the tap
        if (!gdhr_is_live(reg)) {
            int rc = gdhr_live_begin(reg, self);
            if (rc != GDHR_OK) {
                switch (rc) {
                case GDHR_E_NOT_OURS:  return kIOReturnBusy;                           // a pad it has not adopted: Busy, never a final refusal
                case GDHR_E_NOT_OWNER: case GDHR_E_SELFTEST: return kIOReturnNotPermitted;
                case GDHR_E_SPEC:      return kIOReturnBadArgument;            // the accepted mapping targets another pad
                default:               return kIOReturnNotReady;               // no pad / tap / SHADOW applied yet / mapping: ask again
                }
            }
            (void)postNeutralFromRegistry(GDHUB_NEUTRAL_SWITCH, GDHUB_PADSRC_TAP);
            if (gdhr_live_commit(reg, self) != GDHR_OK) { gdhr_live_abort(reg); return kIOReturnNotPermitted; }
        } else if (gdhr_live_commit(reg, self) != GDHR_OK) {
            return kIOReturnNotPermitted;           // already LIVE and the pad is not ours (an unadopted pinned pad)
        }
    } else {
        // Anything else: leave LIVE first (padSource = UC, then the neutral), then store the new state. Only the CURRENT owner of THE
        // PAD may set it, decided under the registry lock: a late request from a client that is going away must not land after
        // release_owner reset the state to INERT, and a client that merely said hello while a pinned pad waits for an owner may not
        // touch it. For such a client INERT is answered with SUCCESS and no effect: an unsupervised GUI client (and a build-22/23
        // app) sends INERT right after hello, before it has created or adopted anything, and must not see an error for it; the pad
        // is the tap's until the client adopts it (the engine's createDevice2 does, and then asks again if it wants a state).
        if (!gdhr_is_owner(reg, self)) return kIOReturnNotPermitted;
        if (gdhr_pad_not_ours(reg, self)) {
            if (state != GDHUB_FWD_INERT) return kIOReturnBusy;
            noEffect = true;
        } else {
            leaveLive(uc);
            if (gdhr_set_desired_if_owner(reg, self, state) != GDHR_OK) return kIOReturnNotPermitted;
            // INERT drops the accepted mapping too (T7 open item: a mapping the engine can no longer express must not stay in the
            // driver for a later arming); the next SHADOW is armed with a fresh push. COUNT and SHADOW keep it.
            if (state == GDHUB_FWD_INERT) gdhr_map_clear(reg);
        }
    }
    if (pauseUntil) gdhr_pause_set(reg, pauseUntil);
    if (!noEffect) GDHubPokeTap();
reply:
    gdhr_snap s;
    gdhr_snapshot(reg, &s);
    a->scalarOutput[0] = s.tapApplied;
    a->scalarOutput[1] = s.tapPresent;
    a->scalarOutput[2] = s.padSource;
    a->scalarOutput[3] = s.lastError;
    a->scalarOutputCount = 4;
    return kIOReturnSuccess;
}

// Selector 10 (T5, CAP_XLATE): push the mapping blob. Runs on the root's queue. Validation, the refusals and the handoff are
// in GDHubMapAccept (GDHubXlateGlue.cpp); there is no synchronous call to the tap (it picks the mapping up at its next frame
// through the registry's seqlock). Outputs: acceptedRevision (0 if refused) and a reason (0 = accepted).
static kern_return_t sSetMapping(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)reference;
    auto uc = OSRequiredCast(GDHubVirtualHIDUserClient, target);
    const uint8_t * bytes = nullptr; size_t len = 0; IOMemoryMap * map = nullptr;
    if (structureBytes(a, &bytes, &len, &map) != kIOReturnSuccess) return kIOReturnBadArgument;
    uint32_t rev = 0, reason = 0;
    kern_return_t kr = GDHubMapAccept(uc, bytes, len, &rev, &reason);
    if (map) map->release();
    if (kr != kIOReturnSuccess) return kr;
    a->scalarOutput[0] = rev;
    a->scalarOutput[1] = reason;
    a->scalarOutputCount = 2;
    return kIOReturnSuccess;
}

// T3, selector 11: GDHubStatus2 as a structure output. The caller's maximum may be smaller than the structure (an older
// app) or larger (a newer one); the dext returns min(size, maximum) bytes and the reader copes with either.
static kern_return_t sGetStatus2(OSObject * target, void * reference, IOUserClientMethodArguments * a)
{
    (void)target; (void)reference;
    uint64_t cap = a->structureOutputMaximumSize;
    if (cap > GDHUB_ST2_MAX_SIZE) cap = GDHUB_ST2_MAX_SIZE;
    if (cap < 8) return kIOReturnBadArgument;
    uint8_t buf[GDHUB_ST2_MAX_SIZE];
    size_t n = GDHubBuildStatus2(buf, (size_t)cap);
    if (n == 0) return kIOReturnNotReady;
    if (a->structureOutputDescriptor) {
        IOMemoryMap * map = nullptr;
        kern_return_t kr = a->structureOutputDescriptor->CreateMapping(0, 0, 0, 0, 0, &map);
        if (kr != kIOReturnSuccess || !map) return kr != kIOReturnSuccess ? kr : kIOReturnError;
        size_t room = (size_t)map->GetLength();
        memcpy((void *)map->GetAddress(), buf, n < room ? n : room);
        map->release();
        return kIOReturnSuccess;
    }
    OSData * out = OSData::withBytes(buf, (uint32_t)n);
    if (!out) return kIOReturnNoMemory;
    a->structureOutput = out;                                    // released by the OS
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
    /* 9 setForwarding  */ { sSetForwarding,  0, 3, 0,                                 4, 0 },   // T3, CAP_ROOT_PAD
    /* 10 setMapping   */ { sSetMapping,     0, 0, kIOUserClientVariableStructureSize,                 2, 0 },   // T5, CAP_XLATE
    /* 11 getStatus2    */ { sGetStatus2,     0, 0, 0,                                 0, kIOUserClientVariableStructureSize },  // T3, CAP_ROOT_PAD
    /* 12 createDevice2 */ { sCreateDevice2,  0, 0, kIOUserClientVariableStructureSize,                 2, 0 },   // T7, CAP_LIVE
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
    GDLog("client free");        // paired with "client start": a count of the two shows whether user clients are freed (timerAction cycle, tap review m2)
    if (ivars) {
        OSSafeReleaseNULL(ivars->timerAction);
        OSSafeReleaseNULL(ivars->timer);
        OSSafeReleaseNULL(ivars->queue);
        OSSafeReleaseNULL(ivars->outputAction);
        for (uint32_t s = 0; s < GDHUB_SLOT_COUNT; s++) OSSafeReleaseNULL(ivars->spec[s]);
        dropInputBuffers(ivars);
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
    GDHubProbeStart("uc start", GDHR_Q_UC, ivars->queue);
    GDLog("client start (watchdog armed: period %u ms, timeout %u ms)",
          (unsigned)GDHUB_WATCHDOG_PERIOD_MS, (unsigned)GDHUB_WATCHDOG_TIMEOUT_MS);
    return kIOReturnSuccess;
}

kern_return_t IMPL(GDHubVirtualHIDUserClient, Stop)
{
    GDLog("client stop (owner=%d posts=%llu watchdogFires=%llu)", (int)ivars->ownsRoot, ALOAD(ivars->postCount),
          ALOAD(ivars->watchdogFires));
    ASTORE(ivars->stopped, true);          // the watchdog handler bails out from now on
    // The pad belongs to the root now, so it does not go away with this client by itself: destroy it here (G5, §3.9).
    // Terminate is asynchronous; the pad's Stop releases its own references. The owner is released last, and the core
    // hands back any pad that is still registered for this owner so none can outlive it.
    if (ivars->ownsRoot) {
        // A pad the tap is driving (LIVE) is PINNED: it is not destroyed with its owner (plan 6.3). The core decides atomically in
        // gdhr_release_owner_pin; the check here only avoids the destroy path. Anything else is G5 exactly as before.
        bool pinnedLive = ALOAD(ivars->padCreated) && gdhr_is_live(GDHubReg());
        if (ALOAD(ivars->padCreated) && !pinnedLive) destroyPad(this);
        GDHubReleaseOwner(this);
        if (pinnedLive) ASTORE(ivars->padCreated, false);       // the client no longer has a pad of its own
        ivars->ownsRoot = false;
    }
    for (uint32_t s = 0; s < GDHUB_SLOT_COUNT; s++) OSSafeReleaseNULL(ivars->spec[s]);
    dropInputBuffers(ivars);
    IOLockLock(ivars->lock);
    OSAction * out = ivars->outputAction;
    ivars->outputAction = nullptr;
    IOLockUnlock(ivars->lock);
    if (out) out->release();

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
    GDHubProbeFirst(GDHR_PROBE_EXT, "first ext", GDHR_Q_UC, ivars->queue);
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
    if (ALOAD(ivars->stopped)) return;            // Stop is cancelling the timer: do nothing and do not re-arm
    uint64_t now = mach_absolute_time();
    uint64_t last = ALOAD(ivars->lastActivity);
    // The heartbeat watchdog guards the engine path (padSource UC). While the tap drives the pad the engine is allowed to be
    // silent or stopped: it has no effect on a TAP pad (plan 6.4), and the tap has its own silence neutral.
    if (ALOAD(ivars->padCreated) && !ALOAD(ivars->neutralised) && last != 0 && now - last > ivars->timeoutTicks &&
        gdhr_pad_source(GDHubReg()) != GDHUB_PADSRC_TAP) {
        postNeutralToPad(this, GDHUB_NEUTRAL_WATCHDOG);
        ASTORE(ivars->neutralised, true);
        ASTORE(ivars->watchdogFires, ALOAD(ivars->watchdogFires) + 1);   // single writer: the watchdog
        GDLog("watchdog: no activity for more than %u ms, neutral reports posted (fires=%llu)",
              (unsigned)GDHUB_WATCHDOG_TIMEOUT_MS, ALOAD(ivars->watchdogFires));
    }
    ivars->timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, now + ivars->periodTicks, ivars->periodTicks / 10);
}
