// Slot 0: the virtual gamepad (design §3.4, §3.7, §3.8). An IOUserHIDDevice created from the user client with
// Create(this, "GDHubPadProperties", ...). Its identity, descriptor and strings all come from the spec blob the app
// sent with createDevice, so nothing here is identity-specific.
#include "GDHubInternal.h"
#include "GDHubVirtualHIDUserClient.h"
#include "GDHubVirtualPad.h"

struct GDHubVirtualPad_IVars {
    GDHubVirtualHIDUserClient * uc;     // retained
    OSData * spec;                      // +1
    bool loggedOutput;
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
        OSSafeReleaseNULL(ivars->uc);
    }
    IOSafeDeleteNULL(ivars, GDHubVirtualPad_IVars, 1);
    super::free();
}

bool GDHubVirtualPad::handleStart(IOService * provider)
{
    ivars->uc = OSDynamicCast(GDHubVirtualHIDUserClient, provider);
    if (!ivars->uc) { GDLog("pad start: provider is not the user client"); return false; }
    ivars->uc->retain();
    ivars->spec = GDHubUCCopySpec(ivars->uc, GDHUB_SLOT_PAD);
    if (!ivars->spec) { GDLog("pad start: no spec stored for the pad slot"); return false; }
    GDLog("pad start: %04x:%04x", (unsigned)GDHubSpecU32(ivars->spec, GDHUB_SPEC_OFF_VENDOR),
          (unsigned)GDHubSpecU32(ivars->spec, GDHUB_SPEC_OFF_PRODUCT));
    return super::handleStart(provider);   // super calls newDeviceDescription / newReportDescriptor
}

kern_return_t IMPL(GDHubVirtualPad, Stop)
{
    GDLog("pad stop");
    OSSafeReleaseNULL(ivars->spec);
    OSSafeReleaseNULL(ivars->uc);
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
kern_return_t IMPL(GDHubVirtualPad, postReport)
{
    uint64_t len = 0;
    kern_return_t kr = report->GetLength(&len);
    if (kr != kIOReturnSuccess) return kr;
    return handleReport(mach_absolute_time(), report, (uint32_t)len, kIOHIDReportTypeInput, 0);
}

// D5 stub. Output reports (rumble) are accepted and completed; forwarding to the app arrives in D5.
kern_return_t GDHubVirtualPad::setReport(IOMemoryDescriptor * report, IOHIDReportType reportType, IOOptionBits options,
                                         uint32_t completionTimeout, OSAction * action)
{
    (void)report; (void)completionTimeout;
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
