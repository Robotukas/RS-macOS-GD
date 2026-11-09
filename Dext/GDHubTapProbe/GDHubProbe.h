// T0 probe dext (docs/plans/receiver-takeover-plan.md §3.3, §11 T0). Throwaway: deleted in T0.5.
#pragma once
#include <DriverKit/DriverKit.h>
#include <HIDDriverKit/HIDDriverKit.h>
#include <os/log.h>
#include <string.h>

// Set by GCC_PREPROCESSOR_DEFINITIONS = GDHUB_PROBE_BUILD=$(PROBE_BUILD) GDHUB_PROBE_CRASH=$(PROBE_CRASH).
#ifndef GDHUB_PROBE_BUILD
#define GDHUB_PROBE_BUILD 0
#endif
#ifndef GDHUB_PROBE_CRASH
#define GDHUB_PROBE_CRASH 0
#endif

// Every line starts "GDHubProbe: build=N crash=C pid=P". getpid() exists in the DriverKit SDK (IOLib.h, TARGET_OS_DRIVERKIT).
#define PLog(fmt, ...) os_log(OS_LOG_DEFAULT, "GDHubProbe: build=%u crash=%u pid=%d " fmt, \
                              (unsigned)GDHUB_PROBE_BUILD, (unsigned)GDHUB_PROBE_CRASH, (int)getpid(), ##__VA_ARGS__)

// Process-global state, defined in GDHubProbeRoot.cpp. Statics live once per process, so a tap that sees rootSeen == 1
// and rootPid == its own getpid() runs in the root's process (assumption A1).
struct GDHubProbeProcess {
    int32_t rootSeen;     // 1 once the root's Start has run in this process
    int32_t rootPid;      // getpid() recorded by the root
    int32_t rootStarts;
    int32_t tapStarts;    // counts every tap Start in this process; the first one declines (crash=0)
};
extern GDHubProbeProcess gProbeProcess;
