#ifndef GDHubProtocol_h
#define GDHubProtocol_h
// Wire contract GDHub.app <-> GDHubVirtualHID.dext. Little-endian. Swift mirror: Output/VirtualHID/DextProtocol.swift
#define GDHUB_PROTOCOL_VERSION          1
#define GDHUB_USERCLIENT_TYPE           0
#define GDHUB_SEL_HELLO                 0
#define GDHUB_SEL_CREATE_DEVICE         1
#define GDHUB_SEL_DESTROY_DEVICE        2
#define GDHUB_SEL_POST_REPORT           3
#define GDHUB_SEL_POST_NEUTRAL          4
#define GDHUB_SEL_HEARTBEAT             5
#define GDHUB_SEL_REGISTER_OUTPUT       6
#define GDHUB_SEL_GET_STATUS            7
#define GDHUB_SEL_COUNT                 8
#define GDHUB_SLOT_PAD                  0
#define GDHUB_SLOT_KEYBOARD             1
#define GDHUB_SLOT_POINTER              2
#define GDHUB_SLOT_COUNT                3
#define GDHUB_CAP_PAD                   1      // hello out[2] bits: 1 << slot
#define GDHUB_CAP_KEYBOARD              2
#define GDHUB_CAP_POINTER               4
#define GDHUB_MAX_DESCRIPTOR            1024
#define GDHUB_MAX_REPORT                64
#define GDHUB_MAX_INPUT_REPORTS         4
#define GDHUB_MAX_NEUTRAL               256
#define GDHUB_SPEC_MAGIC                0x53484447u   /* bytes 'G' 'D' 'H' 'S' */
#define GDHUB_SPEC_HEADER_SIZE          256
#define GDHUB_SPEC_OFF_MAGIC            0      /* u32 */
#define GDHUB_SPEC_OFF_VERSION          4      /* u16 = GDHUB_PROTOCOL_VERSION */
#define GDHUB_SPEC_OFF_HEADER_SIZE      6      /* u16 = 256 */
#define GDHUB_SPEC_OFF_SLOT             8      /* u8 */
#define GDHUB_SPEC_OFF_FLAGS            9      /* u8 */
#define GDHUB_SPEC_OFF_INPUT_COUNT      10     /* u8, 1..4 */
#define GDHUB_SPEC_OFF_VENDOR           12     /* u32 each from here */
#define GDHUB_SPEC_OFF_PRODUCT          16
#define GDHUB_SPEC_OFF_VERSION_NUMBER   20
#define GDHUB_SPEC_OFF_COUNTRY          24
#define GDHUB_SPEC_OFF_LOCATION         28     /* 0 = omit */
#define GDHUB_SPEC_OFF_INTERVAL_US      32
#define GDHUB_SPEC_OFF_USAGE_PAGE       36
#define GDHUB_SPEC_OFF_USAGE            40
#define GDHUB_SPEC_OFF_DESC_LEN         44     /* u16 */
#define GDHUB_SPEC_OFF_NEUTRAL_LEN      46     /* u16 */
#define GDHUB_SPEC_OFF_INPUT_TABLE      48     /* 4 x { u8 reportID (0 = no IDs), u8 sendLength (0 = lengthInclID), u16 lengthInclID } */
#define GDHUB_SPEC_OFF_TRANSPORT        64
#define GDHUB_SPEC_LEN_TRANSPORT        32
#define GDHUB_SPEC_OFF_MANUFACTURER     96
#define GDHUB_SPEC_LEN_MANUFACTURER     32
#define GDHUB_SPEC_OFF_PRODUCT_NAME     128
#define GDHUB_SPEC_LEN_PRODUCT_NAME     64
#define GDHUB_SPEC_OFF_SERIAL           192
#define GDHUB_SPEC_LEN_SERIAL           32
/* 224..255 reserved, zero. Then: descriptor (DESC_LEN bytes), then one neutral report per input-table entry. */
#define GDHUB_SPEC_FLAG_HID_DEFAULT_BEHAVIOR 1  /* sets "HIDDefaultBehavior" = true (keyboard/pointer) */
/* Async output (registerOutput): args[0] = slot | type<<8 | reportID<<16 | length<<24 | truncated<<40,
   args[1..8] = payload, 8 bytes per word little-endian (max 64), args[9] = sequence. */
#define GDHUB_OUTPUT_ARG_COUNT          10
#endif
