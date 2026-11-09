import XCTest
@testable import GDHub

/// Keeps `Dext/GDHubVirtualHID/GDHubProtocol.h` and `DextProtocol.swift` in step (design §7.1).
final class DextProtocolTests: XCTestCase {
    private func headerDefines() throws -> [String: UInt64] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Dext/GDHubVirtualHID/GDHubProtocol.h")
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3, parts[0] == "#define", parts[1].hasPrefix("GDHUB_") else { continue }
            var tok = String(parts[2])
            // "(1u << 8)" style bit definitions
            if tok == "(1u", parts.count >= 5, parts[3] == "<<", let n = UInt64(parts[4].replacingOccurrences(of: ")", with: "")) {
                out[String(parts[1])] = 1 << n
                continue
            }
            if tok.hasSuffix("u") || tok.hasSuffix("U") { tok.removeLast() }
            let value: UInt64?
            if tok.hasPrefix("0x") || tok.hasPrefix("0X") { value = UInt64(tok.dropFirst(2), radix: 16) }
            else { value = UInt64(tok) }
            if let value { out[String(parts[1])] = value }
        }
        return out
    }

    /// Every numeric `#define` in the header and its Swift mirror.
    private var mirror: [String: UInt64] {
        typealias P = DextProtocol
        typealias S2 = DextStatus2.Offset
        return [
            "GDHUB_PROTOCOL_VERSION": UInt64(P.version),
            "GDHUB_SPEC_VERSION": UInt64(P.specVersion),
            "GDHUB_USERCLIENT_TYPE": UInt64(P.userClientType),
            "GDHUB_SEL_HELLO": UInt64(P.Selector.hello),
            "GDHUB_SEL_CREATE_DEVICE": UInt64(P.Selector.createDevice),
            "GDHUB_SEL_DESTROY_DEVICE": UInt64(P.Selector.destroyDevice),
            "GDHUB_SEL_POST_REPORT": UInt64(P.Selector.postReport),
            "GDHUB_SEL_POST_NEUTRAL": UInt64(P.Selector.postNeutral),
            "GDHUB_SEL_HEARTBEAT": UInt64(P.Selector.heartbeat),
            "GDHUB_SEL_REGISTER_OUTPUT": UInt64(P.Selector.registerOutput),
            "GDHUB_SEL_GET_STATUS": UInt64(P.Selector.getStatus),
            "GDHUB_SEL_DEV_TERMINATE": UInt64(P.Selector.devTerminate),
            "GDHUB_SEL_SET_FORWARDING": UInt64(P.Selector.setForwarding),
            "GDHUB_SEL_GET_STATUS2": UInt64(P.Selector.getStatus2),
            "GDHUB_SEL_COUNT": UInt64(P.Selector.count),
            "GDHUB_SLOT_PAD": UInt64(P.Slot.pad.rawValue),
            "GDHUB_SLOT_KEYBOARD": UInt64(P.Slot.keyboard.rawValue),
            "GDHUB_SLOT_POINTER": UInt64(P.Slot.pointer.rawValue),
            "GDHUB_SLOT_COUNT": UInt64(P.Slot.count),
            "GDHUB_CAP_PAD": P.Capability.pad,
            "GDHUB_CAP_KEYBOARD": P.Capability.keyboard,
            "GDHUB_CAP_POINTER": P.Capability.pointer,
            "GDHUB_CAP_ROOT_PAD": P.Capability.rootPad,
            "GDHUB_FWD_INERT": P.Forwarding.inert,
            "GDHUB_PADSRC_NONE": UInt64(P.PadSource.none.rawValue),
            "GDHUB_PADSRC_UC": UInt64(P.PadSource.userClient.rawValue),
            "GDHUB_PADSRC_TAP": UInt64(P.PadSource.tap.rawValue),
            "GDHUB_MAX_DESCRIPTOR": UInt64(P.Limit.maxDescriptor),
            "GDHUB_MAX_REPORT": UInt64(P.Limit.maxReport),
            "GDHUB_MAX_INPUT_REPORTS": UInt64(P.Limit.maxInputReports),
            "GDHUB_MAX_NEUTRAL": UInt64(P.Limit.maxNeutral),
            "GDHUB_SPEC_MAGIC": UInt64(P.Spec.magic),
            "GDHUB_SPEC_HEADER_SIZE": UInt64(P.Spec.headerSize),
            "GDHUB_SPEC_OFF_MAGIC": UInt64(P.Offset.magic),
            "GDHUB_SPEC_OFF_VERSION": UInt64(P.Offset.version),
            "GDHUB_SPEC_OFF_HEADER_SIZE": UInt64(P.Offset.headerSize),
            "GDHUB_SPEC_OFF_SLOT": UInt64(P.Offset.slot),
            "GDHUB_SPEC_OFF_FLAGS": UInt64(P.Offset.flags),
            "GDHUB_SPEC_OFF_INPUT_COUNT": UInt64(P.Offset.inputCount),
            "GDHUB_SPEC_OFF_VENDOR": UInt64(P.Offset.vendor),
            "GDHUB_SPEC_OFF_PRODUCT": UInt64(P.Offset.product),
            "GDHUB_SPEC_OFF_VERSION_NUMBER": UInt64(P.Offset.versionNumber),
            "GDHUB_SPEC_OFF_COUNTRY": UInt64(P.Offset.country),
            "GDHUB_SPEC_OFF_LOCATION": UInt64(P.Offset.location),
            "GDHUB_SPEC_OFF_INTERVAL_US": UInt64(P.Offset.intervalUs),
            "GDHUB_SPEC_OFF_USAGE_PAGE": UInt64(P.Offset.usagePage),
            "GDHUB_SPEC_OFF_USAGE": UInt64(P.Offset.usage),
            "GDHUB_SPEC_OFF_DESC_LEN": UInt64(P.Offset.descLen),
            "GDHUB_SPEC_OFF_NEUTRAL_LEN": UInt64(P.Offset.neutralLen),
            "GDHUB_SPEC_OFF_INPUT_TABLE": UInt64(P.Offset.inputTable),
            "GDHUB_SPEC_OFF_TRANSPORT": UInt64(P.Offset.transport),
            "GDHUB_SPEC_LEN_TRANSPORT": UInt64(P.Length.transport),
            "GDHUB_SPEC_OFF_MANUFACTURER": UInt64(P.Offset.manufacturer),
            "GDHUB_SPEC_LEN_MANUFACTURER": UInt64(P.Length.manufacturer),
            "GDHUB_SPEC_OFF_PRODUCT_NAME": UInt64(P.Offset.productName),
            "GDHUB_SPEC_LEN_PRODUCT_NAME": UInt64(P.Length.productName),
            "GDHUB_SPEC_OFF_SERIAL": UInt64(P.Offset.serial),
            "GDHUB_SPEC_LEN_SERIAL": UInt64(P.Length.serial),
            "GDHUB_SPEC_FLAG_HID_DEFAULT_BEHAVIOR": UInt64(P.Spec.flagHIDDefaultBehavior),
            "GDHUB_OUTPUT_ARG_COUNT": UInt64(P.outputArgCount),
            "GDHUB_ST2_VERSION": UInt64(DextStatus2.version),
            "GDHUB_ST2_MAX_SIZE": UInt64(DextStatus2.maxSize),
            "GDHUB_ST2_SIZE": UInt64(DextStatus2.size),
            "GDHUB_ST2_OFF_VERSION": UInt64(S2.version), "GDHUB_ST2_OFF_SIZE": UInt64(S2.size),
            "GDHUB_ST2_OFF_BUILD": UInt64(S2.build), "GDHUB_ST2_OFF_NONCE": UInt64(S2.nonce),
            "GDHUB_ST2_OFF_ROOT_PID": UInt64(S2.rootPid), "GDHUB_ST2_OFF_DESIRED_STATE": UInt64(S2.desiredState),
            "GDHUB_ST2_OFF_PAD_SOURCE": UInt64(S2.padSource), "GDHUB_ST2_OFF_PAD_LIVE": UInt64(S2.padLive),
            "GDHUB_ST2_OFF_OWNER_PRESENT": UInt64(S2.ownerPresent),
            "GDHUB_ST2_OFF_UC_POSTS": UInt64(S2.ucPosts), "GDHUB_ST2_OFF_UC_REJECTED": UInt64(S2.ucRejected),
            "GDHUB_ST2_OFF_NEUTRAL_POSTS": UInt64(S2.neutralPosts), "GDHUB_ST2_OFF_POST_ERRORS": UInt64(S2.postErrors),
            "GDHUB_ST2_OFF_SYNC_VIOLATIONS": UInt64(S2.syncViolations), "GDHUB_ST2_OFF_PAD_CREATES": UInt64(S2.padCreates),
            "GDHUB_ST2_OFF_PAD_DESTROYS": UInt64(S2.padDestroys), "GDHUB_ST2_OFF_CREATE_FAILS": UInt64(S2.createFails),
            "GDHUB_ST2_OFF_OUTPUTS_SEEN": UInt64(S2.outputsSeen), "GDHUB_ST2_OFF_OUTPUTS_NO_OWNER": UInt64(S2.outputsNoOwner), "GDHUB_ST2_OFF_CREATE_EARLY": UInt64(S2.createEarly),
            "GDHUB_ST2_OFF_PAD_SPEC_CRC": UInt64(S2.padSpecCRC), "GDHUB_ST2_OFF_METER_WINDOWS": UInt64(S2.meterWindows),
            "GDHUB_ST2_OFF_HOP_COUNT": UInt64(S2.hopCount), "GDHUB_ST2_OFF_HOP_P50_NS": UInt64(S2.hopP50),
            "GDHUB_ST2_OFF_HOP_P99_NS": UInt64(S2.hopP99), "GDHUB_ST2_OFF_HOP_MAX_NS": UInt64(S2.hopMax),
            "GDHUB_ST2_OFF_HOP_MEAN_NS": UInt64(S2.hopMean),
            "GDHUB_ST2_OFF_HR_COUNT": UInt64(S2.hrCount), "GDHUB_ST2_OFF_HR_P50_NS": UInt64(S2.hrP50),
            "GDHUB_ST2_OFF_HR_P99_NS": UInt64(S2.hrP99), "GDHUB_ST2_OFF_HR_MAX_NS": UInt64(S2.hrMax),
            "GDHUB_ST2_OFF_HR_MEAN_NS": UInt64(S2.hrMean),
            "GDHUB_ST2_OFF_SYNC_INLINE": UInt64(S2.syncInline), "GDHUB_ST2_OFF_TOPOLOGY": UInt64(S2.topology),
            "GDHUB_ST2_OFF_PROBE_EXT": UInt64(S2.probeExt),
            "GDHUB_CAP_TAP": P.Capability.tap, "GDHUB_FWD_COUNT": P.Forwarding.count,
            "GDHUB_CAP_XLATE": P.Capability.xlate, "GDHUB_FWD_SHADOW": P.Forwarding.shadow,
            "GDHUB_SEL_SET_MAPPING": UInt64(P.Selector.setMapping),
            "GDHUB_MAP_OK": UInt64(P.MapReason.ok), "GDHUB_MAP_NO_PAD": UInt64(P.MapReason.noPad),
            "GDHUB_MAP_TOO_BIG": UInt64(P.MapReason.tooBig), "GDHUB_MAP_NO_REGISTRY": UInt64(P.MapReason.noRegistry),
            "GDHUB_SELFTEST_NOT_RUN": UInt64(P.SelfTest.notRun), "GDHUB_SELFTEST_PASS": UInt64(P.SelfTest.pass),
            "GDHUB_SELFTEST_FAIL": UInt64(P.SelfTest.fail),
            "GDHUB_ST2_OFF_SELF_TEST": UInt64(S2.selfTest), "GDHUB_ST2_OFF_TRANSLATING": UInt64(S2.translating),
            "GDHUB_ST2_OFF_HAS_MAP": UInt64(S2.hasMap), "GDHUB_ST2_OFF_ACCEPTED_REVISION": UInt64(S2.acceptedRevision),
            "GDHUB_ST2_OFF_APPLIED_REVISION": UInt64(S2.appliedRevision), "GDHUB_ST2_OFF_ACCEPTED_SPEC_CRC": UInt64(S2.acceptedSpecCRC),
            "GDHUB_ST2_OFF_FRAMES_TRANSLATED": UInt64(S2.framesTranslated), "GDHUB_ST2_OFF_FRAMES_SKIPPED": UInt64(S2.framesSkipped),
            "GDHUB_ST2_OFF_FRAMES_NOMAP": UInt64(S2.framesNoMap), "GDHUB_ST2_OFF_FRAMES_UNMAPPED": UInt64(S2.framesUnmapped),
            "GDHUB_ST2_OFF_STATES_CHANGED": UInt64(S2.statesChanged), "GDHUB_ST2_OFF_REPORTS_WOULD_POST": UInt64(S2.reportsWouldPost),
            "GDHUB_ST2_OFF_MAP_ACCEPTED": UInt64(S2.mapAccepted), "GDHUB_ST2_OFF_MAP_REFUSED": UInt64(S2.mapRefused),
            "GDHUB_ST2_OFF_MAP_SWAPS": UInt64(S2.mapSwaps),
            "GDHUB_ST2_OFF_XLATE_COUNT": UInt64(S2.xlateCount), "GDHUB_ST2_OFF_XLATE_P50_NS": UInt64(S2.xlateP50),
            "GDHUB_ST2_OFF_XLATE_P99_NS": UInt64(S2.xlateP99), "GDHUB_ST2_OFF_XLATE_MAX_NS": UInt64(S2.xlateMax),
            "GDHUB_ST2_OFF_XLATE_MEAN_NS": UInt64(S2.xlateMean),
            "GDHUB_ST2_OFF_PARITY_COUNT": UInt64(S2.parityCount), "GDHUB_ST2_OFF_PARITY_REVISION": UInt64(S2.parityRevision),
            "GDHUB_ST2_OFF_PARITY_TIMESTAMP": UInt64(S2.parityTimestamp), "GDHUB_ST2_OFF_PARITY_FRAME": UInt64(S2.parityFrame),
            "GDHUB_ST2_OFF_PARITY_OUT01": UInt64(S2.parityOut01), "GDHUB_ST2_OFF_PARITY_OUT02": UInt64(S2.parityOut02),
            "GDHUB_ST2_OFF_TAP_PRESENT": UInt64(S2.tapPresent), "GDHUB_ST2_OFF_TAP_OPENED": UInt64(S2.tapOpened),
            "GDHUB_ST2_OFF_APPLIED_STATE": UInt64(S2.appliedState), "GDHUB_ST2_OFF_POWERED": UInt64(S2.powered),
            "GDHUB_ST2_OFF_TAP_PID": UInt64(S2.tapPid), "GDHUB_ST2_OFF_TAP_STARTS": UInt64(S2.tapStarts),
            "GDHUB_ST2_OFF_LAST_POWER_FLAGS": UInt64(S2.lastPowerFlags), "GDHUB_ST2_OFF_LAST_ERROR": UInt64(S2.lastError),
            "GDHUB_ST2_OFF_FRAMES_IN": UInt64(S2.framesIn), "GDHUB_ST2_OFF_FRAMES_R06": UInt64(S2.framesR06),
            "GDHUB_ST2_OFF_FRAMES_OTHER": UInt64(S2.framesOther), "GDHUB_ST2_OFF_FRAMES_IGNORED": UInt64(S2.framesIgnored),
            "GDHUB_ST2_OFF_FRAMES_BAD": UInt64(S2.framesBad), "GDHUB_ST2_OFF_POOL_MISS": UInt64(S2.poolMiss),
            "GDHUB_ST2_OFF_READD_FAIL": UInt64(S2.readdFail), "GDHUB_ST2_OFF_OPEN_FAILURES": UInt64(S2.openFailures),
            "GDHUB_ST2_OFF_K2D_COUNT": UInt64(S2.k2dCount), "GDHUB_ST2_OFF_K2D_P50_NS": UInt64(S2.k2dP50),
            "GDHUB_ST2_OFF_K2D_P99_NS": UInt64(S2.k2dP99), "GDHUB_ST2_OFF_K2D_MAX_NS": UInt64(S2.k2dMax),
            "GDHUB_ST2_OFF_K2D_MEAN_NS": UInt64(S2.k2dMean),
            "GDHUB_ST2_OFF_POKES_RUN": UInt64(S2.pokesRun), "GDHUB_ST2_OFF_TICK_APPLIES": UInt64(S2.tickApplies),
            "GDHUB_ST2_OFF_CLOSE_FAILURES": UInt64(S2.closeFailures), "GDHUB_ST2_OFF_REOPENS": UInt64(S2.reopens),
            "GDHUB_ST2_OFF_TAP_FREES": UInt64(S2.tapFrees), "GDHUB_ST2_OFF_PROBE_SUBMIT": UInt64(S2.probeSubmit),
            "GDHUB_ST2_OFF_HOLD_NEUTRAL": UInt64(S2.holdNeutral),
            "GDHUB_ST2_OFF_PAD_ORPHANED": UInt64(S2.padOrphaned),
            "GDHUB_ST2_OFF_PAUSED": UInt64(S2.paused),
            "GDHUB_ST2_OFF_TAP_POSTS": UInt64(S2.tapPosts),
            "GDHUB_ST2_OFF_TAP_REJECTED": UInt64(S2.tapRejected),
            "GDHUB_ST2_OFF_TAP_SUBMIT_ERRORS": UInt64(S2.tapSubmitErrors),
            "GDHUB_ST2_OFF_FRAMES_UNCHANGED": UInt64(S2.framesUnchanged),
            "GDHUB_ST2_OFF_SWITCH_NEUTRALS": UInt64(S2.switchNeutrals),
            "GDHUB_ST2_OFF_STOP_NEUTRALS": UInt64(S2.stopNeutrals),
            "GDHUB_ST2_OFF_SILENCE_NEUTRALS": UInt64(S2.silenceNeutrals),
            "GDHUB_ST2_OFF_POWER_NEUTRALS": UInt64(S2.powerNeutrals),
            "GDHUB_ST2_OFF_HOLD_NEUTRALS": UInt64(S2.holdNeutrals),
            "GDHUB_ST2_OFF_ADOPTS": UInt64(S2.adopts),
            "GDHUB_ST2_OFF_ORPHAN_DESTROYS": UInt64(S2.orphanDestroys),
            "GDHUB_ST2_OFF_PAUSE_DROPS": UInt64(S2.pauseDrops),
            "GDHUB_ST2_OFF_SOURCE_SWITCHES": UInt64(S2.sourceSwitches),
            "GDHUB_ST2_OFF_LIVE_NO_PAD": UInt64(S2.liveNoPad),
            "GDHUB_ST2_OFF_TOTAL_COUNT": UInt64(S2.totalCount),
            "GDHUB_ST2_OFF_TOTAL_P50_NS": UInt64(S2.totalP50),
            "GDHUB_ST2_OFF_TOTAL_P99_NS": UInt64(S2.totalP99),
            "GDHUB_ST2_OFF_TOTAL_MAX_NS": UInt64(S2.totalMax),
            "GDHUB_ST2_OFF_TOTAL_MEAN_NS": UInt64(S2.totalMean),
            "GDHUB_ST2_OFF_OCC_COUNT": UInt64(S2.occCount),
            "GDHUB_ST2_OFF_OCC_P50_NS": UInt64(S2.occP50),
            "GDHUB_ST2_OFF_OCC_P99_NS": UInt64(S2.occP99),
            "GDHUB_ST2_OFF_OCC_MAX_NS": UInt64(S2.occMax),
            "GDHUB_ST2_OFF_OCC_MEAN_NS": UInt64(S2.occMean),
            "GDHUB_ST2_OFF_ADDPOOL_COUNT": UInt64(S2.addPoolCount),
            "GDHUB_ST2_OFF_ADDPOOL_P50_NS": UInt64(S2.addPoolP50),
            "GDHUB_ST2_OFF_ADDPOOL_P99_NS": UInt64(S2.addPoolP99),
            "GDHUB_ST2_OFF_ADDPOOL_MAX_NS": UInt64(S2.addPoolMax),
            "GDHUB_ST2_OFF_ADDPOOL_MEAN_NS": UInt64(S2.addPoolMean),
            "GDHUB_ST2_OFF_SUBMIT_COUNT": UInt64(S2.submitCount),
            "GDHUB_ST2_OFF_SUBMIT_P50_NS": UInt64(S2.submitP50),
            "GDHUB_ST2_OFF_SUBMIT_P99_NS": UInt64(S2.submitP99),
            "GDHUB_ST2_OFF_SUBMIT_MAX_NS": UInt64(S2.submitMax),
            "GDHUB_ST2_OFF_SUBMIT_MEAN_NS": UInt64(S2.submitMean),
            "GDHUB_SEL_CREATE_DEVICE2": UInt64(P.Selector.createDevice2), "GDHUB_CAP_LIVE": P.Capability.live,
            "GDHUB_FWD_LIVE": P.Forwarding.live, "GDHUB_FWD_FLAG_DEV_PAUSE_TAP": P.Forwarding.flagDevPauseTap,
            "GDHUB_FWD_FLAG_RELEASE_PAD": P.Forwarding.flagReleasePad,
            "GDHUB_TOPO_UC_EQ_ROOT": UInt64(DextStatus2.Topology.ucEqRoot), "GDHUB_TOPO_PAD_EQ_ROOT": UInt64(DextStatus2.Topology.padEqRoot),
            "GDHUB_TOPO_PAD_EQ_UC": UInt64(DextStatus2.Topology.padEqUC), "GDHUB_TOPO_KNOWN_SHIFT": UInt64(DextStatus2.Topology.knownShift),
            "GDHUB_PROBE_ROOT": UInt64(DextStatus2.Probe.root), "GDHUB_PROBE_UC": UInt64(DextStatus2.Probe.uc),
            "GDHUB_PROBE_PAD": UInt64(DextStatus2.Probe.pad), "GDHUB_PROBE_VALID": UInt64(DextStatus2.Probe.valid),
        ]
    }

    func testEveryHeaderDefineMatchesSwift() throws {
        let header = try headerDefines()
        XCTAssertGreaterThan(header.count, 40, "header parsed")
        for (name, value) in header.sorted(by: { $0.key < $1.key }) {
            guard let swift = mirror[name] else { XCTFail("\(name) has no Swift mirror"); continue }
            XCTAssertEqual(swift, value, name)
        }
        for name in mirror.keys where header[name] == nil { XCTFail("\(name) is mirrored but not in the header") }
    }

    func testSpecHeaderLayoutIsContiguous() {
        typealias O = DextProtocol.Offset
        typealias L = DextProtocol.Length
        XCTAssertEqual(O.inputTable + DextProtocol.Limit.maxInputReports * L.inputTableEntry, O.transport)
        XCTAssertEqual(O.transport + L.transport, O.manufacturer)
        XCTAssertEqual(O.manufacturer + L.manufacturer, O.productName)
        XCTAssertEqual(O.productName + L.productName, O.serial)
        XCTAssertLessThanOrEqual(O.serial + L.serial, DextProtocol.Spec.headerSize, "224..255 are reserved")
        XCTAssertEqual(O.neutralLen + 2, O.inputTable)
        let magic = DextProtocol.Spec.magic
        XCTAssertEqual((0..<4).map { UInt8((magic >> UInt32(8 * $0)) & 0xFF) }, [0x47, 0x44, 0x48, 0x53],
                       "'G' 'D' 'H' 'S' on the wire")
    }

    func testOutputReportDecodesPackedWords() throws {
        var w = [UInt64](repeating: 0, count: DextProtocol.outputArgCount)
        // slot 0, type 2 (output), report ID 3, length 9, not truncated; payload 03 0F 10 20 30 40 FF 00 EB
        w[0] = 0 | (2 << 8) | (3 << 16) | (9 << 24)
        w[1] = 0x00FF_4030_2010_0F03
        w[2] = 0xEB
        w[9] = 41
        let r = try XCTUnwrap(OutputReport(words: w))
        XCTAssertEqual(r.slot, 0); XCTAssertEqual(r.type, 2); XCTAssertEqual(r.reportID, 3)
        XCTAssertEqual(r.bytes, [0x03, 0x0F, 0x10, 0x20, 0x30, 0x40, 0xFF, 0x00, 0xEB])
        XCTAssertFalse(r.truncated)
        XCTAssertEqual(r.sequence, 41)
        XCTAssertNil(OutputReport(words: [0, 1, 2]), "too few words")
    }

    func testErrorCodesRoundTrip() {
        XCTAssertEqual(DextProtocol.krNotPermitted, kern_return_t(bitPattern: 0xE00002E2))
        XCTAssertEqual(DextError(DextProtocol.krExclusiveAccess), .exclusiveAccess)
        XCTAssertEqual(DextError(DextProtocol.krNotPermitted).code, DextProtocol.krNotPermitted)
        XCTAssertEqual(DextError(5), .other(5))
        XCTAssertEqual(DextStatus(words: [3, 100, 2, 7, 1]).watchdogFires, 2)
    }

    // MARK: DeviceSpec encoding (design §7.1)

    private func bt16Spec(_ identity: PadIdentity) throws -> [UInt8] { try identity.spec().encoded() }

    /// The selector numbers are a wire contract; none may ever move (build 17 and every later dext share them).
    func testSelectorNumbersNeverMove() {
        typealias S = DextProtocol.Selector
        XCTAssertEqual([S.hello, S.createDevice, S.destroyDevice, S.postReport, S.postNeutral, S.heartbeat, S.registerOutput,
                        S.getStatus, S.devTerminate], Array(0...8), "the original nine, exactly as build 17 numbers them")
        XCTAssertEqual(S.setForwarding, 9)
        XCTAssertEqual(S.setMapping, 10, "T5: the mapping blob")
        XCTAssertEqual(S.getStatus2, 11)
        XCTAssertEqual(S.createDevice2, 12, "T7"); XCTAssertEqual(S.count, S.createDevice2 + 1)
        XCTAssertEqual(DextProtocol.version, 1, "the protocol version stays 1: hello is an exact match")
        XCTAssertEqual(DextProtocol.specVersion, 1)
    }

    func testCapabilityBitsAreAdditive() {
        typealias C = DextProtocol.Capability
        XCTAssertEqual(C.pad | C.keyboard | C.pointer, 7, "bits 0-2 stay the slot bits")
        XCTAssertEqual(C.rootPad, 0x100)
        XCTAssertEqual(C.rootPad & (C.pad | C.keyboard | C.pointer), 0)
        // build 17 answered hello with capabilities == 1; that must not read as root-pad capable
        XCTAssertFalse(DextHello(protocolVersion: 1, dextBuild: 17, capabilities: C.pad).hasRootPad)
        XCTAssertTrue(DextHello(protocolVersion: 1, dextBuild: 18, capabilities: C.pad | C.rootPad).hasRootPad)
    }

    /// The root is found by class AND server name. The tap that joins in T4 shares the server name; without the class it
    /// would be matched as the root and hello would go to the wrong service.
    func testMatchingDictionaryNamesTheRootClass() throws {
        let props = DextClient.matchingProperties
        XCTAssertEqual(props["IOUserServerName"], "com.interlinked.gdhub.VirtualHID")
        XCTAssertEqual(props["IOUserClass"], "GDHubVirtualHID")
        XCTAssertEqual(props.count, 2)
        let dict = DextClient.matching() as NSDictionary
        let match = try XCTUnwrap(dict[kIOPropertyMatchKey] as? [String: String])
        XCTAssertEqual(match, props)
        // and the class is the one the dext's personality declares
        let yml = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("IOUserClass: \(DextProtocol.rootUserClass)\n"), "project.yml root personality")
    }

    /// T3 moves GDHubPadProperties from the user client's dictionary to the root personality.
    func testPadPropertiesSitAtRootLevelInTheProjectFile() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let yml = try String(contentsOf: url.appendingPathComponent("project.yml"), encoding: .utf8)
        let lines = yml.components(separatedBy: "\n")
        let pad = try XCTUnwrap(lines.firstIndex { $0.contains("GDHubPadProperties:") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") })
        let userClient = try XCTUnwrap(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "UserClientProperties:" })
        func indent(_ l: String) -> Int { l.prefix { $0 == " " }.count }
        XCTAssertEqual(indent(lines[pad]), indent(lines[userClient]), "same level as UserClientProperties, not inside it")
        let plist = try String(contentsOf: url.appendingPathComponent("Dext/GDHubVirtualHID/Info.plist"), encoding: .utf8)
        XCTAssertTrue(plist.contains("GDHubPadProperties"))
    }

    func testForwardingResultDecodesAndPadsShortOutputs() {
        let r = DextForwardingResult(words: [0, 0, 1, 0])
        XCTAssertEqual(r.padSource, 1); XCTAssertEqual(r.appliedState, DextProtocol.Forwarding.inert)
        XCTAssertEqual(DextForwardingResult(words: [0]).lastError, 0, "a shorter reply reads as zeros")
    }

    func testBT16SpecEncoding() throws {
        typealias O = DextProtocol.Offset
        let b = try bt16Spec(.xboxBT16)
        XCTAssertEqual(b.count, 256 + 285 + 18)
        XCTAssertEqual(Array(b[0..<4]), [0x47, 0x44, 0x48, 0x53])
        XCTAssertEqual(Array(b[O.version..<O.version + 2]), [1, 0])
        XCTAssertEqual(Array(b[O.headerSize..<O.headerSize + 2]), [0x00, 0x01])
        XCTAssertEqual(b[O.slot], 0); XCTAssertEqual(b[O.flags], 0); XCTAssertEqual(b[O.inputCount], 2)
        XCTAssertEqual(Array(b[O.vendor..<O.vendor + 4]), [0x5E, 0x04, 0x00, 0x00])
        XCTAssertEqual(Array(b[O.product..<O.product + 4]), [0x13, 0x0B, 0x00, 0x00])
        XCTAssertEqual(Array(b[O.versionNumber..<O.versionNumber + 4]), [0x13, 0x05, 0x00, 0x00])
        XCTAssertEqual(Array(b[O.location..<O.location + 4]), [0x01, 0x48, 0x44, 0x47])
        XCTAssertEqual(Array(b[O.intervalUs..<O.intervalUs + 4]), [0xE8, 0x03, 0x00, 0x00])      // 1000 µs (fix #6)
        XCTAssertEqual(Array(b[O.usagePage..<O.usagePage + 4]), [1, 0, 0, 0])
        XCTAssertEqual(Array(b[O.usage..<O.usage + 4]), [5, 0, 0, 0])
        XCTAssertEqual(Array(b[O.descLen..<O.descLen + 2]), [0x1D, 0x01])      // 285
        XCTAssertEqual(Array(b[O.neutralLen..<O.neutralLen + 2]), [18, 0])
        XCTAssertEqual(Array(b[O.inputTable..<O.inputTable + 8]), [0x01, 0x00, 0x10, 0x00, 0x02, 0x00, 0x02, 0x00])
        XCTAssertEqual(Array(b[O.transport..<O.transport + 21]), Array("Bluetooth Low Energy".utf8) + [0])
        XCTAssertEqual(Array(b[O.manufacturer..<O.manufacturer + 10]), Array("Microsoft".utf8) + [0])
        XCTAssertEqual(Array(b[O.productName..<O.productName + 25]), Array("Xbox Wireless Controller".utf8) + [0])
        XCTAssertEqual(Array(b[O.serial..<O.serial + 8]), Array("GDHub-1".utf8) + [0])
        XCTAssertEqual(Array(b[224..<256]), [UInt8](repeating: 0, count: 32), "reserved bytes are zero")
        XCTAssertEqual(Array(b[256..<256 + 285]), PadDescriptors.xboxBT16)
        XCTAssertEqual(Array(b[(256 + 285)...]), [UInt8](hex: "01 00 80 00 80 00 80 00 80 00 00 00 00 00 00 00 02 00"))
    }

    func test02E0SpecDiffersOnlyInProductID() throws {
        typealias O = DextProtocol.Offset
        let a = try bt16Spec(.xboxBT16_02E0), b = try bt16Spec(.xboxBT16)
        XCTAssertEqual(Array(a[O.product..<O.product + 4]), [0xE0, 0x02, 0x00, 0x00])
        var patched = b
        for i in 0..<4 { patched[O.product + i] = a[O.product + i] }
        XCTAssertEqual(a, patched)
    }

    func testSendLengthSpec() throws {
        // A 17-byte report 0x01 sent as 25 bytes (xbox-pr208 shape), built from a hand-made descriptor.
        let desc = [UInt8](hex: "05 01 09 05 A1 01 85 01 75 08 95 10 81 02 85 20 95 18 81 02 C0")
        func spec(send: Int, neutral0: Int? = nil) -> DeviceSpec {
            DeviceSpec(slot: .pad, vendorID: 1, productID: 2, versionNumber: 3, transport: "Virtual", manufacturer: "m",
                       product: "p", serialNumber: "s", descriptor: desc, sendLengths: [0x01: send],
                       neutralReports: [[0x01] + [UInt8](repeating: 0, count: (neutral0 ?? send) - 1),
                                        [0x20] + [UInt8](repeating: 0, count: 24)])
        }
        let b = try spec(send: 25).encoded()
        XCTAssertEqual(Array(b[DextProtocol.Offset.inputTable..<DextProtocol.Offset.inputTable + 8]),
                       [0x01, 0x19, 0x11, 0x00, 0x20, 0x00, 0x19, 0x00])
        XCTAssertEqual(Array(b[DextProtocol.Offset.transport..<DextProtocol.Offset.transport + 8]),
                       [0x56, 0x69, 0x72, 0x74, 0x75, 0x61, 0x6C, 0x00])
        XCTAssertEqual(b.count, 256 + desc.count + 50)
        XCTAssertThrowsError(try spec(send: 16).encoded(), "below the declared length")
        XCTAssertThrowsError(try spec(send: 26).encoded(), "above the largest input report")
        XCTAssertThrowsError(try spec(send: 25, neutral0: 24).encoded(), "neutral length is not its send length")
    }

    func testSpecValidationRules() throws {
        var s = try PadIdentity.xboxBT16.spec()
        s.product = String(repeating: "x", count: 64)
        XCTAssertThrowsError(try s.encoded(), "overlong product string")
        s.product = String(repeating: "x", count: 63)
        XCTAssertNoThrow(try s.encoded())
        s = try PadIdentity.xboxBT16.spec(); s.transport = ""
        XCTAssertThrowsError(try s.encoded(), "empty transport")
        s = try PadIdentity.xboxBT16.spec(); s.neutralReports[0][0] = 0x09
        XCTAssertThrowsError(try s.encoded(), "neutral must start with its report ID")
        s = try PadIdentity.xboxBT16.spec(); s.neutralReports.removeLast()
        XCTAssertThrowsError(try s.encoded(), "one neutral report per input")
        s = try PadIdentity.xboxBT16.spec(); s.sendLengths = [0x07: 16]
        XCTAssertThrowsError(try s.encoded(), "send length for a non-input report")
        s = try PadIdentity.xboxBT16.spec(); s.descriptor = []
        XCTAssertThrowsError(try s.encoded())
    }
}
