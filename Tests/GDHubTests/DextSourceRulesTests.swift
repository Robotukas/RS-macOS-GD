import XCTest

/// Source-level guards for the dext's design rules (receiver-takeover plan 4.2, 4.3 and the T0 findings), so a later
/// edit cannot break them silently. The dext itself can only be built with Xcode; these run in `swift test`.
final class DextSourceRulesTests: XCTestCase {
    private var dextDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Dext/GDHubVirtualHID")
    }

    private func sources(ext: [String]) throws -> [(name: String, lines: [String])] {
        let fm = FileManager.default
        var out: [(String, [String])] = []
        let e = fm.enumerator(at: dextDir, includingPropertiesForKeys: nil)
        for case let url as URL in e ?? NSEnumerator() where ext.contains(url.pathExtension) {
            let text = try String(contentsOf: url, encoding: .utf8)
            out.append((url.path.replacingOccurrences(of: dextDir.path + "/", with: ""),
                        text.components(separatedBy: "\n")))
        }
        return out
    }

    /// Every synchronous cross-object call in the dext is wrapped in GDH_SYNC (a call site names its ranks).
    func testEveryCrossObjectCallIsWrappedInGDHSync() throws {
        let calls = try NSRegularExpression(pattern: #"->(CreatePad|DestroyPad|submitInput|postNeutralFrom)\("#)
        var found = 0
        for (name, lines) in try sources(ext: ["cpp"]) {
            for (i, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                guard calls.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil else { continue }
                found += 1
                let window = lines[max(0, i - 3)..<i].joined(separator: "\n")
                XCTAssertTrue(window.contains("GDH_SYNC("), "\(name):\(i + 1) calls across objects without GDH_SYNC in the 3 lines before")
            }
        }
        XCTAssertEqual(found, 8, "UC->root CreatePad and DestroyPad, UC->pad submitInput and postNeutralFrom (two sites: the UC's own pad and the registry's pad), root->pad postNeutralFrom (orphan timer), tap->pad submitInput and postNeutralFrom (T7): exactly these eight")
    }

    /// GDH_SYNC only compiles for calls toward a higher rank.
    func testSyncCallSitesGoTowardAHigherRank() throws {
        let rank = ["GDHR_RANK_UC": 1, "GDHR_RANK_ROOT": 2, "GDHR_RANK_TAP": 3, "GDHR_RANK_PAD": 4]
        let re = try NSRegularExpression(pattern: #"GDH_SYNC\((GDHR_RANK_\w+),\s*(GDHR_RANK_\w+),"#)
        var n = 0
        for (name, lines) in try sources(ext: ["cpp"]) {
            for (i, line) in lines.enumerated() {
                guard let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
                n += 1
                let a = String(line[Range(m.range(at: 1), in: line)!]), b = String(line[Range(m.range(at: 2), in: line)!])
                XCTAssertLessThan(try XCTUnwrap(rank[a]), try XCTUnwrap(rank[b]), "\(name):\(i + 1) \(a) -> \(b)")
            }
        }
        XCTAssertEqual(n, 8)
    }

    /// The registry core and its lock know nothing about DriverKit or the GDHub classes, so no RPC can run under its lock;
    /// the typed wrapper never calls a synchronous method of a GDHub class.
    func testRegistryCannotCallIntoGDHubClasses() throws {
        for (name, lines) in try sources(ext: ["c", "h"]) where name.hasPrefix("Core/") {
            // comments may name the rules; only code counts
            var text = lines.joined(separator: "\n")
            text = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
            for banned in ["DriverKit", "IOService", "OSObject", "GDHubVirtual", "os_log", "IOLock", "Terminate", "Create("] {
                XCTAssertFalse(text.contains(banned), "\(name) mentions \(banned)")
            }
        }
        let wrapper = try XCTUnwrap(sources(ext: ["cpp"]).first { $0.name == "GDHubRegistry.cpp" }).lines.joined(separator: "\n")
        for banned in ["->CreatePad(", "->DestroyPad(", "->submitInput(", "->postNeutralFrom(", "->ExternalMethod("] {
            XCTAssertFalse(wrapper.contains(banned), "GDHubRegistry.cpp calls \(banned)")
        }
    }

    /// Widest expansion of a printf format: u32 10 digits, 64-bit 20, int 11, hex 8, a %{public}s string 24, text as written.
    static func worstCaseLength(_ format: String) -> Int {
        var total = "GDHub: ".count
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            guard chars[i] == "%" else { total += 1; i += 1; continue }
            var j = i + 1
            if j < chars.count, chars[j] == "%" { total += 1; i = j + 1; continue }
            var spec = ""
            if j < chars.count, chars[j] == "{" { while j < chars.count, chars[j] != "}" { spec.append(chars[j]); j += 1 }; j += 1 }
            while j < chars.count, !"udxsc".contains(chars[j]) { spec.append(chars[j]); j += 1 }
            let conv = j < chars.count ? chars[j] : "u"
            if conv == "s" { total += 24 }
            else if conv == "x" { total += spec.contains("ll") ? 16 : 8 }
            else if spec.contains("ll") || spec.contains("z") { total += 20 }
            else if conv == "u" { total += 10 }
            else { total += 11 }
            i = j + 1
        }
        return total
    }

    func testWorstCaseLengthEstimator() {
        XCTAssertEqual(Self.worstCaseLength("a %u b"), 7 + 4 + 10)
        XCTAssertEqual(Self.worstCaseLength("%d"), 7 + 11)
        XCTAssertEqual(Self.worstCaseLength("%llu"), 7 + 20)
        XCTAssertEqual(Self.worstCaseLength("%{public}s x"), 7 + 24 + 2)
    }

    /// T0: dext log lines are cut at about 256 characters. Every GDLog format stays well under 250 even when each
    /// conversion prints a 10-digit number (the %{public}s strings of this dext are short constants).
    func testEveryDextLogLineStaysUnder250Characters() throws {
        let re = try NSRegularExpression(pattern: #"GDLog\(((?:\s*"(?:[^"\\]|\\.)*")+)"#)
        let lit = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        var checked = 0
        for (name, lines) in try sources(ext: ["cpp", "h"]) {
            let text = lines.joined(separator: "\n")
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let args = String(text[Range(m.range(at: 1), in: text)!])
                var format = ""
                for l in lit.matches(in: args, range: NSRange(args.startIndex..., in: args)) {
                    format += String(args[Range(l.range(at: 1), in: args)!])
                }
                let worst = Self.worstCaseLength(format)
                checked += 1
                XCTAssertLessThan(worst, 250, "\(name): \"\(format)\" can reach \(worst) characters")
            }
        }
        XCTAssertGreaterThan(checked, 30)
        // the T3 review items: the lines touched there, by their worst case
        let meter = Self.worstCaseLength("pad meter b=%u w=%u n=%u hop p50/p99/max/mean %u/%u/%u/%u.%u hr %u/%u/%u/%u.%u us")
        XCTAssertLessThan(meter, 250)
        XCTAssertEqual(meter, 192, "the worst case of the meter line, as stated in the source comment")
        // the topology probe and the inline-call lines (next build)
        XCTAssertLessThan(Self.worstCaseLength("topo %{public}s: rootq=%u ucq=%u padq=%u onq root/uc/pad=%u/%u/%u"), 150)
        XCTAssertLessThan(Self.worstCaseLength("sync inline (first at this site): %{public}s runs on the target's queue"), 100)
    }

    /// Plan 6.3: neutral before destroy. destroyPad (destroyDevice, Stop and devTerminate all use it) posts neutral first
    /// and ignores the result, then calls DestroyPad; nothing in between waits.
    func testDestroyPostsNeutralBeforeDestroying() throws {
        let text = try XCTUnwrap(sources(ext: ["cpp"]).first { $0.name == "GDHubVirtualHIDUserClient.cpp" }).lines.joined(separator: "\n")
        let s = try XCTUnwrap(text.range(of: "static void destroyPad(GDHubVirtualHIDUserClient * uc)"))
        let body = String(text[s.lowerBound...].prefix(1400))
        let neutral = try XCTUnwrap(body.range(of: "postNeutralToPad(uc, GDHUB_NEUTRAL_UC_REQUEST)"))
        let destroy = try XCTUnwrap(body.range(of: "->DestroyPad("))
        XCTAssertLessThan(neutral.lowerBound, destroy.lowerBound)
        XCTAssertFalse(body[..<destroy.lowerBound].contains("IOSleep"), "no wait between neutral and destroy")
        // and a failed createDevice always empties the slot
        let create = try XCTUnwrap(text.range(of: "static kern_return_t createCommon"))
        let cbody = String(text[create.lowerBound...].prefix(6000))
        XCTAssertTrue(cbody.contains("gdhr_pad_take(reg, iv->ownerGen, &rc)"))
    }

    /// The topology is measured, not assumed: nothing may wait on a queue it cannot name (no IOSleep in the dext), the probe
    /// logs only from the Start methods and once per kind from the hot paths, and GDH_SYNC counts inline calls instead of
    /// calling them violations.
    func testNoBlockingWaitsAndTheProbeIsOneShot() throws {
        for (name, lines) in try sources(ext: ["cpp"]) {
            for (i, line) in lines.enumerated() where (line.components(separatedBy: "//").first ?? "").contains("IOSleep") {
                XCTFail("\(name):\(i + 1) sleeps on a queue")
            }
        }
        let internalH = try String(contentsOf: dextDir.appendingPathComponent("GDHubInternal.h"), encoding: .utf8)
        XCTAssertTrue(internalH.contains("GDHubSyncInline"))
        XCTAssertFalse(internalH.contains("GDHubSyncViolation"), "a runtime violation cannot exist: the rank order is a static_assert")
        XCTAssertTrue(internalH.contains("static_assert((callerRank) < (targetRank)"))
        let probeCalls = NSRegularExpression.escapedPattern(for: "GDHubProbeFirst(")
        var firsts = 0, starts = 0
        for (_, lines) in try sources(ext: ["cpp"]) {
            for l in lines { let c = l.components(separatedBy: "//").first ?? ""
                if c.range(of: probeCalls, options: .regularExpression) != nil && !c.contains("void ") { firsts += 1 }
                if c.contains("GDHubProbeStart(") && !c.contains("void ") { starts += 1 } }
        }
        XCTAssertEqual(firsts, 2, "first ExternalMethod and first submitInput")
        XCTAssertEqual(starts, 3, "root, user client and pad Start")
    }

    /// No per-post allocation, logging or SetLength on the hot paths: the posting functions contain none of them.
    func testHotPathsHaveNoAllocationLoggingOrSetLength() throws {
        func body(of file: String, from marker: String, to end: String) throws -> String {
            let text = try XCTUnwrap(sources(ext: ["cpp"]).first { $0.name == file }).lines.joined(separator: "\n")
            let s = try XCTUnwrap(text.range(of: marker)), e = try XCTUnwrap(text.range(of: end, range: s.upperBound..<text.endIndex))
            return String(text[s.lowerBound..<e.lowerBound])
        }
        let postReport = try body(of: "GDHubVirtualHIDUserClient.cpp", from: "static kern_return_t sPostReport", to: "static kern_return_t sPostNeutral")
        let submit = try body(of: "GDHubVirtualPad.cpp", from: "kern_return_t IMPL(GDHubVirtualPad, submitInput)", to: "// Posts every neutral report")
        for (what, code) in [("sPostReport", postReport), ("submitInput", submit)] {
            for banned in ["SetLength", "Create(", "withBytes", "IONew", "IOMalloc", "OSData::", "->retain()"] {
                XCTAssertFalse(code.contains(banned), "\(what) contains \(banned)")
            }
        }
        // the only logging in submitInput is the once-per-window meter line, behind the window-closed test
        XCTAssertEqual(submit.components(separatedBy: "GDLog(").count - 1, 1)
        XCTAssertTrue(submit.contains("if (gdh_meter_sample("))
        XCTAssertFalse(postReport.contains("GDLog("))
    }
}
