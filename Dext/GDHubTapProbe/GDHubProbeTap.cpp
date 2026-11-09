// T0 probe tap (plan §3.3, §4.5, §11 T0.2/T0.3). Throwaway.
//
// Queue model: Start, Stop, SetPowerState, the 1 s timer and every ReportAvailable run on the service's default queue,
// which is serial, so the ivars are touched by one thread at a time and need no locks. No lock is held across an RPC.
// Per-frame work allocates nothing and logs nothing except the first 3 frames of an Open (and the rare re-add failures).
// The slow mapping fallback (CreateMapping) does allocate; it is counted as slowMap and is not expected to run.
#include "GDHubProbe.h"
#include "GDHubProbeTap.h"

namespace {

constexpr uint32_t kPoolCount   = 8;
constexpr uint32_t kPoolBufSize = 64;                 // MaxInputReportSize (plan §4.5, measured)
constexpr uint64_t kPhaseBEndMs = 30000;              // strategy B (re-add) for the first 30 s after Open succeeds
constexpr uint64_t kPhaseAEndMs = 40000;              // strategy A (no re-add) for the next 10 s, then B again
constexpr uint64_t kWindowMs    = 10000;
constexpr uint64_t kTickMs      = 1000;
constexpr uint32_t kHistFine    = 200;                // 0..999 us in 5 us bins
constexpr uint32_t kHistCoarse  = 90;                 // 1000..9999 us in 100 us bins
constexpr uint32_t kHistBins    = kHistFine + kHistCoarse + 1;   // last bin: >= 10 ms
constexpr uint32_t kFirstFrames = 3;
constexpr uint32_t kReaddLogMax = 5;

enum Strategy : uint32_t { kStrategyB1 = 0, kStrategyA = 1, kStrategyB2 = 2 };

struct Window {
    uint64_t start;                 // mach ticks
    uint64_t frames, r06, other;
    uint64_t poolMiss, slowMap, rangeFail, badLen, tsFuture, readdFail, openFail;
    uint64_t k2dN, k2dMaxUs;
    uint64_t gapTsMaxTicks, gapArrMaxTicks;
    uint32_t hist[kHistBins];
};

}  // namespace

struct GDHubProbeTap_IVars {
    IOHIDInterface *           hid;                       // +1 on the provider
    IODispatchQueue *          queue;                     // +1
    IOTimerDispatchSource *    timer;
    OSAction *                 timerAction;
    OSAction *                 reportAction;
    IOBufferMemoryDescriptor * pool[kPoolCount];
    uint8_t *                  poolAddr[kPoolCount];
    uint64_t                   poolLen[kPoolCount];
    bool                       inPool[kPoolCount];

    uint32_t startNo;
    bool     declined, stopped, superStopped, poolReady, opened;
    uint32_t openTries, tickNo, windowNo;
    uint32_t strategy;
    uint32_t readdLogged;

    uint32_t tbNumer, tbDenom;
    double   usPerTick, msPerTick;
    uint64_t oneSecTicks, openTicks;

    uint64_t totalFrames;
    uint32_t framesLogged;
    uint64_t prevTs, prevArr;
    Window   w;

#if GDHUB_PROBE_CRASH
    bool     chordArmed;
    uint64_t chordStart;
    uint64_t twoSecTicks;
#endif
};

// ---------------------------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------------------------

static void hexDump(const uint8_t * b, uint32_t n, char * out, size_t cap)
{
    static const char digits[] = "0123456789abcdef";
    size_t o = 0;
    for (uint32_t i = 0; i < n && o + 4 < cap; i++) {
        out[o++] = digits[b[i] >> 4];
        out[o++] = digits[b[i] & 15];
        if (i + 1 < n) out[o++] = ' ';
    }
    out[o] = 0;
}

static inline void histAdd(uint32_t * h, uint64_t us)
{
    uint32_t i;
    if (us < 1000)       i = (uint32_t)(us / 5);
    else if (us < 10000) i = kHistFine + (uint32_t)((us - 1000) / 100);
    else                 i = kHistFine + kHistCoarse;
    h[i]++;
}

// Upper edge of the bin that holds the pct-th percentile, in us (the overflow bin reports the exact maximum).
static uint64_t histPercentile(const uint32_t * h, uint64_t total, uint32_t pct, uint64_t maxUs)
{
    if (total == 0) return 0;
    uint64_t need = (total * pct + 99) / 100, cum = 0;
    for (uint32_t i = 0; i < kHistBins; i++) {
        cum += h[i];
        if (cum >= need) {
            if (i < kHistFine) return (uint64_t)(i + 1) * 5;
            if (i < kHistFine + kHistCoarse) return 1000 + (uint64_t)(i - kHistFine + 1) * 100;
            return maxUs;
        }
    }
    return maxUs;
}

static int32_t propInt(OSDictionary * d, const char * key)
{
    OSObject * o = d ? d->getObject(key) : nullptr;
    OSNumber * n = OSDynamicCast(OSNumber, o);
    return n ? (int32_t)n->unsigned32BitValue() : -1;
}

static void windowReset(GDHubProbeTap_IVars * iv, uint64_t now)
{
    memset(&iv->w, 0, sizeof(iv->w));
    iv->w.start = now;
}

static const char * strategyName(uint32_t s) { return s == kStrategyA ? "A(no re-add)" : "B(re-add)"; }

static void windowLog(GDHubProbeTap_IVars * iv, uint64_t now)
{
    Window & w = iv->w;
    double elapsedUs = (double)(now - w.start) * iv->usPerTick;
    uint64_t rate10 = elapsedUs > 0 ? (uint64_t)((double)w.frames * 1e7 / elapsedUs) : 0;   // frames/s x10
    uint32_t inPool = 0;
    for (uint32_t i = 0; i < kPoolCount; i++) if (iv->inPool[i]) inPool++;
    PLog("window #%u strategy=%{public}s frames=%llu rate=%llu.%llu/s r06=%llu other=%llu "
         "k2d_us(n=%llu p50<=%llu p99<=%llu max=%llu future=%llu) poolMiss=%llu slowMap=%llu rangeFail=%llu badLen=%llu "
         "readdFail=%llu openFail=%llu poolIn=%u",
         iv->windowNo, strategyName(iv->strategy), w.frames, rate10 / 10, rate10 % 10, w.r06, w.other,
         w.k2dN, histPercentile(w.hist, w.k2dN, 50, w.k2dMaxUs), histPercentile(w.hist, w.k2dN, 99, w.k2dMaxUs),
         w.k2dMaxUs, w.tsFuture, w.poolMiss, w.slowMap, w.rangeFail, w.badLen, w.readdFail, w.openFail, inPool);
    // Separate line: the kernel log cuts a dext line at about 256 characters (measured in T0.2).
    PLog("gaps #%u gapTs_us=%llu gapArr_us=%llu total=%llu", iv->windowNo,
         (uint64_t)((double)w.gapTsMaxTicks * iv->usPerTick), (uint64_t)((double)w.gapArrMaxTicks * iv->usPerTick),
         iv->totalFrames);
}

#if GDHUB_PROBE_CRASH
// Report 0x06 (docs/protocol/envision-pro-receiver.md): 16 bytes with the ID byte, buttons = bits 0..18 of the 32-bit LE
// word in bytes 12..15 (button n = bit n-1). Accept a frame with or without the ID byte.
static bool buttonsOf(const uint8_t * b, uint32_t len, uint32_t * out)
{
    const uint8_t * d;
    if (len == 16 && b[0] == 6) d = b + 1;
    else if (len == 15)         d = b;
    else return false;
    *out = (uint32_t)d[11] | ((uint32_t)d[12] << 8) | ((uint32_t)d[13] << 16) | ((uint32_t)d[14] << 24);
    return true;
}
static constexpr uint32_t kChordMask = (1u << 6) | (1u << 7) | (1u << 8) | (1u << 9);   // View, Menu, L3, R3 = buttons 7..10
#endif

// ---------------------------------------------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------------------------------------------

bool GDHubProbeTap::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(GDHubProbeTap_IVars, 1);
    if (!ivars) return false;
    mach_timebase_info_data_t tb = {0, 0};
    mach_timebase_info(&tb);
    if (tb.numer == 0 || tb.denom == 0) { tb.numer = 1; tb.denom = 1; }
    ivars->tbNumer = tb.numer;
    ivars->tbDenom = tb.denom;
    ivars->usPerTick = (double)tb.numer / (double)tb.denom / 1000.0;
    ivars->msPerTick = (double)tb.numer / (double)tb.denom / 1e6;
    ivars->oneSecTicks = (uint64_t)(1e9 * (double)tb.denom / (double)tb.numer);
#if GDHUB_PROBE_CRASH
    ivars->twoSecTicks = 2 * ivars->oneSecTicks;
#endif
    return true;
}

void GDHubProbeTap::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->timerAction);
        OSSafeReleaseNULL(ivars->timer);
        OSSafeReleaseNULL(ivars->reportAction);
        OSSafeReleaseNULL(ivars->queue);
        for (uint32_t i = 0; i < kPoolCount; i++) OSSafeReleaseNULL(ivars->pool[i]);
        OSSafeReleaseNULL(ivars->hid);
    }
    IOSafeDeleteNULL(ivars, GDHubProbeTap_IVars, 1);
    super::free();
}

kern_return_t IMPL(GDHubProbeTap, Start)
{
    int32_t k = __atomic_add_fetch(&gProbeProcess.tapStarts, 1, __ATOMIC_RELAXED);
    kern_return_t kr = Start(provider, SUPERDISPATCH);
    if (kr != kIOReturnSuccess) {
        PLog("tap start #%d: super Start failed 0x%x", (int)k, (unsigned)kr);
        return kr;
    }
    ivars->startNo = (uint32_t)k;

    OSDictionary * props = nullptr;
    int32_t vid = -1, pid = -1, page = -1, usage = -1;
    if (provider->CopyProperties(&props) == kIOReturnSuccess && props) {
        vid = propInt(props, "VendorID");
        pid = propInt(props, "ProductID");
        page = propInt(props, "PrimaryUsagePage");
        usage = propInt(props, "PrimaryUsage");
    }
    OSSafeReleaseNULL(props);

    int32_t rootSeen = __atomic_load_n(&gProbeProcess.rootSeen, __ATOMIC_ACQUIRE);
    int32_t rootPid  = __atomic_load_n(&gProbeProcess.rootPid, __ATOMIC_ACQUIRE);
    bool decline = (GDHUB_PROBE_CRASH == 0) && (k == 1);
    PLog("tap start #%d rootSeen=%d rootPid=%d vid=%d pid=%d page=%d usage=%d%{public}s", (int)k, (int)rootSeen, (int)rootPid,
         (int)vid, (int)pid, (int)page, (int)usage, decline ? " \xE2\x86\x92 decline" : "");

    if (decline) {
        // Nothing was allocated yet. Undo the super Start (documented DriverKit pattern for a failed Start) and let IOKit
        // try the next candidate (assumption A8: Apple's event driver).
        ivars->declined = true;
        ivars->superStopped = true;
        Stop(provider, SUPERDISPATCH);
        return kIOReturnUnsupported;
    }

    ivars->hid = OSDynamicCast(IOHIDInterface, provider);
    if (!ivars->hid) {
        PLog("tap start #%d: provider is not an IOHIDInterface", (int)k);
        ivars->superStopped = true;
        Stop(provider, SUPERDISPATCH);
        return kIOReturnBadArgument;
    }
    ivars->hid->retain();

    kr = CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->queue);
    if (kr == kIOReturnSuccess) kr = IOTimerDispatchSource::Create(ivars->queue, &ivars->timer);
    if (kr == kIOReturnSuccess) kr = CreateActionProbeTick(0, &ivars->timerAction);
    if (kr == kIOReturnSuccess) kr = ivars->timer->SetHandler(ivars->timerAction);
    if (kr == kIOReturnSuccess) kr = CreateActionReportAvailable(0, &ivars->reportAction);
    if (kr != kIOReturnSuccess) {
        PLog("tap start #%d: setup failed 0x%x", (int)k, (unsigned)kr);
        ivars->superStopped = true;
        Stop(provider, SUPERDISPATCH);
        return kr;
    }

    windowReset(ivars, mach_absolute_time());
    ivars->timer->SetEnable(true);
    // First tick shortly after Start returns: it does the pool setup and the first Open. Later ticks run every second.
    kr = ivars->timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, mach_absolute_time() + ivars->oneSecTicks / 10, 0);
    if (kr != kIOReturnSuccess) PLog("tap start #%d: timer arm failed 0x%x (the tap will never open the interface)", (int)k, (unsigned)kr);
    return kIOReturnSuccess;
}

kern_return_t IMPL(GDHubProbeTap, Stop)
{
    uint64_t now = mach_absolute_time();
    PLog("tap stop #%u declined=%d opened=%d uptime_ms=%llu totalFrames=%llu", (unsigned)ivars->startNo,
         (int)ivars->declined, (int)ivars->opened, (uint64_t)((double)now * ivars->msPerTick), ivars->totalFrames);
    ivars->stopped = true;                       // frames that are still queued return at their first line

    if (ivars->opened && ivars->hid) {
        kern_return_t ckr = ivars->hid->Close(this, 0);
        PLog("tap stop #%u: Close rc=0x%x", (unsigned)ivars->startNo, (unsigned)ckr);
        ivars->opened = false;
    }
    if (ivars->superStopped) return kIOReturnSuccess;     // Start already ran the super Stop (declined or failed Start)
    ivars->superStopped = true;

    if (!ivars->timer) return Stop(provider, SUPERDISPATCH);

    // Same documented pattern as the production user client: the timer's cancel callout dereferences the timer's ivars,
    // so hold ourselves and complete the super Stop only from inside the cancel handler.
    ivars->timer->SetEnable(false);
    this->retain();
    ivars->timer->Cancel(^{
        Stop(provider, SUPERDISPATCH);
        this->release();
    });
    return kIOReturnSuccess;
}

kern_return_t IMPL(GDHubProbeTap, SetPowerState)
{
    PLog("tap SetPowerState flags=0x%x off=%d on=%d low=%d lpw=%d t_ms=%llu startNo=%u", (unsigned)powerFlags,
         (int)(powerFlags == kIOServicePowerCapabilityOff), (int)((powerFlags & kIOServicePowerCapabilityOn) != 0),
         (int)((powerFlags & kIOServicePowerCapabilityLow) != 0), (int)((powerFlags & kIOServicePowerCapabilityLPW) != 0),
         (uint64_t)((double)mach_absolute_time() * ivars->msPerTick), (unsigned)ivars->startNo);
    return SetPowerState(powerFlags, SUPERDISPATCH);
}

// ---------------------------------------------------------------------------------------------------------------
// Open and the pool (plan §4.5)
// ---------------------------------------------------------------------------------------------------------------

static void poolSetup(GDHubProbeTap_IVars * iv)
{
    iv->poolReady = true;
    uint32_t added = 0, failed = 0;
    for (uint32_t i = 0; i < kPoolCount; i++) {
        kern_return_t kr = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, kPoolBufSize, 0, &iv->pool[i]);
        if (kr != kIOReturnSuccess || !iv->pool[i]) { PLog("pool[%u]: Create 0x%x", i, (unsigned)kr); iv->pool[i] = nullptr; failed++; continue; }
        iv->pool[i]->SetLength(kPoolBufSize);                   // once, here; never per frame
        IOAddressSegment seg = {};
        kr = iv->pool[i]->GetAddressRange(&seg);
        if (kr != kIOReturnSuccess || seg.address == 0) { PLog("pool[%u]: GetAddressRange 0x%x", i, (unsigned)kr); OSSafeReleaseNULL(iv->pool[i]); failed++; continue; }
        iv->poolAddr[i] = (uint8_t *)seg.address;
        iv->poolLen[i]  = seg.length;
        kr = iv->hid->AddReportToPool(iv->pool[i]);
        if (kr != kIOReturnSuccess) { PLog("pool[%u]: AddReportToPool 0x%x", i, (unsigned)kr); failed++; continue; }
        iv->inPool[i] = true;
        added++;
    }
    PLog("pool setup: %u buffers in the pool, %u failed (size %u, mapped once)", added, failed, (unsigned)kPoolBufSize);
}

// Strategy A -> B: put every buffer of ours that the kernel took out of the pool back in.
static void poolRefill(GDHubProbeTap_IVars * iv)
{
    uint32_t refilled = 0, failed = 0;
    for (uint32_t i = 0; i < kPoolCount; i++) {
        if (!iv->pool[i] || iv->inPool[i]) continue;
        if (iv->hid->AddReportToPool(iv->pool[i]) == kIOReturnSuccess) { iv->inPool[i] = true; refilled++; } else failed++;
    }
    PLog("pool refill after strategy A: %u re-added, %u failed", refilled, failed);
}

static void tryOpen(GDHubProbeTap * self, GDHubProbeTap_IVars * iv, uint64_t now)
{
    if (!iv->poolReady) poolSetup(iv);
    iv->openTries++;
    kern_return_t kr = iv->hid->Open(self, 0, iv->reportAction);
    if (kr != kIOReturnSuccess) {
        iv->w.openFail++;
        PLog("tap open failed 0x%x try %u", (unsigned)kr, iv->openTries);     // retried from the 1 s timer
        return;
    }
    iv->opened = true;
    iv->openTicks = now;
    iv->strategy = kStrategyB1;
    windowReset(iv, now);
    iv->prevTs = 0; iv->prevArr = 0;
    PLog("tap open returned 0x0 try %u (success is judged by frames arriving, not by this code); strategy B for %llu s, A for %llu s, then B",
         iv->openTries, (uint64_t)(kPhaseBEndMs / 1000), (uint64_t)((kPhaseAEndMs - kPhaseBEndMs) / 1000));
}

void IMPL(GDHubProbeTap, ProbeTick)
{
    (void)action; (void)time;
    if (ivars->stopped) return;              // Stop is cancelling the timer: do nothing and do not re-arm
    uint64_t now = mach_absolute_time();
    ivars->tickNo++;

    if (!ivars->opened) {
        tryOpen(this, ivars, now);
    } else {
        uint64_t elapsedMs = (uint64_t)((double)(now - ivars->openTicks) * ivars->msPerTick);
        uint32_t want = elapsedMs < kPhaseBEndMs ? kStrategyB1 : (elapsedMs < kPhaseAEndMs ? kStrategyA : kStrategyB2);
        if (want != ivars->strategy) {
            PLog("strategy switch %{public}s -> %{public}s at +%llu ms after Open", strategyName(ivars->strategy), strategyName(want), elapsedMs);
            ivars->strategy = want;
            if (want == kStrategyB2) poolRefill(ivars);
        }
        if ((uint64_t)((double)(now - ivars->w.start) * ivars->msPerTick) >= kWindowMs) {
            ivars->windowNo++;
            windowLog(ivars, now);
            windowReset(ivars, now);
        }
    }
    ivars->timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, now + ivars->oneSecTicks * kTickMs / 1000, ivars->oneSecTicks / 20);
}

// ---------------------------------------------------------------------------------------------------------------
// The report path
// ---------------------------------------------------------------------------------------------------------------

void IMPL(GDHubProbeTap, ReportAvailable)
{
    (void)action;
    GDHubProbeTap_IVars * iv = ivars;
    if (iv->stopped || !iv->opened) return;
    uint64_t now = mach_absolute_time();
    Window & w = iv->w;

    // 1. Find the bytes. Our own buffer first (pointer equality, G·T0), then any IOBufferMemoryDescriptor, then a mapping.
    int ours = -1;
    for (uint32_t i = 0; i < kPoolCount; i++) {
        if (iv->pool[i] && static_cast<IOMemoryDescriptor *>(iv->pool[i]) == report) { ours = (int)i; break; }
    }
    const uint8_t * b = nullptr;
    uint64_t avail = 0;
    IOMemoryMap * map = nullptr;
    if (ours >= 0) {
        b = iv->poolAddr[ours];
        avail = iv->poolLen[ours];
        iv->inPool[ours] = false;                       // the kernel took it out of the pool to deliver this report
    } else {
        w.poolMiss++;
        IOBufferMemoryDescriptor * bmd = OSDynamicCast(IOBufferMemoryDescriptor, report);
        IOAddressSegment seg = {};
        if (bmd && bmd->GetAddressRange(&seg) == kIOReturnSuccess && seg.address != 0) {
            b = (const uint8_t *)seg.address;
            avail = seg.length;
        } else {
            w.rangeFail++;
            if (report && report->CreateMapping(0, 0, 0, 0, 0, &map) == kIOReturnSuccess && map) {
                w.slowMap++;
                b = (const uint8_t *)map->GetAddress();
                avail = map->GetLength();
            }
        }
    }
    if (!b || reportLength == 0 || reportLength > avail) {
        w.badLen++;
        OSSafeReleaseNULL(map);
        return;
    }

    // 2. Count and time.
    w.frames++;
    iv->totalFrames++;
    if (timestamp <= now) {
        uint64_t us = (uint64_t)((double)(now - timestamp) * iv->usPerTick);
        histAdd(w.hist, us);
        w.k2dN++;
        if (us > w.k2dMaxUs) w.k2dMaxUs = us;
    } else {
        w.tsFuture++;
    }
    if (iv->prevTs && timestamp > iv->prevTs && timestamp - iv->prevTs > w.gapTsMaxTicks) w.gapTsMaxTicks = timestamp - iv->prevTs;
    if (iv->prevArr && now - iv->prevArr > w.gapArrMaxTicks) w.gapArrMaxTicks = now - iv->prevArr;
    uint64_t prevArr = iv->prevArr;
    iv->prevTs = timestamp;
    iv->prevArr = now;
    if (reportID == 6) w.r06++; else w.other++;

    // 3. The first three frames of the Open, once: ID, length, type, raw timestamp and now (to check the unit), bytes.
    if (iv->framesLogged < kFirstFrames) {
        iv->framesLogged++;
        char hex[80];
        hexDump(b, reportLength < 24 ? reportLength : 24, hex, sizeof(hex));
        PLog("frame #%u reportID=%u len=%u type=%u ts=%llu now=%llu ours=%d bytes=%{public}s", iv->framesLogged, (unsigned)reportID,
             (unsigned)reportLength, (unsigned)type, timestamp, now, ours, hex);
    }

#if GDHUB_PROBE_CRASH
    // Crash drill: View + Menu + L3 + R3 held together for 2 s of continuous frames. A gap in the stream resets the hold.
    if (reportID == 6) {
        uint32_t btn = 0;
        bool held = buttonsOf(b, reportLength, &btn) && (btn & kChordMask) == kChordMask;
        bool gap = prevArr && now - prevArr > iv->oneSecTicks / 10;
        if (!held || gap) {
            if (iv->chordArmed) PLog("crash chord released before 2 s (held=%d gap=%d)", (int)held, (int)gap);
            iv->chordArmed = false;
        }
        if (held) {
            if (!iv->chordArmed) {
                iv->chordArmed = true;
                iv->chordStart = now;
                PLog("crash chord armed (buttons 0x%x)", (unsigned)btn);
            } else if (now - iv->chordStart >= iv->twoSecTicks) {
                PLog("crash now");
                __builtin_trap();
            }
        }
    }
#else
    (void)prevArr;
#endif

    // 4. Re-add our buffer once the bytes are no longer needed (strategy B). Strategy A skips it, to confirm the leak.
    OSSafeReleaseNULL(map);
    if (ours >= 0 && iv->strategy != kStrategyA) {
        kern_return_t kr = iv->hid->AddReportToPool(iv->pool[ours]);
        if (kr == kIOReturnSuccess) {
            iv->inPool[ours] = true;
        } else {
            w.readdFail++;
            if (iv->readdLogged < kReaddLogMax) { iv->readdLogged++; PLog("re-add failed 0x%x (buffer %d)", (unsigned)kr, ours); }
        }
    }
}
