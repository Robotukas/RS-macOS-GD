#ifndef GDHubProtocol_h
#define GDHubProtocol_h
// Wire contract GDHub.app <-> GDHubVirtualHID.dext. Little-endian. Swift mirror: Output/VirtualHID/DextProtocol.swift
// Additive rule (receiver-takeover plan 5.4): selectors and capability bits are only ever added, each new selector
// behind a capability bit; blobs carry their own versions. GDHUB_PROTOCOL_VERSION changes only for a breaking change,
// because `hello` compares it for equality. An old app and a new dext, and a new app and an old dext, must both work.
#define GDHUB_PROTOCOL_VERSION          1
#define GDHUB_SPEC_VERSION              1      /* version of the DeviceSpec blob (spec validation checks this, not the protocol) */
#define GDHUB_USERCLIENT_TYPE           0
#define GDHUB_SEL_HELLO                 0
#define GDHUB_SEL_CREATE_DEVICE         1
#define GDHUB_SEL_DESTROY_DEVICE        2
#define GDHUB_SEL_POST_REPORT           3
#define GDHUB_SEL_POST_NEUTRAL          4
#define GDHUB_SEL_HEARTBEAT             5
#define GDHUB_SEL_REGISTER_OUTPUT       6
#define GDHUB_SEL_GET_STATUS            7
#define GDHUB_SEL_DEV_TERMINATE         8      /* DEBUG-ONLY dev experiment (not in the design): Terminate(0) on the root so the dext process can exit */
#define GDHUB_SEL_SET_FORWARDING        9      /* T3. scalars in: state, flags, argMs. out: appliedState, tapPresent, padSource, lastError. CAP_ROOT_PAD */
/* 10 is reserved (set mapping, T5) and answers kIOReturnUnsupported until then */
#define GDHUB_SEL_GET_STATUS2           11     /* T3. struct out: GDHubStatus2 (<= 512 bytes, layout below). CAP_ROOT_PAD */
/* 12 is reserved (create device 2, T7). Selectors 9-11 are owner-only, behind hello, the team check and the claim. */
#define GDHUB_SEL_COUNT                 12
#define GDHUB_SLOT_PAD                  0
#define GDHUB_SLOT_KEYBOARD             1
#define GDHUB_SLOT_POINTER              2
#define GDHUB_SLOT_COUNT                3
#define GDHUB_CAP_PAD                   1      // hello out[2] bits: 1 << slot
#define GDHUB_CAP_KEYBOARD              2
#define GDHUB_CAP_POINTER               4
#define GDHUB_CAP_ROOT_PAD              (1u << 8)   /* T3: the root service owns the pad; selectors 9 and 11 exist. Bits 0-2 stay the slot bits */
/* Forwarding state (selector 9). T3 accepts INERT only; every other state, and any flag, answers kIOReturnUnsupported. */
#define GDHUB_FWD_INERT                 0
/* Pad source (GDHubStatus2 padSource, selector 9 output): who may post to the pad. */
#define GDHUB_PADSRC_NONE               0      /* no pad */
#define GDHUB_PADSRC_UC                 1      /* user client posts (the engine or the app) */
#define GDHUB_PADSRC_TAP                2      /* reserved for the receiver tap (T4+) */
#define GDHUB_MAX_DESCRIPTOR            1024
#define GDHUB_MAX_REPORT                64
#define GDHUB_MAX_INPUT_REPORTS         4
#define GDHUB_MAX_NEUTRAL               256
#define GDHUB_SPEC_MAGIC                0x53484447u   /* bytes 'G' 'D' 'H' 'S' */
#define GDHUB_SPEC_HEADER_SIZE          256
#define GDHUB_SPEC_OFF_MAGIC            0      /* u32 */
#define GDHUB_SPEC_OFF_VERSION          4      /* u16 = GDHUB_SPEC_VERSION */
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

/* GDHubStatus2 (selector 11), version 1, T3 subset. Little-endian, fixed offsets, no struct: Swift decodes by offset.
   `size` is the number of bytes the dext wrote (and, if the caller's buffer was shorter, the bytes it could return are
   the first min(size, buffer) of them). Later phases only APPEND fields; a reader takes the fields that fit in
   min(size, bytes received) and treats the rest as zero. Histograms stay inside the dext; the last completed 10 s
   window of `hop` and `hr` is summarised here in nanoseconds (p50 and p99 are bucket upper edges clamped to the window
   maximum, the smallest bucket edge is 1 us; the mean is exact). */
#define GDHUB_ST2_VERSION               1
#define GDHUB_ST2_MAX_SIZE              512
#define GDHUB_ST2_SIZE                  172
#define GDHUB_ST2_OFF_VERSION           0      /* u16 */
#define GDHUB_ST2_OFF_SIZE              2      /* u16 */
#define GDHUB_ST2_OFF_BUILD             4      /* u32 */
#define GDHUB_ST2_OFF_NONCE             8      /* u64, mach_absolute_time at root Start; an identity of the dext process only */
#define GDHUB_ST2_OFF_ROOT_PID          16     /* u32 */
#define GDHUB_ST2_OFF_DESIRED_STATE     20     /* u8, GDHUB_FWD_*; always INERT in T3 */
#define GDHUB_ST2_OFF_PAD_SOURCE        21     /* u8, GDHUB_PADSRC_* */
#define GDHUB_ST2_OFF_PAD_LIVE          22     /* u8, 1 while the pad is started and registered */
#define GDHUB_ST2_OFF_OWNER_PRESENT     23     /* u8 */
#define GDHUB_ST2_OFF_UC_POSTS          24     /* u64 counters from here */
#define GDHUB_ST2_OFF_UC_REJECTED       32
#define GDHUB_ST2_OFF_NEUTRAL_POSTS     40
#define GDHUB_ST2_OFF_POST_ERRORS       48
#define GDHUB_ST2_OFF_SYNC_VIOLATIONS   56
#define GDHUB_ST2_OFF_PAD_CREATES       64
#define GDHUB_ST2_OFF_PAD_DESTROYS      72
#define GDHUB_ST2_OFF_CREATE_FAILS      80
#define GDHUB_ST2_OFF_OUTPUTS_SEEN      88
#define GDHUB_ST2_OFF_OUTPUTS_NO_OWNER  96
#define GDHUB_ST2_OFF_CREATE_EARLY      104    /* u64, CreatePad found Create returned before the pad's Start registered it */
#define GDHUB_ST2_OFF_PAD_SPEC_CRC      112    /* u32, CRC-32 of the live pad's spec blob (0 without a pad) */
#define GDHUB_ST2_OFF_METER_WINDOWS     116    /* u32, completed 10 s windows since the pad started */
#define GDHUB_ST2_OFF_HOP_COUNT         120    /* u32 each from here: count, p50, p99, max, mean (ns; the mean is exact) */
#define GDHUB_ST2_OFF_HOP_P50_NS        124
#define GDHUB_ST2_OFF_HOP_P99_NS        128
#define GDHUB_ST2_OFF_HOP_MAX_NS        132
#define GDHUB_ST2_OFF_HOP_MEAN_NS       136
#define GDHUB_ST2_OFF_HR_COUNT          140
#define GDHUB_ST2_OFF_HR_P50_NS         144
#define GDHUB_ST2_OFF_HR_P99_NS         148
#define GDHUB_ST2_OFF_HR_MAX_NS         152
#define GDHUB_ST2_OFF_HR_MEAN_NS        156
#define GDHUB_ST2_OFF_SYNC_INLINE       160    /* u64, GDH_SYNC calls whose target queue was already on this thread's queue stack */
#define GDHUB_ST2_OFF_TOPOLOGY          168    /* u8, GDHUB_TOPO_*: which of the root, user client and pad share a queue object */
#define GDHUB_ST2_OFF_PROBE_EXT         169    /* u8, GDHUB_PROBE_*: OnQueue() of the root/UC/pad queue at the first ExternalMethod */
#define GDHUB_ST2_OFF_PROBE_SUBMIT      170    /* u8, the same at the first submitInput */
/* 171 reserved. Topology: low nibble = the two queues are the same object, high nibble = both were known (set at Start). */
#define GDHUB_TOPO_UC_EQ_ROOT           0x01
#define GDHUB_TOPO_PAD_EQ_ROOT          0x02
#define GDHUB_TOPO_PAD_EQ_UC            0x04
#define GDHUB_TOPO_KNOWN_SHIFT          4
#define GDHUB_PROBE_ROOT                0x01
#define GDHUB_PROBE_UC                  0x02
#define GDHUB_PROBE_PAD                 0x04
#define GDHUB_PROBE_VALID               0x80
/* hop = pad submitInput entry minus the user client's stamp before the call; hr = handleReport duration. */
#endif
