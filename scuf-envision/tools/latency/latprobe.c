// Observe-only latency probe: timestamps input reports of the SCUF receiver (1B1C:3A08, page 0xFF58, report 0x06)
// and of the GDHub virtual pad (045E:02E0) with their kernel timestamps. Writes one CSV line per report.
// Usage: latprobe <seconds> <out.csv>
#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>

static FILE *out;
static mach_timebase_info_data_t tb;
static uint8_t bufs[8][256];
static int nb = 0;

static void cb(void *ctx, IOReturn r, void *sender, IOHIDReportType type, uint32_t id, uint8_t *rep, CFIndex len, uint64_t ts) {
    (void)r; (void)sender; (void)type;
    uint64_t now = mach_absolute_time();
    fprintf(out, "%s,%llu,%llu,%u,", (const char *)ctx,
            (unsigned long long)(ts * tb.numer / tb.denom), (unsigned long long)(now * tb.numer / tb.denom), id);
    for (CFIndex i = 0; i < len; i++) fprintf(out, "%02x", rep[i]);
    fputc('\n', out);
}

static int intProp(IOHIDDeviceRef d, CFStringRef k) {
    CFTypeRef v = IOHIDDeviceGetProperty(d, k); int x = -1;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberIntType, &x);
    return x;
}

static void matched(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef d) {
    (void)ctx; (void)r; (void)sender;
    int vid = intProp(d, CFSTR(kIOHIDVendorIDKey)), pid = intProp(d, CFSTR(kIOHIDProductIDKey));
    int page = intProp(d, CFSTR(kIOHIDPrimaryUsagePageKey));
    const char *tag = NULL;
    if (vid == 0x1b1c && page == 0xff58) tag = "scuf";
    else if (vid == 0x45e && pid == 0x2e0) tag = "vpad";
    fprintf(stderr, "matched %04x:%04x page %x -> %s\n", vid, pid, page, tag ? tag : "ignored");
    if (!tag || nb >= 8) return;
    IOReturn o = IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone);
    fprintf(stderr, "  open 0x%x\n", o);
    IOHIDDeviceRegisterInputReportWithTimeStampCallback(d, bufs[nb++], 256, cb, (void *)tag);
}

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    mach_timebase_info(&tb);
    out = fopen(argv[2], "w");
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatching(m, NULL);
    IOHIDManagerRegisterDeviceMatchingCallback(m, matched, NULL);
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, atof(argv[1]), false);
    fclose(out);
    return 0;
}
