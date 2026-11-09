import XCTest
@testable import GDHub

/// T7 rules in the dext's own source (no device needed): the order of the arbitration steps, who may write the pad, what is on the
/// tap's frame path, pinning and the orphan timer, and the length of the new log lines.
final class DextLiveSourceTests: XCTestCase {
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func text(_ rel: String) throws -> String { try String(contentsOf: repo.appendingPathComponent("Dext/GDHubVirtualHID/" + rel), encoding: .utf8) }
    private func body(_ src: String, from start: String, to end: String? = nil, max: Int = 12000) throws -> String {
        let s = try XCTUnwrap(src.range(of: start), start)
        let rest = src[s.lowerBound...]
        if let end, let e = rest.dropFirst(start.count).range(of: end) { return String(rest[..<e.lowerBound]) }
        return String(rest.prefix(max))
    }
    private func at(_ s: String, _ needle: String, after: String.Index? = nil) throws -> String.Index {
        try XCTUnwrap(s.range(of: needle, range: (after ?? s.startIndex)..<s.endIndex), needle).lowerBound
    }

    /// Rule B: the pad is the only arbiter. The source word and the hold are read on the pad's queue before handleReport.
    func testPadChecksSourceAndHoldBeforeHandleReport() throws {
        let pad = try text("GDHubVirtualPad.cpp")
        let f = try body(pad, from: "kern_return_t IMPL(GDHubVirtualPad, submitInput)", to: "kern_return_t IMPL(GDHubVirtualPad, postNeutralFrom)")
        let src = try at(f, "gdhr_pad_source(reg)"), hold = try at(f, "gdhr_hold(reg)"), handle = try at(f, "handleReport(")
        XCTAssertTrue(src < hold && hold < handle, "source, then hold, then handleReport")
        XCTAssertEqual(f.components(separatedBy: "handleReport(").count - 1, 1, "one writer into the HID stack per submit")
        XCTAssertTrue(f.contains("if (source != padSource)"))
        XCTAssertTrue(f.contains("source == GDHUB_PADSRC_TAP && gdhr_hold(reg)"), "the hold applies to the tap only")
        XCTAssertTrue(f.contains("GDHR_CTR_TAP_REJECTED") && f.contains("GDHR_CTR_UC_REJECTED"), "a refusal is counted per source")
        let n = try body(pad, from: "kern_return_t IMPL(GDHubVirtualPad, postNeutralFrom)", to: "// D5 stub")
        XCTAssertTrue(n.contains("if (source != padSource)"), "the switch neutral is checked against the source too")
        XCTAssertFalse(n.contains("gdhr_hold("), "a neutral is never held back")
        XCTAssertEqual(pad.components(separatedBy: "handleReport(").count - 1, 2, "submitInput and postNeutralFrom are the only callers")
    }

    func testSwitchToLiveOrderAndSwitchAwayOrder() throws {
        let uc = try text("GDHubVirtualHIDUserClient.cpp")
        let f = try body(uc, from: "static kern_return_t sSetForwarding", to: "static kern_return_t sSetMapping")
        let begin = try at(f, "gdhr_live_begin("), neutral = try at(f, "postNeutralFromRegistry(GDHUB_NEUTRAL_SWITCH, GDHUB_PADSRC_TAP)"),
            commit = try at(f, "gdhr_live_commit("), poke = try at(f, "GDHubPokeTap();", after: commit)
        XCTAssertTrue(begin < neutral && neutral < commit && commit < poke, "source TAP, neutral (TAP), desired LIVE + hold clear, poke")
        let leave = try at(f, "leaveLive(uc);"), set = try at(f, "gdhr_set_desired_if_owner(reg, self, state)")
        XCTAssertLessThan(leave, set, "away from LIVE: source UC and neutral BEFORE the new state is stored")
        XCTAssertFalse(f.contains("DispatchSync") || f.contains("IOSleep"), "nothing waits on the tap")
        let ll = try body(uc, from: "static bool leaveLive", to: "static void destroyPad")
        XCTAssertTrue(ll.contains("gdhr_leave_live(") && ll.contains("GDHUB_NEUTRAL_SWITCH"))
        XCTAssertTrue(f.contains("kIOReturnNotReady") && f.contains("kIOReturnBadArgument") && f.contains("kIOReturnNotPermitted"), "LIVE refusals are distinct")
    }

    func testEngineNeutralWhileTapDrivesStoresTheHoldFirst() throws {
        let uc = try text("GDHubVirtualHIDUserClient.cpp")
        let f = try body(uc, from: "static kern_return_t sPostNeutral", to: "// DEBUG-ONLY dev experiment")
        let hold = try at(f, "gdhr_set_hold(reg, 1)"), neutral = try at(f, "postNeutralToPad(uc, GDHUB_NEUTRAL_HOLD, GDHUB_PADSRC_TAP)")
        XCTAssertLessThan(hold, neutral)
        // D4: the ownership check comes before the hold is stored, a client that owns nothing never holds the tap back
        let owns = try at(f, "gdhr_owns_pad(reg")
        XCTAssertLessThan(owns, hold)
    }

    func testWatchdogDoesNotTouchATapDrivenPadAndStopPinsIt() throws {
        let uc = try text("GDHubVirtualHIDUserClient.cpp")
        let w = try body(uc, from: "void IMPL(GDHubVirtualHIDUserClient, WatchdogFired)")
        XCTAssertTrue(w.contains("gdhr_pad_source(GDHubReg()) != GDHUB_PADSRC_TAP"))
        let stop = try body(uc, from: "kern_return_t IMPL(GDHubVirtualHIDUserClient, Stop)", to: "kern_return_t GDHubVirtualHIDUserClient::ExternalMethod")
        let pinned = try at(stop, "gdhr_is_live(GDHubReg())"), destroy = try at(stop, "destroyPad(this)"), release = try at(stop, "GDHubReleaseOwner(this)")
        XCTAssertTrue(pinned < destroy && destroy < release)
        XCTAssertTrue(stop.contains("!pinnedLive"), "a LIVE pad is not destroyed with its owner")
        let reg = try text("GDHubRegistry.cpp")
        XCTAssertTrue(reg.contains("gdhr_release_owner_pin(") && reg.contains("GDHubOrphanArm("))
    }

    func testAdoptionComparesTheBytesBeforeTheRegistryAndBuildsBuffersFirst() throws {
        let uc = try text("GDHubVirtualHIDUserClient.cpp")
        let c = try body(uc, from: "static kern_return_t createCommon", to: "static kern_return_t sCreateDevice(")
        let cmp = try at(c, "memcmp("), build = try at(c, "buildInputBuffers(iv, spec)"), adopt = try at(c, "gdhr_pad_adopt(")
        XCTAssertTrue(cmp < build && build < adopt)
        XCTAssertTrue(c.contains("GDHubOrphanForceDestroy(") && c.contains("return kIOReturnBusy"), "a different spec removes the orphan and asks the caller to come back")
        XCTAssertTrue(uc.contains("/* 12 createDevice2 */"))
        let proto = try text("GDHubProtocol.h")
        XCTAssertTrue(proto.contains("#define GDHUB_SEL_COUNT                 13") && proto.contains("#define GDHUB_CAP_LIVE"))
        XCTAssertTrue(uc.contains("GDHUB_CAP_LIVE;"), "hello reports CAP_LIVE")
        XCTAssertTrue(uc.contains("GDHUB_TAP_DECLINE") )
    }

    func testOrphanTimerOrderOnTheRootsQueue() throws {
        let root = try text("GDHubVirtualHID.cpp")
        let o = try body(root, from: "static void orphanDestroy", to: "void GDHubOrphanForceDestroy")
        let neutral = try at(o, "postNeutralFrom(GDHUB_PADSRC_UC, 0, GDHUB_NEUTRAL_ORPHAN)"), poke = try at(o, "GDHubPokeTap()"), finish = try at(o, "gdhr_orphan_finish(")
        XCTAssertTrue(neutral < poke && poke < finish, "neutral, INERT poke, then the pad is removed")
        let f = try body(root, from: "void IMPL(GDHubVirtualHID, OrphanFired)")
        XCTAssertTrue(f.contains("gdhr_orphan_begin(reg, now)"))
        XCTAssertTrue(root.contains("GDH_SYNC(GDHR_RANK_ROOT, GDHR_RANK_PAD"))
        let stop = try body(root, from: "kern_return_t IMPL(GDHubVirtualHID, Stop)", to: "// Arms (or re-arms)")
        XCTAssertTrue(stop.contains("orphanTimer->Cancel("), "the timer is cancelled with the documented pattern")
    }

    /// Rule F and D: the tap's frame path holds a pad reference across frames and takes no registry lock; its allocations are in two
    /// places only, none of them per frame.
    func testTapFramePathAndAllocationSites() throws {
        let tap = try text("GDHubReceiverTap.cpp")
        let frame = try body(tap, from: "static void shadowFrame", to: "// The report path.")
        for banned in ["GDHubCopyPad", "GDHubCopyPadSpec", "IOLock", "Create(", "GDLog", "IONew", "->retain(", "OSData::"] {
            XCTAssertFalse(frame.contains(banned), "the frame path contains \(banned)")
        }
        XCTAssertTrue(frame.contains("gdh_live_submit_ok("))
        XCTAssertEqual(tap.components(separatedBy: "IOBufferMemoryDescriptor::Create(").count - 1, 2, "pool setup and LIVE setup: the only allocation sites")
        let setup = try body(tap, from: "static bool liveSetup", to: "// Posts the pad's neutral reports")
        XCTAssertTrue(setup.contains("IOBufferMemoryDescriptor::Create(") && setup.contains("GDHubCopyPad()"))
        XCTAssertFalse(frame.contains("liveSetup("), "never set up from the frame path")
        // a pad change (epoch) only stops submitting on the frame path
        XCTAssertTrue(frame.contains("iv->padEpoch != gdhr_pad_epoch(reg)"))
    }

    func testTapNeutralPathsAreGuardedByTheTokenAndStopComesFirst() throws {
        let tap = try text("GDHubReceiverTap.cpp")
        let n = try body(tap, from: "static void tapNeutral", to: "// Drops the whole pool")
        XCTAssertTrue(n.contains("iv->myToken != gdhr_tap_token(reg)") && n.contains("gdhr_pad_source(reg) != GDHUB_PADSRC_TAP"))
        XCTAssertTrue(n.contains("GDH_SYNC(GDHR_RANK_TAP, GDHR_RANK_PAD"))
        let stop = try body(tap, from: "kern_return_t IMPL(GDHubReceiverTap, Stop)", to: "kern_return_t IMPL(GDHubReceiverTap, SetPowerState)")
        let neutral = try at(stop, "tapNeutral("), close = try at(stop, "closeInterface(this"), unreg = try at(stop, "gdhr_unregister_tap(")
        XCTAssertTrue(neutral < close && close < unreg, "neutral while the registration is still current, then Close, then unregister")
        let power = try body(tap, from: "kern_return_t IMPL(GDHubReceiverTap, SetPowerState)", to: "// COUNT: pool, Open, Close")
        XCTAssertTrue(power.contains("GDHUB_NEUTRAL_POWER") && power.contains("gdhr_set_hold(reg, 0)"))
        let tick = try body(tap, from: "void IMPL(GDHubReceiverTap, TapTick)", to: "static void shadowFrame")
        XCTAssertTrue(tick.contains("gdh_silence_due(") && tick.contains("GDHUB_NEUTRAL_SILENCE"))
        let start = try body(tap, from: "kern_return_t IMPL(GDHubReceiverTap, Start)", to: "static void poolRelease")
        XCTAssertTrue(start.contains("gdhr_register_tap_ex(") && start.contains("gdhr_set_hold(reg, 0)"), "a new tap clears the hold")
    }

    func testPauseDrillLogsOncePerPauseAndLeavesFramesInUncounted() throws {
        let tap = try text("GDHubReceiverTap.cpp")
        let ra = try body(tap, from: "void IMPL(GDHubReceiverTap, ReportAvailable)")
        let pause = try at(ra, "bool paused"), framesIn = try at(ra, "GDHR_CTR_FRAMES_IN")
        XCTAssertLessThan(pause, framesIn, "a paused frame is not counted as framesIn (the engine's F1 watches it)")
        XCTAssertTrue(ra.contains(#"GDLog("tap pause start")"#) && ra.contains("!iv->pauseLogged"))
        XCTAssertTrue(ra.contains("if (paused) return;"), "the buffer still goes back to the pool before")
        let readd = try at(ra, "AddReportToPool"), ret = try at(ra, "if (paused) return;")
        XCTAssertLessThan(readd, ret)
    }

    /// Every new log line stays under 250 characters by the generic estimator (u32 = 10 digits, u64 = 20, %{public}s = 24).
    func testNewLogLinesAreShort() throws {
        var longest = 0
        for file in ["GDHubReceiverTap.cpp", "GDHubVirtualHID.cpp", "GDHubVirtualHIDUserClient.cpp", "GDHubVirtualPad.cpp", "GDHubRegistry.cpp", "GDHubXlateGlue.cpp"] {
            let src = try text(file)
            var i = src.startIndex
            while let r = src.range(of: "GDLog(\"", range: i..<src.endIndex) {
                let fmtStart = r.upperBound
                guard let end = src[fmtStart...].firstIndex(of: "\"") else { break }
                let fmt = String(src[fmtStart..<end])
                var n = "GDHub: ".count, k = fmt.startIndex
                while k < fmt.endIndex {
                    if fmt[k] == "%" {
                        var j = fmt.index(after: k); var longs = 0; var isString = false
                        while j < fmt.endIndex, !"udxsc".contains(fmt[j]) { if fmt[j] == "l" { longs += 1 }; if fmt[j] == "{" { isString = true }; j = fmt.index(after: j) }
                        if j < fmt.endIndex, fmt[j] == "s" { isString = true }
                        n += isString ? 24 : (longs >= 2 ? 20 : 10)
                        k = j < fmt.endIndex ? fmt.index(after: j) : j
                        if isString, let close = fmt[k...].firstIndex(of: "s"), fmt[k...].prefix(1) == "s" || false { _ = close }
                    } else { n += 1; k = fmt.index(after: k) }
                }
                longest = max(longest, n)
                XCTAssertLessThan(n, 250, "\(file): \(fmt.prefix(60))...")
                i = end
            }
        }
        XCTAssertGreaterThan(longest, 100)
    }

    func testRegistryCoreStaysFreeOfDriverKit() throws {
        let c = try text("Core/GDHubRegistryCore.c")
        for banned in ["DriverKit", "IOService", "OSObject", "os_log", "IOLock", "Terminate"] { XCTAssertFalse(c.contains(banned), banned) }
    }

    // MARK: Review items D4, D8, D9, D10, D11, D13 in the dext's source

    /// D8: the tap's token travels with every submit and the pad compares it on its own queue; the UC passes 0 and is never compared.
    func testTapTokenIsComparedOnThePadsQueue() throws {
        let iig = try text("GDHubVirtualPad.iig"), tap = try text("GDHubReceiverTap.cpp"), uc = try text("GDHubVirtualHIDUserClient.cpp")
        XCTAssertTrue(iig.contains("uint64_t token"), "submitInput carries the token")
        XCTAssertTrue(tap.contains("submitInput(GDHUB_PADSRC_TAP, iv->myToken"), "the tap passes its own token")
        XCTAssertTrue(uc.contains("submitInput(GDHUB_PADSRC_UC, 0,"), "a UC post carries no token")
        let pad = try text("GDHubVirtualPad.cpp")
        let f = try body(pad, from: "kern_return_t IMPL(GDHubVirtualPad, submitInput)", to: "kern_return_t IMPL(GDHubVirtualPad, postNeutralFrom)")
        XCTAssertLessThan(try at(f, "token != gdhr_tap_token(reg)"), try at(f, "gdhr_hold(reg)"), "a stale instance is refused before anything else is looked at")
    }

    /// D9: silence is measured from the last frame that was delivered (or found unchanged), set on the tap's own queue.
    func testSilenceClockIsLastDeliveryNotLastFrame() throws {
        let tap = try text("GDHubReceiverTap.cpp")
        XCTAssertFalse(tap.contains("lastLiveFrame"), "the arrival-based clock is gone")
        XCTAssertTrue(tap.contains("iv->lastDeliverTicks = t3s"), "set after a successful submit")
        XCTAssertTrue(tap.contains("iv->lastDeliverTicks = t2"), "an unchanged frame while the gate is open counts as delivered")
        XCTAssertTrue(tap.contains("gdh_silence_due("))
    }

    /// D10: a failed RegisterService cancels the orphan action (the action retains the root until cancelled).
    func testFailedRootStartCancelsTheOrphanAction() throws {
        let root = try text("GDHubVirtualHID.cpp")
        let f = try body(root, from: "kr = RegisterService();", to: "return kIOReturnSuccess;")
        XCTAssertTrue(f.contains("orphanAction->Cancel(") && f.contains("OSSafeReleaseNULL(ivars->orphanAction)") && f.contains("OSSafeReleaseNULL(ivars->orphanTimer)"))
    }

    /// D11: the pause is stored only after the state request has succeeded; and the whole selector-9 body for a client that does
    /// not own the pad can neither hold, pause nor map.
    func testPauseIsStoredAfterTheStateSucceeded() throws {
        let uc = try text("GDHubVirtualHIDUserClient.cpp")
        let f = try body(uc, from: "static kern_return_t sSetForwarding", to: "static kern_return_t sSetMapping")
        let compute = try at(f, "pauseUntil = mach_absolute_time()"), live = try at(f, "gdhr_live_commit("), store = try at(f, "gdhr_pause_set(reg, pauseUntil)")
        XCTAssertLessThan(live, store); XCTAssertLessThan(compute, store)
        XCTAssertEqual(f.components(separatedBy: "gdhr_pause_set(").count - 1, 1, "stored in one place only")
        XCTAssertTrue(f.contains("noEffect"), "INERT from a client that does not own the pad: success, no effect")
    }

    /// D4: the switch neutral comes from the registry's pad, so a caller without a pad of its own can still post it.
    func testSwitchNeutralIsPostedFromTheRegistryPad() throws {
        let uc = try text("GDHubVirtualHIDUserClient.cpp")
        let f = try body(uc, from: "static kern_return_t postNeutralFromRegistry", to: "static bool leaveLive")
        XCTAssertTrue(f.contains("GDHubCopyPad()"))
        XCTAssertFalse(f.contains("ivars->pad"), "not the caller's own pad reference")
        let ll = try body(uc, from: "static bool leaveLive", to: "static void destroyPad")
        XCTAssertTrue(ll.contains("postNeutralFromRegistry("))
    }

    /// D13: the design says the frame path takes the registry lock when the mapping changes.
    func testDesignSaysTheFramePathTakesTheRegistryLockOnAMapChange() throws {
        let doc = try String(contentsOf: repo.appendingPathComponent("docs/plans/driverkit-dext-design.md"), encoding: .utf8)
        XCTAssertFalse(doc.contains("The frame path never takes the registry lock and never allocates"), "the stale sentence is gone")
        XCTAssertTrue(doc.contains("takes the registry lock only once per mapping change"))
        // the code agrees: the only registry call on the tap's frame path is the publish on a swap
        let tap = try text("GDHubReceiverTap.cpp")
        XCTAssertTrue(tap.contains("gdhr_tap_publish_xlate("))
    }

    /// E1: the uninstall checks for the feature marker without running the app, limits the release to 8 s and prints the outcome.
    func testUninstallReleaseHasMarkerCheckAndHardTimeout() throws {
        let sh = try String(contentsOf: repo.appendingPathComponent("scripts/engine-agent.sh"), encoding: .utf8)
        let marker = ReleasePadTool.featureMarker
        XCTAssertTrue(sh.contains("grep -aq '\(marker)' \"$bin\""), "the app is only read, never executed, to find out whether it knows the flag")
        let u = try XCTUnwrap(sh.range(of: "  uninstall)")); let b = String(sh[u.lowerBound...].prefix(4000))
        let grep = try at(b, "grep -aq")
        XCTAssertLessThan(grep, try at(b, "--engine --engine-foreground --release-pad"))
        XCTAssertTrue(b.contains("sleep 8; kill -9 $rpid"), "hard 8 s limit")
        XCTAssertTrue(b.contains("release-pad: killed after 8 s") && b.contains("release-pad: the installed app is older"), "every outcome is printed")
        XCTAssertTrue(b.contains("exit $rc"), "the uninstall's own exit code is the bootout's")
    }

    /// D1: the three deliberate removals (selector 1 over an orphan, selector 12 with another spec, RELEASE_PAD) all go through the
    /// forced path, which does not look at the owner slot; only the timer uses the plain one.
    func testEveryDeliberateOrphanRemovalIsForcedAndOnlyTheTimerIsNot() throws {
        let uc = try text("GDHubVirtualHIDUserClient.cpp"), root = try text("GDHubVirtualHID.cpp")
        XCTAssertEqual(uc.components(separatedBy: "GDHubOrphanForceDestroy(").count - 1, 3)
        XCTAssertTrue(uc.contains("GDHubOrphanForceDestroy(\"the new owner's spec differs\")") && uc.contains("GDHubOrphanForceDestroy(\"an old app's createDevice\")") && uc.contains("GDHubOrphanForceDestroy(\"RELEASE_PAD\")"))
        XCTAssertFalse(uc.contains("gdhr_orphan_begin(") || uc.contains("gdhr_orphan_finish("), "the client side never uses the owner-gated removal")
        let f = try body(root, from: "void GDHubOrphanForceDestroy", to: "void IMPL(GDHubVirtualHID, OrphanFired)")
        XCTAssertTrue(f.contains("gdhr_orphan_force_begin("))
        let d = try body(root, from: "static void orphanDestroy", to: "void GDHubOrphanForceDestroy")
        XCTAssertTrue(d.contains("gdhr_orphan_force_finish(") && d.contains("gdhr_orphan_finish("), "forced and unforced finish chosen by the flag")
        // D2: the timer re-arms only through the pure arm-time decision, and the fired action arms with grace 0
        let arm = try body(root, from: "static void armOrphan", to: "static void orphanDestroy")
        XCTAssertTrue(arm.contains("gdh_orphan_arm_time("), "one place decides when the timer may be armed")
        XCTAssertTrue(root.contains("armOrphan(this, 0)"))
    }

    /// R3: with a client connected the timer re-arms 30 s on and the forced removal takes an orphan the client sat on past deadline + 30 s.
    func testTimerWithAConnectedOwnerRearmsAndEventuallyForcesTheRemoval() throws {
        let root = try text("GDHubVirtualHID.cpp")
        let f = try body(root, from: "void IMPL(GDHubVirtualHID, OrphanFired)")
        let plain = try at(f, "gdhr_orphan_begin(reg, now)"), over = try at(f, "gdh_orphan_owner_overstay("), force = try at(f, "GDHubOrphanForceDestroy("), rearm = try at(f, "armOrphan(this, 0)")
        XCTAssertTrue(plain < over && over < force && force < rearm)
        XCTAssertTrue(f.contains("GDH_ORPHAN_MS"), "the 30 s")
        let arm = try body(root, from: "static void armOrphan", to: "static void orphanDestroy")
        XCTAssertTrue(arm.contains("GDH_ORPHAN_MS"), "the owner grace is passed to the arm-time decision")
        XCTAssertEqual(root.components(separatedBy: "GDHubOrphanForceDestroy(").count - 1, 2, "declaration-free: the definition and the timer's call")
    }

    /// R4: an identical spec whose adoption fails is answered NotReady and removes nothing; only a different spec removes the orphan.
    func testAFailedAdoptionOfAnIdenticalSpecRemovesNothing() throws {
        let uc = try text("GDHubVirtualHIDUserClient.cpp")
        let c = try body(uc, from: "static kern_return_t createCommon", to: "static kern_return_t sCreateDevice(")
        let same = try at(c, "if (same) {"), notReady = try at(c, "return kIOReturnNotReady;", after: same), destroy = try at(c, "GDHubOrphanForceDestroy(\"the new owner's spec differs\")")
        XCTAssertLessThan(notReady, destroy, "the identical spec returns before the forced removal")
        let sameBody = String(c[same..<destroy])
        XCTAssertFalse(sameBody.contains("GDHubOrphanForceDestroy("))
    }

    /// R6: a neutral posted with source TAP carries a token and the pad compares it on its queue; the tap passes its own, the user
    /// client the current one, the root (source UC) none.
    func testTapSourceNeutralsAreTokenCheckedOnThePadsQueue() throws {
        let pad = try text("GDHubVirtualPad.cpp"), iig = try text("GDHubVirtualPad.iig"), tap = try text("GDHubReceiverTap.cpp"),
            uc = try text("GDHubVirtualHIDUserClient.cpp"), root = try text("GDHubVirtualHID.cpp")
        XCTAssertTrue(iig.contains("postNeutralFrom(uint32_t source, uint64_t token, uint32_t reason)"))
        let n = try body(pad, from: "kern_return_t IMPL(GDHubVirtualPad, postNeutralFrom)", to: "// D5 stub")
        let src = try at(n, "if (source != padSource)"), tok = try at(n, "source == GDHUB_PADSRC_TAP && token != gdhr_tap_token(reg)"), first = try at(n, "handleReport(")
        XCTAssertTrue(src < tok && tok < first, "source, token, then the posts")
        XCTAssertTrue(tap.contains("postNeutralFrom(GDHUB_PADSRC_TAP, iv->myToken, reason)"))
        XCTAssertEqual(uc.components(separatedBy: "postNeutralFrom(source, neutralToken(source), reason)").count - 1, 2, "both user-client sites")
        XCTAssertTrue(uc.contains("source == GDHUB_PADSRC_TAP ? gdhr_tap_token(GDHubReg()) : 0"))
        XCTAssertTrue(root.contains("postNeutralFrom(GDHUB_PADSRC_UC, 0, GDHUB_NEUTRAL_ORPHAN)"))
        XCTAssertFalse(n.contains("gdhr_hold("), "a neutral is still never held back")
    }
}
