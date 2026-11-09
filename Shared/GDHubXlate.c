/*
 * GDHubXlate: see GDHubXlate.h. Plain C99, no allocation, no libm, no globals.
 *
 * Every floating-point expression below is written in the operation order of the Swift pipeline it replaces
 * (ControlMapping.stickPosition / triggerValue, PassthroughPadMapper, VirtualPadSink.snapped / unchanged,
 * PadReportBuilders). Compile with -ffp-contract=off so no multiply-add is fused.
 */
#include "GDHubXlate.h"

#include <string.h>

/* ------------------------------------------------------------------------------------------------------------
 * Little-endian readers over a byte buffer (never a cast).
 */

static uint16_t rd16(const uint8_t *p)
{
    return (uint16_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8));
}

static uint32_t rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int32_t rdi32(const uint8_t *p)
{
    uint32_t u = rd32(p);
    int32_t r;
    memcpy(&r, &u, sizeof r);
    return r;
}

static double rdf64(const uint8_t *p)
{
    uint64_t u = (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32);
    double d;
    memcpy(&d, &u, sizeof d);
    return d;
}

/* ------------------------------------------------------------------------------------------------------------
 * CRC-32 (IEEE, reflected). Bitwise: validation is rare, so no table.
 */

static uint32_t crc_update(uint32_t crc, const uint8_t *p, size_t n)
{
    size_t i;
    int k;
    for (i = 0; i < n; i++) {
        crc ^= p[i];
        for (k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
    return crc;
}

uint32_t gdx_crc32(const uint8_t *p, size_t len)
{
    if (!p) return 0;
    return crc_update(0xFFFFFFFFu, p, len) ^ 0xFFFFFFFFu;
}

/* The blob checksum is the CRC-32 of the whole blob with its own four checksum bytes read as zero. */
static uint32_t blob_crc(const uint8_t *b, size_t len)
{
    static const uint8_t zero4[4] = {0, 0, 0, 0};
    uint32_t c = 0xFFFFFFFFu;
    c = crc_update(c, b, GDX_OFF_BLOB_CRC);
    c = crc_update(c, zero4, 4);
    c = crc_update(c, b + GDX_OFF_BLOB_CRC + 4, len - (GDX_OFF_BLOB_CRC + 4));
    return c ^ 0xFFFFFFFFu;
}

/* ------------------------------------------------------------------------------------------------------------
 * Reason strings.
 */

const char *gdx_reason(int code)
{
    switch (code) {
    case GDX_OK: return "ok";
    case GDX_E_ARG: return "NULL argument";
    case GDX_E_SHORT: return "shorter than the header";
    case GDX_E_TOO_BIG: return "longer than 1024 bytes";
    case GDX_E_MAGIC: return "bad magic";
    case GDX_E_VERSION: return "unsupported version";
    case GDX_E_LENGTH: return "length mismatch";
    case GDX_E_CRC: return "checksum mismatch";
    case GDX_E_SOURCE: return "unsupported source kind";
    case GDX_E_FLAGS: return "reserved field not zero";
    case GDX_E_COUNTS: return "section count out of range";
    case GDX_E_PARAM: return "parameter out of range";
    case GDX_E_KIND: return "invalid button rule";
    case GDX_E_ITEM: return "invalid or duplicated item";
    case GDX_E_AXIS: return "invalid axis rule";
    case GDX_E_TRIGGER: return "invalid trigger rule";
    case GDX_E_ENCODING: return "invalid placement encoding";
    case GDX_E_PLACEMENT: return "placement outside its report";
    case GDX_E_REPORT: return "invalid report";
    case GDX_E_SPEC_FORMAT: return "spec is not a GDHS spec";
    case GDX_E_SPEC_CRC: return "spec checksum mismatch";
    case GDX_E_SPEC_REPORT: return "report not declared by the spec";
    default: return "unknown reason";
    }
}

/* ------------------------------------------------------------------------------------------------------------
 * The pad spec (GDHubProtocol.h GDHUB_SPEC_*): just enough to answer GDHubSpecIsDeclaredInput.
 */

#define SPEC_MAGIC            0x53484447u
#define SPEC_HEADER_SIZE      256
#define SPEC_OFF_VERSION      4
#define SPEC_OFF_HEADER_SIZE  6
#define SPEC_OFF_INPUT_COUNT  10
#define SPEC_OFF_INPUT_TABLE  48        /* 4 x { u8 reportID, u8 sendLength, u16 lengthInclID } */
#define SPEC_MAX_INPUTS       4

static uint32_t spec_send_len(const uint8_t *spec, uint32_t i)
{
    const uint8_t *e = spec + SPEC_OFF_INPUT_TABLE + i * 4u;
    return e[1] ? (uint32_t)e[1] : (uint32_t)rd16(e + 2);
}

static int spec_declares(const uint8_t *spec, uint8_t id, uint32_t len)
{
    uint32_t count = spec[SPEC_OFF_INPUT_COUNT], i;
    if (len == 0) return 0;
    if (spec[SPEC_OFF_INPUT_TABLE] == 0) return len == spec_send_len(spec, 0);      /* no report IDs */
    for (i = 0; i < count; i++) {
        if (id == spec[SPEC_OFF_INPUT_TABLE + i * 4u] && len == spec_send_len(spec, i)) return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------------------------------------------------
 * Validation.
 */

static size_t pad8(size_t n) { return (n + 7u) & ~(size_t)7u; }

static int all_zero(const uint8_t *p, size_t n)
{
    size_t i;
    for (i = 0; i < n; i++) if (p[i] != 0) return 0;
    return 1;
}

static int finite_in(double x, double lo, double hi)      /* lo <= x < hi, false for NaN */
{
    return x >= lo && x < hi;
}

int gdx_validate(const uint8_t *b, size_t len, const uint8_t *spec, size_t specLen, gdx_map *out)
{
    gdx_map m;
    size_t off, repOff, btnOff, axOff, trOff, plOff, i;
    uint8_t itemRules[GDX_BUTTON_ITEMS];
    uint8_t axisSeen = 0, trigSeen = 0;

    if (!b || !out || !spec) return GDX_E_ARG;
    if (len < GDX_BLOB_HEADER_SIZE) return GDX_E_SHORT;
    if (len > GDX_BLOB_MAX) return GDX_E_TOO_BIG;
    if (rd32(b + GDX_OFF_MAGIC) != GDX_BLOB_MAGIC) return GDX_E_MAGIC;
    if (rd16(b + GDX_OFF_VERSION) != GDX_BLOB_VERSION) return GDX_E_VERSION;
    if ((size_t)rd16(b + GDX_OFF_LENGTH) != len) return GDX_E_LENGTH;
    if (rd32(b + GDX_OFF_BLOB_CRC) != blob_crc(b, len)) return GDX_E_CRC;
    if (rd16(b + GDX_OFF_SOURCE_KIND) != GDX_SOURCE_ENVISION_PRO) return GDX_E_SOURCE;
    if (rd16(b + GDX_OFF_FLAGS) != 0) return GDX_E_FLAGS;

    memset(&m, 0, sizeof m);
    m.revision = rd32(b + GDX_OFF_REVISION);
    m.specCRC = rd32(b + GDX_OFF_SPEC_CRC);
    m.silenceNeutralMs = rd16(b + GDX_OFF_SILENCE_MS);
    m.nReports = b[GDX_OFF_N_REPORTS];
    m.nButtons = b[GDX_OFF_N_BUTTONS];
    m.nAxes = b[GDX_OFF_N_AXES];
    m.nTriggers = b[GDX_OFF_N_TRIGGERS];
    m.nPlacements = b[GDX_OFF_N_PLACEMENTS];
    if (m.nReports < 1 || m.nReports > GDX_MAX_REPORTS || m.nButtons > GDX_MAX_BUTTONS || m.nAxes > GDX_MAX_AXES ||
        m.nTriggers > GDX_MAX_TRIGGERS || m.nPlacements > GDX_MAX_PLACEMENTS || b[GDX_OFF_N_ECHO] != 0) return GDX_E_COUNTS;

    m.deadband = rdf64(b + GDX_OFF_DEADBAND);
    m.hysteresis = rdf64(b + GDX_OFF_HYSTERESIS);
    m.stickActive = rdf64(b + GDX_OFF_STICK_ACTIVE);
    m.triggerActiveRaw = rdi32(b + GDX_OFF_TRIGGER_ACTIVE);
    m.axisActiveRaw = rdi32(b + GDX_OFF_AXIS_ACTIVE);
    if (!finite_in(m.deadband, 0.0, 1.0) || !finite_in(m.hysteresis, 0.0, 1.0)) return GDX_E_PARAM;
    if (!(m.stickActive > 0.0 && m.stickActive <= 1.0)) return GDX_E_PARAM;
    if (m.triggerActiveRaw < 0 || m.triggerActiveRaw > 1023 || m.axisActiveRaw < 0 || m.axisActiveRaw > 65535) return GDX_E_PARAM;

    /* Section layout: each section starts on an 8-byte boundary and the last one ends exactly at `len`. */
    off = GDX_BLOB_HEADER_SIZE;
    repOff = off; off += pad8((size_t)m.nReports * GDX_REPORT_ENTRY);
    btnOff = off; off += pad8((size_t)m.nButtons * GDX_BUTTON_ENTRY);
    axOff = off;  off += pad8((size_t)m.nAxes * GDX_AXIS_ENTRY);
    trOff = off;  off += pad8((size_t)m.nTriggers * GDX_TRIGGER_ENTRY);
    plOff = off;  off += pad8((size_t)m.nPlacements * GDX_PLACEMENT_ENTRY);
    if (off != len) return GDX_E_LENGTH;
    /* Padding after the 4-byte-entry sections must be zero. */
    if (!all_zero(b + repOff + (size_t)m.nReports * GDX_REPORT_ENTRY, pad8((size_t)m.nReports * GDX_REPORT_ENTRY) - (size_t)m.nReports * GDX_REPORT_ENTRY)) return GDX_E_FLAGS;
    if (!all_zero(b + trOff + (size_t)m.nTriggers * GDX_TRIGGER_ENTRY, pad8((size_t)m.nTriggers * GDX_TRIGGER_ENTRY) - (size_t)m.nTriggers * GDX_TRIGGER_ENTRY)) return GDX_E_FLAGS;

    for (i = 0; i < m.nReports; i++) {
        const uint8_t *e = b + repOff + i * GDX_REPORT_ENTRY;
        if (e[1] < 1 || e[1] > GDX_MAX_REPORT) return GDX_E_REPORT;
        if (rd16(e + 2) != 0) return GDX_E_FLAGS;
        m.reportID[i] = e[0];
        m.reportLen[i] = e[1];
    }

    memset(itemRules, 0, sizeof itemRules);
    for (i = 0; i < m.nButtons; i++) {
        const uint8_t *e = b + btnOff + i * GDX_BUTTON_ENTRY;
        gdx_button_rule *r = &m.buttons[i];
        r->item = e[0]; r->kind = e[1]; r->arg = e[2]; r->sign = (int8_t)(e[3] < 128 ? (int)e[3] : (int)e[3] - 256);
        r->physMask = rd16(e + 4); r->stickRef = e[6]; r->outSlot = e[7];
        if (r->item >= GDX_BUTTON_ITEMS) return GDX_E_ITEM;
        if (++itemRules[r->item] > 2) return GDX_E_ITEM;
        if (r->outSlot != 0) return GDX_E_KIND;
        switch (r->kind) {
        case GDX_KIND_NONE:
            if (r->arg != 0 || r->sign != 0 || r->stickRef != 0) return GDX_E_KIND;
            break;
        case GDX_KIND_BUTTON:
            if (r->arg >= 19 || r->sign != 0 || r->stickRef != 0) return GDX_E_KIND;
            break;
        case GDX_KIND_HAT:
            if (r->sign != 0 || r->stickRef != 0) return GDX_E_KIND;
            break;
        case GDX_KIND_TRIGGER_GT:
            if (r->arg > 1 || r->sign != 0 || r->stickRef != 0) return GDX_E_KIND;
            break;
        case GDX_KIND_AXIS_GT:
            if (r->arg > 3 || r->stickRef != 0) return GDX_E_KIND;
            break;
        case GDX_KIND_STICK_MAG:
            if (r->arg != 0 || r->sign != 0 || r->stickRef > 1) return GDX_E_KIND;
            break;
        default:
            return GDX_E_KIND;
        }
    }

    for (i = 0; i < m.nAxes; i++) {
        const uint8_t *e = b + axOff + i * GDX_AXIS_ENTRY;
        gdx_axis_rule *r = &m.axes[i];
        unsigned bit;
        r->stick = e[0]; r->component = e[1]; r->field = e[2]; r->sign = (int8_t)(e[3] < 128 ? (int)e[3] : (int)e[3] - 256);
        r->hasRange = e[4]; r->min = rdi32(e + 8); r->max = rdi32(e + 12);
        if (r->stick > 1 || r->component > 1) return GDX_E_AXIS;
        bit = 1u << (r->stick * 2u + r->component);
        if (axisSeen & bit) return GDX_E_AXIS;
        axisSeen = (uint8_t)(axisSeen | bit);
        if (r->field > 3 && r->field != GDX_FIELD_NONE) return GDX_E_AXIS;
        if (r->hasRange > 1 || !all_zero(e + 5, 3)) return GDX_E_AXIS;
        if (r->field == GDX_FIELD_NONE && (r->sign != 0 || r->hasRange != 0)) return GDX_E_AXIS;
        if (!r->hasRange && (r->min != 0 || r->max != 0)) return GDX_E_AXIS;
    }

    for (i = 0; i < m.nTriggers; i++) {
        const uint8_t *e = b + trOff + i * GDX_TRIGGER_ENTRY;
        gdx_trigger_rule *r = &m.triggers[i];
        unsigned bit;
        r->item = e[0]; r->field = e[1];
        if (r->item != GDX_ITEM_LT && r->item != GDX_ITEM_RT) return GDX_E_TRIGGER;
        bit = 1u << (r->item - GDX_ITEM_LT);
        if (trigSeen & bit) return GDX_E_TRIGGER;
        trigSeen = (uint8_t)(trigSeen | bit);
        if (r->field > 1 && r->field != GDX_FIELD_NONE) return GDX_E_TRIGGER;
        if (rd16(e + 2) != 0) return GDX_E_FLAGS;
    }

    for (i = 0; i < m.nPlacements; i++) {
        const uint8_t *e = b + plOff + i * GDX_PLACEMENT_ENTRY;
        gdx_placement *r = &m.placements[i];
        uint32_t end;
        r->reportIndex = e[0]; r->item = e[1]; r->bitOffset = rd16(e + 2); r->bits = e[4]; r->encoding = e[5];
        if (rd16(e + 6) != 0) return GDX_E_FLAGS;
        switch (r->encoding) {
        case GDX_ENC_AXIS16:
        case GDX_ENC_AXIS16_NEG:
            if (r->item < GDX_ITEM_LX || r->item > GDX_ITEM_RY || r->bits != 16) return GDX_E_ENCODING;
            break;
        case GDX_ENC_TRIG10_U16:
            if (r->item < GDX_ITEM_LT || r->item > GDX_ITEM_RT || r->bits != 16) return GDX_E_ENCODING;
            break;
        case GDX_ENC_HAT8:
            if (r->item != GDX_ITEM_DPAD_UP || r->bits != 8) return GDX_E_ENCODING;
            break;
        case GDX_ENC_BIT:
            if (r->item >= GDX_BUTTON_ITEMS || r->bits != 1) return GDX_E_ENCODING;
            break;
        default:
            return GDX_E_ENCODING;
        }
        if (r->reportIndex >= m.nReports) return GDX_E_PLACEMENT;
        end = (uint32_t)r->bitOffset + r->bits;
        if (end > 8u * m.reportLen[r->reportIndex]) return GDX_E_PLACEMENT;
        if (m.reportID[r->reportIndex] != 0 && r->bitOffset < 8) return GDX_E_PLACEMENT;     /* the ID byte is not ours */
    }

    /* The pad spec the blob targets. */
    if (specLen < SPEC_HEADER_SIZE || rd32(spec) != SPEC_MAGIC || rd16(spec + SPEC_OFF_VERSION) == 0 ||
        rd16(spec + SPEC_OFF_HEADER_SIZE) != SPEC_HEADER_SIZE || spec[SPEC_OFF_INPUT_COUNT] < 1 ||
        spec[SPEC_OFF_INPUT_COUNT] > SPEC_MAX_INPUTS) return GDX_E_SPEC_FORMAT;
    if (gdx_crc32(spec, specLen) != m.specCRC) return GDX_E_SPEC_CRC;
    for (i = 0; i < m.nReports; i++) {
        if (!spec_declares(spec, m.reportID[i], m.reportLen[i])) return GDX_E_SPEC_REPORT;
    }

    *out = m;
    return GDX_OK;
}

/* ------------------------------------------------------------------------------------------------------------
 * Evaluation: report 0x06 -> pad state.
 */

typedef struct raw_frame {
    int32_t axis[4];        /* x, y, z, rz */
    int32_t trig[2];        /* lt, rt */
    uint32_t hat;           /* 0...15 */
    uint32_t buttons;       /* 19 bits */
    uint32_t extra;         /* 13 bits */
} raw_frame;

static int32_t s16(uint8_t lo, uint8_t hi)
{
    int32_t u = (int32_t)((uint32_t)lo | ((uint32_t)hi << 8));
    return u >= 32768 ? u - 65536 : u;
}

static void parse(const uint8_t *in, raw_frame *f)
{
    uint32_t t = (uint32_t)in[9] | ((uint32_t)in[10] << 8) | ((uint32_t)in[11] << 16);
    uint32_t btn = (uint32_t)in[12] | ((uint32_t)in[13] << 8) | ((uint32_t)in[14] << 16) | ((uint32_t)in[15] << 24);
    f->axis[0] = s16(in[1], in[2]);
    f->axis[1] = s16(in[3], in[4]);
    f->axis[2] = s16(in[5], in[6]);
    f->axis[3] = s16(in[7], in[8]);
    f->trig[0] = (int32_t)(t & 0x3ffu);
    f->trig[1] = (int32_t)((t >> 10) & 0x3ffu);
    f->hat = (t >> 20) & 0xfu;
    f->buttons = btn & 0x7ffffu;
    f->extra = btn >> 19;
}

static double dabs(double v) { return v < 0.0 ? -v : v; }

/* ControlMapping.stickPosition.norm for one bound axis: scale by the learned extremes (asymmetric), else by 32767,
 * multiply by the sign, clamp to -1...1 (Swift.max(-1, Swift.min(1, x))). */
static double axis_norm(const gdx_axis_rule *a, const raw_frame *f)
{
    double scaled;
    int32_t v;
    if (a->field > 3) return 0.0;
    v = f->axis[a->field];
    if (a->hasRange) {
        int64_t d;
        if (v >= 0) { d = a->max; if (d < 1) d = 1; }
        else { d = -(int64_t)a->min; if (d < 1) d = 1; }
        scaled = (double)v / (double)d;
    } else {
        scaled = (double)v / 32767.0;
    }
    scaled *= (double)a->sign;
    scaled = (scaled < 1.0) ? scaled : 1.0;
    scaled = (scaled >= -1.0) ? scaled : -1.0;
    return scaled;
}

static int rule_active(const gdx_map *m, const gdx_button_rule *r, const raw_frame *f)
{
    uint32_t i;
    if (r->physMask != 0) return (f->extra & r->physMask) == r->physMask;      /* physical identity wins */
    switch (r->kind) {
    case GDX_KIND_BUTTON:
        return r->arg < 19 && ((f->buttons >> r->arg) & 1u) != 0;
    case GDX_KIND_HAT: {
        int32_t h = (int32_t)f->hat, d = (int32_t)r->arg;
        if (h >= 8) return 0;
        if (h == d) return 1;
        if (d % 2 == 0) return (h + 1) % 8 == d || (h + 7) % 8 == d;
        return 0;
    }
    case GDX_KIND_TRIGGER_GT:
        return r->arg < 2 && f->trig[r->arg] > m->triggerActiveRaw;
    case GDX_KIND_AXIS_GT:
        return r->arg < 4 && (int64_t)r->sign * (int64_t)f->axis[r->arg] > (int64_t)m->axisActiveRaw;
    case GDX_KIND_STICK_MAG: {
        double x = 0.0, y = 0.0;
        for (i = 0; i < m->nAxes; i++) {
            const gdx_axis_rule *a = &m->axes[i];
            if (a->stick != r->stickRef) continue;
            if (a->component == 0) x = axis_norm(a, f); else y = axis_norm(a, f);
        }
        return dabs(x) > m->stickActive || dabs(y) > m->stickActive;
    }
    default:
        return 0;
    }
}

int gdx_eval(const gdx_map *m, const uint8_t *in, size_t len, gdx_pad *p)
{
    raw_frame f;
    gdx_pad r;
    uint32_t i;

    if (!m || !in || !p) return GDX_BAD_ARG;
    if (len != GDX_SOURCE_REPORT_LEN) return GDX_BAD_LENGTH;
    if (in[0] != GDX_SOURCE_REPORT_ID) return GDX_BAD_REPORT_ID;
    parse(in, &f);

    memset(&r, 0, sizeof r);
    for (i = 0; i < m->nButtons; i++) {
        if (rule_active(m, &m->buttons[i], &f)) r.buttons |= 1u << m->buttons[i].item;
    }
    for (i = 0; i < m->nAxes; i++) {
        const gdx_axis_rule *a = &m->axes[i];
        double n = axis_norm(a, &f);
        /* PassthroughPadMapper: s.ly = -p.y (the mapping's y grows downward, the pad's grows upward). */
        r.v[a->stick * 2u + a->component] = a->component ? -n : n;
    }
    for (i = 0; i < m->nTriggers; i++) {
        const gdx_trigger_rule *t = &m->triggers[i];
        double x;
        if (t->field > 1) continue;
        x = (double)f.trig[t->field] / 1023.0;
        x = (x < 1.0) ? x : 1.0;                    /* min(1, x) */
        x = (x >= 0.0) ? x : 0.0;                   /* max(0, x) */
        r.v[t->item - GDX_ITEM_LX] = x;
    }
    /* VirtualPadSink.snapped */
    for (i = 0; i < 4; i++) if (dabs(r.v[i]) < m->deadband) r.v[i] = 0.0;
    for (i = 4; i < 6; i++) if (r.v[i] < m->deadband) r.v[i] = 0.0;
    *p = r;
    return 0;
}

/* VirtualPadSink.unchanged. A move onto an end stop always counts. */
static int same(double a, double b, double db)
{
    if (a == b) return 1;
    if (dabs(a) >= 1.0) return 0;
    return dabs(a - b) < db;
}

int gdx_unchanged(const gdx_map *m, const gdx_pad *now, const gdx_pad *last)
{
    uint32_t i;
    if (!m || !now || !last) return 0;
    if (now->buttons != last->buttons) return 0;
    for (i = 0; i < 6; i++) if (!same(now->v[i], last->v[i], m->hysteresis)) return 0;
    return 1;
}

/* ------------------------------------------------------------------------------------------------------------
 * Building: pad state -> report bytes.
 */

/* Round half away from zero for x >= 0 (everything built here is non-negative and below 2^32). */
static uint32_t round_pos(double x)
{
    uint32_t i = (uint32_t)x;
    double frac = x - (double)i;
    return frac >= 0.5 ? i + 1u : i;
}

/* PadReportBuilders.axis16: ((clamp(v, -1, 1) + 1) * 32767.5) rounded; clamp(v, lo, hi) = min(max(v, lo), hi). */
static uint32_t axis16(double v)
{
    double t = (-1.0 >= v) ? -1.0 : v;
    t = (1.0 < t) ? 1.0 : t;
    return round_pos((t + 1.0) * 32767.5);
}

/* PadReportBuilders.trigger10: (clamp(t, 0, 1) * 1023) rounded. */
static uint32_t trigger10(double t)
{
    double c = (0.0 >= t) ? 0.0 : t;
    c = (1.0 < c) ? 1.0 : c;
    return round_pos(c * 1023.0);
}

/* PadReportBuilders.hat: 0 none, 1 N, 2 NE ... 8 NW; opposite directions cancel. */
static uint32_t hat8(uint32_t buttons)
{
    int dx = 0, dy = 0;
    if (buttons & (1u << GDX_ITEM_DPAD_RIGHT)) dx += 1;
    if (buttons & (1u << GDX_ITEM_DPAD_LEFT)) dx -= 1;
    if (buttons & (1u << GDX_ITEM_DPAD_UP)) dy += 1;
    if (buttons & (1u << GDX_ITEM_DPAD_DOWN)) dy -= 1;
    if (dx == 0 && dy == 1) return 1;
    if (dx == 1 && dy == 1) return 2;
    if (dx == 1 && dy == 0) return 3;
    if (dx == 1 && dy == -1) return 4;
    if (dx == 0 && dy == -1) return 5;
    if (dx == -1 && dy == -1) return 6;
    if (dx == -1 && dy == 0) return 7;
    if (dx == -1 && dy == 1) return 8;
    return 0;
}

static void put_bits(uint8_t *buf, uint32_t bitOffset, uint32_t bits, uint32_t value)
{
    uint32_t i;
    for (i = 0; i < bits; i++) {
        if ((value >> i) & 1u) buf[(bitOffset + i) >> 3] = (uint8_t)(buf[(bitOffset + i) >> 3] | (1u << ((bitOffset + i) & 7u)));
    }
}

void gdx_build(const gdx_map *m, const gdx_pad *p, gdx_out *o)
{
    uint32_t i;
    if (!m || !p || !o) return;
    memset(o, 0, sizeof *o);
    o->count = m->nReports;
    for (i = 0; i < m->nReports; i++) {
        o->r[i].id = m->reportID[i];
        o->r[i].len = m->reportLen[i];
        if (m->reportID[i] != 0) o->r[i].bytes[0] = m->reportID[i];
    }
    for (i = 0; i < m->nPlacements; i++) {
        const gdx_placement *pl = &m->placements[i];
        uint32_t value = 0;
        switch (pl->encoding) {
        case GDX_ENC_AXIS16:     value = axis16(p->v[pl->item - GDX_ITEM_LX]); break;
        case GDX_ENC_AXIS16_NEG: value = axis16(-p->v[pl->item - GDX_ITEM_LX]); break;
        case GDX_ENC_TRIG10_U16: value = trigger10(p->v[pl->item - GDX_ITEM_LX]); break;
        case GDX_ENC_HAT8:       value = hat8(p->buttons); break;
        case GDX_ENC_BIT:        value = (p->buttons >> pl->item) & 1u; break;
        default: break;
        }
        put_bits(o->r[pl->reportIndex].bytes, pl->bitOffset, pl->bits, value);
    }
}

/* ------------------------------------------------------------------------------------------------------------
 * State and the uncapped step.
 */

void gdx_reset(gdx_state *s)
{
    uint32_t ok, bad, changed, posted;
    if (!s) return;
    ok = s->framesOk; bad = s->framesBad; changed = s->statesChanged; posted = s->reportsPosted;
    memset(s, 0, sizeof *s);
    s->framesOk = ok; s->framesBad = bad; s->statesChanged = changed; s->reportsPosted = posted;
}

uint32_t gdx_step(gdx_state *s, const gdx_map *m, const uint8_t *in, size_t len, gdx_out *o)
{
    gdx_pad p;
    uint32_t mask = 0, i;
    if (!s) return 0;
    if (!m || !o || gdx_eval(m, in, len, &p) < 0) { s->framesBad++; return 0; }
    s->framesOk++;
    if (s->haveLast && gdx_unchanged(m, &p, &s->last)) return 0;
    s->statesChanged++;
    gdx_build(m, &p, o);
    for (i = 0; i < o->count; i++) {
        const gdx_report *r = &o->r[i];
        if (!((s->haveBytes >> i) & 1u) || s->lastLen[i] != r->len || memcmp(s->lastBytes[i], r->bytes, r->len) != 0) {
            mask |= 1u << i;
            memcpy(s->lastBytes[i], r->bytes, r->len);
            s->lastLen[i] = r->len;
            s->haveBytes |= 1u << i;
            s->reportsPosted++;
        }
    }
    s->last = p;                    /* the anchor moves even when no report changed, like VirtualPadSink.flush */
    s->haveLast = 1;
    return mask;
}
