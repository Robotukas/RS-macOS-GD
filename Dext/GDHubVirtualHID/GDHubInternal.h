#pragma once
#include <DriverKit/DriverKit.h>
#include <HIDDriverKit/HIDDriverKit.h>
#include <os/log.h>
#include <string.h>
#include "GDHubProtocol.h"
#include "Core/GDHubDextCore.h"
#define GDHUB_TEAM_ID               "79XF6HYX8A"
#define GDHUB_APP_ID                GDHUB_TEAM_ID ".com.interlinked.gdhub"
#define GDHUB_WATCHDOG_PERIOD_MS    250
#define GDHUB_WATCHDOG_TIMEOUT_MS   2000
#define GDHUB_METER_WINDOW_MS       10000
#define GDHUB_TAP_TICK_MS           50     // the tap's timer while it has work (desired != applied, an Open retry pending, or terminating)
#define GDHUB_TAP_SLOW_TICK_MS      1000   // ... and otherwise: the poke covers the fast path
#define GDHUB_TAP_OPEN_RETRY_MS     500    // between failed Open attempts (never a spin)
#define GDHUB_TAP_POOL_BUF          64     // ... of MaxInputReportSize (64, measured in T0)
#ifndef GDHUB_TAP_DECLINE
#define GDHUB_TAP_DECLINE           0      // 1: the tap's Start logs and returns an error, so Apple's driver attaches. A rollback lever (plan 3.2)
#endif
#ifndef GDHUB_DEV_TERMINATE
#define GDHUB_DEV_TERMINATE         1      // DEBUG-ONLY: enables selector devTerminate; set to 0 for a release build
#endif
#ifndef GDHUB_DEXT_BUILD
#define GDHUB_DEXT_BUILD 0          // set by GCC_PREPROCESSOR_DEFINITIONS = GDHUB_DEXT_BUILD=$(CURRENT_PROJECT_VERSION)
#endif
// Dext log lines are live-only and are cut at about 256 characters: keep every line under 250.
#define GDLog(fmt, ...) os_log(OS_LOG_DEFAULT, "GDHub: " fmt, ##__VA_ARGS__)
class GDHubVirtualHID; class GDHubVirtualHIDUserClient; class GDHubVirtualPad; class GDHubReceiverTap;

// Pad submission sources (GDHUB_PADSRC_*) and neutral reasons (log text only; not part of the wire protocol).
#define GDHUB_NEUTRAL_UC_REQUEST    1
#define GDHUB_NEUTRAL_WATCHDOG      2

// ---------------------------------------------------------------------------------------------------------------
// Call-order invariant (receiver-takeover plan 4.2). Ranks: user client 1, root 2, tap 3 (T4), pad 4. The only
// synchronous cross-object calls are UC -> root (CreatePad, DestroyPad) and UC -> pad (submitInput, postNeutralFrom).
// GDH_SYNC wraps every one of them, in every build.
//  - Compile time: the caller's rank must be below the target's, so a call toward a lower or equal rank cannot be built.
//    With the four call sites above and a root and a pad that call no GDHub object, no wait cycle is expressible.
//  - Run time: if the target's queue is already on this thread's queue stack (OnQueue(), IODispatchQueue.iig:104-105,
//    which is also true for a queue that invoked a second queue) the call is an inline nested call, not a cycle: the
//    thread already owns that queue. It is counted in `syncInline` and logged once per call site. Build 18 measured
//    this for the user client calling the root: the topology is not what the plan assumed (see the probe below).
//    `syncViolations` (GDHR_CTR_SYNC_VIOLATIONS) means a call toward a lower or equal rank; the compile-time assert makes it
//    unreachable, so it reads 0 by construction.
void GDHubSyncInline(const char * what, uint32_t * seenOnce);
static inline void GDHubSyncCheck(IODispatchQueue * targetQueue, const char * what, uint32_t * seenOnce)
{
    if (targetQueue != nullptr && targetQueue->OnQueue()) GDHubSyncInline(what, seenOnce);
}
#define GDH_SYNC(callerRank, targetRank, targetQueue, what) \
    do { static_assert((callerRank) < (targetRank), "GDH_SYNC: a synchronous call must go to a higher rank"); \
         static uint32_t gdhSeenOnce; \
         GDHubSyncCheck((targetQueue), (what), &gdhSeenOnce); } while (0)

// Queue topology probe (next build): which queue objects the root, the user client and the pad really use. Each Start logs
// one line with the object's own default-queue index (process-local, comparable across lines; 0 = none) and which of the
// other known queues are on this thread's stack; the first ExternalMethod and the first submitInput log once more.
// The results are also in status2 (topology flags and the two probe bytes). Nothing here runs per post except one load.
uint32_t GDHubQueueIndex(IODispatchQueue * q);
void     GDHubProbeStart(const char * where, int which, IODispatchQueue * ownQueue);   // GDHR_Q_*; records the index, logs once
void     GDHubProbeFirst(int probe, const char * where, int which, IODispatchQueue * ownQueue);   // GDHR_PROBE_*; once
IODispatchQueue * GDHubUCQueue(GDHubVirtualHIDUserClient * uc);                        // valid while `uc` is retained

// T4 receiver tap. Control reaches the tap only through the registry's desired state plus GDHubPokeTap (DispatchAsync onto
// the tap's own queue) with the tap's 50 ms timer as backstop. Nothing calls the tap synchronously, and the tap calls no
// GDHub object, so it adds no edge to the waits-for graph.
void     GDHubPokeTap(void);                                          // any queue; +1 copies from the registry, released in the block
void     GDHubTerminateTap(void);                                     // devTerminate: Terminate(0) on the registered tap (its Stop closes the interface)
void     GDHubTapApply(GDHubReceiverTap * tap);                       // tap queue only: Open or Close as GDH_TAP decides
bool     GDHubTapReadMeter(GDHubReceiverTap * tap, gdh_summary * xlate, gdh_summary * k2d, uint32_t * windows);
bool     GDHubTapReadParity(GDHubReceiverTap * tap, gdh_parity_rec * rec);

// T5 (GDHubXlateGlue.cpp)
uint32_t GDHubSelfTestEnsure(void);                                   // runs the golden vectors once per process; returns GDHR_SELFTEST_*
kern_return_t GDHubMapAccept(GDHubVirtualHIDUserClient * uc, const uint8_t * bytes, size_t len, uint32_t * acceptedRevision, uint32_t * reason);

// ---------------------------------------------------------------------------------------------------------------
// Process-global registry (GDHubRegistry.cpp over Core/GDHubRegistryCore.c). Whichever object runs first creates it.
// Every Copy function returns a +1 retained object (or nullptr) that the caller releases; none holds a lock afterwards.
gdhr *                       GDHubReg(void);                          // nullptr only if no lock could be allocated
GDHubVirtualPad *            GDHubCopyPad(void);
GDHubVirtualHID *            GDHubCopyRoot(void);
GDHubVirtualHIDUserClient *  GDHubCopyOwner(uint64_t * gen);
OSData *                     GDHubCopyPadSpec(void);                  // the spec the pad being created must use
uint64_t                     GDHubClaimOwner(GDHubVirtualHIDUserClient * uc);   // generation (> 0), or 0 if owned by another client
void                         GDHubReleaseOwner(GDHubVirtualHIDUserClient * uc); // also terminates the owner's pad if one is left
void                         GDHubTerminateAndRelease(OSObject * service);      // Terminate(0), then release; nullptr is fine
IODispatchQueue *            GDHubRootQueue(GDHubVirtualHID * root);   // valid while `root` is retained
IODispatchQueue *            GDHubPadQueue(GDHubVirtualPad * pad);     // valid while `pad` is retained
bool                         GDHubPadReadMeter(GDHubVirtualPad * pad, gdh_summary * hop, gdh_summary * hr, uint32_t * windows);
size_t                       GDHubBuildStatus2(uint8_t * buf, size_t cap);

kern_return_t  GDHubSpecValidate(const uint8_t * p, size_t len);                       // §3.6 rules
uint32_t       GDHubSpecU32(OSData * spec, uint32_t off);
uint16_t       GDHubSpecU16(OSData * spec, uint32_t off);
uint8_t        GDHubSpecU8(OSData * spec, uint32_t off);
OSDictionary * GDHubSpecCreateDescription(OSData * spec);                               // +1
OSData *       GDHubSpecCreateDescriptor(OSData * spec);                                // +1
bool           GDHubSpecIsDeclaredInput(OSData * spec, const uint8_t * report, uint32_t len);
int            GDHubSpecFindInput(OSData * spec, const uint8_t * report, uint32_t len); // input-table index, or -1
uint32_t       GDHubSpecInputCount(OSData * spec);
uint32_t       GDHubSpecSendLength(OSData * spec, uint32_t index);                     // sendLength, or lengthInclID when 0
const uint8_t* GDHubSpecNeutral(OSData * spec, uint32_t index, uint32_t * length);
uint32_t       GDHubSpecCRC32(OSData * spec);                                           // same value as gdx_crc32 over the blob
