/*
 * Meter, CRC-32 and GDHubStatus2 packer, see GDHubDextCore.h. No allocation, no libc, no globals that change.
 */
#include "GDHubDextCore.h"
#include "../GDHubProtocol.h"

/* ------------------------------------------------------------------------------------------------------------- */
/* CRC-32 (IEEE 802.3, reflected). Bitwise: used once per pad creation. */

uint32_t gdh_crc32(const uint8_t *p, size_t len)
{
    uint32_t crc = 0xFFFFFFFFu;
    size_t i;
    int k;
    for (i = 0; i < len; i++) {
        crc ^= p[i];
        for (k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
    return crc ^ 0xFFFFFFFFu;
}

/* ------------------------------------------------------------------------------------------------------------- */
/* Meter */

/* Upper edge of bucket i in nanoseconds, i in 0..60; bucket 61 is the overflow. */
static const uint32_t kEdgeNs[GDH_HIST_BUCKETS - 1] = {
    1000, 2000, 3000, 5000, 8000, 12000, 18000, 25000,                    /* 0..7: below 25 us */
    50000, 75000, 100000, 125000, 150000, 175000, 200000, 225000, 250000, 275000,   /* 8..: 25 us wide, to 1 ms */
    300000, 325000, 350000, 375000, 400000, 425000, 450000, 475000, 500000, 525000,
    550000, 575000, 600000, 625000, 650000, 675000, 700000, 725000, 750000, 775000,
    800000, 825000, 850000, 875000, 900000, 925000, 950000, 975000, 1000000,        /* ..46 */
    1100000, 1200000, 1300000, 1400000, 1500000, 1600000, 1700000, 1800000, 1900000, 2000000,   /* 47..56 */
    3000000, 5000000, 10000000, 20000000                                  /* 57..60 */
};

static uint64_t edge_ns(int i)
{
    return kEdgeNs[i];
}

uint64_t gdh_ticks_to_ns(const gdh_meter *m, uint64_t ticks)
{
    return (m->denom == 0) ? ticks : ticks * m->numer / m->denom;
}

void gdh_meter_init(gdh_meter *m, uint32_t numer, uint32_t denom, uint64_t windowMs)
{
    size_t i;
    for (i = 0; i < sizeof(*m); i++) ((unsigned char *)m)[i] = 0;
    m->numer = numer ? numer : 1;
    m->denom = denom ? denom : 1;
    /* ticks = ns * denom / numer, rounded up so that `ticks < edge` means `ns < edge_ns` */
    m->windowTicks = (windowMs * 1000000u * m->denom + m->numer - 1) / m->numer;
    for (i = 0; i < GDH_HIST_BUCKETS - 1; i++) {
        m->edgeTicks[i] = (edge_ns((int)i) * m->denom + m->numer - 1) / m->numer;
    }
}

static void hist_add(gdh_hist *h, const gdh_meter *m, uint64_t ticks)
{
    int i = 0;
    while (i < GDH_HIST_BUCKETS - 1 && ticks >= m->edgeTicks[i]) i++;
    h->counts[i]++;
    h->n++;
    h->sumTicks += ticks;
    if (ticks > h->maxTicks) h->maxTicks = ticks;
}

void gdh_hist_summarize(const gdh_hist *h, const gdh_meter *m, gdh_summary *out)
{
    out->count = out->p50Ns = out->p99Ns = out->maxNs = out->meanNs = 0;
    if (h->n == 0) return;
    uint64_t maxNs = gdh_ticks_to_ns(m, h->maxTicks);
    uint64_t want50 = (h->n + 1) / 2;                      /* ceil(0.50 n) */
    uint64_t want99 = (h->n * 99 + 99) / 100;              /* ceil(0.99 n) */
    uint64_t cum = 0, p50 = 0, p99 = 0;
    int i, have50 = 0, have99 = 0;
    for (i = 0; i < GDH_HIST_BUCKETS; i++) {
        cum += h->counts[i];
        uint64_t up = (i < GDH_HIST_BUCKETS - 1) ? edge_ns(i) : maxNs;
        if (up > maxNs) up = maxNs;                        /* never report more than the largest sample */
        if (!have50 && cum >= want50) { p50 = up; have50 = 1; }
        if (!have99 && cum >= want99) { p99 = up; have99 = 1; }
        if (have50 && have99) break;
    }
    out->count = h->n > 0xFFFFFFFFu ? 0xFFFFFFFFu : (uint32_t)h->n;
    out->p50Ns = (uint32_t)(p50 > 0xFFFFFFFFu ? 0xFFFFFFFFu : p50);
    out->p99Ns = (uint32_t)(p99 > 0xFFFFFFFFu ? 0xFFFFFFFFu : p99);
    out->maxNs = (uint32_t)(maxNs > 0xFFFFFFFFu ? 0xFFFFFFFFu : maxNs);
    uint64_t mean = gdh_ticks_to_ns(m, h->sumTicks) / h->n;          /* exact: convert the sum, then divide */
    out->meanNs = (uint32_t)(mean > 0xFFFFFFFFu ? 0xFFFFFFFFu : mean);
}

#define RSTORE(p, v) __atomic_store_n((p), (v), __ATOMIC_RELAXED)
#define RLOAD(p)     __atomic_load_n((p), __ATOMIC_RELAXED)

static void store_summary(gdh_summary *dst, const gdh_summary *s)
{
    RSTORE(&dst->count, s->count);
    RSTORE(&dst->p50Ns, s->p50Ns);
    RSTORE(&dst->p99Ns, s->p99Ns);
    RSTORE(&dst->maxNs, s->maxNs);
    RSTORE(&dst->meanNs, s->meanNs);
}

static void load_summary(gdh_summary *dst, const gdh_summary *s)
{
    dst->count = RLOAD(&s->count);
    dst->p50Ns = RLOAD(&s->p50Ns);
    dst->p99Ns = RLOAD(&s->p99Ns);
    dst->maxNs = RLOAD(&s->maxNs);
    dst->meanNs = RLOAD(&s->meanNs);
}

static void publish(gdh_meter *m)
{
    gdh_summary hop, hr;
    gdh_hist_summarize(&m->hop, m, &hop);
    gdh_hist_summarize(&m->hr, m, &hr);
    uint32_t s = RLOAD(&m->seq);
    RSTORE(&m->seq, s + 1);                              /* odd: a write is in progress */
    __atomic_thread_fence(__ATOMIC_RELEASE);
    store_summary(&m->pubHop, &hop);
    store_summary(&m->pubHr, &hr);
    RSTORE(&m->pubWindows, RLOAD(&m->pubWindows) + 1);
    __atomic_store_n(&m->seq, s + 2, __ATOMIC_RELEASE);
}

int gdh_meter_sample(gdh_meter *m, uint64_t nowTicks, int hasHop, uint64_t hopTicks, uint64_t hrTicks)
{
    int rolled = 0;
    if (m->windowStart == 0) {
        m->windowStart = nowTicks ? nowTicks : 1;
    } else if (nowTicks - m->windowStart >= m->windowTicks) {
        publish(m);
        size_t i;
        for (i = 0; i < sizeof(m->hop); i++) ((unsigned char *)&m->hop)[i] = 0;
        for (i = 0; i < sizeof(m->hr); i++) ((unsigned char *)&m->hr)[i] = 0;
        m->windowStart = nowTicks;
        rolled = 1;
    }
    if (hasHop) hist_add(&m->hop, m, hopTicks);
    hist_add(&m->hr, m, hrTicks);
    return rolled;
}

int gdh_meter_read(const gdh_meter *m, gdh_summary *hop, gdh_summary *hr, uint32_t *windows)
{
    int tries;
    for (tries = 0; tries < 8; tries++) {
        uint32_t s1 = __atomic_load_n(&m->seq, __ATOMIC_ACQUIRE);
        if (s1 & 1u) continue;
        load_summary(hop, &m->pubHop);
        load_summary(hr, &m->pubHr);
        uint32_t w = RLOAD(&m->pubWindows);
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        if (__atomic_load_n(&m->seq, __ATOMIC_RELAXED) == s1) {
            if (windows) *windows = w;
            return 1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------------------------------------------------- */
/* GDHubStatus2 */

static void put16(uint8_t *b, size_t off, uint16_t v)
{
    b[off] = (uint8_t)v; b[off + 1] = (uint8_t)(v >> 8);
}

static void put32(uint8_t *b, size_t off, uint32_t v)
{
    size_t i;
    for (i = 0; i < 4; i++) b[off + i] = (uint8_t)(v >> (8 * i));
}

static void put64(uint8_t *b, size_t off, uint64_t v)
{
    size_t i;
    for (i = 0; i < 8; i++) b[off + i] = (uint8_t)(v >> (8 * i));
}

size_t gdh_status2_pack(uint8_t *buf, size_t cap, const gdhr_snap *s,
                        const gdh_summary *hop, const gdh_summary *hr, uint32_t meterWindows, const gdh_summary *k2d)
{
    uint8_t full[GDHUB_ST2_SIZE];
    size_t i;
    if (!buf || cap < 8) return 0;
    for (i = 0; i < sizeof(full); i++) full[i] = 0;
    put16(full, GDHUB_ST2_OFF_VERSION, GDHUB_ST2_VERSION);
    put16(full, GDHUB_ST2_OFF_SIZE, GDHUB_ST2_SIZE);
    put32(full, GDHUB_ST2_OFF_BUILD, s->build);
    put64(full, GDHUB_ST2_OFF_NONCE, s->nonce);
    put32(full, GDHUB_ST2_OFF_ROOT_PID, s->pid);
    full[GDHUB_ST2_OFF_DESIRED_STATE] = (uint8_t)s->desiredState;
    full[GDHUB_ST2_OFF_PAD_SOURCE] = (uint8_t)s->padSource;
    full[GDHUB_ST2_OFF_PAD_LIVE] = (uint8_t)(s->padState == GDHR_PAD_LIVE);
    full[GDHUB_ST2_OFF_OWNER_PRESENT] = (uint8_t)(s->ownerPresent != 0);
    put64(full, GDHUB_ST2_OFF_UC_POSTS, s->counters[GDHR_CTR_UC_POSTS]);
    put64(full, GDHUB_ST2_OFF_UC_REJECTED, s->counters[GDHR_CTR_UC_REJECTED]);
    put64(full, GDHUB_ST2_OFF_NEUTRAL_POSTS, s->counters[GDHR_CTR_NEUTRAL_POSTS]);
    put64(full, GDHUB_ST2_OFF_POST_ERRORS, s->counters[GDHR_CTR_POST_ERRORS]);
    put64(full, GDHUB_ST2_OFF_SYNC_VIOLATIONS, s->counters[GDHR_CTR_SYNC_VIOLATIONS]);
    put64(full, GDHUB_ST2_OFF_PAD_CREATES, s->counters[GDHR_CTR_PAD_CREATES]);
    put64(full, GDHUB_ST2_OFF_PAD_DESTROYS, s->counters[GDHR_CTR_PAD_DESTROYS]);
    put64(full, GDHUB_ST2_OFF_CREATE_FAILS, s->counters[GDHR_CTR_CREATE_FAILS]);
    put64(full, GDHUB_ST2_OFF_OUTPUTS_SEEN, s->counters[GDHR_CTR_OUTPUTS_SEEN]);
    put64(full, GDHUB_ST2_OFF_OUTPUTS_NO_OWNER, s->counters[GDHR_CTR_OUTPUTS_NO_OWNER]);
    put64(full, GDHUB_ST2_OFF_CREATE_EARLY, s->counters[GDHR_CTR_CREATE_EARLY]);
    put64(full, GDHUB_ST2_OFF_SYNC_INLINE, s->counters[GDHR_CTR_SYNC_INLINE]);
    full[GDHUB_ST2_OFF_TAP_PRESENT] = (uint8_t)(s->tapPresent != 0);
    full[GDHUB_ST2_OFF_TAP_OPENED] = (uint8_t)(s->tapOpened != 0);
    full[GDHUB_ST2_OFF_APPLIED_STATE] = (uint8_t)s->tapApplied;
    full[GDHUB_ST2_OFF_POWERED] = (uint8_t)(s->tapPowered != 0);
    put32(full, GDHUB_ST2_OFF_TAP_PID, s->tapPid);
    put32(full, GDHUB_ST2_OFF_TAP_STARTS, (uint32_t)s->counters[GDHR_CTR_TAP_STARTS]);
    put32(full, GDHUB_ST2_OFF_LAST_POWER_FLAGS, s->tapLastPowerFlags);
    put32(full, GDHUB_ST2_OFF_LAST_ERROR, s->lastError);
    put64(full, GDHUB_ST2_OFF_FRAMES_IN, s->counters[GDHR_CTR_FRAMES_IN]);
    put64(full, GDHUB_ST2_OFF_FRAMES_R06, s->counters[GDHR_CTR_FRAMES_R06]);
    put64(full, GDHUB_ST2_OFF_FRAMES_OTHER, s->counters[GDHR_CTR_FRAMES_OTHER]);
    put64(full, GDHUB_ST2_OFF_FRAMES_IGNORED, s->counters[GDHR_CTR_FRAMES_IGNORED]);
    put64(full, GDHUB_ST2_OFF_FRAMES_BAD, s->counters[GDHR_CTR_FRAMES_BAD]);
    put64(full, GDHUB_ST2_OFF_POOL_MISS, s->counters[GDHR_CTR_POOL_MISS]);
    put64(full, GDHUB_ST2_OFF_READD_FAIL, s->counters[GDHR_CTR_READD_FAIL]);
    put64(full, GDHUB_ST2_OFF_OPEN_FAILURES, s->counters[GDHR_CTR_OPEN_FAILURES]);
    if (k2d) {
        put32(full, GDHUB_ST2_OFF_K2D_COUNT, k2d->count);
        put32(full, GDHUB_ST2_OFF_K2D_P50_NS, k2d->p50Ns);
        put32(full, GDHUB_ST2_OFF_K2D_P99_NS, k2d->p99Ns);
        put32(full, GDHUB_ST2_OFF_K2D_MAX_NS, k2d->maxNs);
        put32(full, GDHUB_ST2_OFF_K2D_MEAN_NS, k2d->meanNs);
    }
    put64(full, GDHUB_ST2_OFF_POKES_RUN, s->counters[GDHR_CTR_POKES_RUN]);
    put64(full, GDHUB_ST2_OFF_TICK_APPLIES, s->counters[GDHR_CTR_TICK_APPLIES]);
    put64(full, GDHUB_ST2_OFF_CLOSE_FAILURES, s->counters[GDHR_CTR_CLOSE_FAILURES]);
    put64(full, GDHUB_ST2_OFF_REOPENS, s->counters[GDHR_CTR_REOPENS]);
    put64(full, GDHUB_ST2_OFF_TAP_FREES, s->counters[GDHR_CTR_TAP_FREES]);
    full[GDHUB_ST2_OFF_TOPOLOGY] = (uint8_t)s->topology;
    full[GDHUB_ST2_OFF_PROBE_EXT] = (uint8_t)s->probeExt;
    full[GDHUB_ST2_OFF_PROBE_SUBMIT] = (uint8_t)s->probePad;
    put32(full, GDHUB_ST2_OFF_PAD_SPEC_CRC, s->padSpecCrc);
    put32(full, GDHUB_ST2_OFF_METER_WINDOWS, meterWindows);
    if (hop) {
        put32(full, GDHUB_ST2_OFF_HOP_COUNT, hop->count);
        put32(full, GDHUB_ST2_OFF_HOP_P50_NS, hop->p50Ns);
        put32(full, GDHUB_ST2_OFF_HOP_P99_NS, hop->p99Ns);
        put32(full, GDHUB_ST2_OFF_HOP_MAX_NS, hop->maxNs);
        put32(full, GDHUB_ST2_OFF_HOP_MEAN_NS, hop->meanNs);
    }
    if (hr) {
        put32(full, GDHUB_ST2_OFF_HR_COUNT, hr->count);
        put32(full, GDHUB_ST2_OFF_HR_P50_NS, hr->p50Ns);
        put32(full, GDHUB_ST2_OFF_HR_P99_NS, hr->p99Ns);
        put32(full, GDHUB_ST2_OFF_HR_MAX_NS, hr->maxNs);
        put32(full, GDHUB_ST2_OFF_HR_MEAN_NS, hr->meanNs);
    }
    size_t n = cap < sizeof(full) ? cap : sizeof(full);
    for (i = 0; i < n; i++) buf[i] = full[i];
    return n;
}
