// T0 probe root (plan §3.3): proves, together with the tap's log line, that both personalities share one process.
#include "GDHubProbe.h"
#include "GDHubProbeRoot.h"

GDHubProbeProcess gProbeProcess;

kern_return_t IMPL(GDHubProbeRoot, Start)
{
    kern_return_t kr = Start(provider, SUPERDISPATCH);
    if (kr != kIOReturnSuccess) {
        PLog("root start: super Start failed 0x%x", (unsigned)kr);
        return kr;
    }
    __atomic_store_n(&gProbeProcess.rootPid, (int32_t)getpid(), __ATOMIC_RELEASE);
    __atomic_store_n(&gProbeProcess.rootSeen, 1, __ATOMIC_RELEASE);
    int32_t n = __atomic_add_fetch(&gProbeProcess.rootStarts, 1, __ATOMIC_RELAXED);
    PLog("root start #%d rootSeen=1 rootPid=%d", (int)n, (int)getpid());
    return RegisterService();
}

kern_return_t IMPL(GDHubProbeRoot, Stop)
{
    PLog("root stop (rootStarts=%d tapStarts=%d)", (int)__atomic_load_n(&gProbeProcess.rootStarts, __ATOMIC_RELAXED),
         (int)__atomic_load_n(&gProbeProcess.tapStarts, __ATOMIC_RELAXED));
    return Stop(provider, SUPERDISPATCH);
}
