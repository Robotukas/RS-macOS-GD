// Root IOService of the GDHub virtual HID dext (design §3.4).
// D0: only the root service exists; NewUserClient returns kIOReturnUnsupported until D2.
#include "GDHubInternal.h"
#include "GDHubVirtualHID.h"

struct GDHubVirtualHID_IVars {
    IOLock * lock;
    GDHubVirtualHIDUserClient * owner;   // not retained
};

bool GDHubVirtualHID::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(GDHubVirtualHID_IVars, 1);
    return ivars != nullptr;
}

void GDHubVirtualHID::free()
{
    if (ivars) {
        if (ivars->lock) { IOLockFree(ivars->lock); ivars->lock = nullptr; }
    }
    IOSafeDeleteNULL(ivars, GDHubVirtualHID_IVars, 1);
    super::free();
}

kern_return_t IMPL(GDHubVirtualHID, Start)
{
    kern_return_t kr = Start(provider, SUPERDISPATCH);
    if (kr != kIOReturnSuccess) return kr;
    ivars->lock = IOLockAlloc();
    GDLog("root start build %u", (unsigned)GDHUB_DEXT_BUILD);
    return RegisterService();
}

kern_return_t IMPL(GDHubVirtualHID, Stop)
{
    GDLog("root stop");
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t IMPL(GDHubVirtualHID, NewUserClient)
{
    (void)type; (void)userClient;
    GDLog("NewUserClient: not implemented in D0");
    return kIOReturnUnsupported;
}

bool GDHubRootClaim(GDHubVirtualHID * root, GDHubVirtualHIDUserClient * uc)
{
    (void)root; (void)uc;   // D2
    return false;
}

void GDHubRootRelease(GDHubVirtualHID * root, GDHubVirtualHIDUserClient * uc)
{
    (void)root; (void)uc;   // D2
}
