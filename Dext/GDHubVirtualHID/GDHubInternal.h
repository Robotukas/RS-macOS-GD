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
#define GDHUB_CREATE_WAIT_MS        500    // createDevice waits at most this long for a pad that Create returned before it started
#ifndef GDHUB_DEV_TERMINATE
#define GDHUB_DEV_TERMINATE         1      // DEBUG-ONLY: enables selector devTerminate; set to 0 for a release build
#endif
#ifndef GDHUB_DEXT_BUILD
#define GDHUB_DEXT_BUILD 0          // set by GCC_PREPROCESSOR_DEFINITIONS = GDHUB_DEXT_BUILD=$(CURRENT_PROJECT_VERSION)
#endif
// Dext log lines are live-only and are cut at about 256 characters: keep every line under 250.
#define GDLog(fmt, ...) os_log(OS_LOG_DEFAULT, "GDHub: " fmt, ##__VA_ARGS__)
class GDHubVirtualHID; class GDHubVirtualHIDUserClient; class GDHubVirtualPad;

// Pad submission sources (GDHUB_PADSRC_*) and neutral reasons (log text only; not part of the wire protocol).
#define GDHUB_NEUTRAL_UC_REQUEST    1
#define GDHUB_NEUTRAL_WATCHDOG      2

// ---------------------------------------------------------------------------------------------------------------
// Call-order invariant (receiver-takeover plan 4.2). Ranks: user client 1, root 2, tap 3 (T4), pad 4. The only
// synchronous cross-object calls are UC -> root (CreatePad, DestroyPad) and UC -> pad (submitInput, postNeutralFrom).
// GDH_SYNC wraps every one of them, in every build:
//  - compile time: the caller's rank must be below the target's, so a call toward a lower or equal rank cannot be built;
//  - run time: if the target's queue is already on this thread's queue stack (OnQueue(), IODispatchQueue.iig:105, which
//    is also true for a queue that invoked a second queue), the call would re-enter a queue we are nested in. That is a
//    call cycle: it is counted (status2 syncViolations) and the first few are logged. It never blocks or aborts.
void GDHubSyncViolation(const char * what, uint32_t callerRank, uint32_t targetRank);
static inline void GDHubSyncCheck(IODispatchQueue * targetQueue, const char * what, uint32_t callerRank, uint32_t targetRank)
{
    if (targetQueue != nullptr && targetQueue->OnQueue()) GDHubSyncViolation(what, callerRank, targetRank);
}
#define GDH_SYNC(callerRank, targetRank, targetQueue, what) \
    do { static_assert((callerRank) < (targetRank), "GDH_SYNC: a synchronous call must go to a higher rank"); \
         GDHubSyncCheck((targetQueue), (what), (callerRank), (targetRank)); } while (0)

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
