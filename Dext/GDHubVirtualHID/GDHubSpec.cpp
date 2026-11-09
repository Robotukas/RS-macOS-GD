// DeviceSpec helpers (design §3.4 bridge functions, §3.6 validation). Plain C++ over the spec blob; no iig classes.
// Layout: 256-byte header, descriptor (descLen), then one neutral report per input-table entry (send length each).
// The Swift encoder (DextProtocol.swift `DeviceSpec.encoded()`) enforces the same rules.
#include "GDHubInternal.h"

// ---------------------------------------------------------------------------------------------------------------
// Little-endian readers over a raw buffer.

static inline uint32_t rd32(const uint8_t * p, uint32_t off)
{
    return (uint32_t)p[off] | ((uint32_t)p[off + 1] << 8) | ((uint32_t)p[off + 2] << 16) | ((uint32_t)p[off + 3] << 24);
}

static inline uint16_t rd16(const uint8_t * p, uint32_t off)
{
    return (uint16_t)(p[off] | (p[off + 1] << 8));
}

// Input-table entry i: { u8 reportID, u8 sendLength, u16 lengthInclID }.
static inline uint32_t entryBase(uint32_t i) { return GDHUB_SPEC_OFF_INPUT_TABLE + i * 4; }

static inline uint32_t sendLen(const uint8_t * p, uint32_t i)
{
    uint32_t base = entryBase(i);
    uint32_t send = p[base + 1];
    return send ? send : rd16(p, base + 2);
}

static bool stringTerminated(const uint8_t * p, uint32_t off, uint32_t len)
{
    return p[off + len - 1] == 0;
}

// ---------------------------------------------------------------------------------------------------------------
// §3.6 validation

kern_return_t GDHubSpecValidate(const uint8_t * p, size_t len)
{
    if (!p || len < GDHUB_SPEC_HEADER_SIZE) { GDLog("spec rejected: length %zu < header", len); return kIOReturnBadArgument; }
    if (rd32(p, GDHUB_SPEC_OFF_MAGIC) != GDHUB_SPEC_MAGIC) { GDLog("spec rejected: bad magic"); return kIOReturnBadArgument; }
    if (rd16(p, GDHUB_SPEC_OFF_VERSION) != GDHUB_SPEC_VERSION) { GDLog("spec rejected: bad version"); return kIOReturnBadArgument; }
    if (rd16(p, GDHUB_SPEC_OFF_HEADER_SIZE) != GDHUB_SPEC_HEADER_SIZE) { GDLog("spec rejected: bad header size"); return kIOReturnBadArgument; }
    if (p[GDHUB_SPEC_OFF_SLOT] >= GDHUB_SLOT_COUNT) { GDLog("spec rejected: slot %u", (unsigned)p[GDHUB_SPEC_OFF_SLOT]); return kIOReturnBadArgument; }

    uint32_t inputCount = p[GDHUB_SPEC_OFF_INPUT_COUNT];
    uint32_t descLen = rd16(p, GDHUB_SPEC_OFF_DESC_LEN);
    uint32_t neutralLen = rd16(p, GDHUB_SPEC_OFF_NEUTRAL_LEN);
    if (inputCount < 1 || inputCount > GDHUB_MAX_INPUT_REPORTS) { GDLog("spec rejected: inputCount %u", inputCount); return kIOReturnBadArgument; }
    if (descLen < 1 || descLen > GDHUB_MAX_DESCRIPTOR) { GDLog("spec rejected: descLen %u", descLen); return kIOReturnBadArgument; }
    if (len != (size_t)GDHUB_SPEC_HEADER_SIZE + descLen + neutralLen) {
        GDLog("spec rejected: length %zu != 256 + %u + %u", len, descLen, neutralLen);
        return kIOReturnBadArgument;
    }

    // Rule 6: lengths, and the send-length window [lengthInclID, max(lengthInclID)].
    uint32_t maxLen = 0;
    for (uint32_t i = 0; i < inputCount; i++) {
        uint32_t l = rd16(p, entryBase(i) + 2);
        if (l < 1 || l > GDHUB_MAX_REPORT) { GDLog("spec rejected: input %u length %u", i, l); return kIOReturnBadArgument; }
        if (l > maxLen) maxLen = l;
    }
    uint32_t sumSend = 0;
    bool anyNoID = false;
    for (uint32_t i = 0; i < inputCount; i++) {
        uint32_t base = entryBase(i);
        uint32_t l = rd16(p, base + 2);
        uint32_t s = p[base + 1];
        if (s != 0 && (s < l || s > maxLen)) { GDLog("spec rejected: input %u sendLength %u outside %u...%u", i, s, l, maxLen); return kIOReturnBadArgument; }
        if (p[base] == 0) anyNoID = true;
        sumSend += s ? s : l;
    }
    // Rule 7
    if (anyNoID && inputCount != 1) { GDLog("spec rejected: report ID 0 with %u inputs", inputCount); return kIOReturnBadArgument; }
    // Rule 8
    if (neutralLen != sumSend || neutralLen > GDHUB_MAX_NEUTRAL) {
        GDLog("spec rejected: neutralLen %u, expected %u (max %u)", neutralLen, sumSend, (unsigned)GDHUB_MAX_NEUTRAL);
        return kIOReturnBadArgument;
    }
    // Rule 9
    const uint8_t * neutral = p + GDHUB_SPEC_HEADER_SIZE + descLen;
    uint32_t off = 0;
    for (uint32_t i = 0; i < inputCount; i++) {
        uint8_t id = p[entryBase(i)];
        if (id != 0 && neutral[off] != id) { GDLog("spec rejected: neutral %u does not start with ID 0x%02x", i, (unsigned)id); return kIOReturnBadArgument; }
        off += sendLen(p, i);
    }
    // Rule 10
    if (!stringTerminated(p, GDHUB_SPEC_OFF_TRANSPORT, GDHUB_SPEC_LEN_TRANSPORT) ||
        !stringTerminated(p, GDHUB_SPEC_OFF_MANUFACTURER, GDHUB_SPEC_LEN_MANUFACTURER) ||
        !stringTerminated(p, GDHUB_SPEC_OFF_PRODUCT_NAME, GDHUB_SPEC_LEN_PRODUCT_NAME) ||
        !stringTerminated(p, GDHUB_SPEC_OFF_SERIAL, GDHUB_SPEC_LEN_SERIAL)) {
        GDLog("spec rejected: unterminated string");
        return kIOReturnBadArgument;
    }
    if (p[GDHUB_SPEC_OFF_TRANSPORT] == 0) { GDLog("spec rejected: empty Transport"); return kIOReturnBadArgument; }
    return kIOReturnSuccess;
}

// ---------------------------------------------------------------------------------------------------------------
// Accessors over a stored (already validated) spec.

static const uint8_t * specBytes(OSData * spec, uint32_t * length)
{
    if (!spec) { if (length) *length = 0; return nullptr; }
    if (length) *length = spec->getLength();
    return (const uint8_t *)spec->getBytesNoCopy();
}

uint32_t GDHubSpecU32(OSData * spec, uint32_t off)
{
    uint32_t n; const uint8_t * p = specBytes(spec, &n);
    return (p && off + 4 <= n) ? rd32(p, off) : 0;
}

uint16_t GDHubSpecU16(OSData * spec, uint32_t off)
{
    uint32_t n; const uint8_t * p = specBytes(spec, &n);
    return (p && off + 2 <= n) ? rd16(p, off) : 0;
}

uint8_t GDHubSpecU8(OSData * spec, uint32_t off)
{
    uint32_t n; const uint8_t * p = specBytes(spec, &n);
    return (p && off < n) ? p[off] : 0;
}

uint32_t GDHubSpecInputCount(OSData * spec)
{
    return GDHubSpecU8(spec, GDHUB_SPEC_OFF_INPUT_COUNT);
}

uint32_t GDHubSpecSendLength(OSData * spec, uint32_t index)
{
    if (index >= GDHubSpecInputCount(spec)) return 0;
    uint32_t base = entryBase(index);
    uint32_t send = GDHubSpecU8(spec, base + 1);
    return send ? send : GDHubSpecU16(spec, base + 2);
}

const uint8_t * GDHubSpecNeutral(OSData * spec, uint32_t index, uint32_t * length)
{
    if (length) *length = 0;
    uint32_t n; const uint8_t * p = specBytes(spec, &n);
    uint32_t count = GDHubSpecInputCount(spec);
    if (!p || index >= count) return nullptr;
    uint32_t off = GDHUB_SPEC_HEADER_SIZE + GDHubSpecU16(spec, GDHUB_SPEC_OFF_DESC_LEN);
    for (uint32_t i = 0; i < index; i++) off += GDHubSpecSendLength(spec, i);
    uint32_t l = GDHubSpecSendLength(spec, index);
    if (off + l > n) return nullptr;
    if (length) *length = l;
    return p + off;
}

// Index of the input-table entry that `report` (first byte = report ID unless the spec has no IDs) is a complete
// report for: same ID and exactly the entry's send length. -1 if there is none.
int GDHubSpecFindInput(OSData * spec, const uint8_t * report, uint32_t len)
{
    uint32_t count = GDHubSpecInputCount(spec);
    if (!report || len == 0 || count == 0) return -1;
    if (GDHubSpecU8(spec, entryBase(0)) == 0) return len == GDHubSpecSendLength(spec, 0) ? 0 : -1;   // no report IDs
    for (uint32_t i = 0; i < count; i++) {
        if (report[0] == GDHubSpecU8(spec, entryBase(i)) && len == GDHubSpecSendLength(spec, i)) return (int)i;
    }
    return -1;
}

bool GDHubSpecIsDeclaredInput(OSData * spec, const uint8_t * report, uint32_t len)
{
    return GDHubSpecFindInput(spec, report, len) >= 0;
}

// CRC-32 of the whole spec blob: the value GDHM's specCRC32 field must carry (Shared/GDHubXlate.c gdx_crc32).
uint32_t GDHubSpecCRC32(OSData * spec)
{
    uint32_t n; const uint8_t * p = specBytes(spec, &n);
    return p ? gdh_crc32(p, n) : 0;
}

// ---------------------------------------------------------------------------------------------------------------
// §3.6 GDHubSpecCreateDescription / descriptor copy

static void setOptionalString(OSDictionary * d, const char * key, OSData * spec, uint32_t off)
{
    uint32_t n; const uint8_t * p = specBytes(spec, &n);
    if (!p || off >= n || p[off] == 0) return;
    OSDictionarySetStringValue(d, key, (const char *)(p + off));
}

OSDictionary * GDHubSpecCreateDescription(OSData * spec)
{
    if (!spec) return nullptr;
    OSDictionary * d = OSDictionary::withCapacity(16);
    if (!d) return nullptr;
    OSDictionarySetValue(d, "RegisterService", kOSBooleanTrue);     // registration method; Start is not overridden
    OSDictionarySetUInt64Value(d, "VendorID", GDHubSpecU32(spec, GDHUB_SPEC_OFF_VENDOR));
    OSDictionarySetUInt64Value(d, "ProductID", GDHubSpecU32(spec, GDHUB_SPEC_OFF_PRODUCT));
    OSDictionarySetUInt64Value(d, "VersionNumber", GDHubSpecU32(spec, GDHUB_SPEC_OFF_VERSION_NUMBER));
    OSDictionarySetUInt64Value(d, "CountryCode", GDHubSpecU32(spec, GDHUB_SPEC_OFF_COUNTRY));
    OSDictionarySetUInt64Value(d, "ReportInterval", GDHubSpecU32(spec, GDHUB_SPEC_OFF_INTERVAL_US));
    OSDictionarySetUInt64Value(d, "PrimaryUsagePage", GDHubSpecU32(spec, GDHUB_SPEC_OFF_USAGE_PAGE));
    OSDictionarySetUInt64Value(d, "PrimaryUsage", GDHubSpecU32(spec, GDHUB_SPEC_OFF_USAGE));
    uint32_t location = GDHubSpecU32(spec, GDHUB_SPEC_OFF_LOCATION);
    if (location) OSDictionarySetUInt64Value(d, "LocationID", location);
    setOptionalString(d, "Transport", spec, GDHUB_SPEC_OFF_TRANSPORT);
    setOptionalString(d, "Manufacturer", spec, GDHUB_SPEC_OFF_MANUFACTURER);
    setOptionalString(d, "Product", spec, GDHUB_SPEC_OFF_PRODUCT_NAME);
    setOptionalString(d, "SerialNumber", spec, GDHUB_SPEC_OFF_SERIAL);
    if (GDHubSpecU8(spec, GDHUB_SPEC_OFF_FLAGS) & GDHUB_SPEC_FLAG_HID_DEFAULT_BEHAVIOR) {
        OSDictionarySetValue(d, "HIDDefaultBehavior", kOSBooleanTrue);
    }
    // Never set: HIDVirtualDevice, Built-In, GameControllerEligible, GCSyntheticDevice, Privileged,
    // IOServiceDEXTEntitlements (design §3.6).
    return d;
}

OSData * GDHubSpecCreateDescriptor(OSData * spec)
{
    uint32_t n; const uint8_t * p = specBytes(spec, &n);
    if (!p) return nullptr;
    uint32_t descLen = GDHubSpecU16(spec, GDHUB_SPEC_OFF_DESC_LEN);
    if (descLen == 0 || GDHUB_SPEC_HEADER_SIZE + descLen > n) return nullptr;
    return OSData::withBytes(p + GDHUB_SPEC_HEADER_SIZE, descLen);
}
