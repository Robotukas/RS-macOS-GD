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
#define GDHUB_SEL_SET_MAPPING           10     /* T5. struct in: GDHM blob (<= 1024 B). scalars out: acceptedRevision (0 if refused), reason. CAP_XLATE.
                                                  kIOReturnBadArgument only for a size outside 64...1024; every other refusal is kIOReturnSuccess with reason != 0
                                                  (kernel does not copy scalar outputs of a failed call), kIOReturnNotPermitted for a non-owner */
#define GDHUB_SEL_GET_STATUS2           11     /* T3. struct out: GDHubStatus2 (<= 512 bytes, layout below). CAP_ROOT_PAD */
#define GDHUB_SEL_CREATE_DEVICE2        12     /* T7. struct in: spec (as selector 1). scalars out: adopted (1 = a live pinned pad with the same spec became ours), padSource. CAP_LIVE */
/* Selectors 9-12 are owner-only, behind hello, the team check and the claim. */
#define GDHUB_SEL_COUNT                 13
#define GDHUB_SLOT_PAD                  0
#define GDHUB_SLOT_KEYBOARD             1
#define GDHUB_SLOT_POINTER              2
#define GDHUB_SLOT_COUNT                3
#define GDHUB_CAP_PAD                   1      // hello out[2] bits: 1 << slot
#define GDHUB_CAP_KEYBOARD              2
#define GDHUB_CAP_POINTER               4
#define GDHUB_CAP_LIVE                  (1u << 11)  /* T7: the LIVE state, selector 12, the pause and release-pad flags of selector 9, pinning and adoption. Absent in a GDHUB_TAP_DECLINE build */
#define GDHUB_CAP_XLATE                 (1u << 10)  /* T5: selector 10 (setMapping) and the SHADOW state exist. Absent in a GDHUB_TAP_DECLINE build */
#define GDHUB_CAP_TAP                   (1u << 9)   /* T4: the receiver tap exists in this dext; selector 9 also accepts COUNT. Absent in a GDHUB_TAP_DECLINE build */
#define GDHUB_CAP_ROOT_PAD              (1u << 8)   /* T3: the root service owns the pad; selectors 9 and 11 exist. Bits 0-2 stay the slot bits */
/* Forwarding state (selector 9). T5 accepts INERT, COUNT and SHADOW (SHADOW needs a passed self-test: kIOReturnNotPermitted otherwise);
   LIVE and any flag answer kIOReturnUnsupported. */
#define GDHUB_FWD_INERT                 0      /* tap attached, interface NOT opened: no per-frame code. Every dext launch starts here */
#define GDHUB_FWD_SHADOW                2      /* T5: opened; translates with the accepted mapping and records a parity sample; posts nothing. Without a mapping it is COUNT */
#define GDHUB_FWD_LIVE                  3      /* T7: SHADOW, and the tap submits what it translates to the pad (padSource TAP). Only from SHADOW with the pad's mapping accepted and the self-test passed */
#define GDHUB_FWD_FLAG_DEV_PAUSE_TAP    (1u << 8)   /* T7, owner only, every build with CAP_LIVE: the tap ignores frames for argMs (<= 10000); state is applied as well */
#define GDHUB_FWD_FLAG_RELEASE_PAD      (1u << 9)   /* T7, owner only, with state INERT: padSource UC, neutral, destroy the pad even if it is pinned and ownerless */
/* bit 0 (STAMP_SOURCE_TIME of the plan) is not implemented: any other flag answers kIOReturnUnsupported */
#define GDHUB_FWD_COUNT                 1      /* T4: opened; counts frames and the kernel-to-driver delay; translates and posts nothing */
/* setMapping reasons (scalar output 1): 0 accepted; 1...21 are GDX_E_* of Shared/GDHubXlate.h (gdx_validate); then: */
#define GDHUB_MAP_OK                    0
#define GDHUB_MAP_NO_PAD                100    /* no pad has been created: there is no spec to validate against */
#define GDHUB_MAP_TOO_BIG               101    /* does not fit the handoff buffer after validation (never expected) */
#define GDHUB_MAP_NO_REGISTRY           102
/* Pad source (GDHubStatus2 padSource, selector 9 output): who may post to the pad. */
#define GDHUB_PADSRC_NONE               0      /* no pad */
#define GDHUB_PADSRC_UC                 1      /* user client posts (the engine or the app) */
#define GDHUB_PADSRC_TAP                2      /* the receiver tap drives the pad (LIVE) */
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
#define GDHUB_ST2_MAX_SIZE              1024   /* was 512 until T5: the parity record needed room. A caller that offers less gets the first bytes */
#define GDHUB_ST2_SIZE                  676
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
/* T4 receiver tap fields, appended. All zero when no tap is attached. */
#define GDHUB_ST2_OFF_TAP_PRESENT       172    /* u8, 1 while a GDHubReceiverTap instance is registered */
#define GDHUB_ST2_OFF_TAP_OPENED        173    /* u8, 1 while the interface is open (COUNT applied) */
#define GDHUB_ST2_OFF_APPLIED_STATE     174    /* u8, GDHUB_FWD_*: what the tap's queue has applied (desiredState at offset 20 is what was asked) */
#define GDHUB_ST2_OFF_POWERED           175    /* u8, 0 between SetPowerState(Off) and On */
#define GDHUB_ST2_OFF_TAP_PID           176    /* u32, getpid() of the process the tap runs in: equal to rootPid when both share one process */
#define GDHUB_ST2_OFF_TAP_STARTS        180    /* u32, tap Start calls kept in this process */
#define GDHUB_ST2_OFF_LAST_POWER_FLAGS  184    /* u32, last SetPowerState argument */
#define GDHUB_ST2_OFF_LAST_ERROR        188    /* u32, last Open error (kern_return), 0 if none */
#define GDHUB_ST2_OFF_FRAMES_IN         192    /* u64 counters from here; they accumulate over tap instances in this process */
#define GDHUB_ST2_OFF_FRAMES_R06        200
#define GDHUB_ST2_OFF_FRAMES_OTHER      208
#define GDHUB_ST2_OFF_FRAMES_IGNORED    216
#define GDHUB_ST2_OFF_FRAMES_BAD        224
#define GDHUB_ST2_OFF_POOL_MISS         232
#define GDHUB_ST2_OFF_READD_FAIL        240
#define GDHUB_ST2_OFF_OPEN_FAILURES     248
#define GDHUB_ST2_OFF_K2D_COUNT         256    /* u32 each: count, p50, p99, max, mean (ns) of the kernel-to-driver delay, last 10 s window */
#define GDHUB_ST2_OFF_K2D_P50_NS        260
#define GDHUB_ST2_OFF_K2D_P99_NS        264
#define GDHUB_ST2_OFF_K2D_MAX_NS        268
#define GDHUB_ST2_OFF_K2D_MEAN_NS       272
/* T4 review additions, appended after the k2d words. */
#define GDHUB_ST2_OFF_POKES_RUN         276    /* u64, pokes (DispatchAsync) that ran on the tap's queue */
#define GDHUB_ST2_OFF_TICK_APPLIES      284    /* u64, Open/Close attempts made by the tap's own timer (not by a poke) */
#define GDHUB_ST2_OFF_CLOSE_FAILURES    292    /* u64, Close returned an error */
#define GDHUB_ST2_OFF_REOPENS           300    /* u64, Opens after an earlier Close in one tap instance (each with a fresh pool) */
#define GDHUB_ST2_OFF_TAP_FREES         308    /* u64, tap objects freed: tapStarts == tapFrees + live instances */
/* T5: SHADOW (in-driver translation, nothing posted), appended after the T4 review counters. */
#define GDHUB_ST2_OFF_SELF_TEST         316    /* u8, GDHUB_SELFTEST_*: the golden vectors through the dext's build of the core */
#define GDHUB_ST2_OFF_TRANSLATING       317    /* u8, 1 while the tap is applying SHADOW with an accepted mapping */
#define GDHUB_ST2_OFF_HAS_MAP           318    /* u8, 1 while a mapping is accepted (registry) */
/* 319 reserved */
#define GDHUB_ST2_OFF_ACCEPTED_REVISION 320    /* u32, revision of the accepted mapping, 0 if none */
#define GDHUB_ST2_OFF_APPLIED_REVISION  324    /* u32, revision the tap translated its last frame with (changes at the first frame after a swap) */
#define GDHUB_ST2_OFF_ACCEPTED_SPEC_CRC 328    /* u32, spec CRC the accepted mapping targets */
/* 332 reserved */
#define GDHUB_ST2_OFF_FRAMES_TRANSLATED 336    /* u64 counters from here */
#define GDHUB_ST2_OFF_FRAMES_SKIPPED    344    /* not report 6 of 16 bytes */
#define GDHUB_ST2_OFF_FRAMES_NOMAP      352    /* SHADOW frame, no accepted mapping */
#define GDHUB_ST2_OFF_FRAMES_UNMAPPED   360    /* bytes unreadable without allocating (never expected) */
#define GDHUB_ST2_OFF_STATES_CHANGED    368    /* translated frames after which gdx_step would post */
#define GDHUB_ST2_OFF_REPORTS_WOULD_POST 376   /* reports in those posts */
#define GDHUB_ST2_OFF_MAP_ACCEPTED      384    /* selector 10 blobs accepted */
#define GDHUB_ST2_OFF_MAP_REFUSED       392    /* selector 10 blobs refused */
#define GDHUB_ST2_OFF_MAP_SWAPS         400    /* tap switched to a new mapping */
#define GDHUB_ST2_OFF_XLATE_COUNT       408    /* u32 each: count, p50, p99, max, mean (ns) of one gdx_step + parity build, last 10 s window */
#define GDHUB_ST2_OFF_XLATE_P50_NS      412
#define GDHUB_ST2_OFF_XLATE_P99_NS      416
#define GDHUB_ST2_OFF_XLATE_MAX_NS      420
#define GDHUB_ST2_OFF_XLATE_MEAN_NS     424
#define GDHUB_ST2_OFF_PARITY_COUNT      428    /* u32, frames recorded by this tap instance; moves with every translated frame */
#define GDHUB_ST2_OFF_PARITY_REVISION   432    /* u32, mapping revision of the recorded frame */
#define GDHUB_ST2_OFF_PARITY_TIMESTAMP  436    /* u64, kernel timestamp (mach ticks) of the recorded frame */
#define GDHUB_ST2_OFF_PARITY_FRAME      444    /* u8[16], the raw report 0x06 */
#define GDHUB_ST2_OFF_PARITY_OUT01      460    /* u8[16], report 0 of the mapping as gdx_eval + gdx_build give it (xbox-bt16: 0x01) */
#define GDHUB_ST2_OFF_PARITY_OUT02      476    /* u8[2], report 1 of the mapping (xbox-bt16: 0x02) */
/* 478-479 reserved. */
/* T7: LIVE, appended after the parity record. */
#define GDHUB_ST2_OFF_HOLD_NEUTRAL      480    /* u8, the engine's neutral request is holding the tap back while it drives the pad */
#define GDHUB_ST2_OFF_PAD_ORPHANED      481    /* u8, a pinned pad whose owner left; removed 30 s after it left unless adopted */
#define GDHUB_ST2_OFF_PAUSED            482    /* u8, the pause drill is active */
/* 483 reserved */
#define GDHUB_ST2_OFF_TAP_POSTS         484    /* u64 counters from here */
#define GDHUB_ST2_OFF_TAP_REJECTED      492
#define GDHUB_ST2_OFF_TAP_SUBMIT_ERRORS 500
#define GDHUB_ST2_OFF_FRAMES_UNCHANGED  508
#define GDHUB_ST2_OFF_SWITCH_NEUTRALS   516
#define GDHUB_ST2_OFF_STOP_NEUTRALS     524
#define GDHUB_ST2_OFF_SILENCE_NEUTRALS  532
#define GDHUB_ST2_OFF_POWER_NEUTRALS    540
#define GDHUB_ST2_OFF_HOLD_NEUTRALS     548
#define GDHUB_ST2_OFF_ADOPTS            556
#define GDHUB_ST2_OFF_ORPHAN_DESTROYS   564
#define GDHUB_ST2_OFF_PAUSE_DROPS       572
#define GDHUB_ST2_OFF_SOURCE_SWITCHES   580
#define GDHUB_ST2_OFF_LIVE_NO_PAD       588
#define GDHUB_ST2_OFF_TOTAL_COUNT       596    /* u32 each: count, p50, p99, max, mean (ns), last 10 s window: kernel timestamp -> submitInput returned */
#define GDHUB_ST2_OFF_TOTAL_P50_NS      600
#define GDHUB_ST2_OFF_TOTAL_P99_NS      604
#define GDHUB_ST2_OFF_TOTAL_MAX_NS      608
#define GDHUB_ST2_OFF_TOTAL_MEAN_NS     612
#define GDHUB_ST2_OFF_OCC_COUNT         616    /* tap-queue occupancy per frame (entry -> AddReportToPool returned) */
#define GDHUB_ST2_OFF_OCC_P50_NS        620
#define GDHUB_ST2_OFF_OCC_P99_NS        624
#define GDHUB_ST2_OFF_OCC_MAX_NS        628
#define GDHUB_ST2_OFF_OCC_MEAN_NS       632
#define GDHUB_ST2_OFF_ADDPOOL_COUNT     636    /* AddReportToPool */
#define GDHUB_ST2_OFF_ADDPOOL_P50_NS    640
#define GDHUB_ST2_OFF_ADDPOOL_P99_NS    644
#define GDHUB_ST2_OFF_ADDPOOL_MAX_NS    648
#define GDHUB_ST2_OFF_ADDPOOL_MEAN_NS   652
#define GDHUB_ST2_OFF_SUBMIT_COUNT      656    /* the submitInput round trip, as the tap sees it (translate done -> returned) */
#define GDHUB_ST2_OFF_SUBMIT_P50_NS     660
#define GDHUB_ST2_OFF_SUBMIT_P99_NS     664
#define GDHUB_ST2_OFF_SUBMIT_MAX_NS     668
#define GDHUB_ST2_OFF_SUBMIT_MEAN_NS    672
/* 676 = end. */
#define GDHUB_SELFTEST_NOT_RUN          0
#define GDHUB_SELFTEST_PASS             1
#define GDHUB_SELFTEST_FAIL             2
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
