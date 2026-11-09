// Slot 0: the virtual gamepad (design §3.4, §3.7, §3.8). An IOUserHIDDevice created by the ROOT with
// Create(root, "GDHubPadProperties", ...) (T3; before T3 the user client created it). Its identity, descriptor and
// strings come from the spec blob the app sent with createDevice, staged in the registry by the user client.
//
// Queue: every method of this class runs on the pad's default queue (rank 4). submitInput and postNeutralFrom are the
// only callers of handleReport. The pad calls no GDHub object: it reads the registry (a private lock, no callouts) and
// calls the kernel (handleReport, CompleteReport).
#include "GDHubInternal.h"
#include "GDHubVirtualHID.h"
#include "GDHubVirtualHIDUserClient.h"
#include "GDHubVirtualPad.h"

struct GDHubVirtualPad_IVars {
    OSData * spec;                                          // +1; read in handleStart, immutable afterwards
    IODispatchQueue * queue;                                // retained copy of this device's default queue
    IOBufferMemoryDescriptor * neutral[GDHUB_MAX_INPUT_REPORTS];   // prefilled, fixed length (SetLength once)
    uint32_t neutralLen[GDHUB_MAX_INPUT_REPORTS];
    uint32_t neutralCount;
    bool stopping;                                          // written in Stop, read in the posting methods: atomic
    bool loggedOutput;
    gdh_meter meter;                                        // written on the pad queue, read lock-free elsewhere
};

bool GDHubVirtualPad::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(GDHubVirtualPad_IVars, 1);
    return ivars != nullptr;
}

void GDHubVirtualPad::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->spec);
        OSSafeReleaseNULL(ivars->queue);
        for (uint32_t i = 0; i < GDHUB_MAX_INPUT_REPORTS; i++) OSSafeReleaseNULL(ivars->neutral[i]);
    }
    IOSafeDeleteNULL(ivars, GDHubVirtualPad_IVars, 1);
    super::free();
}

IODispatchQueue * GDHubPadQueue(GDHubVirtualPad * pad)
{
    return (pad && pad->ivars) ? pad->ivars->queue : nullptr;
}

bool GDHubPadReadMeter(GDHubVirtualPad * pad, gdh_summary * hop, gdh_summary * hr, uint32_t * windows)
{
    if (!pad || !pad->ivars) return false;
    return gdh_meter_read(&pad->ivars->meter, hop, hr, windows) != 0;
}

// Builds the prefilled neutral buffers: one per input-table entry, length set once, bytes copied once.
static bool buildNeutrals(GDHubVirtualPad_IVars * iv)
{
    iv->neutralCount = GDHubSpecInputCount(iv->spec);
    if (iv->neutralCount < 1 || iv->neutralCount > GDHUB_MAX_INPUT_REPORTS) return false;
    for (uint32_t i = 0; i < iv->neutralCount; i++) {
        uint32_t len = 0;
        const uint8_t * bytes = GDHubSpecNeutral(iv->spec, i, &len);
        if (!bytes || len == 0 || len > GDHUB_MAX_REPORT) return false;
        IOBufferMemoryDescriptor * b = nullptr;
        if (IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, len, 0, &b) != kIOReturnSuccess || !b) return false;
        iv->neutral[i] = b;
        IOAddressSegment range = {};
        if (b->SetLength(len) != kIOReturnSuccess || b->GetAddressRange(&range) != kIOReturnSuccess ||
            !range.address || range.length < len) return false;
        memcpy((void *)range.address, bytes, len);
        iv->neutralLen[i] = len;
    }
    return true;
}

bool GDHubVirtualPad::handleStart(IOService * provider)
{
    // Only a pad that the root is creating right now may start (registry state CREATING); anything else is refused.
    if (!OSDynamicCast(GDHubVirtualHID, provider)) { GDLog("pad start: provider is not the root"); return false; }
    ivars->spec = GDHubCopyPadSpec();
    if (!ivars->spec) { GDLog("pad start: no spec staged for the pad slot"); return false; }
    if (CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->queue) != kIOReturnSuccess) ivars->queue = nullptr;
    GDHubProbeStart("pad start", GDHR_Q_PAD, ivars->queue);
    if (!buildNeutrals(ivars)) { GDLog("pad start: neutral buffers could not be built"); return false; }
    mach_timebase_info_data_t tb = {0, 0};
    mach_timebase_info(&tb);
    gdh_meter_init(&ivars->meter, tb.numer, tb.denom, GDHUB_METER_WINDOW_MS);
    GDLog("pad start: %04x:%04x", (unsigned)GDHubSpecU32(ivars->spec, GDHUB_SPEC_OFF_VENDOR),
          (unsigned)GDHubSpecU32(ivars->spec, GDHUB_SPEC_OFF_PRODUCT));
    if (!super::handleStart(provider)) return false;   // super calls newDeviceDescription / newReportDescriptor
    // Register last: from here on the user client can find and use this pad. If the registry refuses (the slot is not
    // CREATING any more), the start fails and the root cleans up.
    if (gdhr_pad_started(GDHubReg(), static_cast<OSObject *>(this)) != GDHR_OK) {
        GDLog("pad start: registry refused (slot not in CREATING)");
        return false;
    }
    gdhr_ctr_add(GDHubReg(), GDHR_CTR_PAD_CREATES, 1);
    return true;
}

kern_return_t IMPL(GDHubVirtualPad, Stop)
{
    GDLog("pad stop");
    __atomic_store_n(&ivars->stopping, true, __ATOMIC_RELAXED);   // every later submission returns NotReady
    gdhr_pad_stopped(GDHubReg(), static_cast<OSObject *>(this));   // no-op if DestroyPad already took it
    return Stop(provider, SUPERDISPATCH);
}

OSDictionary * GDHubVirtualPad::newDeviceDescription(void)
{
    return GDHubSpecCreateDescription(ivars->spec);
}

OSData * GDHubVirtualPad::newReportDescriptor(void)
{
    return GDHubSpecCreateDescriptor(ivars->spec);
}

// Input report injection (§3.7). Runs on this device's queue (iig RPC from the user client).
kern_return_t IMPL(GDHubVirtualPad, submitInput)
{
    uint64_t tPin = mach_absolute_time();
    gdhr * reg = GDHubReg();
    GDHubProbeFirst(GDHR_PROBE_SUBMIT, "first submit", GDHR_Q_PAD, ivars->queue);
    bool stopping = __atomic_load_n(&ivars->stopping, __ATOMIC_RELAXED);
    int rejectCtr = (source == GDHUB_PADSRC_TAP) ? GDHR_CTR_TAP_REJECTED : GDHR_CTR_UC_REJECTED;
    if (stopping || !report || length == 0 || length > GDHUB_MAX_REPORT) {
        gdhr_ctr_add(reg, rejectCtr, 1);
        return stopping ? kIOReturnNotReady : kIOReturnBadArgument;
    }
    // The ONE arbitration point (plan 6.2): the word is read here, on the pad's own queue, for every submission. Whoever is not
    // the current source is refused, and no report of the old source can get past a switch that was stored before this load.
    uint32_t padSource = gdhr_pad_source(reg);
    if (source != padSource) {
        gdhr_ctr_add(reg, rejectCtr, 1);
        return padSource == GDHUB_PADSRC_NONE ? kIOReturnNotReady : kIOReturnBusy;
    }
    // A report from a tap instance that has been replaced in the meantime (a re-enumeration): its token is stale.
    if (source == GDHUB_PADSRC_TAP && token != gdhr_tap_token(reg)) {
        gdhr_ctr_add(reg, GDHR_CTR_TAP_REJECTED, 1);
        return kIOReturnBusy;
    }
    // The hold (the engine's willSleep neutral) is read on this queue too: the neutral request stores it BEFORE its RPC reaches
    // this queue, so a TAP report that runs after the neutral sees it, and one that ran before it was followed by the neutral.
    if (source == GDHUB_PADSRC_TAP && gdhr_hold(reg)) {
        gdhr_ctr_add(reg, GDHR_CTR_TAP_REJECTED, 1);
        return kIOReturnBusy;
    }
    kern_return_t kr = handleReport(tPin, report, length, kIOHIDReportTypeInput, 0);
    uint64_t tPout = mach_absolute_time();
    gdhr_ctr_add(reg, kr == kIOReturnSuccess ? (source == GDHUB_PADSRC_TAP ? GDHR_CTR_TAP_POSTS : GDHR_CTR_UC_POSTS) : GDHR_CTR_POST_ERRORS, 1);
    bool hasHop = (tSrc != 0 && tPin >= tSrc);
    if (gdh_meter_sample(&ivars->meter, tPout, hasHop ? 1 : 0, hasHop ? tPin - tSrc : 0, tPout - tPin)) {
        // One notice per completed 10 s window, never per report. Live-only and cut near 256 characters: stay short.
        gdh_summary hop, hr;
        uint32_t windows = 0;
        if (gdh_meter_read(&ivars->meter, &hop, &hr, &windows)) {
            // Counters are in status2, not here. Worst case: 192 characters with every conversion at its widest (u32 = 10
            // digits); the real maximum is about 144, because the microsecond values are at most 7 digits.
            GDLog("pad meter b=%u w=%u n=%u hop p50/p99/max/mean %u/%u/%u/%u.%u hr %u/%u/%u/%u.%u us",
                  (unsigned)GDHUB_DEXT_BUILD, windows, hop.count, hop.p50Ns / 1000, hop.p99Ns / 1000, hop.maxNs / 1000,
                  hop.meanNs / 1000, (hop.meanNs % 1000) / 100,
                  hr.p50Ns / 1000, hr.p99Ns / 1000, hr.maxNs / 1000, hr.meanNs / 1000, (hr.meanNs % 1000) / 100);
        }
    }
    return kr;
}

// Posts every neutral report of the spec (watchdog, postNeutral selector). No allocation: the buffers were built in
// handleStart. Returns the last error, or success.
kern_return_t IMPL(GDHubVirtualPad, postNeutralFrom)
{
    gdhr * reg = GDHubReg();
    if (__atomic_load_n(&ivars->stopping, __ATOMIC_RELAXED)) return kIOReturnNotReady;
    uint32_t padSource = gdhr_pad_source(reg);
    if (source != padSource) return padSource == GDHUB_PADSRC_NONE ? kIOReturnNotReady : kIOReturnBusy;
    if (source == GDHUB_PADSRC_TAP && token != gdhr_tap_token(reg)) {                // a replaced tap instance: its neutral is stale
        gdhr_ctr_add(reg, GDHR_CTR_TAP_REJECTED, 1);
        return kIOReturnBusy;
    }
    kern_return_t result = kIOReturnSuccess;
    uint64_t now = mach_absolute_time();
    for (uint32_t i = 0; i < ivars->neutralCount; i++) {
        kern_return_t kr = handleReport(now, ivars->neutral[i], ivars->neutralLen[i], kIOHIDReportTypeInput, 0);
        if (kr != kIOReturnSuccess) { result = kr; gdhr_ctr_add(reg, GDHR_CTR_POST_ERRORS, 1); }
    }
    gdhr_ctr_add(reg, GDHR_CTR_NEUTRAL_POSTS, 1);
    switch (reason) {                                          // by reason, for the live checks (every neutral is explained)
    case GDHUB_NEUTRAL_SWITCH:  gdhr_ctr_add(reg, GDHR_CTR_SWITCH_NEUTRALS, 1); break;
    case GDHUB_NEUTRAL_STOP:    gdhr_ctr_add(reg, GDHR_CTR_STOP_NEUTRALS, 1); break;
    case GDHUB_NEUTRAL_SILENCE: gdhr_ctr_add(reg, GDHR_CTR_SILENCE_NEUTRALS, 1); break;
    case GDHUB_NEUTRAL_POWER:   gdhr_ctr_add(reg, GDHR_CTR_POWER_NEUTRALS, 1); break;
    case GDHUB_NEUTRAL_HOLD:    gdhr_ctr_add(reg, GDHR_CTR_HOLD_NEUTRALS, 1); break;
    default: break;
    }
    return result;
}

// D5 stub. Output reports (rumble) are accepted and completed; forwarding to the app arrives in D5. The owner client is
// looked up through the registry (+1), never through a pointer kept in this object: that is the D5 path of the plan.
kern_return_t GDHubVirtualPad::setReport(IOMemoryDescriptor * report, IOHIDReportType reportType, IOOptionBits options,
                                         uint32_t completionTimeout, OSAction * action)
{
    (void)report; (void)completionTimeout;
    gdhr * reg = GDHubReg();
    gdhr_ctr_add(reg, GDHR_CTR_OUTPUTS_SEEN, 1);
    GDHubVirtualHIDUserClient * owner = GDHubCopyOwner(nullptr);
    if (owner) {
        // D5: GDHubUCDeliverOutput(owner, GDHUB_SLOT_PAD, reportType, options & 0xFF, bytes, n) goes here.
        owner->release();
    } else {
        gdhr_ctr_add(reg, GDHR_CTR_OUTPUTS_NO_OWNER, 1);
    }
    if (!ivars->loggedOutput) {
        ivars->loggedOutput = true;
        GDLog("pad setReport: type %u id 0x%02x (not forwarded before D5)", (unsigned)reportType, (unsigned)(options & 0xFF));
    }
    if (action) CompleteReport(action, kIOReturnSuccess, 0);
    return kIOReturnSuccess;
}

// D5 stub.
kern_return_t GDHubVirtualPad::getReport(IOMemoryDescriptor * report, IOHIDReportType reportType, IOOptionBits options,
                                         uint32_t completionTimeout, OSAction * action)
{
    (void)report; (void)reportType; (void)options; (void)completionTimeout;
    if (action) CompleteReport(action, kIOReturnUnsupported, 0);
    return kIOReturnUnsupported;
}
