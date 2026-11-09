// The receiver tap, T4 and T5 (docs/plans/receiver-takeover-plan.md 3.2, 4.1, 4.5, 5.6, 6.1, 6.4, 6.5).
//
// States: INERT (attached, interface NOT opened, no per-frame code), COUNT (opened; counts reports and the kernel-to-driver
// delay; translates nothing, posts nothing) and, from T5, SHADOW (COUNT plus: the shared translator runs on every report 0x06
// with the accepted mapping, the result is recorded as a parity sample and counted as "would post"; nothing is ever posted).
// SHADOW without an accepted mapping, or after a failed self-test, is exactly COUNT: frames are counted, `framesNoMap`
// rises, nothing is translated. The state asked for lives in the registry (`desiredState`), starts INERT in
// every process and is set only by an owner's selector 9, so a relaunched dext never opens the interface by itself (rule A).
//
// Queue: Start, Stop, SetPowerState, the timer, ReportAvailable and the DispatchAsync pokes all run on this service's default
// queue (rank 3). The ivars are touched by that queue only, except `stopping` (atomic) and the meter (a seqlock, read by
// status2). No lock is held across any call. The tap calls no GDHub object: it reads and writes the registry's atomics and
// takes no pointer to the root or the owner, so it works whichever of root and tap starts first.
// Nothing here logs per frame: the only log lines are Start/Stop, Open/Close, a rate-limited Open failure, power changes and
// one meter line per 10 s window.
#include "GDHubInternal.h"
#include "GDHubReceiverTap.h"
#include "GDHubVirtualPad.h"     // T7: the tap submits to the pad (rank 3 -> rank 4, the only synchronous call the tap makes)
#include "GDHubXlate.h"          // Shared/GDHubXlate.h: the one C translator, compiled into this dext with -ffp-contract=off

static_assert(sizeof(gdx_map) <= GDH_MAP_MAX, "a validated mapping must fit the registry's handoff buffer");

struct GDHubReceiverTap_IVars {
    IOHIDInterface * hid;                                   // +1 on the provider; released after the super Stop
    IODispatchQueue * queue;                                // +1, this service's default queue
    IOTimerDispatchSource * timer;
    OSAction * timerAction;
    OSAction * reportAction;
    IOBufferMemoryDescriptor * poolObj[GDH_POOL_SLOTS];     // the buffers; `pool` (core) records which are in the kernel's pool
    uint8_t * poolAddr[GDH_POOL_SLOTS];                     // mapped once per pool generation; T5 reads the bytes, T4 only counts
    gdh_pool pool;
    bool opened;                                            // tap queue only; published through gdhr_tap_publish
    bool powered;                                           // tap queue only (SetPowerState runs on this queue)
    bool stopping;                                          // atomic: set first thing in Stop
    bool superStopped, everClosed, selfTerminated;
    uint32_t startNo, openTries, openFailLogged;
    uint64_t nextOpenTicks, fastTicks, slowTicks, retryTicks;
    gdh_meter meter;                                        // k2d in the `hr` slot, translate time in the `hop` slot; one writer
    // T5 (tap queue only, except `parity`, a seqlock read by status2)
    uint32_t mode;                                          // applied while open: GDH_FWD_COUNT or GDH_FWD_SHADOW
    bool shadowActive;                                      // mode == SHADOW and the self-test passed
    bool haveMap;
    uint32_t haveSeq;                                       // registry mapSeq the private copy below was taken at
    uint32_t mapRevision;
    gdx_map map;                                            // private copy of the accepted mapping (never the registry's memory)
    gdx_state xstate;                                       // hysteresis anchor and byte dedupe: reset on every map change
    alignas(8) uint8_t mapRaw[GDH_MAP_MAX];                 // staging for the seqlock read
    gdh_parity parity;
    uint32_t parityCount;
    // T7 (tap queue only; nothing here is read by another queue). LIVE = SHADOW + submit what the translator produced to the pad.
    uint64_t myToken;                                       // this instance's registry token: it may submit only while it is current
    bool wantLive;                                          // the applied mode is LIVE (desired LIVE and SHADOW is active)
    bool liveActive;                                        // pad reference, spec and input buffers are in place and the report map is valid
    bool needReset;                                         // the next submitted frame must repost the full state (gdx_reset first)
    bool silenced;                                          // the silence neutral was posted; cleared by the next frame
    bool pauseLogged;
    bool liveNoteLogged;
    uint32_t padEpoch;                                      // registry epoch of the pad `pad` was copied at
    uint32_t mapSpecCrc;                                    // spec CRC the loaded mapping targets
    GDHubVirtualPad * pad;                                  // +1, held across frames (see liveSetup); dropped when the epoch moves
    OSData * padSpec;                                       // +1, the spec the buffers were built from
    IOBufferMemoryDescriptor * inBuf[GDHUB_MAX_INPUT_REPORTS];     // one fixed-length buffer per input-table entry (SetLength once)
    uint8_t * inAddr[GDHUB_MAX_INPUT_REPORTS];
    uint32_t inLen[GDHUB_MAX_INPUT_REPORTS];
    int8_t repBuf[GDX_MAX_REPORTS];                         // mapping report index -> input-table entry, -1 = not submittable
    uint64_t lastDeliverTicks, silenceTicks, nextLiveTry;     // lastDeliverTicks: the last frame translated AND submitted (or found unchanged) in LIVE
    gdh_meter meter2;                                       // total (hop slot) and occupancy (hr slot)
    gdh_meter meter3;                                       // AddReportToPool (hop slot) and the submit round trip (hr slot)
};

bool GDHubReceiverTap::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(GDHubReceiverTap_IVars, 1);
    if (!ivars) return false;
    ivars->powered = true;
    mach_timebase_info_data_t tb = {0, 0};
    mach_timebase_info(&tb);
    if (tb.numer == 0 || tb.denom == 0) { tb.numer = 1; tb.denom = 1; }
    ivars->fastTicks = (uint64_t)GDHUB_TAP_TICK_MS * 1000000ull * tb.denom / tb.numer;
    ivars->slowTicks = (uint64_t)GDHUB_TAP_SLOW_TICK_MS * 1000000ull * tb.denom / tb.numer;
    ivars->retryTicks = (uint64_t)GDHUB_TAP_OPEN_RETRY_MS * 1000000ull * tb.denom / tb.numer;
    gdh_meter_init(&ivars->meter, tb.numer, tb.denom, GDHUB_METER_WINDOW_MS);
    gdh_meter_init(&ivars->meter2, tb.numer, tb.denom, GDHUB_METER_WINDOW_MS);
    gdh_meter_init(&ivars->meter3, tb.numer, tb.denom, GDHUB_METER_WINDOW_MS);
    ivars->silenceTicks = (uint64_t)GDH_SILENCE_NEUTRAL_MS * 1000000ull * tb.denom / tb.numer;
    memset(ivars->repBuf, -1, sizeof(ivars->repBuf));
    return true;
}

// An OSAction retains its target until it is cancelled or freed (OSAction.iig:69-70), and this object holds its actions, so
// without the Cancel calls in Stop's cancel handler the tap would never reach free(). This line, with the tapStarts and
// tapFrees counters of status2, shows whether it does: starts == frees + live instances.
void GDHubReceiverTap::free()
{
    if (ivars) {
        GDLog("tap free #%u", ivars->startNo);
        gdhr_ctr_add(GDHubReg(), GDHR_CTR_TAP_FREES, 1);
        OSSafeReleaseNULL(ivars->timerAction);
        OSSafeReleaseNULL(ivars->timer);
        OSSafeReleaseNULL(ivars->reportAction);
        OSSafeReleaseNULL(ivars->queue);
        for (uint32_t i = 0; i < GDH_POOL_SLOTS; i++) OSSafeReleaseNULL(ivars->poolObj[i]);
        OSSafeReleaseNULL(ivars->hid);
        OSSafeReleaseNULL(ivars->pad);
        OSSafeReleaseNULL(ivars->padSpec);
        for (uint32_t i = 0; i < GDHUB_MAX_INPUT_REPORTS; i++) OSSafeReleaseNULL(ivars->inBuf[i]);
    }
    IOSafeDeleteNULL(ivars, GDHubReceiverTap_IVars, 1);
    super::free();
}

bool GDHubTapReadMeter(GDHubReceiverTap * tap, gdh_summary * xlate, gdh_summary * k2d, uint32_t * windows)
{
    if (!tap || !tap->ivars) return false;
    return gdh_meter_read(&tap->ivars->meter, xlate, k2d, windows) != 0;
}

bool GDHubTapReadParity(GDHubReceiverTap * tap, gdh_parity_rec * rec)
{
    if (!tap || !tap->ivars) return false;
    return gdh_parity_read(&tap->ivars->parity, rec) != 0;
}

bool GDHubTapReadLive(GDHubReceiverTap * tap, gdh_summary * total, gdh_summary * occ, gdh_summary * addPool, gdh_summary * submit)
{
    if (!tap || !tap->ivars) return false;
    uint32_t w = 0;
    bool a = gdh_meter_read(&tap->ivars->meter2, total, occ, &w) != 0;
    bool b = gdh_meter_read(&tap->ivars->meter3, addPool, submit, &w) != 0;
    return a && b;
}

// ---------------------------------------------------------------------------------------------------------------
// Lifecycle

// Start returns an error after undoing the super Start (the documented pattern for a failed Start), so IOKit attaches the
// next candidate, Apple's event driver (T0.2 measured that this works).
#define TAP_FAIL_START(kr) do { ivars->superStopped = true; Stop(provider, SUPERDISPATCH); return (kr); } while (0)

kern_return_t IMPL(GDHubReceiverTap, Start)
{
    kern_return_t kr = Start(provider, SUPERDISPATCH);
    if (kr != kIOReturnSuccess) { GDLog("tap start: super Start failed 0x%x", (unsigned)kr); return kr; }
    gdhr * reg = GDHubReg();
#if GDHUB_TAP_DECLINE
    GDLog("tap start declined (GDHUB_TAP_DECLINE build) pid=%d", (int)getpid());
    TAP_FAIL_START(kIOReturnUnsupported);
#endif
    if (!reg) { GDLog("tap start: no registry lock"); TAP_FAIL_START(kIOReturnNoMemory); }
    if (gdhr_terminating(reg)) {
        // devTerminate is ending this process: a tap attached now would keep it alive. Decline; Apple's driver takes over.
        GDLog("tap start declined: dext is terminating pid=%d", (int)getpid());
        TAP_FAIL_START(kIOReturnUnsupported);
    }
    ivars->hid = OSDynamicCast(IOHIDInterface, provider);
    if (!ivars->hid) { GDLog("tap start: provider is not an IOHIDInterface"); TAP_FAIL_START(kIOReturnBadArgument); }
    ivars->hid->retain();

    kr = CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->queue);
    if (kr == kIOReturnSuccess) kr = IOTimerDispatchSource::Create(ivars->queue, &ivars->timer);
    if (kr == kIOReturnSuccess) kr = CreateActionTapTick(0, &ivars->timerAction);
    if (kr == kIOReturnSuccess) kr = ivars->timer->SetHandler(ivars->timerAction);
    if (kr == kIOReturnSuccess) kr = CreateActionReportAvailable(0, &ivars->reportAction);
    if (kr != kIOReturnSuccess) { GDLog("tap start: setup failed 0x%x", (unsigned)kr); TAP_FAIL_START(kr); }

    gdhr_set_queue_idx(reg, GDHR_Q_TAP, GDHubQueueIndex(ivars->queue));
    // Register and read the desired state in one critical section. Normally INERT: after a relaunch nothing is armed. In the
    // same process, a re-enumeration (controller off/on, Mac wake) starts a new instance that finds COUNT still asked for.
    uint32_t desired = 0;
    int replaced = gdhr_register_tap_ex(reg, static_cast<OSObject *>(this), ivars->queue, (uint32_t)getpid(), &desired, &ivars->myToken);
    gdhr_set_hold(reg, 0);                                             // a new tap starts with no hold (plan 6.2); its xstate is fresh, so its first frame posts everything
    gdhr_ctr_add(reg, GDHR_CTR_TAP_STARTS, 1);
    ivars->startNo = (uint32_t)gdhr_ctr_get(reg, GDHR_CTR_TAP_STARTS);
    ivars->timer->SetEnable(true);
    kr = ivars->timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, mach_absolute_time() + ivars->fastTicks, ivars->fastTicks / 10);
    if (kr != kIOReturnSuccess) {
        GDLog("tap start: timer arm failed 0x%x", (unsigned)kr);
        gdhr_unregister_tap(reg, static_cast<OSObject *>(this));
        TAP_FAIL_START(kr);
    }
    GDLog("tap start #%u pid=%d desired=%u replaced=%d tapq=%u", ivars->startNo, (int)getpid(), (unsigned)desired, replaced,
          gdhr_queue_idx(reg, GDHR_Q_TAP));
    return kIOReturnSuccess;
}

// ---------------------------------------------------------------------------------------------------------------
// T7: LIVE helpers (tap queue only). The tap holds one +1 on the pad and one on its spec across frames; nothing on the frame
// path takes the registry lock or allocates. The reference is dropped when the registry's pad epoch moves (a pad entered or left
// the slot): the frame path notices with one acquire load and simply stops submitting; the 50 ms tick rebuilds or releases.

static void liveRelease(GDHubReceiverTap_IVars * iv)
{
    iv->liveActive = false;
    OSSafeReleaseNULL(iv->pad);
    OSSafeReleaseNULL(iv->padSpec);
    for (uint32_t i = 0; i < GDHUB_MAX_INPUT_REPORTS; i++) { OSSafeReleaseNULL(iv->inBuf[i]); iv->inAddr[i] = nullptr; iv->inLen[i] = 0; }
    memset(iv->repBuf, -1, sizeof(iv->repBuf));
}

// Loads the accepted mapping into this tap's private copy when the registry's sequence moved. Lock-free; a torn read keeps the old
// copy. Returns true when a NEW mapping was loaded (xstate is reset, the caller re-derives anything that depends on the map).
static bool loadMap(GDHubReceiverTap * tap, GDHubReceiverTap_IVars * iv, gdhr * reg)
{
    uint32_t seq = gdhr_map_seq(reg);
    if (seq == iv->haveSeq) return false;
    uint32_t n = 0, rev = 0, crc = 0, got = 0;
    if (!gdhr_map_read(reg, iv->mapRaw, sizeof(iv->mapRaw), &n, &got, &rev, &crc)) return false;     // never blocks
    iv->haveSeq = got;
    iv->haveMap = false;
    gdx_reset(&iv->xstate);                                    // hysteresis and dedupe restart with every mapping
    if (n == sizeof(gdx_map)) {
        memcpy(&iv->map, iv->mapRaw, sizeof(gdx_map));         // the bytes were written from a validated gdx_map by this same build
        iv->haveMap = (iv->map.nReports <= GDX_MAX_REPORTS && iv->map.nButtons <= GDX_MAX_BUTTONS &&
                       iv->map.nAxes <= GDX_MAX_AXES && iv->map.nTriggers <= GDX_MAX_TRIGGERS &&
                       iv->map.nPlacements <= GDX_MAX_PLACEMENTS && iv->map.nReports >= 1);
    }
    iv->mapRevision = iv->haveMap ? iv->map.revision : 0;
    iv->mapSpecCrc = iv->haveMap ? crc : 0;
    gdhr_ctr_add(reg, GDHR_CTR_MAP_SWAPS, 1);
    gdhr_tap_publish_xlate(reg, static_cast<OSObject *>(tap), iv->mapRevision, iv->haveMap ? 1 : 0);
    return true;
}

// Which input-table entry each report of the mapping goes to, found once per mapping by building the neutral state through it
// (the report ID is the first byte). No allocation. False if a report matches no entry or its length differs from the buffer's.
static bool remapReports(GDHubReceiverTap_IVars * iv)
{
    memset(iv->repBuf, -1, sizeof(iv->repBuf));
    if (!iv->haveMap || !iv->padSpec) return false;
    gdx_pad zero;
    memset(&zero, 0, sizeof(zero));
    gdx_out o;
    gdx_build(&iv->map, &zero, &o);
    if (o.count == 0 || o.count > GDX_MAX_REPORTS) return false;
    for (uint32_t i = 0; i < o.count; i++) {
        int idx = GDHubSpecFindInput(iv->padSpec, o.r[i].bytes, o.r[i].len);
        if (idx < 0 || (uint32_t)idx >= GDHUB_MAX_INPUT_REPORTS || !iv->inBuf[idx] || iv->inLen[idx] != o.r[i].len) return false;
        iv->repBuf[i] = (int8_t)idx;
    }
    return true;
}

// Allocates (the only place that does): pad reference, spec reference and the fixed-length input buffers (SetLength once, like the
// user client's), then derives the report map. Tap queue, from syncMode and the tick only, never from the frame path.
static bool liveSetup(GDHubReceiverTap * tap, GDHubReceiverTap_IVars * iv, gdhr * reg)
{
    liveRelease(iv);
    loadMap(tap, iv, reg);
    if (!iv->haveMap) return false;
    iv->padEpoch = gdhr_pad_epoch(reg);
    GDHubVirtualPad * pad = GDHubCopyPad();
    OSData * spec = GDHubCopyPadSpec();
    if (!pad || !spec || GDHubSpecCRC32(spec) != iv->mapSpecCrc) {
        if (pad) pad->release();
        if (spec) spec->release();
        return false;
    }
    uint32_t count = GDHubSpecInputCount(spec);
    bool ok = count >= 1 && count <= GDHUB_MAX_INPUT_REPORTS;
    for (uint32_t i = 0; ok && i < count; i++) {
        uint32_t len = GDHubSpecSendLength(spec, i);
        IOBufferMemoryDescriptor * b = nullptr;
        IOAddressSegment seg = {};
        ok = len != 0 && len <= GDHUB_MAX_REPORT &&
             IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, len, 0, &b) == kIOReturnSuccess && b &&
             b->SetLength(len) == kIOReturnSuccess && b->GetAddressRange(&seg) == kIOReturnSuccess && seg.address != 0 && seg.length >= len;
        if (b) { if (ok) { iv->inBuf[i] = b; iv->inAddr[i] = (uint8_t *)seg.address; iv->inLen[i] = len; } else b->release(); }
    }
    iv->pad = pad;
    iv->padSpec = spec;
    if (ok) ok = remapReports(iv);
    if (!ok) { liveRelease(iv); return false; }
    iv->liveActive = true;
    iv->needReset = true;                                       // the first frame after setup posts the full state
    return true;
}

// Posts the pad's neutral reports with source TAP, only if this instance is the registered tap and the tap is the pad's source.
// Tap queue; may use a temporary pad reference when LIVE was never set up (the source can already be TAP: the user client stores
// it before the tap has applied LIVE). The pad's own queue serialises it with any submission; the post order is therefore total.
static void tapNeutral(GDHubVirtualPad * held, GDHubReceiverTap_IVars * iv, gdhr * reg, uint32_t reason)
{
    if (gdhr_pad_source(reg) != GDHUB_PADSRC_TAP || iv->myToken != gdhr_tap_token(reg)) return;
    bool temp = !(held && iv->padEpoch == gdhr_pad_epoch(reg));      // a held reference is used only while it is the slot's pad
    GDHubVirtualPad * pad = temp ? GDHubCopyPad() : held;
    if (!pad) return;
    GDH_SYNC(GDHR_RANK_TAP, GDHR_RANK_PAD, GDHubPadQueue(pad), "postNeutralFrom(tap)");
    pad->postNeutralFrom(GDHUB_PADSRC_TAP, iv->myToken, reason);
    if (temp) pad->release();
    gdx_reset(&iv->xstate);                                     // whatever comes next reposts the whole state
    iv->needReset = true;
}

// Drops the whole pool: after a Close nobody knows whether the kernel keeps its pool, so a fresh one is built at the next
// Open. A late report that still carries an old buffer then matches nothing (counted as a pool miss) and is never touched.
static void poolRelease(GDHubReceiverTap_IVars * iv)
{
    void * old[GDH_POOL_SLOTS];
    gdh_pool_reset(&iv->pool, old);
    for (uint32_t i = 0; i < GDH_POOL_SLOTS; i++) { OSSafeReleaseNULL(iv->poolObj[i]); iv->poolAddr[i] = nullptr; }
}

// Tap queue only. `opened` becomes false even if Close fails (we must not keep counting); the failure is counted and the next
// Open is still attempted.
static void closeInterface(GDHubReceiverTap * self, GDHubReceiverTap_IVars * iv, const char * why)
{
    if (!iv->opened || !iv->hid) return;
    gdhr * reg = GDHubReg();
    kern_return_t kr = iv->hid->Close(self, 0);                       // IOHIDInterface.iig:168
    iv->opened = false;
    iv->everClosed = true;
    if (kr != kIOReturnSuccess) { gdhr_ctr_add(reg, GDHR_CTR_CLOSE_FAILURES, 1); gdhr_set_last_error(reg, (uint32_t)kr); }
    gdhr_tap_publish(reg, static_cast<OSObject *>(self), 0, GDH_FWD_INERT);
    iv->mode = 0;
    if (iv->shadowActive) {
        iv->shadowActive = false;
        gdhr_tap_publish_xlate(reg, static_cast<OSObject *>(self), 0, 0);
    }
    iv->haveMap = false;                                               // a map is never kept across an Open: the next Open reloads it
    iv->haveSeq = ~gdhr_map_seq(reg);
    iv->wantLive = false;
    liveRelease(iv);                                                   // the pad reference does not outlive the open interface
    iv->lastDeliverTicks = 0; iv->silenced = false;
    poolRelease(iv);
    GDLog("tap close (%{public}s) rc=0x%x", why, (unsigned)kr);
}

kern_return_t IMPL(GDHubReceiverTap, Stop)
{
    GDLog("tap stop #%u opened=%d", ivars->startNo, (int)ivars->opened);
    __atomic_store_n(&ivars->stopping, true, __ATOMIC_RELAXED);        // reports, ticks and pokes that are still queued return at once
    // The controller went away (or the dext is ending): if this tap was driving the pad, the pad goes neutral NOW (plan 6.4). Only
    // the registered tap does it, so an older instance stopping after its successor started cannot blank the successor's pad.
    tapNeutral(ivars->pad, ivars, GDHubReg(), GDHUB_NEUTRAL_STOP);
    closeInterface(this, ivars, "stop");                               // Close comes before the actions are cancelled
    gdhr_unregister_tap(GDHubReg(), static_cast<OSObject *>(this));    // no more pokes; ignored if a newer tap replaced us
    if (ivars->superStopped) return kIOReturnSuccess;                  // Start already ran the super Stop
    ivars->superStopped = true;
    if (!ivars->timer) return Stop(provider, SUPERDISPATCH);
    // The timer's cancel callout dereferences the timer's ivars, so hold ourselves and complete the super Stop only from
    // inside the cancel handler (same documented pattern as the user client). The handler also breaks the reference cycles
    // object -> action -> object: both actions are cancelled (OSAction.iig:69-70, 100-105: after Cancel the action can only be
    // freed and no longer retains its target), and the pool and the provider are released. Everything that could touch them
    // checks `stopping` first, or finds a null/empty slot.
    ivars->timer->SetEnable(false);
    this->retain();
    ivars->timer->Cancel(^{
        if (ivars->reportAction) ivars->reportAction->Cancel(^{});
        if (ivars->timerAction) ivars->timerAction->Cancel(^{});
        Stop(provider, SUPERDISPATCH);
        poolRelease(ivars);
        OSSafeReleaseNULL(ivars->hid);
        this->release();
    });
    return kIOReturnSuccess;
}

// Make the driver safe, then pass the call to super (IOService.iig:250-262). Off: ignore frames until On. The interface is
// not closed here: the receiver re-enumerates on wake (T0.2) and a new instance starts, which opens again only if still armed.
kern_return_t IMPL(GDHubReceiverTap, SetPowerState)
{
    bool off = (powerFlags == kIOServicePowerCapabilityOff);
    bool on = (powerFlags & kIOServicePowerCapabilityOn) != 0;
    gdhr * reg = GDHubReg();
    if (off) {
        ivars->powered = false;
        tapNeutral(ivars->pad, ivars, reg, GDHUB_NEUTRAL_POWER);       // Mac sleep: neutral first, then frames are ignored
    } else if (on) {
        ivars->powered = true;
        if (ivars->myToken == gdhr_tap_token(reg)) gdhr_set_hold(reg, 0);       // the hold ends at power on (plan 6.2)
        gdx_reset(&ivars->xstate);
        ivars->needReset = true;
    }
    gdhr_tap_set_power(GDHubReg(), static_cast<OSObject *>(this), ivars->powered ? 1 : 0, powerFlags);
    GDLog("tap SetPowerState flags=0x%x powered=%d opened=%d", (unsigned)powerFlags, (int)ivars->powered, (int)ivars->opened);
    return SetPowerState(powerFlags, SUPERDISPATCH);
}

// ---------------------------------------------------------------------------------------------------------------
// COUNT: pool, Open, Close (plan 4.5)

static void poolBuild(GDHubReceiverTap_IVars * iv)
{
    uint32_t failed = 0;
    for (uint32_t i = 0; i < GDH_POOL_SLOTS; i++) {
        kern_return_t kr = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, GDHUB_TAP_POOL_BUF, 0, &iv->poolObj[i]);
        if (kr != kIOReturnSuccess || !iv->poolObj[i]) { iv->poolObj[i] = nullptr; failed++; continue; }
        iv->poolObj[i]->SetLength(GDHUB_TAP_POOL_BUF);                 // once per buffer, here; never per frame
        IOAddressSegment seg = {};
        if (iv->poolObj[i]->GetAddressRange(&seg) != kIOReturnSuccess || seg.address == 0) { OSSafeReleaseNULL(iv->poolObj[i]); failed++; continue; }
        iv->poolAddr[i] = (uint8_t *)seg.address;
        gdh_pool_set(&iv->pool, (int)i, static_cast<void *>(static_cast<IOMemoryDescriptor *>(iv->poolObj[i])));
    }
    iv->pool.ready = 1;
    if (failed) GDLog("tap pool: %u of %u buffers could not be created", failed, (unsigned)GDH_POOL_SLOTS);
}

// Puts every buffer of ours that is not in the kernel's pool into it (all of them on a fresh pool).
static void poolFill(GDHubReceiverTap_IVars * iv)
{
    for (int i = gdh_pool_next_missing(&iv->pool, 0); i >= 0; i = gdh_pool_next_missing(&iv->pool, i + 1)) {
        if (iv->hid->AddReportToPool(iv->poolObj[i]) == kIOReturnSuccess) gdh_pool_added(&iv->pool, i);     // IOHIDInterface.iig:129
        else gdhr_ctr_add(GDHubReg(), GDHR_CTR_READD_FAIL, 1);
    }
}

// Keeps the applied mode (COUNT or SHADOW) and the "translating" flag in step with the desired state while the interface is
// open. SHADOW is only active after a passed self-test; otherwise the tap simply keeps counting. Tap queue only.
static void syncMode(GDHubReceiverTap * tap, GDHubReceiverTap_IVars * iv, gdhr * reg)
{
    if (!iv->opened) return;
    uint32_t d = gdhr_desired_state(reg);
    uint32_t want = (d == GDH_FWD_LIVE) ? GDH_FWD_LIVE : ((d == GDH_FWD_SHADOW) ? GDH_FWD_SHADOW : GDH_FWD_COUNT);
    bool shadow = (want >= GDH_FWD_SHADOW) && gdhr_selftest_get(reg) == GDHR_SELFTEST_PASS;
    bool live = (want == GDH_FWD_LIVE) && shadow;
    if (want != iv->mode) {
        iv->mode = want;
        gdhr_tap_publish(reg, static_cast<OSObject *>(tap), 1, want);
        GDLog("tap mode %u", (unsigned)want);
    }
    if (shadow != iv->shadowActive) {
        iv->shadowActive = shadow;
        iv->haveMap = false;
        iv->haveSeq = ~gdhr_map_seq(reg);
        gdx_reset(&iv->xstate);
        gdhr_tap_publish_xlate(reg, static_cast<OSObject *>(tap), 0, 0);
    }
    if (live != iv->wantLive) {
        iv->wantLive = live;
        iv->nextLiveTry = 0;
        iv->liveNoteLogged = false;
        if (live) {
            gdx_reset(&iv->xstate);
            iv->needReset = true;                                      // the first LIVE frame reposts everything
            iv->silenced = false;
            iv->lastDeliverTicks = mach_absolute_time();               // the silence clock starts now, not at the last frame of SHADOW
        } else {
            liveRelease(iv);
        }
    }
    if (iv->wantLive && !iv->liveActive) {
        // (Re)build the pad reference and buffers: at most every 500 ms, and quietly (one log line per run of failures).
        uint64_t now = mach_absolute_time();
        if (now >= iv->nextLiveTry) {
            if (!liveSetup(tap, iv, reg)) {
                iv->nextLiveTry = now + iv->retryTicks;
                if (!iv->liveNoteLogged) { iv->liveNoteLogged = true; GDLog("tap live: not ready (no pad, mapping or buffers yet); frames are not submitted"); }
            } else {
                GDLog("tap live: ready (pad epoch %u, mapping rev %u)", (unsigned)iv->padEpoch, (unsigned)iv->mapRevision);
            }
        }
    }
}

// Tap queue only. The one place Open and Close are called; gdh_tap_decide says which, and when. `fromTick` is 1 when the timer
// (not a poke) got here, for the tickApplies counter. Returns the action taken.
static int tapApply(GDHubReceiverTap * tap, int fromTick)
{
    auto iv = tap->ivars;
    gdhr * reg = GDHubReg();
    if (!iv || !iv->hid) return GDH_TAP_NONE;                          // after Stop released it
    uint64_t now = mach_absolute_time();
    int act = gdh_tap_decide(gdhr_desired_state(reg), iv->opened, iv->powered, __atomic_load_n(&iv->stopping, __ATOMIC_RELAXED),
                             now >= iv->nextOpenTicks);
    if (act == GDH_TAP_CLOSE) {
        if (fromTick) gdhr_ctr_add(reg, GDHR_CTR_TICK_APPLIES, 1);
        closeInterface(tap, iv, "inert");
    } else if (act == GDH_TAP_OPEN) {
        if (fromTick) gdhr_ctr_add(reg, GDHR_CTR_TICK_APPLIES, 1);
        if (!iv->pool.ready) poolBuild(iv);                            // a fresh pool after every Close
        poolFill(iv);
        iv->openTries++;
        kern_return_t kr = iv->hid->Open(tap, 0, iv->reportAction);    // IOHIDInterface.iig:149-151
        if (kr != kIOReturnSuccess) {
            // A user-space client that seized the device makes Open fail. Retry from the timer, count it, never spin.
            iv->nextOpenTicks = now + iv->retryTicks;
            gdhr_ctr_add(reg, GDHR_CTR_OPEN_FAILURES, 1);
            gdhr_set_last_error(reg, (uint32_t)kr);
            if (iv->openFailLogged < 3 || iv->openFailLogged % 60 == 0) GDLog("tap open failed 0x%x try %u", (unsigned)kr, iv->openTries);
            iv->openFailLogged++;
            return act;
        }
        iv->opened = true;
        iv->openFailLogged = 0;
        if (iv->everClosed) gdhr_ctr_add(reg, GDHR_CTR_REOPENS, 1);
        gdhr_set_last_error(reg, 0);
        iv->mode = 0;                                                  // syncMode below publishes the applied state
        iv->haveMap = false;
        iv->haveSeq = ~gdhr_map_seq(reg);                              // force a load of the accepted mapping at the first frame
        gdx_reset(&iv->xstate);
        GDLog("tap open rc=0x0 try %u (success is judged by frames arriving)", iv->openTries);
    }
    syncMode(tap, iv, reg);
    return act;
}

// Runs on the tap's queue from the DispatchAsync block of GDHubPokeTap.
void GDHubTapApply(GDHubReceiverTap * tap)
{
    gdhr_ctr_add(GDHubReg(), GDHR_CTR_POKES_RUN, 1);
    tapApply(tap, 0);
}

// The timer is a backstop for a lost poke and drives the Open retry. Adaptive: 50 ms while the tap has something to do, is
// waiting to retry an Open, or the dext is terminating; otherwise 1 s.
void IMPL(GDHubReceiverTap, TapTick)
{
    (void)action; (void)time;
    if (__atomic_load_n(&ivars->stopping, __ATOMIC_RELAXED)) return;   // Stop is cancelling the timer: do nothing, do not re-arm
    gdhr * reg = GDHubReg();
    uint32_t terminating = gdhr_terminating(reg);
    if (terminating && !ivars->selfTerminated) {
        // devTerminate / root Stop only reach the REGISTERED tap. An older instance or a second receiver's tap would keep the
        // shared process alive, so every tap ends itself once when the dext is terminating. No more ticks after that.
        ivars->selfTerminated = true;
        kern_return_t kr = Terminate(0);                               // IOService.iig:324-326
        GDLog("tap #%u terminates itself (dext is terminating) rc=0x%x", ivars->startNo, (unsigned)kr);
        return;
    }
    if (ivars->selfTerminated) return;
    tapApply(this, 1);
    // LIVE silence neutral (plan 6.4): the stream stopped without the receiver re-enumerating (controller asleep, link lost).
    // No frame for 250 ms -> neutral and a full repost with the next frame. The tick is 50 ms in LIVE (gdh_tap_fast_tick), so the
    // neutral is on the pad within 250-300 ms of the last frame.
    if (gdh_silence_due(ivars->wantLive, ivars->opened, ivars->powered, ivars->silenced, gdhr_hold(reg), gdhr_pad_source(reg),
                        ivars->lastDeliverTicks, mach_absolute_time(), ivars->silenceTicks)) {
        ivars->silenced = true;
        tapNeutral(ivars->liveActive ? ivars->pad : nullptr, ivars, reg, GDHUB_NEUTRAL_SILENCE);
    }
    bool fast = gdh_tap_fast_tick(gdhr_desired_state(reg), ivars->opened, ivars->powered, 0, terminating) != 0;
    uint64_t next = fast ? ivars->fastTicks : ivars->slowTicks;
    ivars->timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, mach_absolute_time() + next, next / 10);
}

// SHADOW and LIVE, one frame (tap queue, per report). Takes no lock and allocates nothing: the shared reads are acquire loads of
// the registry's mapSeq, padEpoch, padSource, tapToken and holdNeutral (and, when mapSeq moved, a lock-free seqlock read of the
// mapping into this tap's private copy). Everything the translator touches is in `iv` (map, state) or on the stack (gdx_out twice,
// gdx_pad: about 600 bytes). In LIVE the only call out is pad->submitInput, one synchronous RPC per changed report onto the pad's
// own queue (rank 3 -> rank 4; the pad calls nothing, so the tap can wait only for the pad's queue to get to it, never for the
// root's or the user client's). `submitTicks` is the time spent in those calls.
static void shadowFrame(GDHubReceiverTap * tap, GDHubReceiverTap_IVars * iv, gdhr * reg, const uint8_t * bytes, uint32_t len,
                        uint64_t timestamp, uint64_t * xlateTicks, uint64_t * submitTicks)
{
    if (loadMap(tap, iv, reg) && iv->wantLive) {
        // A new mapping may have another report layout. The buffers stay (they belong to the pad's spec); only the report map is
        // re-derived, without allocation. If it no longer fits, nothing is submitted until the tick sets LIVE up again.
        if (!iv->haveMap || !remapReports(iv)) iv->liveActive = false;
        iv->needReset = true;
    }
    if (!iv->haveMap) { gdhr_ctr_add(reg, GDHR_CTR_FRAMES_NOMAP, 1); return; }
    if (len != GDX_SOURCE_REPORT_LEN || bytes[0] != GDX_SOURCE_REPORT_ID) { gdhr_ctr_add(reg, GDHR_CTR_FRAMES_SKIPPED, 1); return; }

    // LIVE gate: every condition is a cheap atomic load, and each is re-checked by the pad on its own queue anyway (it is the
    // arbiter); checking here only avoids sending what would be refused. Not submitting never loses state: the next frame after
    // the gate opens reposts everything (needReset), and the stream is full-state at ~955 reports/s.
    bool submit = false;
    if (iv->wantLive) {
        if (iv->liveActive && iv->padEpoch != gdhr_pad_epoch(reg)) iv->liveActive = false;      // the pad changed under us: the tick rebuilds
        bool held = gdhr_hold(reg) != 0;
        submit = gdh_live_submit_ok(iv->liveActive, held ? 1 : 0, iv->myToken, gdhr_tap_token(reg), iv->padEpoch, gdhr_pad_epoch(reg),
                                    gdhr_pad_source(reg)) != 0;
        if (!submit) { iv->needReset = true; if (!held) gdhr_ctr_add(reg, GDHR_CTR_LIVE_NO_PAD, 1); }
        else if (iv->needReset) { gdx_reset(&iv->xstate); iv->needReset = false; }
    }

    uint64_t t0 = mach_absolute_time();
    gdx_out out;
    uint32_t mask = gdx_step(&iv->xstate, &iv->map, bytes, len, &out);       // what a LIVE tap posts
    gdx_pad pad;
    gdx_out stateless;
    gdh_parity_rec rec;
    if (gdx_eval(&iv->map, bytes, len, &pad) == 0) {
        gdx_build(&iv->map, &pad, &stateless);                           // the stateless result: what the engine's own core must also produce
        memcpy(rec.frame, bytes, 16);
        memset(rec.out01, 0, sizeof(rec.out01));
        memset(rec.out02, 0, sizeof(rec.out02));
        memset(rec.pad, 0, sizeof(rec.pad));
        if (stateless.count >= 1) memcpy(rec.out01, stateless.r[0].bytes, stateless.r[0].len < 16 ? stateless.r[0].len : 16);
        if (stateless.count >= 2) memcpy(rec.out02, stateless.r[1].bytes, stateless.r[1].len < 2 ? stateless.r[1].len : 2);
        rec.timestamp = timestamp;
        rec.revision = iv->mapRevision;
        rec.count = ++iv->parityCount;
        gdh_parity_write(&iv->parity, &rec);
    }
    uint64_t t2 = mach_absolute_time();
    *xlateTicks = t2 - t0;
    gdhr_ctr_add(reg, GDHR_CTR_FRAMES_TRANSLATED, 1);
    if (mask != 0) {
        gdhr_ctr_add(reg, GDHR_CTR_STATES_CHANGED, 1);
        gdhr_ctr_add(reg, GDHR_CTR_REPORTS_WOULD_POST, (uint64_t)__builtin_popcount(mask));
    }
    // The LIVE silence clock (plan 6.4, review D9) counts DELIVERY, not arrival: a frame that was translated and either submitted or
    // found unchanged (an idle controller streams identical frames) moves it; a frame that could not be submitted (set-up failed, no
    // map, the pad changed, a refused submit) does not, so whatever stops the tap from delivering ends in the same 250-300 ms neutral.
    if (!submit) return;
    if (mask == 0) { gdhr_ctr_add(reg, GDHR_CTR_FRAMES_UNCHANGED, 1); iv->lastDeliverTicks = t2; iv->silenced = false; return; }
    bool failed = false;
    for (uint32_t i = 0; i < out.count && i < GDX_MAX_REPORTS; i++) {
        if (!((mask >> i) & 1u)) continue;
        int idx = iv->repBuf[i];
        if (idx < 0 || out.r[i].len != iv->inLen[idx]) { iv->needReset = true; failed = true; gdhr_ctr_add(reg, GDHR_CTR_LIVE_NO_PAD, 1); continue; }
        memcpy(iv->inAddr[idx], out.r[i].bytes, out.r[i].len);          // the buffer's length was set once, at setup
        GDH_SYNC(GDHR_RANK_TAP, GDHR_RANK_PAD, GDHubPadQueue(iv->pad), "submitInput(tap)");
        kern_return_t kr = iv->pad->submitInput(GDHUB_PADSRC_TAP, iv->myToken, t2, iv->inBuf[idx], out.r[i].len);
        if (kr != kIOReturnSuccess) {
            gdhr_ctr_add(reg, GDHR_CTR_TAP_SUBMIT_ERRORS, 1);           // the pad refused or failed: whatever it has is stale, repost all
            iv->needReset = true;
            failed = true;
        }
    }
    uint64_t t3s = mach_absolute_time();
    *submitTicks = t3s - t2;
    if (!failed) { iv->lastDeliverTicks = t3s; iv->silenced = false; }
}

// ---------------------------------------------------------------------------------------------------------------
// The report path. Runs only while the interface is open, which only an owner's COUNT, SHADOW or LIVE request causes.

void IMPL(GDHubReceiverTap, ReportAvailable)
{
    (void)action; (void)type;
    auto iv = ivars;
    if (__atomic_load_n(&iv->stopping, __ATOMIC_RELAXED)) return;      // after Stop the pool is gone: nothing is touched
    gdhr * reg = GDHubReg();
    uint64_t now = mach_absolute_time();                               // t1: tap entry

    // Ownership bookkeeping first, whatever the state: a buffer of ours that the kernel delivered is out of its pool.
    int slot = gdh_pool_find(&iv->pool, static_cast<const void *>(report));
    if (slot >= 0) gdh_pool_delivered(&iv->pool, slot);
    else gdhr_ctr_add(reg, GDHR_CTR_POOL_MISS, 1);                     // a kernel buffer, or a late one from a dropped pool
    if (!iv->opened) return;                                           // late delivery after Close: never counted, never re-added

    // The pause drill (every build with CAP_LIVE, owner only): frames are ignored, as if the tap stalled. They do not count as
    // framesIn (the engine's F1 watches that counter), do not reset the silence clock, and the buffer still goes back to the pool.
    uint64_t pauseUntil = gdhr_pause_until(reg);
    bool paused = pauseUntil != 0 && now < pauseUntil;
    if (paused) {
        gdhr_ctr_add(reg, GDHR_CTR_PAUSE_DROPS, 1);
        if (!iv->pauseLogged) { iv->pauseLogged = true; GDLog("tap pause start"); }
    } else if (iv->pauseLogged) {
        iv->pauseLogged = false;
        iv->needReset = true;                                          // the pad may have gone neutral by silence meanwhile
        gdx_reset(&iv->xstate);
        GDLog("tap pause end");
    }

    uint64_t t3 = now, xlateTicks = 0, submitTicks = 0;
    if (paused) {
        // nothing
    } else if (!iv->powered) {
        gdhr_ctr_add(reg, GDHR_CTR_FRAMES_IGNORED, 1);
    } else if (reportLength == 0 || reportLength > GDHUB_TAP_POOL_BUF) {
        gdhr_ctr_add(reg, GDHR_CTR_FRAMES_BAD, 1);
    } else {
        gdhr_ctr_add(reg, GDHR_CTR_FRAMES_IN, 1);
        gdhr_ctr_add(reg, reportID == 6 ? GDHR_CTR_FRAMES_R06 : GDHR_CTR_FRAMES_OTHER, 1);
        if (iv->shadowActive) {
            // The bytes: our own pool buffer (mapped once at pool setup) and nothing else. A report that arrived in a buffer we do
            // not own (a pool miss) is never read: it counts framesUnmapped and is not translated, in LIVE too. The pool is 32
            // buffers (32 ms of tap-queue stall before a miss is even possible) and every frame carries the full controller state,
            // so a frame that cannot be read delays the pad by one frame interval (~1 ms) and loses nothing; the silence neutral
            // fires only if NO frame is read for 250 ms. Mapping a kernel buffer would be a blocking kernel call on this queue.
            const uint8_t * bytes = (slot >= 0 && iv->poolAddr[slot]) ? iv->poolAddr[slot] : nullptr;
            if (bytes) shadowFrame(this, iv, reg, bytes, reportLength, timestamp, &xlateTicks, &submitTicks);
            else { gdhr_ctr_add(reg, GDHR_CTR_FRAMES_UNMAPPED, 1); if (iv->wantLive) iv->needReset = true; }
        }
        t3 = mach_absolute_time();
        if (timestamp <= now &&
            gdh_meter_sample(&iv->meter, now, xlateTicks != 0, xlateTicks, now - timestamp)) {   // hop slot = translate time, hr slot = k2d
            gdh_summary xl, k2d;
            uint32_t windows = 0;
            if (gdh_meter_read(&iv->meter, &xl, &k2d, &windows)) {
                // Once per 10 s window. Worst case 237 characters by the generic estimator (u32 = 10 digits, u64 = 20); about 150 in practice.
                GDLog("tap meter b=%u w=%u n=%u k2d p50/p99/max/mean %u/%u/%u/%u.%u us xl p50/p99/max %u/%u/%u ns chg=%llu",
                      (unsigned)GDHUB_DEXT_BUILD, windows, k2d.count, k2d.p50Ns / 1000, k2d.p99Ns / 1000, k2d.maxNs / 1000,
                      k2d.meanNs / 1000, (k2d.meanNs % 1000) / 100, xl.p50Ns, xl.p99Ns, xl.maxNs,
                      gdhr_ctr_get(reg, GDHR_CTR_STATES_CHANGED));
            }
        }
    }

    // Strategy B: give our buffer back to the pool once the report is handled. A kernel temporary buffer is not re-added.
    if (slot >= 0 && iv->poolObj[slot]) {
        if (iv->hid->AddReportToPool(iv->poolObj[slot]) == kIOReturnSuccess) gdh_pool_added(&iv->pool, slot);
        else gdhr_ctr_add(reg, GDHR_CTR_READD_FAIL, 1);
    }
    if (paused) return;
    uint64_t t4 = mach_absolute_time();
    // T7 stage histograms (plan 9.1), one sample per frame each: total = kernel timestamp -> submit returned (t3 - t0), occ = this
    // queue's occupancy for the frame (t4 - t1), addPool = t4 - t3, submit = the submitInput round trip. Windows of 10 s.
    bool have = iv->shadowActive && xlateTicks != 0;
    if (have) (void)gdh_meter_sample(&iv->meter3, t4, 1, t4 - t3, submitTicks);
    if (have && timestamp <= t3 && gdh_meter_sample(&iv->meter2, t4, 1, t3 - timestamp, t4 - now)) {
        gdh_summary total, occ, addPool, submit;
        uint32_t w = 0;
        if (gdh_meter_read(&iv->meter2, &total, &occ, &w) && gdh_meter_read(&iv->meter3, &addPool, &submit, &w) && iv->wantLive) {
            // Once per window, only while LIVE is applied. Estimator worst case (u32 = 10 digits, u64 = 20): 214 characters.
            GDLog("tap live b=%u n=%u total p50/p99/max %u/%u/%u us occ p99 %u submit p50/p99 %u/%u addpool p99 %u us posts=%llu rej=%llu",
                  (unsigned)GDHUB_DEXT_BUILD, total.count, total.p50Ns / 1000, total.p99Ns / 1000, total.maxNs / 1000, occ.p99Ns / 1000,
                  submit.p50Ns / 1000, submit.p99Ns / 1000, addPool.p99Ns / 1000, gdhr_ctr_get(reg, GDHR_CTR_TAP_POSTS),
                  gdhr_ctr_get(reg, GDHR_CTR_TAP_REJECTED));
        }
    }
}
