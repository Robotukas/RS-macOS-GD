import XCTest
@testable import GDHub

/// T4 guards that need no device: the personalities and entitlement as generated into the dext's plists, the build checks in
/// build-xcode.sh, and rules of the tap's source (plan 3.2, 3.5, 3.6, 4.2, 6.5).
final class DextTapSourceTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func text(_ rel: String) throws -> String { try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8) }
    private func plist(_ rel: String) throws -> [String: Any] {
        let d = try Data(contentsOf: repo.appendingPathComponent(rel))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any])
    }
    private func personality(_ name: String) throws -> [String: Any] {
        let p = try plist("Dext/GDHubVirtualHID/Info.plist")
        return try XCTUnwrap((p["IOKitPersonalities"] as? [String: Any])?[name] as? [String: Any], name)
    }

    func testTapPersonalityMatchesInterface3Only() throws {
        let t = try personality("GDHubReceiverTap")
        XCTAssertEqual(t["IOProviderClass"] as? String, "IOHIDInterface")
        XCTAssertEqual(t["IOClass"] as? String, "IOUserService")
        XCTAssertEqual(t["IOUserClass"] as? String, "GDHubReceiverTap")
        XCTAssertEqual(t["IOUserServerName"] as? String, "$(PRODUCT_BUNDLE_IDENTIFIER)", "expanded by the build to the root's server name")
        // every match key is an INTEGER with the measured value, never a string
        for (k, v) in [("VendorID", 6940), ("ProductID", 14856), ("PrimaryUsagePage", 65368), ("PrimaryUsage", 1), ("IOProbeScore", 1000)] {
            let n = try XCTUnwrap(t[k] as? NSNumber, "\\(k) must be a number")
            XCTAssertFalse(t[k] is String, k)
            XCTAssertEqual(n.intValue, v, k)
            XCTAssertFalse(CFGetTypeID(n) == CFBooleanGetTypeID(), "\\(k) is not a boolean")
        }
        XCTAssertEqual(t["ProductID"] as? Int, 0x3A08, "3A08 only: the idle receiver 3A09 and the wired products never match")
        XCTAssertEqual(t["VendorID"] as? Int, 0x1B1C)
        XCTAssertNil(t["IOMatchCategory"], "the tap competes in the default category")
        XCTAssertNil(t["Transport"], "no extra key that could miss the match")
        XCTAssertEqual(t["IOUserServerOneProcess"] as? Bool, true)
    }

    func testRootPersonalityStaysAndJoinsTheSameProcess() throws {
        let r = try personality("GDHubVirtualHID")
        XCTAssertEqual(r["IOUserServerOneProcess"] as? Bool, true)
        XCTAssertEqual(r["IOProviderClass"] as? String, "IOUserResources")
        XCTAssertEqual(r["IOUserClass"] as? String, "GDHubVirtualHID")
        XCTAssertEqual(r["IOMatchCategory"] as? String, "$(PRODUCT_BUNDLE_IDENTIFIER)", "unchanged own category on IOUserResources")
        XCTAssertNotNil(r["GDHubPadProperties"], "T3: the pad properties stay at root level")
        let t = try personality("GDHubReceiverTap")
        XCTAssertEqual(r["IOUserServerName"] as? String, t["IOUserServerName"] as? String, "OneProcess needs the same server name")
        let all = try XCTUnwrap(try plist("Dext/GDHubVirtualHID/Info.plist")["IOKitPersonalities"] as? [String: Any])
        XCTAssertEqual(Set(all.keys), ["GDHubVirtualHID", "GDHubReceiverTap"], "exactly these two; no probe personality")
    }

    func testEntitlementsCarryTransportHID() throws {
        let e = try plist("Dext/GDHubVirtualHID/GDHubVirtualHID.entitlements")
        for k in ["com.apple.developer.driverkit", "com.apple.developer.driverkit.family.hid.device",
                  "com.apple.developer.driverkit.allow-any-userclient-access", "com.apple.developer.driverkit.transport.hid"] {
            XCTAssertEqual(e[k] as? Bool, true, k)
        }
        XCTAssertNil(e["com.apple.developer.driverkit.transport.usb"], "transport.usb is not needed")
        XCTAssertNil(e["com.apple.developer.hid.virtual.device"], "never in a dext (design 3.3)")
        XCTAssertTrue(try text("project.yml").contains("com.apple.developer.driverkit.transport.hid: true"))
    }

    func testBuildScriptAssertsThePersonalityRules() throws {
        let sh = try text("scripts/build-xcode.sh")
        XCTAssertTrue(sh.contains("com.apple.developer.driverkit.transport.hid"), "need(): signature AND profile")
        for k in ["VendorID", "ProductID", "PrimaryUsagePage", "PrimaryUsage", "IOProbeScore"] { XCTAssertTrue(sh.contains(k), k) }
        XCTAssertTrue(sh.contains("<integer>"))
        XCTAssertTrue(sh.contains("IOUserServerOneProcess"))
        XCTAssertTrue(sh.contains("GDHubVirtualHID GDHubReceiverTap"), "both personalities")
        XCTAssertTrue(sh.contains("IOMatchCategory Transport"), "the tap has neither key")
        XCTAssertTrue(sh.contains("IOHIDInterface"))
        // the checks sit before the early exit of --no-install, so the allowed compile check runs them
        let checks = try XCTUnwrap(sh.range(of: "Receiver tap personality checks"))
        let exit = try XCTUnwrap(sh.range(of: "[[ ${1:-} == --no-install ]] && exit 0"))
        XCTAssertLessThan(checks.lowerBound, exit.lowerBound)
    }

    func testDeclineLeverIsABuildDefineDefaultingToZero() throws {
        XCTAssertTrue(try text("project.yml").contains("GDHUB_TAP_DECLINE=0"))
        let h = try text("Dext/GDHubVirtualHID/GDHubInternal.h")
        XCTAssertTrue(h.contains("#ifndef GDHUB_TAP_DECLINE"))
        XCTAssertTrue(h.contains("#define GDHUB_TAP_DECLINE           0"))
        let tap = try text("Dext/GDHubVirtualHID/GDHubReceiverTap.cpp")
        XCTAssertTrue(tap.contains("#if GDHUB_TAP_DECLINE"))
        let uc = try text("Dext/GDHubVirtualHID/GDHubVirtualHIDUserClient.cpp")
        XCTAssertTrue(uc.contains("#if GDHUB_TAP_DECLINE"), "a decline build reports no CAP_TAP and refuses COUNT")
    }

    // MARK: the tap's source

    private func tapSource() throws -> String {
        let t = try text("Dext/GDHubVirtualHID/GDHubReceiverTap.cpp")
        return t.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
    }

    /// Rule A: Open is called from exactly one place, and only after gdh_tap_decide said so.
    func testOpenIsCalledFromOneGuardedPlace() throws {
        let code = try tapSource()
        XCTAssertEqual(code.components(separatedBy: "->Open(").count - 1, 1)
        let decide = try XCTUnwrap(code.range(of: "gdh_tap_decide("))
        let open = try XCTUnwrap(code.range(of: "->Open("))
        XCTAssertLessThan(decide.lowerBound, open.lowerBound)
        XCTAssertTrue(code.contains("act == GDH_TAP_OPEN"))
        let start = try XCTUnwrap(code.range(of: "IMPL(GDHubReceiverTap, Start)")), stop = try XCTUnwrap(code.range(of: "IMPL(GDHubReceiverTap, Stop)"))
        XCTAssertFalse(code[start.lowerBound..<stop.lowerBound].contains("->Open("), "Start never opens the interface")
        XCTAssertFalse(code[start.lowerBound..<stop.lowerBound].contains("GDH_FWD_COUNT"), "and does not arm anything")
    }

    /// The tap takes no pointer to the root, the owner or the pad and makes no synchronous call to any GDHub object.
    func testTapCallsNoGDHubObject() throws {
        let code = try tapSource()
        for banned in ["GDHubVirtualHID", "GDHubVirtualPad", "GDHubCopyRoot", "GDHubCopyOwner", "GDHubCopyPad", "->CreatePad(", "->DestroyPad(",
                       "->submitInput(", "->postNeutralFrom(", "GDHubClaimOwner", "gdhr_copy_root", "gdhr_copy_owner", "gdhr_pad_"] {
            XCTAssertFalse(code.contains(banned), "the tap mentions \(banned)")
        }
        XCTAssertFalse(code.contains("IOSleep"), "nothing blocks the tap's queue")
        XCTAssertFalse(code.contains("DispatchSync"), "and nothing waits on another queue")
        XCTAssertFalse(code.contains("handleReport"))
    }

    /// Nothing logs per frame: ReportAvailable's only GDLog is the once-per-window meter line.
    func testReportAvailableLogsOnlyTheWindowLine() throws {
        let code = try tapSource()
        let s = try XCTUnwrap(code.range(of: "IMPL(GDHubReceiverTap, ReportAvailable)"))
        let body = String(code[s.lowerBound...])
        XCTAssertEqual(body.components(separatedBy: "GDLog(").count - 1, 1)
        XCTAssertTrue(body.contains("gdh_meter_sample("))
        for banned in ["Create(", "withBytes", "IONew", "IOMalloc", "CreateMapping", "SetLength", "IOSleep"] {
            XCTAssertFalse(body.contains(banned), "the frame path contains \(banned)")
        }
        XCTAssertTrue(body.contains("AddReportToPool"), "strategy B: re-add after the report")
    }

    func testStopOrderCloseThenUnregisterThenTimerCancel() throws {
        let code = try tapSource()
        let s = try XCTUnwrap(code.range(of: "IMPL(GDHubReceiverTap, Stop)")), e = try XCTUnwrap(code.range(of: "IMPL(GDHubReceiverTap, SetPowerState)"))
        let body = String(code[s.lowerBound..<e.lowerBound])
        let stopping = try XCTUnwrap(body.range(of: "stopping")), close = try XCTUnwrap(body.range(of: "closeInterface(")),
            unreg = try XCTUnwrap(body.range(of: "gdhr_unregister_tap(")), cancel = try XCTUnwrap(body.range(of: "->Cancel(^{"))
        XCTAssertLessThan(stopping.lowerBound, close.lowerBound)
        XCTAssertLessThan(close.lowerBound, unreg.lowerBound)
        XCTAssertLessThan(unreg.lowerBound, cancel.lowerBound)
        XCTAssertTrue(body.contains("this->retain()") && body.contains("this->release()"), "the documented cancel pattern")
        // SetPowerState: make safe, then super
        let p = try XCTUnwrap(code.range(of: "IMPL(GDHubReceiverTap, SetPowerState)"))
        let pEnd = try XCTUnwrap(code.range(of: "static void poolBuild"))
        let pbody = String(code[p.lowerBound..<pEnd.lowerBound])
        XCTAssertLessThan(try XCTUnwrap(pbody.range(of: "ivars->powered")).lowerBound, try XCTUnwrap(pbody.range(of: "SUPERDISPATCH")).lowerBound)
    }

    func testDevTerminateOrderIsPadThenTapThenRoot() throws {
        let uc = try text("Dext/GDHubVirtualHID/GDHubVirtualHIDUserClient.cpp")
        let s = try XCTUnwrap(uc.range(of: "static kern_return_t sDevTerminate"))
        let body = String(uc[s.lowerBound...].prefix(1500))
        let terminating = try XCTUnwrap(body.range(of: "gdhr_set_terminating")), pad = try XCTUnwrap(body.range(of: "destroyPad(uc)")),
            tap = try XCTUnwrap(body.range(of: "GDHubTerminateTap()")), root = try XCTUnwrap(body.range(of: "root->Terminate(0)"))
        XCTAssertLessThan(terminating.lowerBound, pad.lowerBound)
        XCTAssertLessThan(pad.lowerBound, tap.lowerBound)
        XCTAssertLessThan(tap.lowerBound, root.lowerBound)
        // a tap that starts after that declines
        XCTAssertTrue(try tapSource().contains("gdhr_terminating("))
    }

    func testSelectorNineIsPokedNotCalled() throws {
        let uc = try text("Dext/GDHubVirtualHID/GDHubVirtualHIDUserClient.cpp")
        let s = try XCTUnwrap(uc.range(of: "static kern_return_t sSetForwarding"))
        let body = String(uc[s.lowerBound...].prefix(1400))
        XCTAssertTrue(body.contains("gdh_fwd_validate("))
        XCTAssertTrue(body.contains("gdhr_set_desired_if_owner("), "tied to ownership under the registry lock")
        XCTAssertFalse(body.contains("gdhr_set_desired("), "no bare store")
        XCTAssertTrue(body.contains("GDHubPokeTap()"))
        XCTAssertFalse(body.contains("GDH_SYNC"), "no synchronous call to the tap")
        let reg = try text("Dext/GDHubVirtualHID/GDHubRegistry.cpp")
        XCTAssertTrue(reg.contains("DispatchAsync("))
    }

    func testOwnerLossPokesTheTap() throws {
        let reg = try text("Dext/GDHubVirtualHID/GDHubRegistry.cpp")
        let s = try XCTUnwrap(reg.range(of: "void GDHubReleaseOwner"))
        XCTAssertTrue(String(reg[s.lowerBound...].prefix(900)).contains("GDHubPokeTap()"))
    }

    // MARK: T4 review fixes

    /// M3: bookkeeping before the early return; Close drops the pool; a fresh pool at the next Open.
    func testReportAvailableDoesBookkeepingBeforeTheOpenedCheck() throws {
        let code = try tapSource()
        let s = try XCTUnwrap(code.range(of: "IMPL(GDHubReceiverTap, ReportAvailable)"))
        let body = String(code[s.lowerBound...])
        let stopping = try XCTUnwrap(body.range(of: "stopping")), find = try XCTUnwrap(body.range(of: "gdh_pool_find(")),
            delivered = try XCTUnwrap(body.range(of: "gdh_pool_delivered(")), opened = try XCTUnwrap(body.range(of: "!iv->opened"))
        XCTAssertLessThan(stopping.lowerBound, find.lowerBound, "after Stop the pool is gone: nothing is touched")
        XCTAssertLessThan(find.lowerBound, delivered.lowerBound)
        XCTAssertLessThan(delivered.lowerBound, opened.lowerBound, "ownership first, then the early return")
    }

    func testCloseDropsThePoolAndCountsFailures() throws {
        let code = try tapSource()
        let s = try XCTUnwrap(code.range(of: "static void closeInterface")), e = try XCTUnwrap(code.range(of: "IMPL(GDHubReceiverTap, Stop)"))
        let body = String(code[s.lowerBound..<e.lowerBound])
        XCTAssertTrue(body.contains("iv->opened = false"))
        XCTAssertTrue(body.contains("GDHR_CTR_CLOSE_FAILURES") && body.contains("gdhr_set_last_error"))
        XCTAssertTrue(body.contains("poolRelease(iv)"))
        let pr = try XCTUnwrap(code.range(of: "static void poolRelease"))
        let prBody = String(code[pr.lowerBound...].prefix(500))
        XCTAssertTrue(prBody.contains("gdh_pool_reset(") && prBody.contains("OSSafeReleaseNULL(iv->poolObj[i])") && prBody.contains("poolAddr[i] = nullptr"))
        // the next Open builds a fresh pool and counts the re-open
        XCTAssertTrue(code.contains("if (!iv->pool.ready) poolBuild(iv)"))
        XCTAssertTrue(code.contains("GDHR_CTR_REOPENS"))
    }

    /// m2: the actions are cancelled after Close (they retain their target until then), the pool and provider are released.
    func testStopBreaksTheActionCyclesAfterClose() throws {
        let code = try tapSource()
        let s = try XCTUnwrap(code.range(of: "IMPL(GDHubReceiverTap, Stop)")), e = try XCTUnwrap(code.range(of: "IMPL(GDHubReceiverTap, SetPowerState)"))
        let body = String(code[s.lowerBound..<e.lowerBound])
        let close = try XCTUnwrap(body.range(of: "closeInterface(")), handler = try XCTUnwrap(body.range(of: "->Cancel(^{"))
        let cancelReport = try XCTUnwrap(body.range(of: "reportAction->Cancel(")), cancelTimer = try XCTUnwrap(body.range(of: "timerAction->Cancel("))
        XCTAssertLessThan(close.lowerBound, handler.lowerBound)
        XCTAssertLessThan(handler.lowerBound, cancelReport.lowerBound)
        XCTAssertLessThan(cancelReport.lowerBound, cancelTimer.lowerBound)
        XCTAssertTrue(body.contains("poolRelease(ivars)") && body.contains("OSSafeReleaseNULL(ivars->hid)"))
        XCTAssertTrue(code.contains("GDLog(\"tap free #%u\"") && code.contains("GDHR_CTR_TAP_FREES"))
        let uc = try text("Dext/GDHubVirtualHID/GDHubVirtualHIDUserClient.cpp")
        XCTAssertTrue(uc.contains("GDLog(\"client free\")"), "so a count of client start/free shows whether user clients leak")
    }

    /// m4 and the tick cadence: every tap ends itself once when the dext is terminating; the timer is adaptive.
    func testTapSelfTerminatesOnceAndTheTickIsAdaptive() throws {
        let code = try tapSource()
        let s = try XCTUnwrap(code.range(of: "IMPL(GDHubReceiverTap, TapTick)")), e = try XCTUnwrap(code.range(of: "IMPL(GDHubReceiverTap, ReportAvailable)"))
        let body = String(code[s.lowerBound..<e.lowerBound])
        XCTAssertTrue(body.contains("gdhr_terminating(reg)") && body.contains("selfTerminated") && body.contains("Terminate(0)"))
        XCTAssertEqual(body.components(separatedBy: "Terminate(0)").count - 1, 1)
        XCTAssertTrue(body.contains("gdh_tap_fast_tick("))
        XCTAssertTrue(body.contains("fastTicks") && body.contains("slowTicks"))
        let h = try text("Dext/GDHubVirtualHID/GDHubInternal.h")
        XCTAssertTrue(h.contains("#define GDHUB_TAP_TICK_MS           50") && h.contains("#define GDHUB_TAP_SLOW_TICK_MS      1000"))
    }

    /// m6: pokes that ran and applies made by the timer are counted separately.
    func testPokesAndTickAppliesAreCounted() throws {
        let code = try tapSource()
        XCTAssertTrue(code.contains("GDHR_CTR_POKES_RUN"))
        XCTAssertTrue(code.contains("GDHR_CTR_TICK_APPLIES"))
        let s = try XCTUnwrap(code.range(of: "void GDHubTapApply(GDHubReceiverTap * tap)"))
        let body = String(code[s.lowerBound...].prefix(300))
        XCTAssertTrue(body.contains("GDHR_CTR_POKES_RUN") && body.contains("tapApply(tap, 0)"))
        XCTAssertTrue(code.contains("tapApply(this, 1)"), "the timer path says it is the timer")
    }

    /// m3: a failed devTerminate must not leave the terminating flag set.
    func testFailedDevTerminateClearsTheFlag() throws {
        let uc = try text("Dext/GDHubVirtualHID/GDHubVirtualHIDUserClient.cpp")
        let s = try XCTUnwrap(uc.range(of: "static kern_return_t sDevTerminate"))
        let body = String(uc[s.lowerBound...].prefix(2200))
        let term = try XCTUnwrap(body.range(of: "root->Terminate(0)")), clear = try XCTUnwrap(body.range(of: "gdhr_clear_terminating("))
        XCTAssertLessThan(term.lowerBound, clear.lowerBound)
        XCTAssertTrue(body.contains("kr != kIOReturnSuccess"))
    }
}
