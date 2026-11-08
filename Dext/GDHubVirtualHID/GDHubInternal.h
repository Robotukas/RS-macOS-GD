#pragma once
#include <DriverKit/DriverKit.h>
#include <HIDDriverKit/HIDDriverKit.h>
#include <os/log.h>
#include <string.h>
#include "GDHubProtocol.h"
#define GDHUB_TEAM_ID               "79XF6HYX8A"
#define GDHUB_APP_ID                GDHUB_TEAM_ID ".com.interlinked.gdhub"
#define GDHUB_WATCHDOG_PERIOD_MS    250
#define GDHUB_WATCHDOG_TIMEOUT_MS   2000
#ifndef GDHUB_DEXT_BUILD
#define GDHUB_DEXT_BUILD 0          // set by GCC_PREPROCESSOR_DEFINITIONS = GDHUB_DEXT_BUILD=$(CURRENT_PROJECT_VERSION)
#endif
#define GDLog(fmt, ...) os_log(OS_LOG_DEFAULT, "GDHub: " fmt, ##__VA_ARGS__)
class GDHubVirtualHID; class GDHubVirtualHIDUserClient;
bool     GDHubRootClaim(GDHubVirtualHID * root, GDHubVirtualHIDUserClient * uc);     // single authorized owner
void     GDHubRootRelease(GDHubVirtualHID * root, GDHubVirtualHIDUserClient * uc);
OSData * GDHubUCCopySpec(GDHubVirtualHIDUserClient * uc, uint32_t slot);               // +1 or nullptr; any queue
void     GDHubUCDeliverOutput(GDHubVirtualHIDUserClient * uc, uint32_t slot, uint32_t reportType,
                              uint32_t reportID, const uint8_t * bytes, uint32_t length); // any queue
kern_return_t  GDHubSpecValidate(const uint8_t * p, size_t len);                       // §3.6 rules
uint32_t       GDHubSpecU32(OSData * spec, uint32_t off);
uint16_t       GDHubSpecU16(OSData * spec, uint32_t off);
uint8_t        GDHubSpecU8(OSData * spec, uint32_t off);
OSDictionary * GDHubSpecCreateDescription(OSData * spec);                               // +1
OSData *       GDHubSpecCreateDescriptor(OSData * spec);                                // +1
bool           GDHubSpecIsDeclaredInput(OSData * spec, const uint8_t * report, uint32_t len);
uint32_t       GDHubSpecInputCount(OSData * spec);
uint32_t       GDHubSpecSendLength(OSData * spec, uint32_t index);                     // sendLength, or lengthInclID when 0
const uint8_t* GDHubSpecNeutral(OSData * spec, uint32_t index, uint32_t * length);
