import XCTest
@testable import GDHub

final class DevTemplateTests: XCTestCase {
    private let layout = ControlLayout.loadFromBundle()!

    private func template(id: String = "full", steps: [DevStep]) -> DevTemplate {
        DevTemplate(id: id, title: "t", steps: steps)
    }
    private func digital(_ id: String, _ controls: [String]) -> DevStep { DevStep(id: id, kind: .digital, controls: controls, title: "t") }
    private func fresh(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("devtpl-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: validation messages

    func testUnknownControlMessageIsInThePlansStyle() {
        var steps = (1...6).map { digital("s\($0)", ["a"]) }
        steps.append(digital("s7", ["g6"]))
        XCTAssertEqual(template(steps: steps).validate(layout: layout), ["full.json step 7: unknown control g6"])
    }

    func testKindMustFitTheControl() {
        let t = template(steps: [
            DevStep(id: "s1", kind: .stick, controls: ["a"], title: "t"),
            DevStep(id: "s2", kind: .trigger, controls: ["left_stick"], title: "t"),
            DevStep(id: "s3", kind: .digital, controls: ["lt"], title: "t"),
            DevStep(id: "s4", kind: .stick, controls: ["right_stick"], title: "t"),
            DevStep(id: "s5", kind: .rest, controls: ["a"], title: "t"),
            DevStep(id: "s6", kind: .digital, controls: [], title: "t"),
        ])
        XCTAssertEqual(t.validate(layout: layout), [
            "full.json step 1: a stick step does not fit control a (a button)",
            "full.json step 2: a trigger step does not fit control left_stick (a stick)",
            "full.json step 3: a digital step does not fit control lt (a trigger)",
            "full.json step 5: a rest step takes no controls",
            "full.json step 6: needs at least one control",
        ])
    }

    func testDuplicateIdsBadPathsBadIdAndUnknownKind() {
        var bad = DevStep(id: "x", kind: .rest, title: "t"); bad.kind = "wiggle"
        var t = DevTemplate(id: "Bad_ID", version: 0, title: "t", paths: ["engine", "usb"], steps: [digital("a", ["a"]), digital("a", ["b"]), bad])
        let v = t.validation(layout: layout)
        XCTAssertEqual(v.warnings, [])
        XCTAssertEqual(v.errors, [
            "Bad_ID.json: id \"Bad_ID\" may only use lowercase letters, digits and dashes",
            "Bad_ID.json: version must be 1 or more",
            "Bad_ID.json: paths value \"usb\" is not engine, shadow or driver",
            "Bad_ID.json step 2: duplicate step id \"a\" (also step 1)",
            "Bad_ID.json step 3: unknown kind \"wiggle\"",
        ])
        t.id = "ok-1"; t.version = 1; t.paths = nil; t.steps = []
        XCTAssertEqual(t.validate(layout: layout), ["ok-1.json: has no steps"])
        XCTAssertTrue(DevTemplate.isValidID("t7-sleep-neutral"))
        XCTAssertFalse(DevTemplate.isValidID("")); XCTAssertFalse(DevTemplate.isValidID("Full")); XCTAssertFalse(DevTemplate.isValidID("a_b"))
    }

    func testSecondsOutOfRangeWarnAndClamp() {
        var low = digital("a", ["a"]); low.seconds = 0.2
        var high = digital("b", ["b"]); high.seconds = 500
        var ok = digital("c", ["x"]); ok.seconds = 120
        let t = template(steps: [low, high, ok])
        let v = t.validation(layout: layout)
        XCTAssertEqual(v.errors, [])
        XCTAssertEqual(v.warnings, [
            "full.json step 1: seconds 0.2 is outside 1…120, using 1",
            "full.json step 2: seconds 500 is outside 1…120, using 120",
        ])
        XCTAssertEqual(low.effectiveSeconds, 1)
        XCTAssertEqual(high.effectiveSeconds, 120)
        XCTAssertEqual(ok.effectiveSeconds, 120, "a template may raise a step up to 120 s")
        XCTAssertEqual(digital("d", ["a"]).effectiveSeconds, 3)
        XCTAssertEqual(DevStep(id: "s", kind: .stick, controls: ["left_stick"], title: "t").effectiveSeconds, 5)
        XCTAssertEqual(DevStep(id: "s", kind: .stick, controls: ["left_stick"], title: "t").effectiveReleaseSeconds, 0.5)
        XCTAssertEqual(digital("d", ["a"]).effectiveReleaseSeconds, 0)
        XCTAssertEqual(digital("d", ["a"]).effectiveReadySeconds, 2)
    }

    func testExpectAndActionAndRequiresChecks() {
        var s = digital("a", ["a"])
        var e = DevExpect(); e.items = DevExpectedItems(buttons: ["Q"], hat: "UP")
        s.expect = e
        var r = DevRequires(); r.mapping = ["g9": "y"]
        s.requires = r
        var act = DevAction(); act.toggleInputPath = DevToggleInputPath()
        s.actions = [act]
        let errors = template(steps: [s]).validation(layout: layout).errors
        XCTAssertTrue(errors.contains("full.json step 1: expect names unknown button \"Q\""))
        XCTAssertTrue(errors.contains("full.json step 1: expect names unknown hat direction \"UP\""))
        XCTAssertTrue(errors.contains("full.json step 1: unknown control g9 in requires"))
        XCTAssertTrue(errors.contains { $0.contains("toggleInputPath needs values") })
    }

    func testRequiresValuesComeFromAClosedVocabulary() {
        func errors(_ cid: String, _ value: String) -> [String] {
            var s = digital("a", ["a"])
            var r = DevRequires(); r.mapping = [cid: value]
            s.requires = r
            return template(steps: [s]).validation(layout: layout).errors.filter { $0.contains("requires") }
        }
        for ok in ["y", "dpad_up", "lt", "rt", "guide", "l3", "nothing"] { XCTAssertEqual(errors("g1", ok), [], ok) }
        for ok in ["g2", "g3", "g4"] { XCTAssertEqual(errors(ok, "built_in"), [], ok) }
        for ok in ControlMapping.echoKeyIDs {       // the paddle and SAX keys take every pick, built_in (Controller's profile) too
            XCTAssertEqual(errors(ok, "built_in"), [], ok)
            XCTAssertEqual(errors(ok, "y"), [], ok)
            XCTAssertEqual(errors(ok, "nothing"), [], ok)
        }
        let unknown = "full.json step 1: requires names unknown output \"Y\" (use a pad output such as y or dpad_up, nothing, or built_in)"
        XCTAssertEqual(errors("g1", "Y"), [unknown], "case-sensitive lowercase")
        XCTAssertEqual(errors("g1", "NOTHING").count, 1)
        XCTAssertEqual(errors("g1", "").count, 1)
        XCTAssertEqual(errors("g1", "volume").count, 1)
        XCTAssertEqual(errors("g1", "built_in"), ["full.json step 1: requires built_in for g1, but built_in is valid only for g2, g3, g4 and the paddle and SAX keys"])
        XCTAssertEqual(errors("a", "built_in").count, 1)
        XCTAssertEqual(errors("g9", "y"), ["full.json step 1: unknown control g9 in requires"])
        XCTAssertEqual(errors("left_stick", "nothing"), ["full.json step 1: requires names left_stick, which has no output that can be remapped"])
    }

    func testOnlyTheRemapTemplatesUseRequirementsAndAllBuiltInsValidate() {
        // Every `requires` in a built-in must pass the closed vocabulary; only the remap templates use it.
        for t in DevBuiltins.generate(layout: layout) {
            if t.id.hasPrefix("remap-") || t.id == "gkeys-volume" {
                XCTAssertTrue(t.steps.allSatisfy { $0.requires != nil }, t.id)
            } else {
                XCTAssertTrue(t.steps.allSatisfy { $0.requires == nil }, t.id)
            }
            XCTAssertEqual(t.validation(layout: layout).errors, [], t.id)
        }
    }

    // MARK: decoding

    func testTolerantDecodeAndSchemaGate() throws {
        let minimal = #"{"id":"mine","steps":[{"id":"a","kind":"digital","controls":["a"],"futureKey":1}],"alsoNew":true}"#
        let t = try DevTemplate.decode(Data(minimal.utf8))
        XCTAssertEqual(t.id, "mine"); XCTAssertEqual(t.version, 1); XCTAssertEqual(t.title, ""); XCTAssertNil(t.paths)
        XCTAssertEqual(t.steps[0].title, ""); XCTAssertEqual(t.steps[0].devKind, .digital)
        XCTAssertThrowsError(try DevTemplate.decode(Data(#"{"schema":2,"id":"x"}"#.utf8))) { XCTAssertEqual($0 as? DevSchemaError, DevSchemaError(found: 2, supported: 1)) }
        // a kind from a newer build decodes (so the picker can list it with a problem) and fails validation
        let odd = try DevTemplate.decode(Data(#"{"id":"odd","steps":[{"id":"a","kind":"swipe","controls":["a"]}]}"#.utf8))
        XCTAssertEqual(odd.steps[0].devKind, nil)
        XCTAssertEqual(odd.validate(layout: layout), ["odd.json step 1: unknown kind \"swipe\""])
        XCTAssertThrowsError(try DevTemplate.decode(Data(#"{"id":5}"#.utf8)))
    }

    func testEncodeDecodeRoundTrip() throws {
        for t in DevBuiltins.generate(layout: layout) {
            XCTAssertEqual(try DevTemplate.decode(try t.encoded()), t)
        }
        var s = digital("g1", ["g1"])
        var e = DevExpect(); e.times = 3; e.items = DevExpectedItems(buttons: ["Y"], hat: "N", guide: true)
        s.expect = e
        var r = DevRequires(); r.mapping = ["g1": "y"]
        s.requires = r
        var t = template(id: "remap-g1-as-y", steps: [s]); t.paths = ["engine", "driver"]
        XCTAssertEqual(try DevTemplate.decode(try t.encoded()), t)
    }

    // MARK: generated built-ins

    func testFullCoversEveryControlOnceWithTheRightKinds() throws {
        let full = try XCTUnwrap(DevBuiltins.generate(layout: layout).first { $0.id == "full" })
        // Sticks first, then the hands-off check, then everything else in layout order: the pad posts nothing while
        // idle and does not answer GetReport, so its state is known only after it has moved once.
        let stickIDs: [String] = layout.controlsByOrder.filter { $0.kind == .stick }.map { $0.id }
        XCTAssertEqual(full.steps.prefix(stickIDs.count).map { $0.controls.first! }, stickIDs)
        XCTAssertEqual(full.steps[stickIDs.count].devKind, .rest)
        XCTAssertEqual(full.steps.count, 1 + layout.controls.count)
        // Profile is last: each press switches the controller's onboard profile, which changes the paddle/SAX echoes.
        XCTAssertEqual(full.steps.filter { $0.devKind != .rest }.map { $0.controls.first! },
                       stickIDs + layout.controlsByOrder.filter { $0.kind != .stick && $0.id != "profile" }.map { $0.id } + ["profile"],
                       "one step per control, Profile last")
        XCTAssertEqual(full.steps.filter { $0.devKind == .rest }.count, 1)
        for s in full.steps where s.devKind != .rest {
            let c = layout.control(id: s.controls[0])!
            switch c.kind {
            case .stick: XCTAssertEqual(s.devKind, .stick); XCTAssertEqual(s.seconds, 5); XCTAssertEqual(s.releaseSeconds, 0.5)
            case .trigger: XCTAssertEqual(s.devKind, .trigger); XCTAssertEqual(s.seconds, 3); XCTAssertEqual(s.releaseSeconds, 0.5)
            case .button: XCTAssertEqual(s.devKind, .digital); XCTAssertEqual(s.seconds, 3); XCTAssertNil(s.releaseSeconds)
            }
            XCTAssertFalse(s.title.isEmpty); XCTAssertFalse(s.detail.isEmpty)
        }
        let byID = Dictionary(uniqueKeysWithValues: full.steps.map { ($0.id, $0) })
        XCTAssertEqual(byID["rest"]?.title, "Hands off everything")
        XCTAssertEqual(byID["left_stick"]?.title, "Roll the LEFT stick in one or two slow circles, then let go")
        XCTAssertEqual(byID["lt"]?.title, "Pull LT fully, then let go")
        XCTAssertEqual(byID["a"]?.title, "Press A twice")
        XCTAssertEqual(byID["dpad_left"]?.title, "Press D-pad left twice")
        let sticks = try XCTUnwrap(DevBuiltins.generate(layout: layout).first { $0.id == "sticks" })
        XCTAssertEqual(sticks.steps.map(\.id), ["left_stick", "right_stick", "rest"])
        let gkeys = try XCTUnwrap(DevBuiltins.generate(layout: layout).first { $0.id == "gkeys" })
        XCTAssertEqual(gkeys.steps.map(\.id), ["g1", "g2", "g3", "g4", "g5", "profile", "start"])
    }

    func testBundledFilesAreTheGeneratorsOutputAndValidate() throws {
        let entries = DevTemplates.load(folder: fresh(), layout: layout)
        let generated = DevBuiltins.generate(layout: layout)
        XCTAssertEqual(entries.map(\.id), generated.map(\.id), "full, sticks, gkeys, paddles-sax-echo, remap-g1-as-y, remap-swap-a-b, gkeys-volume, t7-rt-hold-toggle, t8-latency, echo-survey, in that order")
        for (entry, want) in zip(entries, generated) {
            XCTAssertEqual(entry.source, .builtIn)
            XCTAssertEqual(entry.url.lastPathComponent, DevBuiltins.fileName(for: want))
            XCTAssertEqual(entry.template, want, "\(entry.url.lastPathComponent) has drifted from DevBuiltins.generate; regenerate with GDHUB_WRITE_DEV_TEMPLATES=1")
            XCTAssertEqual(entry.problems, [])
            XCTAssertTrue(entry.isRunnable)
        }
    }

    /// `GDHUB_WRITE_DEV_TEMPLATES=1 swift test --filter DevTemplateTests/testWriteBundledTemplates` rewrites the bundled
    /// files from the generator. Without the variable it only checks that they are in the canonical (pretty, sorted) form.
    func testWriteBundledTemplates() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/GDHub/Resources", isDirectory: true)
        let writing = ProcessInfo.processInfo.environment["GDHUB_WRITE_DEV_TEMPLATES"] == "1"
        for t in DevBuiltins.generate(layout: layout) {
            let url = resources.appendingPathComponent(DevBuiltins.fileName(for: t))
            let data = try t.encoded() + Data("\n".utf8)
            if writing { try data.write(to: url, options: .atomic) }
            else {
                let onDisk = try Data(contentsOf: url)
                XCTAssertEqual(try DevTemplate.decode(onDisk), t, url.lastPathComponent)
            }
        }
    }

    // MARK: held steps and actions

    func testT7HoldToggleTemplateIsAsSpecifiedAndValidates() throws {
        let t = try XCTUnwrap(DevBuiltins.generate(layout: layout).first { $0.id == "t7-rt-hold-toggle" })
        XCTAssertEqual(t.title, "Hold RT while the app switches App ↔ Driver (T7)")
        XCTAssertFalse(t.notes.isEmpty)
        XCTAssertNil(t.paths)
        XCTAssertEqual(t.validate(layout: layout), [])
        let step = try XCTUnwrap(t.steps.first)
        XCTAssertEqual(t.steps.count, 1)
        XCTAssertEqual(step.id, "rt-hold")
        XCTAssertEqual(step.devKind, .held)
        XCTAssertEqual(step.controls, ["rt"])
        XCTAssertEqual(step.title, "Pull RT all the way in and just hold it still")
        XCTAssertEqual(step.seconds, 45)
        XCTAssertEqual(step.expect?.item, "RT")
        XCTAssertEqual(step.expect?.minLevel, 0.5)
        XCTAssertEqual(step.actions?.count, 1)
        XCTAssertEqual(step.actions?.first?.toggleInputPath?.values, ["driver", "engine"])
        XCTAssertEqual(step.actions?.first?.toggleInputPath?.intervalMs, 3000)
        XCTAssertEqual(step.actions?.first?.toggleInputPath?.count, 12)
        // 12 hand-overs 3 s apart, then 1.5 s: the window follows the actions, not the 45 s.
        XCTAssertEqual(step.inputPathActionsMs, 36_000)
        XCTAssertEqual(step.windowSeconds, 37.5)
        XCTAssertEqual(step.effectiveReleaseSeconds, 0.5)
        let schedule = step.inputPathSchedule
        XCTAssertEqual(schedule.count, 12)
        XCTAssertEqual(schedule.map(\.offsetMs), (0..<12).map { $0 * 3000 })
        XCTAssertEqual(schedule.map(\.value), (0..<12).map { $0 % 2 == 0 ? "driver" : "engine" })
    }

    func testHeldKindFitsButtonsAndTriggersButNotSticks() {
        let t = template(steps: [
            DevStep(id: "s1", kind: .held, controls: ["rt"], title: "t"),
            DevStep(id: "s2", kind: .held, controls: ["a"], title: "t"),
            DevStep(id: "s3", kind: .held, controls: ["left_stick"], title: "t"),
            DevStep(id: "s4", kind: .held, controls: [], title: "t"),
        ])
        XCTAssertEqual(t.validate(layout: layout), [
            "full.json step 3: a held step does not fit control left_stick (a stick)",
            "full.json step 4: needs at least one control",
        ])
        var seconds = DevStep(id: "h", kind: .held, controls: ["rt"], title: "t")
        seconds.seconds = 120
        XCTAssertEqual(template(steps: [seconds]).validation(layout: layout).warnings, [])
        XCTAssertEqual(seconds.effectiveSeconds, 120, "a held step may be raised up to maxSeconds")
        XCTAssertEqual(DevKind.held.defaultReleaseSeconds, 0.5)
    }

    func testHeldExpectActionsAndWindowChecks() {
        var s = DevStep(id: "h", kind: .held, controls: ["rt"], title: "t", seconds: 10)
        var e = DevExpect(); e.item = "Q"; e.minLevel = 1.5
        s.expect = e
        var toggle = DevToggleInputPath(); toggle.values = ["driver", "engine"]; toggle.intervalMs = 3000; toggle.count = 12
        var act = DevAction(); act.toggleInputPath = toggle
        s.actions = [act]
        let v = template(steps: [s]).validation(layout: layout)
        XCTAssertTrue(v.errors.contains { $0.contains("unknown item \"Q\"") }, "\(v.errors)")
        XCTAssertTrue(v.errors.contains { $0.contains("minLevel 1.5 must be above 0 and at most 1") }, "\(v.errors)")
        XCTAssertEqual(v.warnings.count, 1, "10 s is shorter than the actions need")
        XCTAssertTrue(v.warnings[0].contains("the window follows the actions and runs 37.5 s"), v.warnings[0])
        // Actions belong to held steps.
        var d = digital("a", ["a"]); d.actions = [act]
        XCTAssertTrue(template(steps: [d]).validate(layout: layout).contains("full.json step 1: actions are only supported on held steps"))
        // Names a build knows.
        for name in ["RT", "LT", "A", "D-pad left", "N", "NW"] {
            var ok = DevStep(id: "h", kind: .held, controls: ["rt"], title: "t")
            var ex = DevExpect(); ex.item = name
            ok.expect = ex
            XCTAssertEqual(template(steps: [ok]).validate(layout: layout), [], name)
        }
    }

    func testActionScheduleRunsToggleActionsOneAfterTheOther() {
        var s = DevStep(id: "h", kind: .held, controls: ["rt"], title: "t")
        var one = DevToggleInputPath(); one.values = ["driver", "engine"]; one.intervalMs = 100; one.count = 3
        var two = DevToggleInputPath(); two.values = ["shadow"]; two.intervalMs = 50; two.count = 2
        var a1 = DevAction(); a1.toggleInputPath = one
        var a2 = DevAction(); a2.toggleInputPath = two
        s.actions = [a1, a2, DevAction()]
        XCTAssertEqual(s.inputPathSchedule.map(\.offsetMs), [0, 100, 200, 300, 350])
        XCTAssertEqual(s.inputPathSchedule.map(\.value), ["driver", "engine", "driver", "shadow", "shadow"])
        XCTAssertEqual(s.inputPathActionsMs, 400)
        XCTAssertTrue(s.hasInputPathActions)
        XCTAssertFalse(DevStep(id: "x", kind: .held, controls: ["rt"], title: "t").hasInputPathActions)
        XCTAssertNil(DevStep(id: "x", kind: .held, controls: ["rt"], title: "t").inputPathActionsMs)
    }

    func testHeldFieldsRoundTripAndOlderFilesStillDecode() throws {
        let t = try XCTUnwrap(DevBuiltins.generate(layout: layout).first { $0.id == "t7-rt-hold-toggle" })
        XCTAssertEqual(try DevTemplate.decode(try t.encoded()), t)
        let old = try DevTemplate.decode(Data(#"{"id":"o","steps":[{"id":"h","kind":"held","controls":["rt"],"expect":{"item":"RT","futureKey":2}}]}"#.utf8))
        XCTAssertEqual(old.steps[0].expect?.item, "RT")
        XCTAssertNil(old.steps[0].expect?.minLevel)
        XCTAssertNil(old.steps[0].actions)
        var ev = DevPathEvent(tMs: 12, armed: "live"); ev.wrote = "driver"
        let data = try JSONEncoder().encode(ev)
        XCTAssertEqual(try JSONDecoder().decode(DevPathEvent.self, from: data), ev)
        XCTAssertNil(try JSONDecoder().decode(DevPathEvent.self, from: Data(#"{"tMs":1,"armed":"live"}"#.utf8)).wrote)
    }

    // MARK: latency expectations and the T8 template

    func testFlicksRequireDirectionsAndTimesDecodeTolerantlyAndRoundTrip() throws {
        let t = try DevTemplate.decode(Data(#"{"id":"f","steps":[{"id":"s","kind":"stick","controls":["left_stick"],"expect":{"flicks":10,"requireDirections":false,"times":3,"futureKey":1}}]}"#.utf8))
        let e = try XCTUnwrap(t.steps[0].expect)
        XCTAssertEqual(e.flicks, 10)
        XCTAssertEqual(e.requireDirections, false)
        XCTAssertEqual(e.times, 3)
        XCTAssertEqual(try DevTemplate.decode(try t.encoded()), t)
        // older files: nothing set
        let old = try DevTemplate.decode(Data(#"{"id":"o","steps":[{"id":"s","kind":"stick","controls":["left_stick"],"expect":{"extent":0.5}}]}"#.utf8))
        XCTAssertNil(old.steps[0].expect?.flicks)
        XCTAssertNil(old.steps[0].expect?.requireDirections)
        // the judge's rules take them over
        let rules = DevJudge.Rules().applying(e)
        XCTAssertEqual(rules.flicks, 10)
        XCTAssertFalse(rules.requireDirections)
        XCTAssertEqual(rules.triggerTimes, 3)
        XCTAssertEqual(rules.digitalTimes, 3)
        let defaults = DevJudge.Rules()
        XCTAssertNil(defaults.flicks); XCTAssertTrue(defaults.requireDirections)
        XCTAssertEqual(defaults.triggerTimes, 1); XCTAssertEqual(defaults.digitalTimes, 2)
        // a wrong type is a broken file, not an old one
        XCTAssertThrowsError(try DevTemplate.decode(Data(#"{"id":"b","steps":[{"id":"s","expect":{"flicks":"ten"}}]}"#.utf8)))
    }

    func testFlicksAndTimesAreValidated() {
        func step(_ id: String, _ kind: DevKind, _ control: String, _ edit: (inout DevExpect) -> Void) -> DevStep {
            var s = DevStep(id: id, kind: kind, controls: [control], title: "t")
            var e = DevExpect(); edit(&e); s.expect = e
            return s
        }
        let t = template(steps: [
            step("s1", .stick, "left_stick") { $0.flicks = 10; $0.requireDirections = false },
            step("s2", .stick, "left_stick") { $0.flicks = 0 },
            step("s3", .digital, "a") { $0.flicks = 3 },
            step("s4", .digital, "a") { $0.times = 0 },
            step("s5", .trigger, "rt") { $0.times = -2 },
            step("s6", .trigger, "rt") { $0.times = 5 },
        ])
        XCTAssertEqual(t.validate(layout: layout), [
            "full.json step 2: expect flicks 0 must be 1 or more",
            "full.json step 3: expect flicks only applies to stick steps",
            "full.json step 4: expect times 0 must be 1 or more",
            "full.json step 5: expect times -2 must be 1 or more",
        ])
    }

    func testT8LatencyTemplateIsAsSpecifiedAndValidates() throws {
        let t = try XCTUnwrap(DevBuiltins.generate(layout: layout).first { $0.id == "t8-latency" })
        XCTAssertEqual(t.title, "Latency: controller to pad, per press (App, then Driver) — T8 gate")
        XCTAssertEqual(t.paths, ["engine", "driver"])
        XCTAssertEqual(t.validate(layout: layout), [])
        for word in ["G4a", "G4b", "0.5 ms", "0.2 ms", "dev-run-compare.py", "back to back"] {
            XCTAssertTrue(t.notes.contains(word), "notes lack \(word)")
        }
        XCTAssertEqual(t.steps.map(\.title), [
            "Flick the LEFT stick hard and let it spring back, 10 times",
            "Tap A 10 times",
            "Tap B 10 times",
            "Pull RT all the way and release, 5 times",
            "Roll the LEFT stick in one or two slow circles, then let go",
        ])
        XCTAssertEqual(t.steps.map(\.id), ["flick-left", "tap-a", "tap-b", "pull-rt", "circle-left"])
        XCTAssertEqual(t.steps.map { $0.devKind }, [.stick, .digital, .digital, .trigger, .stick])
        XCTAssertEqual(t.steps.map(\.controls), [["left_stick"], ["a"], ["b"], ["rt"], ["left_stick"]])
        XCTAssertEqual(t.steps.map(\.effectiveSeconds), [12, 10, 10, 10, 5])
        let flick = t.steps[0]
        XCTAssertEqual(flick.expect?.flicks, 10)
        XCTAssertEqual(flick.expect?.requireDirections, false)
        XCTAssertEqual(t.steps[1].expect?.times, 10)
        XCTAssertEqual(t.steps[2].expect?.times, 10)
        XCTAssertEqual(t.steps[3].expect?.times, 5)
        XCTAssertNil(t.steps[4].expect)
        XCTAssertTrue(t.steps.allSatisfy { !$0.detail.isEmpty })
        XCTAssertEqual(try DevTemplate.decode(try t.encoded()), t)
    }

    // MARK: remap templates (R4)

    func testRemapG1AsYTemplateIsAsSpecifiedAndValidates() throws {
        let t = try XCTUnwrap(DevBuiltins.generate(layout: layout).first { $0.id == "remap-g1-as-y" })
        XCTAssertEqual(t.title, "Remap check: G1 sent to Y (App, then Driver)")
        XCTAssertEqual(t.paths, ["engine", "driver"])
        XCTAssertEqual(t.validate(layout: layout), [])
        XCTAssertTrue(t.notes.contains("Before you start: Mapping → G1 → Y. Afterwards: Mapping → Reset all remaps."), t.notes)
        XCTAssertEqual(t.steps.map(\.id), ["rest", "g1", "y", "hold-g1-then-y"])
        XCTAssertEqual(t.steps.map { $0.devKind }, [.rest, .digital, .digital, .held])
        XCTAssertEqual(t.steps.map(\.controls), [[], ["g1"], ["y"], ["g1", "y"]])
        XCTAssertEqual(t.steps.map(\.title), ["Hands off everything", "Press G1 twice", "Press Y twice",
                                              "Hold G1, then also hold Y, let go of G1, keep Y held"])
        for step in t.steps { XCTAssertEqual(step.requires?.mapping, ["g1": "y"], step.id) }
        XCTAssertEqual(t.steps[1].expect?.items, DevExpectedItems(buttons: ["Y"]))
        XCTAssertEqual(t.steps[2].expect?.items, DevExpectedItems(buttons: ["Y"]))
        XCTAssertEqual(t.steps[3].expect?.item, "Y")
        XCTAssertEqual(t.steps[3].expect?.releases, ["g1"])
        XCTAssertNil(t.steps[3].actions)
        XCTAssertTrue(t.steps.allSatisfy { !$0.detail.isEmpty })
        XCTAssertEqual(try DevTemplate.decode(try t.encoded()), t)
        // The expectations are written out, so they hold whatever the mapper does: not derived from the mapping.
        let resolved = DevResolvedStep.resolve(template: t, mapping: .default, layout: layout)
        XCTAssertEqual(resolved[1].expected, DevExpectedItems(buttons: ["Y"]))
        XCTAssertEqual(resolved[3].expected, DevExpectedItems(buttons: ["Y"]))
    }

    func testRemapSwapABTemplateIsAsSpecifiedAndValidates() throws {
        let t = try XCTUnwrap(DevBuiltins.generate(layout: layout).first { $0.id == "remap-swap-a-b" })
        XCTAssertEqual(t.title, "Remap check: A and B swapped (App, then Driver)")
        XCTAssertEqual(t.paths, ["engine", "driver"])
        XCTAssertEqual(t.validate(layout: layout), [])
        XCTAssertTrue(t.notes.contains("Mapping → A → B"), t.notes)
        XCTAssertTrue(t.notes.contains("Mapping → B → A"), t.notes)
        XCTAssertTrue(t.notes.contains("an A/B swap left on breaks games"), t.notes)
        XCTAssertTrue(t.notes.contains("Afterwards: Mapping → Reset all remaps"), t.notes)
        XCTAssertEqual(t.steps.map(\.id), ["rest", "a", "b"])
        XCTAssertEqual(t.steps.map { $0.devKind }, [.rest, .digital, .digital])
        XCTAssertEqual(t.steps.map(\.controls), [[], ["a"], ["b"]])
        XCTAssertEqual(t.steps.map(\.title), ["Hands off everything", "Press A twice", "Press B twice"])
        for step in t.steps { XCTAssertEqual(step.requires?.mapping, ["a": "b", "b": "a"], step.id) }
        XCTAssertEqual(t.steps[1].expect?.items, DevExpectedItems(buttons: ["B"]))
        XCTAssertEqual(t.steps[2].expect?.items, DevExpectedItems(buttons: ["A"]))
        XCTAssertTrue(t.steps.allSatisfy { !$0.detail.isEmpty })
        XCTAssertEqual(try DevTemplate.decode(try t.encoded()), t)
    }

    func testRemapTemplatesAreBundledAsTheGeneratorWritesThem() throws {
        let entries = DevTemplates.load(folder: fresh(), layout: layout)
        for id in ["remap-g1-as-y", "remap-swap-a-b"] {
            let entry = try XCTUnwrap(entries.first { $0.id == id }, id)
            XCTAssertEqual(entry.source, .builtIn)
            XCTAssertEqual(entry.url.lastPathComponent, "dev-script-\(id).json")
            XCTAssertEqual(entry.template, DevBuiltins.generate(layout: layout).first { $0.id == id }, "\(id) has drifted from DevBuiltins.generate")
            XCTAssertEqual(entry.problems, [])
        }
    }

    // MARK: expect.releases

    func testReleasesDecodesAndRoundTrips() throws {
        let json = #"{"id":"r","steps":[{"id":"h","kind":"held","controls":["g1","y"],"expect":{"item":"Y","releases":["g1"]}}]}"#
        let t = try DevTemplate.decode(Data(json.utf8))
        XCTAssertEqual(t.steps[0].expect?.releases, ["g1"])
        XCTAssertEqual(t.steps[0].expect?.item, "Y")
        XCTAssertEqual(t.validate(layout: layout), [])
        XCTAssertEqual(try DevTemplate.decode(try t.encoded()), t)
        let without = try DevTemplate.decode(Data(#"{"id":"r","steps":[{"id":"h","kind":"held","controls":["a"],"expect":{"item":"A"}}]}"#.utf8))
        XCTAssertNil(without.steps[0].expect?.releases, "older files have no releases")
    }

    func testReleasesIsValidated() {
        func errors(_ kind: DevKind, controls: [String], releases: [String]) -> [String] {
            var s = DevStep(id: "s", kind: kind, controls: controls, title: "t")
            var e = DevExpect(); e.releases = releases
            s.expect = e
            return template(steps: [s]).validation(layout: layout).errors
        }
        XCTAssertEqual(errors(.held, controls: ["g1", "y"], releases: ["g1"]), [])
        XCTAssertEqual(errors(.held, controls: ["g1", "y"], releases: ["g1", "y"]), [])
        XCTAssertEqual(errors(.held, controls: ["g1", "y"], releases: []), [])
        XCTAssertEqual(errors(.held, controls: ["g1", "y"], releases: ["a"]),
                       ["full.json step 1: expect releases names a, which is not one of the step's controls"])
        XCTAssertEqual(errors(.held, controls: ["g1", "y"], releases: ["g1", "x", "b"]),
                       ["full.json step 1: expect releases names x, which is not one of the step's controls",
                        "full.json step 1: expect releases names b, which is not one of the step's controls"])
        XCTAssertEqual(errors(.digital, controls: ["g1"], releases: ["g1"]),
                       ["full.json step 1: expect releases only applies to held steps"])
        XCTAssertEqual(errors(.trigger, controls: ["rt"], releases: ["rt"]),
                       ["full.json step 1: expect releases only applies to held steps"])
    }

    // MARK: loader

    func testLocalFilesOverrideBuiltInsAndAddNewOnes() throws {
        let dir = fresh()
        var override = DevBuiltins.generate(layout: layout)[1]       // sticks
        override.title = "My sticks"
        try override.encoded().write(to: dir.appendingPathComponent("sticks.json"))
        let mine = DevTemplate(id: "mine", title: "Mine", steps: [digital("a", ["a"])])
        try mine.encoded().write(to: dir.appendingPathComponent("mine.json"))
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        try Data(#"{"schema":3,"id":"future"}"#.utf8).write(to: dir.appendingPathComponent("future.json"))
        try Data("ignored".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let wrong = DevTemplate(id: "wrong", title: "Wrong", steps: [digital("a", ["g6"])])
        try wrong.encoded().write(to: dir.appendingPathComponent("wrong.json"))

        let entries = DevTemplates.load(folder: dir, layout: layout)
        func entry(_ id: String) -> DevTemplateEntry? { entries.first { $0.id == id } }
        XCTAssertEqual(entry("full")?.source, .builtIn)
        XCTAssertEqual(entry("gkeys")?.source, .builtIn)
        XCTAssertEqual(entry("sticks")?.source, .localOverride)
        XCTAssertEqual(entry("sticks")?.template?.title, "My sticks")
        XCTAssertEqual(entries.filter { $0.template?.id == "sticks" }.count, 1, "the override replaces, it does not double")
        XCTAssertEqual(entry("mine")?.source, .local)
        XCTAssertEqual(entry("mine")?.isRunnable, true)
        XCTAssertEqual(entry("broken")?.isRunnable, false)
        XCTAssertTrue(entry("broken")?.errors.first?.hasPrefix("broken.json: ") ?? false)
        XCTAssertEqual(entry("future")?.errors, ["future.json: schema 3 is newer than this build understands (1)"])
        XCTAssertEqual(entry("wrong")?.errors, ["wrong.json step 1: unknown control g6"])
        XCTAssertEqual(entry("wrong")?.isRunnable, false, "Start stays disabled while an error stands")
        XCTAssertNil(entry("notes"))
        XCTAssertEqual(entries.prefix(10).map(\.id), ["full", "sticks", "gkeys", "paddles-sax-echo", "remap-g1-as-y", "remap-swap-a-b", "gkeys-volume", "t7-rt-hold-toggle", "t8-latency", "echo-survey"], "built-ins and overrides first, in their order")
        XCTAssertEqual(entries.last?.source, .local)
    }

    func testAMissingFolderIsFine() {
        let entries = DevTemplates.load(folder: fresh().appendingPathComponent("nope"), layout: layout)
        XCTAssertEqual(entries.count, 10)
    }

    func testWarningsKeepATemplateRunnable() throws {
        let dir = fresh()
        var s = digital("a", ["a"]); s.seconds = 900
        try DevTemplate(id: "slow", title: "Slow", steps: [s]).encoded().write(to: dir.appendingPathComponent("slow.json"))
        let e = try XCTUnwrap(DevTemplates.load(folder: dir, layout: layout).first { $0.id == "slow" })
        XCTAssertTrue(e.isRunnable)
        XCTAssertEqual(e.errors, [])
        XCTAssertEqual(e.warnings.count, 1)
    }

    // MARK: expect.volume and the gkeys-volume template (remap R4b)

    func testExpectVolumeDecodesTolerantlyAndRoundTripsAndIsOmittedWhenAbsent() throws {
        let t = try DevTemplate.decode(Data(#"{"id":"v","steps":[{"id":"s","kind":"digital","controls":["g3"],"expect":{"volume":"unchanged","futureKey":1}}]}"#.utf8))
        XCTAssertEqual(t.steps[0].expect?.volume, "unchanged")
        XCTAssertEqual(t.steps[0].expect?.volumeExpectation, .unchanged)
        XCTAssertEqual(try DevTemplate.decode(try t.encoded()), t)
        let old = try DevTemplate.decode(Data(#"{"id":"o","steps":[{"id":"s","kind":"digital","controls":["a"],"expect":{"times":3}}]}"#.utf8))
        XCTAssertNil(old.steps[0].expect?.volume)
        XCTAssertFalse(String(decoding: try old.encoded(), as: UTF8.self).contains("volume"), "absent stays absent in the file")
        // a word from a newer build still loads, and is rejected by validation rather than guessed at
        let odd = try DevTemplate.decode(Data(#"{"id":"o","steps":[{"id":"s","kind":"digital","controls":["g3"],"expect":{"volume":"louder"}}]}"#.utf8))
        XCTAssertEqual(odd.steps[0].expect?.volume, "louder")
        XCTAssertNil(odd.steps[0].expect?.volumeExpectation)
        XCTAssertThrowsError(try DevTemplate.decode(Data(#"{"id":"b","steps":[{"id":"s","expect":{"volume":3}}]}"#.utf8)), "a wrong type is a broken file")
    }

    func testExpectVolumeIsValidated() {
        func step(_ id: String, _ kind: DevKind, _ control: String, _ volume: String?) -> DevStep {
            var s = DevStep(id: id, kind: kind, controls: [control], title: "t")
            var e = DevExpect(); e.volume = volume; s.expect = e
            return s
        }
        let t = template(steps: [
            step("s1", .digital, "g3", "unchanged"),
            step("s2", .digital, "g4", "changes"),
            step("s3", .digital, "g2", "louder"),
            step("s4", .digital, "g2", ""),
            step("s5", .trigger, "rt", "unchanged"),
            step("s6", .held, "a", "changes"),
            step("s7", .digital, "a", nil),
        ])
        XCTAssertEqual(t.validate(layout: layout), [
            "full.json step 3: expect volume \"louder\" must be \"unchanged\" or \"changes\"",
            "full.json step 4: expect volume \"\" must be \"unchanged\" or \"changes\"",
            "full.json step 5: expect volume only applies to digital steps",
            "full.json step 6: expect volume only applies to digital steps",
        ])
    }

    func testGKeysVolumeTemplateIsAsSpecifiedAndValidates() throws {
        let t = try XCTUnwrap(DevBuiltins.generate(layout: layout).first { $0.id == "gkeys-volume" })
        XCTAssertEqual(t.paths, ["engine", "driver"], "App, then Driver")
        XCTAssertEqual(t.validate(layout: layout), [])
        XCTAssertEqual(t.steps.map(\.id), ["rest", "g3-rb", "g4-mute-on", "g4-mute-off", "g2-nothing"])
        XCTAssertEqual(t.steps.map { $0.devKind }, [.rest, .digital, .digital, .digital, .digital])
        XCTAssertEqual(t.steps.map(\.controls), [[], ["g3"], ["g4"], ["g4"], ["g2"]])
        for s in t.steps {
            XCTAssertEqual(s.requires?.mapping, ["g3": "rb", "g4": "built_in", "g2": "nothing"], "\(s.id): requires is step-level, so every step carries it")
            XCTAssertFalse(s.title.isEmpty); XCTAssertFalse(s.detail.isEmpty)
        }
        XCTAssertEqual(t.steps.map { $0.expect?.volume }, [nil, "unchanged", "changes", "changes", "unchanged"])
        XCTAssertEqual(t.steps[1].expect?.items, DevExpectedItems(buttons: ["RB"]), "G3 sends RB to the pad")
        XCTAssertEqual(t.steps[2].expect?.items, DevExpectedItems(), "G4 sends nothing to the pad")
        XCTAssertEqual(t.steps[3].expect?.items, DevExpectedItems())
        XCTAssertEqual(t.steps[4].expect?.items, DevExpectedItems(), "G2 is silenced: nothing on the pad")
        XCTAssertEqual(t.steps[2].expect?.times, 1); XCTAssertEqual(t.steps[3].expect?.times, 1)
        for s in t.steps.dropFirst() { XCTAssertEqual(s.effectiveReleaseSeconds, 1, "\(s.id): the 1 s release tail") }
        // plain words, the picks the owner makes by hand, and the way back
        for word in ["G3 → RB", "G4", "G2 → Nothing", "half", "inconclusive"] { XCTAssertTrue(t.notes.contains(word), "notes lack \(word)") }
        XCTAssertTrue(t.notes.contains("Afterwards: Mapping → Reset all remaps"))
        XCTAssertEqual(try DevTemplate.decode(try t.encoded()), t)
    }

    func testGKeysVolumeSkipsEveryStepOnTheFactoryMappingAndRunsWithThePicks() throws {
        let t = try XCTUnwrap(DevBuiltins.generate(layout: layout).first { $0.id == "gkeys-volume" })
        let factory = DevResolvedStep.resolve(template: t, mapping: .default, layout: layout)
        XCTAssertTrue(factory.allSatisfy { $0.skipReason != nil })
        XCTAssertEqual(DevRequirementCheck.startBlock(template: t, mapping: .default, layout: layout),
                       "Needs G2 → Nothing; G3 → RB: set it in Mapping first (leave Developer mode, press Mapping, pick, Done)")
        var picked = ControlMapping.default
        picked.setOutput(.pad(.rb), for: "g3")
        picked.setOutput(.nothing, for: "g2")
        let steps = DevResolvedStep.resolve(template: t, mapping: picked, layout: layout)
        XCTAssertTrue(steps.allSatisfy { $0.skipReason == nil }, "\(steps.map(\.skipReason))")
        XCTAssertEqual(steps[1].expected, DevExpectedItems(buttons: ["RB"]))
        XCTAssertEqual(steps[2].expected, DevExpectedItems())
        XCTAssertNil(DevRequirementCheck.startBlock(template: t, mapping: picked, layout: layout))
    }

    /// Existing templates are untouched by the volume work: a pinned hash of each (compact sorted JSON).
    func testExistingBuiltInTemplatesAreByteIdenticalToBeforeTheVolumeWork() {
        let pinned = [
            "full": "f2774bac2edda1ef627ee5f9c85fc89ee061d6ad3974acc6cba7bbb058578b0c",
            "sticks": "3201055f3b02ff3b155a69a575a4d948267316589d25d6e01ab1d0163b3cc027",
            "gkeys": "baf29ee65edd062a11cdb234339abe3ee711048a48e9847ee72af64194741d20",
            "paddles-sax-echo": "51bb4fed4932c429f1d5ab15451ade7a02a9c4706cfe45ddbc1243755e6d90d0",
            "remap-g1-as-y": "b276c1d6b2d0f3420bf96555b6a8d98306ddf8e98807f69d300d465c19e06394",
            "remap-swap-a-b": "1da25b925a427722b788c981e5b8b2464cfd05f775e10e6b1462f53feb4e5788",
            "t7-rt-hold-toggle": "ade46865ef35704efe98f415254c19892c7d145eae262930d3f8ddffa6c870f0",
            "t8-latency": "d5b889447f85385d388a08729da1b30e12c5dc81377379caadff72fb4b5f25d7",
        ]
        let generated = DevBuiltins.generate(layout: layout)
        XCTAssertEqual(Set(generated.map(\.id)), Set(pinned.keys).union(["gkeys-volume", "echo-survey"]))
        for t in generated where t.id != "gkeys-volume" && t.id != "echo-survey" {
            XCTAssertEqual(DevRunReportStore.templateSha256(t), pinned[t.id], "\(t.id) changed")
        }
    }

    // MARK: echo survey (picker row 10) and the record kind

    func testTheEchoSurveyIsRowTenAmongTheBuiltInsAndAfterNineExistingOnes() {
        XCTAssertEqual(DevTemplates.builtInOrder.count, 10)
        XCTAssertEqual(DevTemplates.builtInOrder[9], "echo-survey", "appended: rows 1 to 9 keep their numbers")
        XCTAssertEqual(Array(DevTemplates.builtInOrder.prefix(9)), ["full", "sticks", "gkeys", "paddles-sax-echo", "remap-g1-as-y",
                                                                   "remap-swap-a-b", "gkeys-volume", "t7-rt-hold-toggle", "t8-latency"])
        // A local file that used to be row 10 is row 11 now.
        let dir = fresh()
        let mine = DevTemplate(id: "volume-spike", title: "Mine", steps: [digital("a", ["a"])])
        try? mine.encoded().write(to: dir.appendingPathComponent("volume-spike.json"))
        let ids = DevTemplates.load(folder: dir, layout: layout).map(\.id)
        XCTAssertEqual(ids.firstIndex(of: "echo-survey"), 9)
        XCTAssertEqual(ids.firstIndex(of: "volume-spike"), 10)
    }

    func testEchoSurveyTemplateIsAsSpecifiedAndValidates() throws {
        let t = try XCTUnwrap(DevBuiltins.generate(layout: layout).first { $0.id == "echo-survey" })
        XCTAssertEqual(t.title, "Paddles and SAX: what the controller adds (survey)")
        XCTAssertEqual(t.validation(layout: layout), DevTemplate.Validation())
        XCTAssertEqual(t.recordReceiver, true)
        XCTAssertNil(t.paths, "runs on the chosen path")
        XCTAssertTrue(t.steps.allSatisfy { $0.requires == nil }, "no requires: it runs on any mapping")
        XCTAssertEqual(Set(t.steps.map(\.id)).count, t.steps.count)
        let record = t.steps.filter { $0.devKind == .record }
        XCTAssertEqual(t.steps.filter { $0.devKind != .record }.map(\.id), ["rest"], "only the closing rest step is not a record step")
        XCTAssertEqual(t.steps.last?.id, "rest")
        // each of the six keys alone, ten times
        let six = ["paddle_outer_right", "paddle_inner_right", "paddle_inner_left", "paddle_outer_left", "sax_left", "sax_right"]
        for id in six {
            let s = try XCTUnwrap(t.steps.first { $0.id == "alone-\(id)" }, id)
            XCTAssertEqual(s.controls, [id]); XCTAssertEqual(s.expect?.rises, 10)
        }
        // D-pad up held with each paddle, the paddle-held blocks, A and SAX left, pairs
        for id in ["paddle_inner_left", "paddle_outer_right", "paddle_inner_right", "paddle_outer_left"] {
            XCTAssertEqual(t.steps.first { $0.id == "up-held-\(id)" }?.controls, ["dpad_up", id])
        }
        XCTAssertEqual(t.steps.first { $0.id == "outer-right-dpad-up" }?.controls, ["paddle_outer_right", "dpad_up"])
        XCTAssertEqual(t.steps.first { $0.id == "outer-right-dpad-left" }?.controls, ["paddle_outer_right", "dpad_left"])
        XCTAssertEqual(t.steps.first { $0.id == "outer-right-outer-left" }?.controls, ["paddle_outer_right", "paddle_outer_left"])
        XCTAssertEqual(t.steps.first { $0.id == "outer-right-inner-right" }?.controls, ["paddle_outer_right", "paddle_inner_right"])
        XCTAssertEqual(t.steps.first { $0.id == "a-held-sax-left" }?.controls, ["a", "sax_left"])
        XCTAssertEqual(t.steps.first { $0.id == "sax-left-held-a" }?.controls, ["sax_left", "a"])
        XCTAssertEqual(t.steps.first { $0.id == "together-outer" }?.controls, ["paddle_outer_left", "paddle_outer_right"])
        XCTAssertEqual(t.steps.first { $0.id == "together-inner" }?.controls, ["paddle_inner_left", "paddle_inner_right"])
        XCTAssertEqual(t.steps.first { $0.id == "together-sax" }?.controls, ["sax_left", "sax_right"])
        // Q4 = yes: three Profile blocks, each followed by the six keys three times
        for block in 1...3 {
            XCTAssertEqual(t.steps.first { $0.id == "profile-block-\(block)" }?.controls, ["paddle_outer_right", "profile"])
            for id in six { XCTAssertEqual(t.steps.first { $0.id == "profile-\(block)-\(id)" }?.expect?.rises, 3, "\(block) \(id)") }
        }
        XCTAssertEqual(record.count, 6 + 4 + 6 + 3 + 3 * 7)
        for s in record { XCTAssertNotNil(s.expect?.rises, s.id) }
        XCTAssertTrue(t.notes.contains("Do not press Profile except where a step says so."))
        XCTAssertTrue(t.notes.contains("After the last block, press Profile until your starting colour is back."))
        // plain words: no code names in what the owner reads
        for text in t.steps.flatMap({ [$0.title, $0.detail] }) + [t.notes] {
            for word in ["paddle_", "sax_", "dpad_", "physicalBits", "extra bit", "hex", "0x06"] {
                XCTAssertFalse(text.contains(word), "\"\(word)\" in: \(text)")
            }
        }
        XCTAssertEqual(try DevTemplate.decode(try t.encoded()), t)
        XCTAssertEqual(DevRunReportStore.templateSha256(t), "c5018ca6cba3fdbd31f668bd14db83e3d5d3b0e314a7485324382dde99746364", "pinned; update only with the template")
    }

    func testRecordStepsFitButtonsAndTriggersAndTheRisesAreValidated() {
        func record(_ controls: [String], rises: Int? = nil) -> DevStep {
            var s = DevStep(id: "r", kind: .record, controls: controls, title: "t")
            if let rises { var e = DevExpect(); e.rises = rises; s.expect = e }
            return s
        }
        func errors(_ s: DevStep) -> [String] { template(steps: [s]).validation(layout: layout).errors }
        XCTAssertEqual(errors(record(["paddle_outer_right", "dpad_up", "rt"], rises: 3)), [])
        XCTAssertEqual(errors(record(["left_stick"])), ["full.json step 1: a record step does not fit control left_stick (a stick)"])
        XCTAssertEqual(errors(record([])), ["full.json step 1: needs at least one control"])
        XCTAssertEqual(errors(record(["a"], rises: 0)), ["full.json step 1: expect rises 0 must be 1 or more"])
        var other = digital("d", ["a"]); var e = DevExpect(); e.rises = 2; other.expect = e
        XCTAssertEqual(errors(other), ["full.json step 1: expect rises only applies to record steps"])
    }

    func testRecordReceiverAndRisesAreOmittedWhenAbsentAndRoundTripWhenSet() throws {
        let plain = template(steps: [digital("a", ["a"])])
        let json = String(decoding: try plain.encoded(), as: UTF8.self)
        XCTAssertFalse(json.contains("recordReceiver"), "an existing template keeps its bytes")
        XCTAssertFalse(json.contains("rises"))
        var withIt = plain; withIt.recordReceiver = true
        withIt.steps[0].kind = DevKind.record.rawValue
        var e = DevExpect(); e.rises = 4; withIt.steps[0].expect = e
        let back = try DevTemplate.decode(try withIt.encoded())
        XCTAssertEqual(back, withIt)
        XCTAssertEqual(back.recordReceiver, true); XCTAssertEqual(back.steps[0].expect?.rises, 4)
        XCTAssertTrue(back.recordsReceiver(stepAt: 0))
        XCTAssertFalse(plain.recordsReceiver(stepAt: 0))
        XCTAssertTrue(withIt.recordsReceiver(stepAt: 0))
        var kindOnly = plain; kindOnly.steps[0].kind = "record"
        XCTAssertTrue(kindOnly.recordsReceiver(stepAt: 0), "a record step stores the frames whatever the template says")
    }

    func testTheRecordedVerdictAndTheReceiverKeyRoundTripAndOlderFilesStillDecode() throws {
        let v = DevVerdict.recorded("Recorded 3 receiver reports")
        XCTAssertEqual(v.tag, "recorded")
        XCTAssertEqual(v.reason, "Recorded 3 receiver reports")
        XCTAssertEqual(v.label, "Recorded")
        XCTAssertFalse(v.isPass)
        XCTAssertEqual(try JSONDecoder().decode(DevVerdict.self, from: try JSONEncoder().encode(v)), v)
        var att = DevAttempt()
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(att), as: UTF8.self).contains("receiver"), "absent when not recorded")
        att.receiver = [DevReceiverFrame(n: 7, t: -1.5, bytes: [6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80, 1, 0, 8, 0]), DevReceiverFrame(n: 9, t: 0, bytes: [UInt8](repeating: 6, count: 16))]
        att.receiverDropped = 3
        let back = try JSONDecoder().decode(DevAttempt.self, from: try JSONEncoder().encode(att))
        XCTAssertEqual(back.receiver, att.receiver)
        XCTAssertEqual(back.receiverDropped, 3)
        XCTAssertEqual(back.receiver?[0].hex, "06 00 00 00 00 00 00 00 00 00 00 80 01 00 08 00")
        XCTAssertEqual(back.receiver?[0].byteValues.count, 16)
        // a verdict word from a newer build is still shown, not guessed at
        XCTAssertEqual(try JSONDecoder().decode(DevVerdict.self, from: Data(#"{"verdict":"surveyed","reason":"x"}"#.utf8)),
                       .inconclusive("unknown verdict \"surveyed\": x"))
    }
}
