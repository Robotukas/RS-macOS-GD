import Foundation

/// Turns what the virtual pad sent during one step into a verdict and numbers. Pure: no clock, no IOKit, no UI, so
/// every rule has a unit test with a synthetic report stream.
///
/// The judge works on the held state, not on report presence. The sink posts on change only, so a stick that has
/// returned to centre sends nothing more; "the stick was at rest for the last 300 ms" therefore means "the state in
/// force during those 300 ms (the last report at or before each instant, across report 0x01 and 0x02) was inside the
/// tolerance". The state is seeded with `entryState`, the last thing the reader saw before the step.
///
/// Tolerances (all in `Rules`): buttons, hat and Guide are exact; sticks count as still inside the 12 % dead zone,
/// triggers below 5 %. The sink's own dead band is 0.2 %, so jitter alone must not fail a step; the exact number of
/// changes is kept as `padChanged`.
///
/// Fixed keys in `DevMetrics.values`, by kind (p is `ls` or `rs`, t is `lt` or `rt`):
/// - rest: `rest.offReports`, `rest.maxStick`, `rest.maxTrigger`
/// - stick: `p.reportsOutside`, `p.xMin`, `p.xMax`, `p.yMin`, `p.yMax`, `p.otherOutside`, `p.settledMs`, `p.onsets`
///   (times the pad's stick left the dead zone from rest)
/// - trigger: `t.peak`, `t.settledMs`, `t.pulls` (peaks followed by a release)
/// - digital: `bit.rises`, `bit.falls` (the fewest over the expected items; the totals when nothing is expected),
///   `hat.visited` (bit mask of the hat values seen, bit n = value n), `neutrals`, `unexpected`, `entrySet`
/// - held: `held.minLevel` (lowest trigger value from the moment it was held; 1 or 0 for a button), `held.drops`
///   (held to released transitions), `held.padReports`, `held.ms` (held until the window end). Only the window counts:
///   the release tail is where the owner lets go. With `expect.releases`: `held.released` (how many of the listed
///   controls were seen pressed and then let go while the item stayed held).
/// - every kind but rest, when the receiver frames are known (`Reference.frames`): `lat.n`, `lat.unmatched`, and when
///   n > 0 `lat.p50Ms`, `lat.p95Ms`, `lat.p99Ms`, `lat.maxMs`; see `DevLatency` for the edge and match definitions.
enum DevJudge {
    struct Rules: Equatable {
        var deadZone = 0.12
        var triggerRelease = 0.05
        var triggerPeak = 0.90
        var stickExtent = 0.40
        var stickMinReports = 100
        var holdMs = 300.0
        /// Per-event latency (`DevLatency`): a trigger edge is the value crossing this, a stick onset needs this long
        /// inside the dead zone first.
        var latencyTriggerEdge = 0.5
        var onsetRestMs = 60.0
        var digitalTimes = 2
        var otherStickStill = true
        var requireReturn = true
        /// Full pulls (peak, then release) a trigger step needs.
        var triggerTimes = 1
        /// Flick steps: the stick must leave the dead zone from rest at least this often; nil = the circle rule.
        var flicks: Int?
        /// The four-direction check of the stick rule (off for flick steps).
        var requireDirections = true
        /// A held step: the trigger value that counts as held, and how long after the window start the item may take
        /// to get there (the window opens when the control first moves, so the pull is still on its way).
        var heldMinLevel = 0.5
        var heldEngageMs = 2000.0

        /// A release shorter than this is a switch blip, not a drop: the pad posts a neutral on every source switch by design

        /// (plan 6.2) and the new source reposts the full state with its next frame, about 1 ms later. Measured 0.39-0.87 ms.

        var heldMaxBlipMs: Double = 5

        /// The rules with a step's own overrides applied.
        func applying(_ e: DevExpect?) -> Rules {
            guard let e else { return self }
            var r = self
            if let v = e.deadZone { r.deadZone = v }
            if let v = e.release { r.triggerRelease = v }
            if let v = e.peak { r.triggerPeak = v }
            if let v = e.extent { r.stickExtent = v }
            if let v = e.minReports { r.stickMinReports = v }
            if let v = e.times { r.digitalTimes = v; r.triggerTimes = v }
            if let v = e.flicks { r.flicks = v }
            if let v = e.requireDirections { r.requireDirections = v }
            if let v = e.otherStickStill { r.otherStickStill = v }
            if let v = e.requireReturn { r.requireReturn = v }
            if let v = e.minLevel { r.heldMinLevel = v }
            return r
        }
    }

    /// One input report of the pad with its kernel timestamp (`LatencyMeter.nanos(fromMach:)`).
    struct TimedReport: Equatable {
        var tNs: UInt64
        var id: UInt8
        var bytes: [UInt8]
    }

    /// What the GUI's own receiver frames say should have happened (frames → `PassthroughPadMapper` → the sink's
    /// `snapped` / `unchanged`), so two runs compare on what the path lost and not on how long the hands moved.
    struct Reference: Equatable {
        /// One receiver frame as the pad should show it (mapper output, dead band applied) with its kernel timestamp.
        struct Frame: Equatable {
            var tNs: UInt64
            var pad: PadState
        }

        var expectedChanges: Int
        var firstFrameChangeNs: UInt64?
        var framesSeen = 0
        var framesPerSecond = 0.0
        var movingMs = 0.0
        /// Every frame from the window start to the end of the release tail, in time order: the receiver edges of the
        /// per-event latency (`DevLatency`) come from these. Empty = no latency is measured.
        var frames: [Frame] = []
    }

    /// Which of a held step's `expect.releases` controls were physically active (`ControlMapping.isActive`) on one
    /// receiver frame. Only the listed controls are recorded.
    struct ControlSample: Equatable {
        var tNs: UInt64
        var active: Set<String>
    }

    struct Input {
        var step: DevStep
        var expected: DevExpectedItems
        /// The pad state before the step; nil = the reader has seen no report since it opened.
        var entryState: PadDecodedState?
        /// Everything read from the ready phase to the end of the release tail. Reports before `windowStartNs` only
        /// move the held state; the ones after `endNs` are ignored.
        var reports: [TimedReport]
        var windowStartNs: UInt64
        var windowEndNs: UInt64
        /// End of the release tail (equal to `windowEndNs` when the step has none).
        var endNs: UInt64
        /// How many virtual pads the reader matched at window start.
        var matchedCount: Int
        var reference: Reference?
        /// Path hand-overs the app made during the window (held steps with actions), for the detail line.
        var handOvers: Int
        /// Receiver frames from the window start on, for `expect.releases`. Empty = no frames known.
        var controlActivity: [ControlSample]
        /// What the Mac's volume did from Go to the end of the release tail, for a step with `expect.volume`. nil with
        /// such a step = nothing was watched, which is "cannot judge".
        var volume: DevVolumeObservation?
        /// What the step's `background` controls send to the pad: held from before the pressed ones to after them.
        var background: Set<PadItem>
        /// The step takes the `builtInEcho` rule: one pad item per press, whichever the controller's profile gives.
        var builtInEcho: Bool
        /// What the run saw of the remapped paddle and SAX keys of the step, for the hiding check; nil = no claim.
        var hiding: HidingEvidence?

        init(step: DevStep, expected: DevExpectedItems = DevExpectedItems(), entryState: PadDecodedState?,
             reports: [TimedReport], windowStartNs: UInt64, windowEndNs: UInt64, endNs: UInt64? = nil,
             matchedCount: Int = 1, reference: Reference? = nil, handOvers: Int = 0,
             controlActivity: [ControlSample] = [], volume: DevVolumeObservation? = nil,
             background: Set<PadItem> = [], builtInEcho: Bool = false, hiding: HidingEvidence? = nil) {
            self.background = background
            self.builtInEcho = builtInEcho
            self.hiding = hiding
            self.volume = volume
            self.handOvers = handOvers
            self.controlActivity = controlActivity
            self.step = step
            self.expected = expected
            self.entryState = entryState
            self.reports = reports
            self.windowStartNs = windowStartNs
            self.windowEndNs = windowEndNs
            self.endNs = endNs ?? windowEndNs
            self.matchedCount = matchedCount
            self.reference = reference
        }

        /// The reports as stored in the run report: milliseconds from the window start, with their phase.
        func rawReports() -> [DevRawReport] {
            reports.sorted { $0.tNs < $1.tNs }.map { r in
                let phase: DevRawReport.Phase = r.tNs < windowStartNs ? .ready : (r.tNs < windowEndNs ? .window : .release)
                let ms = r.tNs >= windowStartNs ? Double(r.tNs - windowStartNs) / 1e6 : -Double(windowStartNs - r.tNs) / 1e6
                return DevRawReport(tMs: ms, id: r.id, bytes: r.bytes, phase: phase)
            }
        }
    }

    struct Outcome: Equatable {
        var verdict: DevVerdict
        var metrics: DevMetrics
        /// The volume part, for a step with `expect.volume`.
        var volume: DevVolumeResult?
        /// The hiding check, for a step with a remapped paddle or SAX key whose receiver reports were recorded.
        var hiding: DevHiding?
        /// The pad item an untouched paddle or SAX key brought (`builtInEcho`), named.
        var echoItem: String?
    }

    static func judge(_ input: Input, rules base: Rules = Rules(), decoder: PadReportDecoder = .xboxBT16) -> Outcome {
        let step = input.step
        var metrics = DevMetrics()
        func done(_ v: DevVerdict, _ detail: String) -> Outcome {
            metrics.detail = detail
            return Outcome(verdict: v, metrics: metrics)
        }

        guard let kind = step.devKind else { return done(.inconclusive("unknown kind \"\(step.kind)\""), "The step has a kind this build cannot judge.") }
        // A record step has nothing to judge: the runner stores the receiver's reports and says so.
        if kind == .record { return done(.recorded("nothing was judged"), "Recorded; nothing was judged.") }
        if input.matchedCount != 1 {
            return done(.inconclusive("reader matched \(input.matchedCount) pads"),
                        "The pad reader must see exactly one GDHub pad to judge a step; it saw \(input.matchedCount).")
        }
        guard let entry = input.entryState else {
            return done(.inconclusive("pad state unknown"), "The reader had seen no report from the pad before this step, so there is nothing to compare with.")
        }

        let rules = base.applying(step.expect)
        // A held step is judged on the window alone: the tail after it is where the owner lets go.
        var timelineInput = input
        if kind == .held { timelineInput.endNs = max(input.windowEndNs, input.windowStartNs) }
        let tl = Timeline(input: timelineInput, entry: entry, decoder: decoder)
        tl.fill(&metrics, reference: input.reference)

        var outcome: Outcome
        switch kind {
        case .rest: return tl.judgeRest(input, entry: entry, rules: rules, metrics: &metrics)
        case .stick: outcome = tl.judgeStick(input, rules: rules, metrics: &metrics)
        case .trigger: outcome = tl.judgeTrigger(input, rules: rules, metrics: &metrics)
        case .digital:
            outcome = tl.judgeDigital(input, entry: entry, rules: rules, metrics: &metrics)
            if let want = step.expect?.volumeExpectation { outcome = applyVolume(want, to: outcome, input: input) }
        case .held: outcome = tl.judgeHeld(input, rules: rules, metrics: &metrics)
        case .record: return done(.recorded("nothing was judged"), "Recorded; nothing was judged.")
        }

        // What a pass proves about hiding the controller's own button for a remapped key (never changes the verdict).
        if let evidence = input.hiding, let hiding = DevJudge.judgeHiding(evidence, expected: input.expected.items, background: input.background) {
            outcome.hiding = hiding
            outcome.metrics.detail += (outcome.metrics.detail.isEmpty ? "" : " ") + hiding.line.prefix(1).uppercased() + hiding.line.dropFirst() + "."
        }

        // Per-event latency: every kind but rest, when the receiver frames are known. The pad side is read from a
        // timeline that runs past the end of the release tail, so an edge near the end still finds its report.
        if let ref = input.reference, !ref.frames.isEmpty, let watch = latencyWatch(input, kind: kind) {
            var wide = input
            wide.endNs = UInt64.max
            let wl = Timeline(input: wide, entry: entry, decoder: decoder)
            let pad = (0..<wl.count).map { DevLatency.PadSample(tNs: wl.times[$0], state: wl.states[$0], changed: wl.changed[$0]) }
            let config = DevLatency.Config(deadZone: rules.deadZone, triggerEdge: rules.latencyTriggerEdge,
                                           triggerRelease: rules.triggerRelease, onsetRestMs: rules.onsetRestMs)
            let lat = DevLatency.measure(frames: ref.frames, pad: pad, watch: watch, config: config)
            for (k, v) in DevLatency.values(lat) { outcome.metrics.values[k] = v }
            outcome.metrics.detail += (outcome.metrics.detail.isEmpty ? "" : " ") + DevLatency.text(lat)
        }
        return outcome
    }

    /// Folds the volume check into the pad's outcome. The pad failing stays a failure; "cannot judge the volume" never
    /// turns a pass into a pass (the step becomes inconclusive) and never hides a pad failure.
    private static func applyVolume(_ want: DevVolumeExpectation, to pad: Outcome, input: Input) -> Outcome {
        let vol = DevVolumeJudge.judge(want, input.volume ?? DevVolumeObservation())
        var out = pad
        out.volume = vol
        out.metrics.detail += (out.metrics.detail.isEmpty ? "" : " ") + vol.summary
        switch (pad.verdict, vol.verdict) {
        case (.pass, .pass):
            break
        case (.pass, .inconclusive(let why)):
            out.verdict = .inconclusive("cannot judge the volume: \(why)")
        case (.pass, .fail(let why)):
            out.verdict = .fail(why)
        case (.fail(let padWhy), .fail(let why)):
            out.verdict = .fail(padWhy + "; " + why)
        default:
            break
        }
        return out
    }

    /// What the latency measurement watches for a step, or nil when the step names nothing it can watch.
    private static func latencyWatch(_ input: Input, kind: DevKind) -> DevLatency.Watch? {
        let step = input.step
        switch kind {
        case .rest, .record:
            return nil
        case .stick:
            switch step.controls.first {
            case "left_stick": return DevLatency.Watch(stick: .left)
            case "right_stick": return DevLatency.Watch(stick: .right)
            default: return nil
            }
        case .trigger:
            // The pad trigger (or button) the pull is mapped to; with nothing worked out, the control's own trigger.
            var w = DevLatency.Watch(items: input.expected.items, triggers: input.expected.triggers)
            if w.triggers.isEmpty && w.items.isEmpty {
                w.triggers = step.controls.compactMap { $0 == "lt" ? .left : ($0 == "rt" ? .right : nil) }
            }
            return w.triggers.isEmpty && w.items.isEmpty ? nil : w
        case .digital:
            return DevLatency.Watch(items: input.expected.items, triggers: input.expected.triggers)
        case .held:
            guard let targets = DevExpectation.heldTargets(step: step, expected: input.expected) else { return nil }
            var w = DevLatency.Watch()
            for t in targets {
                if case .trigger(let tr) = t { w.triggers.append(tr) } else { w.items.formUnion(t.padItems) }
            }
            return w
        }
    }

    // MARK: Held-state timeline

    /// The held state over time from the window start to the end of the release tail: segment i holds `states[i]`
    /// from `times[i]` until `times[i + 1]` (the last one until `endNs`). Segment 0 is the state in force at the window
    /// start (entry state plus the ready-phase reports); every later segment starts at a report.
    private struct Timeline {
        var times: [UInt64] = []
        var states: [PadDecodedState] = []
        /// Whether the report that opened segment i changed the state (segment 0: false).
        var changed: [Bool] = []
        let endNs: UInt64

        init(input: Input, entry: PadDecodedState, decoder: PadReportDecoder) {
            endNs = max(input.endNs, input.windowStartNs)
            var held = entry
            let ordered = input.reports.enumerated().sorted { ($0.element.tNs, $0.offset) < ($1.element.tNs, $1.offset) }.map(\.element)
            for r in ordered where r.tNs < input.windowStartNs { decoder.apply(reportID: r.id, bytes: r.bytes, to: &held) }
            times = [input.windowStartNs]; states = [held]; changed = [false]
            for r in ordered where r.tNs >= input.windowStartNs && r.tNs <= endNs {
                let did = decoder.apply(reportID: r.id, bytes: r.bytes, to: &held)
                times.append(r.tNs); states.append(held); changed.append(did)
            }
        }

        var count: Int { times.count }
        var reportCount: Int { count - 1 }
        var last: PadDecodedState { states[count - 1] }

        /// When the state last became (and stayed) acceptable up to the end, or nil if the final state is not.
        func settledSince(_ ok: (PadDecodedState) -> Bool) -> UInt64? {
            guard ok(last) else { return nil }
            var since = times[0]
            var i = count - 1
            while i >= 0 {
                if !ok(states[i]) { break }
                since = times[i]
                i -= 1
            }
            return since
        }

        func settledMs(_ ok: (PadDecodedState) -> Bool) -> Double? {
            settledSince(ok).map { Double(endNs &- $0) / 1e6 }
        }

        func fill(_ m: inout DevMetrics, reference: Reference?) {
            m.padReports = reportCount
            m.padChanged = changed.filter { $0 }.count
            var movingFirst: UInt64?, movingLast: UInt64?
            for i in 1..<max(count, 1) where changed[i] {
                if movingFirst == nil { movingFirst = times[i] }
                movingLast = times[i]
            }
            m.movingMs = movingFirst.flatMap { f in movingLast.map { Double($0 - f) / 1e6 } } ?? 0
            guard let reference else { return }
            m.expectedChanges = reference.expectedChanges
            m.framesSeen = reference.framesSeen
            m.framesPerSecond = reference.framesPerSecond
            if reference.movingMs > 0 { m.movingMs = reference.movingMs }
            if reference.expectedChanges > 0 { m.lossRatio = Double(m.padChanged) / Double(reference.expectedChanges) }
            if let first = movingFirst, let ref = reference.firstFrameChangeNs {
                m.onsetMs = (Double(first) - Double(ref)) / 1e6
            }
        }

        // MARK: rest

        func judgeRest(_ input: Input, entry: PadDecodedState, rules: Rules, metrics m: inout DevMetrics) -> Outcome {
            let ok: (PadDecodedState) -> Bool = { $0.isNeutral(deadZone: rules.deadZone, triggerMax: rules.triggerRelease) }
            var maxStick = 0.0, maxTrigger = 0.0, off = 0
            var firstOffence: String?
            for (i, s) in states.enumerated() {
                for stick in [PadStick.left, .right] {
                    let p = s.position(of: stick)
                    maxStick = max(maxStick, (p.x * p.x + p.y * p.y).squareRoot())
                }
                maxTrigger = max(maxTrigger, s.lt, s.rt)
                if !ok(s) {
                    if i > 0 { off += 1 }
                    if firstOffence == nil { firstOffence = DevJudge.describeOffences(s, rules: rules) }
                }
            }
            m.values = ["rest.offReports": Double(off), "rest.maxStick": maxStick, "rest.maxTrigger": maxTrigger]
            var fails: [String] = []
            if !ok(entry) { fails.append("the pad was not at rest at step start (\(DevJudge.describeOffences(entry, rules: rules)))") }
            else if let o = firstOffence { fails.append("the pad left rest during the step (\(o))") }
            let summary = "\(m.padReports) pad reports, \(m.padChanged) changed; largest stick deflection \(DevJudge.fmt(maxStick)), largest trigger \(DevJudge.fmt(maxTrigger))."
            if fails.isEmpty { return Outcome(verdict: .pass, metrics: with(&m, "The pad stayed at rest. " + summary)) }
            return Outcome(verdict: .fail(fails.joined(separator: "; ")), metrics: with(&m, fails.joined(separator: "; ") + ". " + summary))
        }

        // MARK: stick

        func judgeStick(_ input: Input, rules: Rules, metrics m: inout DevMetrics) -> Outcome {
            let cid = input.step.controls.first
            guard let stick: PadStick = cid == "left_stick" ? .left : (cid == "right_stick" ? .right : nil) else {
                return Outcome(verdict: .inconclusive("the step names no stick"), metrics: with(&m, "A stick step needs left_stick or right_stick as its control."))
            }
            let other: PadStick = stick == .left ? .right : .left
            let p = stick == .left ? "ls" : "rs"
            let name = stick == .left ? "left" : "right"
            var outside = 0, otherOutside = 0
            var xMin = 0.0, xMax = 0.0, yMin = 0.0, yMax = 0.0
            for (i, s) in states.enumerated() {
                let pos = s.position(of: stick)
                xMin = min(xMin, pos.x); xMax = max(xMax, pos.x); yMin = min(yMin, pos.y); yMax = max(yMax, pos.y)
                if i > 0 && !s.isInside(stick, deadZone: rules.deadZone) { outside += 1 }
                if i > 0 && !s.isInside(other, deadZone: rules.deadZone) { otherOutside += 1 }
            }
            let inside: (PadDecodedState) -> Bool = { $0.isInside(stick, deadZone: rules.deadZone) }
            let settled = settledMs(inside)
            // Onsets on the pad: leaving the dead zone after 60 ms inside it (the segment 0 state is the one before any move).
            let onsets = DevLatency.onsetIndices(times: times, magnitudes: states.map { s in
                let q = s.position(of: stick); return DevLatency.magnitude(q.x, q.y)
            }, deadZone: rules.deadZone, restMs: rules.onsetRestMs, startArmed: inside(states[0])).filter { $0 > 0 }.count
            m.values = ["\(p).reportsOutside": Double(outside), "\(p).xMin": xMin, "\(p).xMax": xMax,
                        "\(p).yMin": yMin, "\(p).yMax": yMax, "\(p).otherOutside": Double(otherOutside),
                        "\(p).settledMs": settled ?? 0, "\(p).onsets": Double(onsets)]
            var fails: [String] = []
            // A flick step is about how often the stick left rest; its report count is only checked when the step asks.
            let needReports = rules.flicks == nil ? rules.stickMinReports : (input.step.expect?.minReports ?? 0)
            if outside < needReports {
                fails.append("only \(outside) reports with the \(name) stick outside the dead zone (needs \(needReports))")
            }
            if rules.requireDirections {
                var missing: [String] = []
                let e = rules.stickExtent
                if xMax < e { missing.append("x +\(DevJudge.fmt(e)) (reached \(DevJudge.fmt(xMax)))") }
                if xMin > -e { missing.append("x -\(DevJudge.fmt(e)) (reached \(DevJudge.fmt(xMin)))") }
                if yMax < e { missing.append("y +\(DevJudge.fmt(e)) (reached \(DevJudge.fmt(yMax)))") }
                if yMin > -e { missing.append("y -\(DevJudge.fmt(e)) (reached \(DevJudge.fmt(yMin)))") }
                if !missing.isEmpty { fails.append("the \(name) stick never reached " + missing.joined(separator: ", ")) }
            }
            if let want = rules.flicks, onsets < want {
                fails.append("the \(name) stick left the dead zone from rest \(onsets) times (needs \(want) flicks)")
            }
            if rules.otherStickStill && otherOutside > 0 {
                fails.append("the \(other == .left ? "left" : "right") stick moved too (\(otherOutside) reports outside the dead zone)")
            }
            if rules.requireReturn {
                if settled == nil {
                    fails.append("the \(name) stick was still outside the dead zone at the end")
                } else if let s = settled, s < rules.holdMs {
                    fails.append("the \(name) stick had only been at rest for \(Int(s)) ms at the end (needs \(Int(rules.holdMs)))")
                }
            }
            let flickText = rules.flicks.map { " \(onsets) flicks (needs \($0))," } ?? ""
            let summary = "\(name.capitalized) stick:\(flickText) \(outside) reports outside the dead zone, x \(DevJudge.fmt(xMin))…\(DevJudge.fmt(xMax)), y \(DevJudge.fmt(yMin))…\(DevJudge.fmt(yMax)); \(m.padReports) pad reports, \(m.padChanged) changed."
            return finish(fails, passText: summary, summary: summary, &m)
        }

        // MARK: items and triggers (shared by the digital, trigger and held rules)

        /// When each pad item went down and up over the timeline (indices into `states`), the D-pad values seen and the
        /// number of times the pad came to neutral.
        struct ItemTrace {
            var rises: [PadItem: [Int]] = [:]
            var falls: [PadItem: [Int]] = [:]
            var visited = 0
            var neutrals = 0
            var touched: Set<PadItem> { Set(rises.keys).union(falls.keys) }
        }

        func trace(rules: Rules) -> ItemTrace {
            var t = ItemTrace()
            var prev = states[0].items
            t.visited = 1 << Int(states[0].hat)
            var wasNeutral = states[0].isNeutral(deadZone: rules.deadZone, triggerMax: rules.triggerRelease)
            for i in 1..<max(count, 1) {
                let s = states[i]
                t.visited |= 1 << Int(s.hat)
                let cur = s.items
                for item in cur.subtracting(prev) { t.rises[item, default: []].append(i) }
                for item in prev.subtracting(cur) { t.falls[item, default: []].append(i) }
                prev = cur
                let n = s.isNeutral(deadZone: rules.deadZone, triggerMax: rules.triggerRelease)
                if n && !wasNeutral { t.neutrals += 1 }
                wasNeutral = n
            }
            return t
        }

        /// One trigger over the timeline: its highest value, the full pulls (up to `peak`, then back to `release`), and how
        /// long it has been released at the end (nil = still pulled).
        func pulls(of trig: PadTrigger, rules: Rules) -> (peak: Double, pulls: Int, settledMs: Double?) {
            let peak = states.map { $0.value(of: trig) }.max() ?? 0
            let low: (PadDecodedState) -> Bool = { $0.value(of: trig) <= rules.triggerRelease }
            var n = 0
            var peaked = false
            for s in states {
                let v = s.value(of: trig)
                if v >= rules.triggerPeak { peaked = true } else if v <= rules.triggerRelease && peaked { n += 1; peaked = false }
            }
            return (peak, n, settledMs(low))
        }

        /// The trigger part of a step that pulls pad triggers: each expected trigger reaches `triggerPeak` and comes back
        /// `times` times, and the other one stays still.
        func triggerFails(_ expected: [PadTrigger], times: Int, rules: Rules, values: inout [String: Double]) -> (fails: [String], text: String) {
            var fails: [String] = []
            var parts: [String] = []
            for trig in [PadTrigger.left, .right] {
                let name = trig == .left ? "LT" : "RT"
                let key = trig == .left ? "lt" : "rt"
                let p = pulls(of: trig, rules: rules)
                values["\(key).peak"] = p.peak
                values["\(key).settledMs"] = p.settledMs ?? 0
                values["\(key).pulls"] = Double(p.pulls)
                if expected.contains(trig) {
                    if p.peak < rules.triggerPeak {
                        fails.append("\(name) only reached \(DevJudge.fmt(p.peak)) (needs \(DevJudge.fmt(rules.triggerPeak)))")
                    } else if times > 1 && p.pulls < times {
                        fails.append("\(name) was pulled to \(DevJudge.fmt(rules.triggerPeak)) and released \(p.pulls) times (needs \(times))")
                    }
                    if p.settledMs == nil {
                        fails.append("\(name) was still above \(DevJudge.fmt(rules.triggerRelease)) at the end")
                    } else if let s = p.settledMs, s < rules.holdMs {
                        fails.append("\(name) had only been released for \(Int(s)) ms at the end (needs \(Int(rules.holdMs)))")
                    }
                    parts.append("\(name) peak \(DevJudge.fmt(p.peak))" + (times > 1 ? ", \(p.pulls) full pulls (needs \(times))" : ""))
                } else if !expected.isEmpty, p.peak > rules.triggerRelease {
                    let wanted = expected.map { $0 == .left ? "LT" : "RT" }.joined(separator: " and ")
                    fails.append("\(name) moved although only \(wanted) was expected (reached \(DevJudge.fmt(p.peak)))")
                }
            }
            return (fails, parts.joined(separator: "; "))
        }

        /// The pad items that changed although the step did not ask for them. `allowed` is what it expects and what it
        /// holds in the background.
        func unexpectedFail(_ tr: ItemTrace, allowed: Set<PadItem>) -> (items: Set<PadItem>, fail: String?) {
            let unexpected = tr.touched.subtracting(allowed)
            guard !unexpected.isEmpty else { return ([], nil) }
            return (unexpected, "unexpected change on " + unexpected.sorted().map(\.ownerName).joined(separator: ", "))
        }

        /// `background` items: pressed first, let go last. Per item B: not set at the window start (then it must come up
        /// exactly once, before the first rise of every expected item) or set there with no rise; it must not fall before
        /// the last fall of every expected item. Nothing later counts: the window may end first.
        func backgroundFails(_ background: Set<PadItem>, expected: Set<PadItem>, tr: ItemTrace) -> [String] {
            var fails: [String] = []
            let firstExpectedRise = expected.compactMap { tr.rises[$0]?.first }.min()
            // The expected item that was let go last names the press in the message.
            let lastExpected = expected.compactMap { item in tr.falls[item]?.last.map { (item, $0) } }.max { $0.1 < $1.1 }
            for b in background.sorted() {
                let rises = tr.rises[b] ?? [], falls = tr.falls[b] ?? []
                let setAtStart = states[0].items.contains(b)
                // Let go while the expected item was still being pressed: the failure the step is about.
                if let (e, last) = lastExpected {
                    let early = falls.filter { $0 < last }.count
                    if early > 0 {
                        fails.append("\(b.ownerName) dropped while \(e.ownerName) was being pressed (fell \(early) time\(early == 1 ? "" : "s") before the last \(e.ownerName) release)")
                        continue
                    }
                }
                if setAtStart ? !rises.isEmpty : rises.count != 1 {
                    fails.append("\(b.ownerName) went down \(rises.count + (setAtStart ? 1 : 0)) times (needs 1)")
                    continue
                }
                if !setAtStart, let first = rises.first, let early = firstExpectedRise, first > early, let e = lastExpected?.0 ?? expected.sorted().first {
                    fails.append("\(b.ownerName) came up after \(e.ownerName)")
                }
            }
            return fails
        }

        // MARK: trigger

        func judgeTrigger(_ input: Input, rules: Rules, metrics m: inout DevMetrics) -> Outcome {
            let cid = input.step.controls.first
            // The pad trigger the control is mapped to (LT sent to RT judges RT); with nothing worked out, its own.
            var expectedTriggers = input.expected.triggers
            if expectedTriggers.isEmpty && input.expected.items.isEmpty {
                guard let own: PadTrigger = cid == "lt" ? .left : (cid == "rt" ? .right : nil) else {
                    return Outcome(verdict: .inconclusive("the step names no trigger"), metrics: with(&m, "A trigger step needs lt or rt as its control."))
                }
                expectedTriggers = [own]
            }
            let allowed = input.expected.items.union(input.background)
            let tr = trace(rules: rules)
            var values: [String: Double] = [:]
            var (fails, text) = triggerFails(expectedTriggers, times: rules.triggerTimes, rules: rules, values: &values)
            // A trigger pull that is sent to a button presses it as often as the pull.
            if !input.expected.items.isEmpty {
                for item in input.expected.items.sorted() {
                    let r = tr.rises[item]?.count ?? 0, f = tr.falls[item]?.count ?? 0
                    if r < rules.triggerTimes || f < rules.triggerTimes {
                        fails.append("\(item.ownerName) went down \(r) and up \(f) times (needs \(rules.triggerTimes))")
                    } else if last.items.contains(item) {
                        fails.append("\(item.ownerName) was still down at the end")
                    }
                }
                text += (text.isEmpty ? "" : "; ") + input.expected.items.sorted().map(\.ownerName).joined(separator: ", ")
            }
            let (unexpected, unexpectedText) = unexpectedFail(tr, allowed: allowed)
            if let unexpectedText { fails.append(unexpectedText) }
            fails += backgroundFails(input.background, expected: input.expected.items, tr: tr)
            values["unexpected"] = Double(unexpected.count)
            m.values = values
            let summary = "\(text); \(m.padReports) pad reports, \(m.padChanged) changed."
            return finish(fails, passText: summary, summary: summary, &m)
        }

        // MARK: digital

        func judgeDigital(_ input: Input, entry: PadDecodedState, rules: Rules, metrics m: inout DevMetrics) -> Outcome {
            if input.builtInEcho { return judgeBuiltInEcho(input, rules: rules, metrics: &m) }
            let expected = input.expected.items
            let tr = trace(rules: rules)
            let rises = tr.rises.mapValues(\.count), falls = tr.falls.mapValues(\.count)
            let (unexpected, unexpectedText) = unexpectedFail(tr, allowed: expected.union(input.background))
            let entryHeld = expected.intersection(entry.items)
            let minRises = expected.isEmpty ? rises.values.reduce(0, +) : (expected.map { rises[$0] ?? 0 }.min() ?? 0)
            let minFalls = expected.isEmpty ? falls.values.reduce(0, +) : (expected.map { falls[$0] ?? 0 }.min() ?? 0)
            m.values = ["bit.rises": Double(minRises), "bit.falls": Double(minFalls), "hat.visited": Double(tr.visited),
                        "neutrals": Double(tr.neutrals), "unexpected": Double(unexpected.count),
                        "entrySet": entryHeld.isEmpty ? 0 : 1]

            var fails: [String] = []
            let times = rules.digitalTimes
            for item in expected.sorted() {
                let r = rises[item] ?? 0, f = falls[item] ?? 0
                if r < times || f < times {
                    var why = "\(item.ownerName) went down \(r) and up \(f) times (needs \(times))"
                    if entryHeld.contains(item) { why += ", bit already set at step start" }
                    fails.append(why)
                } else if last.items.contains(item) {
                    fails.append("\(item.ownerName) was still down at the end")
                }
            }
            if let unexpectedText { fails.append(unexpectedText) }
            fails += backgroundFails(input.background, expected: expected, tr: tr)
            // Pad triggers the step pulls: one full pull per press, the other trigger still.
            var triggerText = ""
            if !input.expected.triggers.isEmpty {
                let t = triggerFails(input.expected.triggers, times: times, rules: rules, values: &m.values)
                fails += t.fails
                triggerText = t.text
            }
            if input.expected.isEmpty {
                let quiet: (PadDecodedState) -> Bool = { $0.sticksInside(deadZone: rules.deadZone) && $0.triggersBelow(rules.triggerRelease) }
                if let bad = states.first(where: { !quiet($0) }) {
                    fails.append("an axis moved although nothing was expected (\(DevJudge.describeOffences(bad, rules: rules)))")
                }
            }
            var summary: String
            if input.expected.isEmpty {
                summary = "Nothing was expected on the pad; \(m.padReports) pad reports, \(m.padChanged) changed."
            } else {
                var head = input.expected.summary
                if !expected.isEmpty { head += ": down \(minRises) and up \(minFalls) times (needs \(times))" }
                if !triggerText.isEmpty { head += (expected.isEmpty ? ": " : "; ") + triggerText }
                summary = "\(head); \(m.padReports) pad reports, \(m.padChanged) changed."
            }
            if !input.background.isEmpty {
                summary = input.background.sorted().map(\.ownerName).joined(separator: " and ") + " held throughout; " + summary
            }
            if !entryHeld.isEmpty { summary += " Bit already set at step start." }
            return finish(fails, passText: summary, summary: summary, &m)
        }

        // MARK: builtInEcho

        /// One untouched paddle or SAX key: each press must bring exactly one pad item (a button, a D-pad direction or a
        /// trigger pull), the same item every time, and the result names it. A key for which the controller sent nothing
        /// cannot be judged: that is not a failure.
        func judgeBuiltInEcho(_ input: Input, rules: Rules, metrics m: inout DevMetrics) -> Outcome {
            func tokens(_ s: PadDecodedState) -> Set<String> {
                var t = Set(s.items.map(\.ownerName))
                if s.lt >= 0.5 { t.insert("LT") }
                if s.rt >= 0.5 { t.insert("RT") }
                return t
            }
            let order = PadItem.allCases.map(\.ownerName) + ["LT", "RT"]
            func sorted(_ t: Set<String>) -> [String] { t.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) } }
            var presses: [Set<String>] = []
            var run: Set<String>?
            for s in states {
                let t = tokens(s)
                if t.isEmpty {
                    if let r = run { presses.append(r); run = nil }
                } else {
                    run = (run ?? []).union(t)
                }
            }
            let stillDown = run != nil
            if let r = run { presses.append(r) }
            let tr = trace(rules: rules)
            m.values = ["bit.rises": Double(presses.count), "bit.falls": Double(presses.count - (stillDown ? 1 : 0)),
                        "hat.visited": Double(tr.visited), "neutrals": Double(tr.neutrals), "unexpected": 0, "entrySet": 0]
            guard !presses.isEmpty else {
                return Outcome(verdict: .inconclusive("cannot judge: the controller sent no button for this key"),
                               metrics: with(&m, "The controller sent no button for this key, so there is no echo to judge. \(m.padReports) pad reports, \(m.padChanged) changed."))
            }
            var fails: [String] = []
            for (i, p) in presses.enumerated() where p.count != 1 {
                fails.append("press \(i + 1) showed \(p.count) pad items (\(sorted(p).joined(separator: ", "))), needs exactly one")
            }
            let single = presses.filter { $0.count == 1 }.map { sorted($0)[0] }
            let distinct = single.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if distinct.count > 1 { fails.append("the key showed different items on different presses (\(distinct.joined(separator: ", then ")))") }
            if presses.count < rules.digitalTimes {
                fails.append("only \(presses.count) press\(presses.count == 1 ? "" : "es") showed an item (needs \(rules.digitalTimes))")
            }
            if stillDown { fails.append("\(sorted(run ?? []).joined(separator: ", ")) was still down at the end") }
            if let bad = states.first(where: { !$0.sticksInside(deadZone: rules.deadZone) }) {
                fails.append("an axis moved although nothing was expected (\(DevJudge.describeOffences(bad, rules: rules)))")
            }
            let named = distinct.joined(separator: ", ")
            let summary = "Saw \(named) on each press (\(presses.count) press\(presses.count == 1 ? "" : "es"), one item per press); \(m.padReports) pad reports, \(m.padChanged) changed."
            var out = finish(fails, passText: summary, summary: summary, &m)
            out.echoItem = distinct.joined(separator: ", then ")
            return out
        }

        // MARK: held

        func judgeHeld(_ input: Input, rules: Rules, metrics m: inout DevMetrics) -> Outcome {
            guard let targets = DevExpectation.heldTargets(step: input.step, expected: input.expected) else {
                return Outcome(verdict: .inconclusive("unknown item \"\(input.step.expect?.item ?? "")\""),
                               metrics: with(&m, "The step's expect.item is not a name this build knows."))
            }
            guard !targets.isEmpty else {
                return Outcome(verdict: .inconclusive("nothing on the pad to hold"),
                               metrics: with(&m, "The step's controls produce nothing on the pad (a G key or Profile, say), so there is nothing to hold; name an item in expect.item."))
            }
            let label = targets.map(\.name).joined(separator: " + ")
            let level = rules.heldMinLevel
            let held: (PadDecodedState) -> Bool = { s in
                targets.allSatisfy { $0.isHeld(s, minLevel: level) }
                    && !s.isNeutral(deadZone: rules.deadZone, triggerMax: rules.triggerRelease)
            }
            let triggers: [PadTrigger] = targets.compactMap { if case .trigger(let t) = $0 { return t } else { return nil } }
            // "Lowest" starts once the trigger has been all the way down (the pull in is not a dip).
            func lowest(from engage: Int) -> Double? {
                guard !triggers.isEmpty else { return nil }
                let level: (PadDecodedState) -> Double = { s in triggers.map { s.value(of: $0) }.min() ?? 1 }
                let from = states.indices.first { $0 >= engage && level(states[$0]) >= rules.triggerPeak } ?? engage
                return states[from...].map(level).min()
            }
            let windowMs = Double(endNs &- times[0]) / 1e6

            // The window opens on the first movement, so the item is still on its way up: it counts as held from the
            // first moment it is, which must come within the engage allowance.
            guard let engage = states.indices.first(where: { held(states[$0]) }) else {
                let best = triggers.isEmpty ? nil : states.map { s in triggers.map { s.value(of: $0) }.min() ?? 1 }.max()
                m.values = ["held.minLevel": best ?? 0, "held.drops": 0, "held.padReports": Double(m.padReports), "held.ms": 0]
                let how = best.map { " (highest \(DevJudge.fmt($0)), needs \(DevJudge.fmt(level)))" } ?? ""
                return finish(["\(label) never became held in the window\(how)"], passText: "",
                              summary: "\(m.padReports) pad reports, \(m.padChanged) changed.", &m)
            }
            // A release that ends within heldMaxBlipMs is a switch blip (the design's switch neutral, reposted at once); a
            // longer one, or one that lasts to the end of the window, is a drop.
            var drops = 0, blips = 0
            var firstDropNs: UInt64?
            var finalDropNs: UInt64?                // a let-go that never comes back before the window ends
            var longestMs = 0.0
            for i in (engage + 1)..<max(count, engage + 1) where held(states[i - 1]) && !held(states[i]) {
                let back = states.indices.first { $0 > i && held(states[$0]) }
                let lengthMs = Double((back.map { times[$0] } ?? endNs) &- times[i]) / 1e6
                longestMs = max(longestMs, lengthMs)
                if back != nil && lengthMs <= rules.heldMaxBlipMs { blips += 1; continue }
                drops += 1
                if firstDropNs == nil { firstDropNs = times[i] }
                if back == nil { finalDropNs = times[i] }
            }
            let engageMs = Double(times[engage] - times[0]) / 1e6
            let heldMs = Double(endNs &- times[engage]) / 1e6
            let low = lowest(from: engage)
            m.values = ["held.minLevel": low ?? (drops == 0 ? 1 : 0), "held.drops": Double(drops), "held.blips": Double(blips),
                        "held.longestReleaseMs": longestMs, "held.padReports": Double(m.padReports), "held.ms": heldMs]

            var fails: [String] = []
            var dropFailIndex: Int?
            if drops > 0 {
                dropFailIndex = 0
                let first = firstDropNs.map { String(format: ", first at %.2f s", Double($0 - times[0]) / 1e6 / 1000) } ?? ""
                fails.append("\(label) did not stay held: drops \(drops)\(first)" + (low.map { ", lowest \(DevJudge.fmt($0))" } ?? ""))
            } else if !held(last) {
                fails.append("\(label) was not held at the end of the window")
            }
            if engageMs > rules.heldEngageMs {
                fails.append("\(label) only became held \(String(format: "%.1f", engageMs / 1000)) s into the window (allowed \(String(format: "%.1f", rules.heldEngageMs / 1000)) s)")
            }
            // `expect.releases`: each listed control must be seen pressed and then let go while the item is held.
            let wanted = (input.step.expect?.releases ?? []).filter { !$0.isEmpty }
            var releasedText = ""
            if !wanted.isEmpty {
                let samples = input.controlActivity.enumerated()
                    .sorted { ($0.element.tNs, $0.offset) < ($1.element.tNs, $1.offset) }.map(\.element)
                    .filter { $0.tNs <= input.windowEndNs }
                var released: [String] = []
                var releaseFails: [String] = []
                var lastLetGoNs: UInt64 = 0
                for id in wanted {
                    let who = DevJudge.controlWord(id)
                    let engageNs = times[engage]
                    // Armed once the control is down while the item is held; the next sample without it is the let-go.
                    var armed = samples.last { $0.tNs <= engageNs }?.active.contains(id) ?? false
                    var done = false
                    for s in samples where s.tNs > engageNs {
                        if s.active.contains(id) { armed = true } else if armed { done = true; lastLetGoNs = max(lastLetGoNs, s.tNs); break }
                    }
                    if done { released.append(who); continue }
                    releaseFails.append(samples.contains { $0.active.contains(id) }
                                        ? "\(who) was never let go while \(label) stayed held"
                                        : "\(who) was never seen pressed while \(label) stayed held")
                }
                m.values["held.released"] = Double(released.count)
                if samples.isEmpty && fails.isEmpty {
                    return Outcome(verdict: .inconclusive("cannot tell when \(wanted.map(DevJudge.controlWord).joined(separator: ", ")) was let go: no receiver frames"),
                                   metrics: with(&m, "The run has no receiver frames for this window, so the let-go of \(wanted.map(DevJudge.controlWord).joined(separator: ", ")) cannot be judged."))
                }
                // The step's goal is the hand-over: once every listed control has been let go and the item stayed held for
                // `heldAfterReleaseMs` more, the owner letting go of everything before the window runs out is the end of the
                // step, not a drop. "The owner let go" is read from the receiver: no control of the step is down in the
                // last frame before the pad dropped the item (a pad that drops it while a button is still down stays a drop).
                let handsOff: (UInt64) -> Bool = { t in
                    guard let s = samples.last(where: { $0.tNs <= t &+ 2_000_000 }) else { return false }
                    return s.active.isDisjoint(with: Set(input.step.controls).union(wanted))
                }
                if releaseFails.isEmpty, released.count == wanted.count, drops == 1, let end = finalDropNs,
                   end >= lastLetGoNs &+ UInt64(DevJudge.heldAfterReleaseMs * 1e6), handsOff(end), let i = dropFailIndex {
                    fails.remove(at: i)
                    m.values["held.endedEarlyMs"] = Double(endNs &- end) / 1e6
                }
                if !samples.isEmpty { fails += releaseFails }
                if !released.isEmpty { releasedText = "; \(released.joined(separator: ", ")) let go while \(label) stayed held" }
            }
            // Nothing else may change on the pad while the item is held (a button the step did not ask for), and a
            // `background` item has to stay where it is.
            let tr = trace(rules: rules)
            let (unexpected, unexpectedText) = unexpectedFail(tr, allowed: input.expected.items.union(input.background))
            if let unexpectedText { fails.append(unexpectedText) }
            fails += backgroundFails(input.background, expected: input.expected.items, tr: tr)
            m.values["unexpected"] = Double(unexpected.count)
            let overs = input.handOvers > 0 ? " through \(input.handOvers) hand-over\(input.handOvers == 1 ? "" : "s")" : ""
            let lowText = low.map { "; lowest \(DevJudge.fmt($0))" } ?? ""
            let blipText = blips > 0 ? String(format: "; %d switch blip%@ of at most %.2f ms (the design's switch neutral, reposted at once)", blips, blips == 1 ? "" : "s", longestMs) : ""
            let pass = "\(label) stayed held for \(String(format: "%.1f", heldMs / 1000)) s\(overs)\(lowText)\(blipText)\(releasedText); \(m.padReports) pad reports."
            let summary = "\(label) held \(String(format: "%.1f", heldMs / 1000)) s of a \(String(format: "%.1f", windowMs / 1000)) s window\(overs)\(lowText)\(blipText)\(releasedText); \(m.padReports) pad reports, \(m.padChanged) changed."
            return finish(fails, passText: pass, summary: summary, &m)
        }

        // MARK: shared

        private func finish(_ fails: [String], passText: String, summary: String, _ m: inout DevMetrics) -> Outcome {
            var detail = fails.isEmpty ? passText : fails.joined(separator: "; ") + ". " + summary
            if let expectedChanges = m.expectedChanges, expectedChanges > 0, m.padChanged == 0 {
                detail += " The receiver changed \(expectedChanges) times and the pad never did."
            }
            if fails.isEmpty { return Outcome(verdict: .pass, metrics: with(&m, detail)) }
            return Outcome(verdict: .fail(fails.joined(separator: "; ")), metrics: with(&m, detail))
        }

        private func with(_ m: inout DevMetrics, _ detail: String) -> DevMetrics {
            m.detail = detail
            return m
        }
    }

    // MARK: Hiding the controller's own button

    /// What the run saw of the remapped paddle and SAX keys of one step. Built by the runner from the echo filter it steps
    /// on every receiver report, and from the receiver reports the step kept (`recordReceiver`).
    struct HidingEvidence: Equatable {
        enum Found: String, Equatable { case seen, confirmed, other, unconfirmed }

        /// One press of a remapped key.
        struct Hold: Equatable {
            /// The key's control id.
            var control: String
            /// Index of the receiver report of the press, and of the first report after the key was let go (nil = still held
            /// at the end of the step).
            var pressN: Int
            var releaseN: Int?
            /// The item the filter read for the key (1...14, `EchoParams`' codes) and how it found it.
            var code: UInt8
            var found: Found
            /// D-pad directions (item bits 10...13) the pad showed during the hold that the controller did not send.
            var recovered: UInt16 = 0
        }

        /// The remapped keys of the step.
        var keys: [String]
        var holds: [Hold]
        /// The receiver reports the step kept, in order: their index and their raw items (`EchoFilter.items(word: 0, ...)`:
        /// bits 0...9 buttons, 10...13 directions, a diagonal two of them). A report not kept equals the one before it.
        var reports: [Report]

        struct Report: Equatable {
            var n: Int
            var items: UInt16
        }
    }

    /// The pad item of a filter item code (1...10 receiver buttons A...R3, 11...14 D-pad up, right, down, left).
    static func padItem(code: UInt8) -> PadItem? {
        switch code {
        case 1...10: return PadItem(rawValue: Int(code) - 1)
        case 11...14: return PadItem(rawValue: Int(code))
        default: return nil
        }
    }

    static func itemName(code: UInt8) -> String { padItem(code: code)?.ownerName ?? "item \(code)" }

    /// The layout's words for the six keys.
    static func keyLabel(_ id: String) -> String {
        let words: [String: String] = ["paddle_outer_right": "Paddle outer right", "paddle_inner_right": "Paddle inner right",
                                       "paddle_inner_left": "Paddle inner left", "paddle_outer_left": "Paddle outer left",
                                       "sax_left": "SAX left", "sax_right": "SAX right"]
        return words[id] ?? id
    }

    static let cannotJudgeUnseen = "the controller's button for this key was not seen at its press (it sent none or several)"
    static func cannotJudgeSame(_ item: String) -> String { "the controller's current profile sends \(item) for this key" }
    static func notExercised(_ item: String) -> String { "the controller sent no \(item) during the hold" }

    /// The hiding claim of a step, press by press: the item the filter read for the key is
    /// - "cannot judge" when the press was not seen (`unconfirmed`), or when the item is what the step expects, a background
    ///   item or the button pressed during the hold: a pass would not show the item was hidden;
    /// - "not exercised" when the raw reports never set it from the press report to the last report before the key was
    ///   let go (a direction counts on its diagonals), as when the controller cancelled it against a held opposite;
    /// - otherwise conclusive: it reached the receiver and never the pad (a leak would already be an unexpected change).
    /// A key is conclusive with one conclusive press. nil when the step has no press of a remapped key.
    static func judgeHiding(_ evidence: HidingEvidence, expected: Set<PadItem>, background: Set<PadItem>) -> DevHiding? {
        func exercised(_ h: HidingEvidence.Hold) -> Bool {
            let mask = EchoFilter.mask(h.code)
            guard mask != 0 else { return false }
            // The report in force at the press report counts, then every kept report up to the release.
            if let inForce = evidence.reports.last(where: { $0.n <= h.pressN }), inForce.items & mask != 0 { return true }
            return evidence.reports.contains { $0.n > h.pressN && $0.n < (h.releaseN ?? Int.max) && $0.items & mask != 0 }
        }
        var presses: [DevHiding.Press] = []
        for h in evidence.holds where evidence.keys.contains(h.control) {
            var p = DevHiding.Press()
            p.control = h.control
            p.press = h.pressN
            p.item = itemName(code: h.code)
            p.found = h.found.rawValue
            if h.found == .unconfirmed {
                p.result = "cannot judge"; p.reason = cannotJudgeUnseen
            } else if let item = padItem(code: h.code), expected.contains(item) || background.contains(item) {
                p.result = "cannot judge"; p.reason = cannotJudgeSame(p.item)
            } else if !exercised(h) {
                p.result = "not exercised"; p.reason = notExercised(p.item)
            } else {
                p.result = "hidden"
            }
            presses.append(p)
        }
        guard !presses.isEmpty else { return nil }

        // One sentence per key: conclusive with one conclusive press, else the commonest reason (unseen first).
        var parts: [(key: String, conclusive: Bool, text: String, item: String)] = []
        for key in evidence.keys where presses.contains(where: { $0.control == key }) {
            let mine = presses.filter { $0.control == key }
            let item = mine.first(where: { $0.result == "hidden" })?.item ?? mine[0].item
            if mine.contains(where: { $0.result == "hidden" }) {
                let recovered = evidence.holds.filter { $0.control == key }.reduce(UInt16(0)) { $0 | $1.recovered }
                var text = "pass (\(item) seen on the receiver, never on the pad)"
                if recovered != 0, let dir = (10...13).first(where: { recovered >> UInt16($0) & 1 == 1 }) {
                    let shown = itemName(code: UInt8(dir + 1))
                    text = "pass (\(item) was seen on the receiver before \(shown); the pad showed \(shown) while the controller sent no direction)"
                }
                parts.append((key, true, text, item))
            } else {
                let worst = mine.first(where: { $0.reason == cannotJudgeUnseen })
                    ?? mine.first(where: { $0.result == "cannot judge" }) ?? mine[0]
                let text = worst.result == "cannot judge" ? "cannot judge: \(worst.reason)" : "not exercised (\(worst.reason))"
                parts.append((key, false, text, item))
            }
        }
        let conclusive = parts.allSatisfy(\.conclusive)
        var line: String
        if conclusive, parts.count > 1, parts.allSatisfy({ $0.text.hasPrefix("pass (") && !$0.text.contains(" before ") }) {
            line = "controller's own button hidden: pass (\(parts.map(\.item).joined(separator: " and ")) seen on the receiver, never on the pad)"
        } else if parts.count == 1 {
            line = "controller's own button hidden: \(parts[0].text)"
        } else {
            line = "controller's own button hidden: " + parts.map { "\(keyLabel($0.key)): \($0.text)" }.joined(separator: "; ")
        }
        return DevHiding(conclusive: conclusive, line: line, presses: presses)
    }

    // MARK: Words

    /// The Expected column of a held step: what has to stay held.
    static func heldSummary(step: DevStep, expected: DevExpectedItems) -> String {
        let level = step.expect?.minLevel ?? Rules().heldMinLevel
        guard let targets = DevExpectation.heldTargets(step: step, expected: expected), !targets.isEmpty else { return "nothing to hold" }
        return targets.map { $0.isTrigger ? "\($0.name) held ≥ \(fmt(level))" : "\($0.name) held" }.joined(separator: ", ")
    }

    static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    /// With `expect.releases`: how long the item must stay held after the last listed control was let go.
    static let heldAfterReleaseMs = 500.0

    /// A control id as the owner says it in a verdict: "g1" → "G1", "paddle_outer_left" → "paddle outer left".
    static func controlWord(_ id: String) -> String {
        id.count <= 3 ? id.uppercased() : id.replacingOccurrences(of: "_", with: " ")
    }

    /// What is out of tolerance in one state, in words ("A down, left stick at 0.31").
    static func describeOffences(_ s: PadDecodedState, rules: Rules) -> String {
        var parts: [String] = s.items.sorted().map { "\($0.name) down" }
        for stick in [PadStick.left, .right] where !s.isInside(stick, deadZone: rules.deadZone) {
            let p = s.position(of: stick)
            parts.append("\(stick.rawValue) stick at \(fmt((p.x * p.x + p.y * p.y).squareRoot()))")
        }
        for trig in [PadTrigger.left, .right] where s.value(of: trig) > rules.triggerRelease {
            parts.append("\(trig == .left ? "LT" : "RT") at \(fmt(s.value(of: trig)))")
        }
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }
}
