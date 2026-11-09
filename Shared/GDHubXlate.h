#ifndef GDHubXlate_h
#define GDHubXlate_h
/*
 * GDHubXlate: the one translator from a raw Envision Pro report 0x06 to the virtual pad's input reports.
 *
 * Plain C (C99), no allocation, no stdio, no locale, no global state, no libm: <stdint.h> and <stddef.h> only.
 * The same source is compiled into the app/engine (SwiftPM target and Xcode app target) and, from T5, into the
 * driver. Every function is pure over its arguments; the caller owns all state (gdx_map, gdx_state), so a
 * translator instance is confined to whatever queue the caller runs it on.
 *
 * Numerics: double precision in Swift's operation order (docs/plans/receiver-takeover-plan.md section 5.1). Compile
 * with -ffp-contract=off everywhere. Rounding is round-half-away-from-zero, written by hand.
 *
 * The mapping arrives as a "GDHM" v1 blob (section 5.3), little-endian, at most GDX_BLOB_MAX bytes, read with
 * memcpy-style byte assembly (never cast). gdx_validate is the only way to obtain a gdx_map; it never reads outside
 * [blob, blob+len) and never writes *out unless the whole blob is accepted.
 */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- blob format -------------------------------------------------------------------------------------------- */

#define GDX_BLOB_MAGIC            0x4D484447u   /* bytes 'G' 'D' 'H' 'M' */
#define GDX_BLOB_VERSION          1
#define GDX_BLOB_MAX              1024
#define GDX_BLOB_HEADER_SIZE      64
#define GDX_SOURCE_ENVISION_PRO   1             /* report 0x06, 16 bytes with the ID byte */
#define GDX_SOURCE_REPORT_ID      6
#define GDX_SOURCE_REPORT_LEN     16
#define GDX_SILENCE_NEUTRAL_MS    250

/* Header offsets (all little-endian). Offset 28 is the blob CRC32, computed with those four bytes zero. */
#define GDX_OFF_MAGIC             0     /* u32 */
#define GDX_OFF_VERSION           4     /* u16 */
#define GDX_OFF_LENGTH            6     /* u16, total bytes */
#define GDX_OFF_REVISION          8     /* u32 */
#define GDX_OFF_SPEC_CRC          12    /* u32, CRC32 of the pad spec the blob targets */
#define GDX_OFF_SOURCE_KIND       16    /* u16 */
#define GDX_OFF_FLAGS             18    /* u16, 0 */
#define GDX_OFF_SILENCE_MS        20    /* u16 */
#define GDX_OFF_N_REPORTS         22    /* u8 */
#define GDX_OFF_N_BUTTONS         23    /* u8 */
#define GDX_OFF_N_AXES            24    /* u8 */
#define GDX_OFF_N_TRIGGERS        25    /* u8 */
#define GDX_OFF_N_PLACEMENTS      26    /* u8 */
#define GDX_OFF_N_ECHO            27    /* u8, 0 in v1 */
#define GDX_OFF_BLOB_CRC          28    /* u32 */
#define GDX_OFF_DEADBAND          32    /* f64 */
#define GDX_OFF_HYSTERESIS        40    /* f64 */
#define GDX_OFF_STICK_ACTIVE      48    /* f64 */
#define GDX_OFF_TRIGGER_ACTIVE    56    /* i32 */
#define GDX_OFF_AXIS_ACTIVE       60    /* i32 */

/* Entry sizes. Sections follow the header in this order, each starting on an 8-byte boundary. */
#define GDX_REPORT_ENTRY          4     /* { u8 reportID, u8 length, u16 0 } */
#define GDX_BUTTON_ENTRY          8     /* { u8 item, u8 kind, u8 arg, i8 sign, u16 physMask, u8 stickRef, u8 outSlot } */
#define GDX_AXIS_ENTRY            16    /* { u8 stick, u8 component, u8 field, i8 sign, u8 hasRange, u8 0[3], i32 min, i32 max } */
#define GDX_TRIGGER_ENTRY         4     /* { u8 item, u8 field, u16 0 } */
#define GDX_PLACEMENT_ENTRY       8     /* { u8 reportIndex, u8 item, u16 bitOffset, u8 bits, u8 encoding, u16 0 } */

#define GDX_MAX_REPORTS           4
#define GDX_MAX_BUTTONS           32
#define GDX_MAX_AXES              4
#define GDX_MAX_TRIGGERS          2
#define GDX_MAX_PLACEMENTS        32
#define GDX_MAX_REPORT            64    /* bytes per output report, including the ID byte */

/* Output items. Buttons are bit `item` of gdx_pad.buttons; axes and triggers are gdx_pad.v[item - 16]. */
enum {
    GDX_ITEM_A = 0, GDX_ITEM_B = 1, GDX_ITEM_X = 2, GDX_ITEM_Y = 3, GDX_ITEM_LB = 4, GDX_ITEM_RB = 5,
    GDX_ITEM_VIEW = 6, GDX_ITEM_MENU = 7, GDX_ITEM_LS = 8, GDX_ITEM_RS = 9, GDX_ITEM_GUIDE = 10,
    GDX_ITEM_DPAD_UP = 11, GDX_ITEM_DPAD_RIGHT = 12, GDX_ITEM_DPAD_DOWN = 13, GDX_ITEM_DPAD_LEFT = 14,
    GDX_ITEM_SHARE = 15,                        /* reserved: never produced by v1 */
    GDX_ITEM_LX = 16, GDX_ITEM_LY = 17, GDX_ITEM_RX = 18, GDX_ITEM_RY = 19, GDX_ITEM_LT = 20, GDX_ITEM_RT = 21
};
#define GDX_BUTTON_ITEMS          15    /* items 0...14 */

/* Button rule kinds. A non-zero physMask overrides the kind. */
enum {
    GDX_KIND_NONE = 0,
    GDX_KIND_BUTTON = 1,        /* arg = bit index 0...18 (button n is bit n-1) */
    GDX_KIND_HAT = 2,           /* arg = direction; an even direction also accepts its two adjacent diagonals */
    GDX_KIND_TRIGGER_GT = 3,    /* arg = trigger field (0 lt, 1 rt): raw > triggerActiveRaw */
    GDX_KIND_AXIS_GT = 4,       /* arg = axis field (0 x, 1 y, 2 z, 3 rz): sign * raw > axisActiveRaw */
    GDX_KIND_STICK_MAG = 5      /* stickRef = 0 left, 1 right: |x| > stickActive or |y| > stickActive */
};

#define GDX_FIELD_NONE            0xFF

/* Placement encodings. */
enum {
    GDX_ENC_AXIS16 = 1,         /* round((clamp(v,-1,1)+1) * 32767.5), 16 bits */
    GDX_ENC_AXIS16_NEG = 2,     /* the same for -v */
    GDX_ENC_TRIG10_U16 = 3,     /* round(clamp(t,0,1) * 1023), in a 16-bit field */
    GDX_ENC_HAT8 = 4,           /* 8 bits from the four D-pad items: 0 none, 1 N, 2 NE ... 8 NW; opposites cancel */
    GDX_ENC_BIT = 5             /* 1 bit from a button item */
};

/* ---- reason codes ------------------------------------------------------------------------------------------- */

#define GDX_OK                   0
#define GDX_E_ARG                1   /* NULL argument */
#define GDX_E_SHORT              2   /* shorter than the header */
#define GDX_E_TOO_BIG            3   /* longer than GDX_BLOB_MAX */
#define GDX_E_MAGIC              4
#define GDX_E_VERSION            5
#define GDX_E_LENGTH             6   /* length field differs from the byte count, or the sections do not fill it exactly */
#define GDX_E_CRC                7   /* blob checksum */
#define GDX_E_SOURCE             8   /* sourceKind */
#define GDX_E_FLAGS              9   /* flags, reserved or padding bytes not zero */
#define GDX_E_COUNTS             10   /* a section count is out of range, or nEcho != 0 */
#define GDX_E_PARAM              11   /* deadband, hysteresis or an activation threshold is out of range or not finite */
#define GDX_E_KIND               12   /* unknown rule kind, or an argument invalid for it */
#define GDX_E_ITEM               13   /* item number invalid for its section, duplicated, or more than 2 rules */
#define GDX_E_AXIS               14   /* axis stick/component/field/range invalid */
#define GDX_E_TRIGGER            15
#define GDX_E_ENCODING           16   /* unknown placement encoding, or width/item invalid for it */
#define GDX_E_PLACEMENT          17   /* report index out of range, or the field does not fit its report */
#define GDX_E_REPORT             18   /* report ID/length invalid */
#define GDX_E_SPEC_FORMAT        19   /* the spec buffer is not a GDHS spec */
#define GDX_E_SPEC_CRC           20   /* specCRC32 differs from the CRC32 of the spec */
#define GDX_E_SPEC_REPORT        21   /* a blob report is not a declared input of the spec */

/* ---- parsed mapping ----------------------------------------------------------------------------------------- */

typedef struct gdx_button_rule {
    uint8_t item, kind, arg;
    int8_t sign;
    uint16_t physMask;
    uint8_t stickRef, outSlot;
} gdx_button_rule;

typedef struct gdx_axis_rule {
    uint8_t stick, component, field;
    int8_t sign;
    uint8_t hasRange;
    int32_t min, max;
} gdx_axis_rule;

typedef struct gdx_trigger_rule {
    uint8_t item, field;
} gdx_trigger_rule;

typedef struct gdx_placement {
    uint8_t reportIndex, item;
    uint16_t bitOffset;
    uint8_t bits, encoding;
} gdx_placement;

/* A validated mapping in native layout. Only gdx_validate produces one (a zeroed gdx_map has no reports and
 * translates nothing). The caller may copy it freely; it holds no pointers. */
typedef struct gdx_map {
    uint32_t revision, specCRC;
    uint16_t silenceNeutralMs;
    uint8_t nReports, nButtons, nAxes, nTriggers, nPlacements;
    double deadband, hysteresis, stickActive;
    int32_t triggerActiveRaw, axisActiveRaw;
    uint8_t reportID[GDX_MAX_REPORTS], reportLen[GDX_MAX_REPORTS];
    gdx_button_rule buttons[GDX_MAX_BUTTONS];
    gdx_axis_rule axes[GDX_MAX_AXES];
    gdx_trigger_rule triggers[GDX_MAX_TRIGGERS];
    gdx_placement placements[GDX_MAX_PLACEMENTS];
} gdx_map;

/* ---- pad state and output ----------------------------------------------------------------------------------- */

/* The device-independent pad: bit `item` of buttons (items 0...15), v[0...3] = LX, LY, RX, RY in -1...1 with Y UP
 * positive (the sign of the learned vertical axis is inverted by the translator), v[4], v[5] = LT, RT in 0...1.
 * gdx_eval returns it already snapped to the deadband. */
typedef struct gdx_pad {
    uint32_t buttons;
    double v[6];
} gdx_pad;

typedef struct gdx_report {
    uint8_t id, len;
    uint8_t bytes[GDX_MAX_REPORT];      /* bytes[0] = id when id != 0; bytes beyond len are zero */
} gdx_report;

typedef struct gdx_out {
    uint8_t count;
    gdx_report r[GDX_MAX_REPORTS];
} gdx_out;

/* Per-instance delivery state for gdx_step (hysteresis anchor, per-report byte dedupe, counters). Zero-initialise
 * with gdx_reset or memset. Not thread safe: one owner. */
typedef struct gdx_state {
    uint32_t haveLast;                  /* 1 when `last` is the anchor of the hysteresis test */
    uint32_t haveBytes;                 /* bit i: lastBytes[i] valid */
    gdx_pad last;
    uint8_t lastBytes[GDX_MAX_REPORTS][GDX_MAX_REPORT];
    uint8_t lastLen[GDX_MAX_REPORTS];
    uint32_t framesOk, framesBad, statesChanged, reportsPosted;
} gdx_state;

/* gdx_eval results below zero. */
#define GDX_BAD_ARG               (-1)
#define GDX_BAD_LENGTH            (-2)  /* len != 16 */
#define GDX_BAD_REPORT_ID         (-3)  /* in[0] != 6 */

/* ---- API ---------------------------------------------------------------------------------------------------- */

/* CRC-32 (IEEE 802.3, reflected, init/final 0xFFFFFFFF), the checksum of both the spec and the blob. */
uint32_t gdx_crc32(const uint8_t *p, size_t len);

/* Validates a blob against the pad spec it targets (a GDHS spec as built by DextProtocol / GDHubSpec). 0 = ok,
 * otherwise a GDX_E_* code. On success *out is filled; on failure *out is left untouched. Checks: size, magic,
 * version, length, CRC, source, counts, every enumeration and index, placements inside their reports, specCRC32 equal
 * to gdx_crc32(spec) and every blob (reportID, length) a declared input of the spec. */
int gdx_validate(const uint8_t *blob, size_t len, const uint8_t *spec, size_t specLen, gdx_map *out);

/* Short constant description of a reason code ("ok", "bad magic", ...). Never NULL. */
const char *gdx_reason(int code);

/* Forgets what was sent: the next gdx_step posts every report. Counters are kept. */
void gdx_reset(gdx_state *s);

/* Parse + map + snap. `in` is a raw report 0x06 including the ID byte, exactly GDX_SOURCE_REPORT_LEN bytes. Returns 0,
 * or GDX_BAD_ARG / GDX_BAD_LENGTH / GDX_BAD_REPORT_ID (a frame the Swift parser rejects too); *p is untouched on error. */
int gdx_eval(const gdx_map *m, const uint8_t *in, size_t len, gdx_pad *p);

/* The sink's hysteresis test: 1 when `now` would not change what the host already has from `lastSent`. */
int gdx_unchanged(const gdx_map *m, const gdx_pad *now, const gdx_pad *lastSent);

/* Placements -> report bytes, for every report of the map. */
void gdx_build(const gdx_map *m, const gdx_pad *p, gdx_out *o);

/* One frame without a rate cap: eval, hysteresis against the last state, build, per-report byte dedupe. Returns the
 * mask of reports to post (bit i = o->r[i]); 0 for a bad frame (counted in framesBad) or an unchanged state.
 * `o` is only valid when the mask is non-zero. */
uint32_t gdx_step(gdx_state *s, const gdx_map *m, const uint8_t *in, size_t len, gdx_out *o);

#ifdef __cplusplus
}
#endif
#endif
