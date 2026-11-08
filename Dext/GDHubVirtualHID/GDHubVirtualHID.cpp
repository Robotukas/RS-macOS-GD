// Root IOService of the GDHub virtual HID dext (design §3.4).
// D2: NewUserClient creates GDHubVirtualHIDUserClient; the root tracks the single authorized owner (§3.11).
#include "GDHubInternal.h"
#include "GDHubVirtualHID.h"
#include "GDHubVirtualHIDUserClient.h"

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
    if (type != GDHUB_USERCLIENT_TYPE) return kIOReturnBadArgument;
    IOService * c = nullptr;
    kern_return_t kr = Create(this, "UserClientProperties", &c);
    if (kr != kIOReturnSuccess) {
        GDLog("NewUserClient: Create failed 0x%x", (unsigned)kr);
        return kr;
    }
    *userClient = OSDynamicCast(IOUserClient, c);
    if (!*userClient) {
        c->release();
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

bool GDHubRootClaim(GDHubVirtualHID * root, GDHubVirtualHIDUserClient * uc)
{
    if (!root || !root->ivars || !root->ivars->lock) return false;
    IOLockLock(root->ivars->lock);
    bool ok = (root->ivars->owner == nullptr || root->ivars->owner == uc);
    if (ok) root->ivars->owner = uc;
    IOLockUnlock(root->ivars->lock);
    return ok;
}

void GDHubRootRelease(GDHubVirtualHID * root, GDHubVirtualHIDUserClient * uc)
{
    if (!root || !root->ivars || !root->ivars->lock) return;
    IOLockLock(root->ivars->lock);
    if (root->ivars->owner == uc) root->ivars->owner = nullptr;
    IOLockUnlock(root->ivars->lock);
}
