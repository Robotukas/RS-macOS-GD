// The receiver tap, T4 (docs/plans/receiver-takeover-plan.md 3.2, 4.1, 4.5, 6.1, 6.4, 6.5).
//
// States: INERT (attached, interface NOT opened, no per-frame code) and COUNT (opened; counts reports and the kernel-to-driver
// delay; translates nothing, posts nothing). The state asked for lives in the registry (`desiredState`), starts INERT in
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
    gdh_meter meter;                                        // k2d in the `hr` slot; written on this queue, read lock-free
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
    }
    IOSafeDeleteNULL(ivars, GDHubReceiverTap_IVars, 1);
    super::free();
}

bool GDHubTapReadMeter(GDHubReceiverTap * tap, gdh_summary * k2d, uint32_t * windows)
{
    if (!tap || !tap->ivars) return false;
    gdh_summary unusedHop = {};
    return gdh_meter_read(&tap->ivars->meter, &unusedHop, k2d, windows) != 0;
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
    int replaced = gdhr_register_tap(reg, static_cast<OSObject *>(this), ivars->queue, (uint32_t)getpid(), &desired);
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
    poolRelease(iv);
    GDLog("tap close (%{public}s) rc=0x%x", why, (unsigned)kr);
}

kern_return_t IMPL(GDHubReceiverTap, Stop)
{
    GDLog("tap stop #%u opened=%d", ivars->startNo, (int)ivars->opened);
    __atomic_store_n(&ivars->stopping, true, __ATOMIC_RELAXED);        // reports, ticks and pokes that are still queued return at once
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
    if (off) ivars->powered = false; else if (on) ivars->powered = true;
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
        gdhr_tap_publish(reg, static_cast<OSObject *>(tap), 1, GDH_FWD_COUNT);
        GDLog("tap open rc=0x0 try %u (success is judged by frames arriving)", iv->openTries);
    }
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
    bool fast = gdh_tap_fast_tick(gdhr_desired_state(reg), ivars->opened, ivars->powered, 0, terminating) != 0;
    uint64_t next = fast ? ivars->fastTicks : ivars->slowTicks;
    ivars->timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, mach_absolute_time() + next, next / 10);
}

// ---------------------------------------------------------------------------------------------------------------
// The report path. Runs only while the interface is open, which only an owner's COUNT request causes.

void IMPL(GDHubReceiverTap, ReportAvailable)
{
    (void)action; (void)type;
    auto iv = ivars;
    if (__atomic_load_n(&iv->stopping, __ATOMIC_RELAXED)) return;      // after Stop the pool is gone: nothing is touched
    gdhr * reg = GDHubReg();
    uint64_t now = mach_absolute_time();

    // Ownership bookkeeping first, whatever the state: a buffer of ours that the kernel delivered is out of its pool.
    int slot = gdh_pool_find(&iv->pool, static_cast<const void *>(report));
    if (slot >= 0) gdh_pool_delivered(&iv->pool, slot);
    else gdhr_ctr_add(reg, GDHR_CTR_POOL_MISS, 1);                     // a kernel buffer, or a late one from a dropped pool
    if (!iv->opened) return;                                           // late delivery after Close: never counted, never re-added

    if (!iv->powered) {
        gdhr_ctr_add(reg, GDHR_CTR_FRAMES_IGNORED, 1);
    } else if (reportLength == 0 || reportLength > GDHUB_TAP_POOL_BUF) {
        gdhr_ctr_add(reg, GDHR_CTR_FRAMES_BAD, 1);
    } else {
        gdhr_ctr_add(reg, GDHR_CTR_FRAMES_IN, 1);
        gdhr_ctr_add(reg, reportID == 6 ? GDHR_CTR_FRAMES_R06 : GDHR_CTR_FRAMES_OTHER, 1);
        if (timestamp <= now &&
            gdh_meter_sample(&iv->meter, now, 0, 0, now - timestamp)) {      // k2d goes in the meter's second histogram
            gdh_summary unusedHop, k2d;
            uint32_t windows = 0;
            if (gdh_meter_read(&iv->meter, &unusedHop, &k2d, &windows)) {
                // Once per 10 s window. Worst case 175 characters by the generic estimator (u32 = 10 digits, u64 = 20).
                GDLog("tap meter b=%u w=%u n=%u k2d p50/p99/max/mean %u/%u/%u/%u.%u us frames=%llu miss=%llu",
                      (unsigned)GDHUB_DEXT_BUILD, windows, k2d.count, k2d.p50Ns / 1000, k2d.p99Ns / 1000, k2d.maxNs / 1000,
                      k2d.meanNs / 1000, (k2d.meanNs % 1000) / 100, gdhr_ctr_get(reg, GDHR_CTR_FRAMES_IN),
                      gdhr_ctr_get(reg, GDHR_CTR_POOL_MISS));
            }
        }
    }

    // Strategy B: give our buffer back to the pool once the report is handled. A kernel temporary buffer is not re-added.
    if (slot >= 0 && iv->poolObj[slot]) {
        if (iv->hid->AddReportToPool(iv->poolObj[slot]) == kIOReturnSuccess) gdh_pool_added(&iv->pool, slot);
        else gdhr_ctr_add(reg, GDHR_CTR_READD_FAIL, 1);
    }
}
