import Foundation

struct LearnProgress: Equatable {
    var current: Int
    var total: Int
    var text: String { "\(current) of \(total)" }
}

/// The learn guard's decision, pure so it can be tested without a session (remap plan, "Learn guard").
enum LearnGuard {
    /// The result line when `assignment` would take another control's binding, else nil. `label` maps a control id to its
    /// layout label.
    static func refusal(mapping: ControlMapping, assignment: LearnAssignment, label: (String) -> String) -> String? {
        // A paddle or SAX key learned with another one's signal (the wrong key was pressed): refused before anything else.
        if let other = mapping.learnSignalOwner(assignment) {
            return "That was \(label(other))'s signal: press \(label(assignment.controlId)) itself."
        }
        guard let owner = mapping.learnConflict(assignment) else { return nil }
        let o = label(owner), c = label(assignment.controlId)
        return "That is \(o)'s button. To make \(c) send \(o) use Mapping \u{2192} \(o)."
    }
}

/// Learn algorithm: docs/ARCHITECTURE.md. Fed every frame by the device.
@MainActor
final class LearnSession: ObservableObject {
    enum Mode { case guided, single }

    private struct Step {
        var control: ControlLayout.Control
        var target: LearnTarget
        var controlIndex: Int
    }

    // Thresholds (activity detection, same as the proven mapwalk tool).
    private let axisActivity = 4000
    private let triggerActivity = 80
    private let settleTime: TimeInterval = 0.5
    private let maxStepTime: TimeInterval = 8
    private let maxStickStepTime: TimeInterval = 15
    /// An axis must travel at least this far from its baseline to count as part of the stick.
    private let stickAxisTravel = 8000

    @Published private(set) var currentControl: ControlLayout.Control?
    @Published private(set) var instruction: String = ""
    @Published private(set) var progress: LearnProgress
    @Published private(set) var lastResult: String = ""
    @Published private(set) var isCollecting = false
    @Published private(set) var isFinished = false
    /// True when there is a previous step to return to.
    @Published private(set) var canGoBack = false
    /// Circle capture: one flag per 10-degree sector, true once the stick has been there at the edge.
    /// Empty when the current step is not a stick rotation.
    @Published private(set) var circleCovered: [Bool] = []
    static let circleSectors = 36
    /// Deflection (int16 units) that counts as "at the edge" for the circle capture.
    private let circleEdge = 14000
    private var baseInstruction = ""
    /// Sector of the previous edge sample, so the arc between samples is marked too (fast rotations).
    private var lastCircleSector: Int?

    var circlePercent: Int {
        guard !circleCovered.isEmpty else { return 0 }
        return circleCovered.filter { $0 }.count * 100 / circleCovered.count
    }

    let mode: Mode
    private let steps: [Step]
    private var stepIndex = 0
    private let onAssign: (LearnAssignment) -> Void
    private let onFinish: () -> Void
    /// Single-control learn only: returns a result line when the assignment must not be applied (see `LearnGuard`).
    private let refusal: ((LearnAssignment) -> String?)?

    private var baseline: GamepadFrame
    private var lastFrame: GamepadFrame
    private var startedAt = Date()
    private var lastActive = Date()

    // Accumulators for the current step.
    private var risenButtons: [Int] = []      // 1-based, in order of appearance
    private var risenExtra: UInt16 = 0
    private var hatCounts: [UInt8: Int] = [:]
    /// Single D-pad directions (item bits 10...13: up, right, down, left) that changed against the baseline, and in how many frames.
    private var hatDirections: [Int: Int] = [:]
    private var peakDelta: [String: Int] = [:] // field -> signed delta with largest magnitude
    private var axisMin: [String: Int] = [:]   // raw extremes seen during a circle capture
    private var axisMax: [String: Int] = [:]

    init(controls: [ControlLayout.Control], mode: Mode, baseline: GamepadFrame,
         refusal: ((LearnAssignment) -> String?)? = nil,
         onAssign: @escaping (LearnAssignment) -> Void, onFinish: @escaping () -> Void) {
        self.mode = mode
        self.refusal = mode == .single ? refusal : nil          // guided "Learn all" is never refused
        self.baseline = baseline
        self.lastFrame = baseline
        self.onAssign = onAssign
        self.onFinish = onFinish
        var steps: [Step] = []
        for (i, c) in controls.enumerated() {
            if c.kind == .stick {
                steps.append(Step(control: c, target: .stickCircle, controlIndex: i))
            } else {
                steps.append(Step(control: c, target: .whole, controlIndex: i))
            }
        }
        self.steps = steps
        self.progress = LearnProgress(current: steps.isEmpty ? 0 : 1, total: controls.count)
        if steps.isEmpty {
            isFinished = true
        } else {
            enterStep()
        }
    }

    // MARK: Control

    func skip() {
        guard !isFinished else { return }
        lastResult = "\(steps[stepIndex].control.label): skipped"
        advance()
    }

    /// Return to the previous step so it can be learned again; its new result replaces the old one.
    func back() {
        guard !isFinished, stepIndex > 0 else { return }
        stepIndex -= 1
        isCollecting = false
        lastResult = "Back to \(steps[stepIndex].control.label)"
        enterStep()
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        instruction = "Cancelled"
        isCollecting = false
        onFinish()
    }

    /// Call for every frame (any rate).
    func feed(_ frame: GamepadFrame, now: Date = Date()) {
        lastFrame = frame
        guard !isFinished else { return }
        let quiet = isNear(frame, baseline)
        if !isCollecting {
            if quiet { return }
            isCollecting = true
            startedAt = now
            lastActive = now
            risenButtons = []
            risenExtra = 0
            hatCounts = [:]
            hatDirections = [:]
            peakDelta = [:]
            axisMin = [:]
            axisMax = [:]
            instruction = steps[stepIndex].target == .stickCircle
                ? "Keep going round the full circle, then let go"
                : "Got it - now release"
        }
        accumulate(frame)
        if steps[stepIndex].target == .stickCircle { trackCircle(frame) }
        if quiet {
            if now.timeIntervalSince(lastActive) >= settleTime { finishStep() }
        } else {
            lastActive = now
        }
        if isCollecting && now.timeIntervalSince(startedAt) >= stepLimit { finishStep() }
    }

    /// Call periodically so the time limit also applies when frames stop arriving.
    func tick(now: Date = Date()) {
        guard !isFinished, isCollecting else { return }
        if now.timeIntervalSince(startedAt) >= stepLimit { finishStep() }
    }

    private var stepLimit: TimeInterval {
        steps[stepIndex].target == .stickCircle ? maxStickStepTime : maxStepTime
    }

    // MARK: Internals

    private func isNear(_ a: GamepadFrame, _ b: GamepadFrame) -> Bool {
        abs(Int(a.x) - Int(b.x)) < axisActivity && abs(Int(a.y) - Int(b.y)) < axisActivity
            && abs(Int(a.z) - Int(b.z)) < axisActivity && abs(Int(a.rz) - Int(b.rz)) < axisActivity
            && abs(Int(a.lt) - Int(b.lt)) < triggerActivity && abs(Int(a.rt) - Int(b.rt)) < triggerActivity
            && a.hat == b.hat && a.buttons == b.buttons && a.extra == b.extra
    }

    private func accumulate(_ f: GamepadFrame) {
        let newBits = f.buttons & ~baseline.buttons
        if newBits != 0 {
            for bit in 0..<19 where (newBits >> UInt32(bit)) & 1 == 1 && !risenButtons.contains(bit + 1) {
                risenButtons.append(bit + 1)
            }
        }
        // Keep only the first extra bit that rose: a neighbouring paddle brushed later must not merge in.
        if risenExtra == 0 {
            let newExtra = f.extra & ~baseline.extra
            if newExtra != 0 { risenExtra = newExtra & (~newExtra &+ 1) }
        }
        if f.hat != 8 && f.hat != baseline.hat { hatCounts[f.hat, default: 0] += 1 }
        // The D-pad echo of a key, read per axis against the baseline: the one direction that changed, so a key learned while
        // D-pad up is held is stored as right (the controller sends up-right), never as the diagonal; a direction the
        // controller cancelled counts as the opposite (D-pad left held, the key's right cancels it: right).
        if f.hat != baseline.hat {
            let changed = EchoFilter.changed(EchoFilter.items(word: 0, buttons: baseline.buttons, hat: baseline.hat),
                                             EchoFilter.items(word: 0, buttons: f.buttons, hat: f.hat))
            for bit in 10...13 where (changed >> UInt16(bit)) & 1 == 1 { hatDirections[bit, default: 0] += 1 }
        }
        for name in GamepadFrame.axisNames {
            if let v = f.axis(name), let b = baseline.axis(name) {
                recordPeak(name, v - b)
                axisMin[name] = Swift.min(axisMin[name] ?? v, v)
                axisMax[name] = Swift.max(axisMax[name] ?? v, v)
            }
        }
        for name in ["lt", "rt"] {
            if let v = f.trigger(name), let b = baseline.trigger(name) { recordPeak(name, v - b) }
        }
    }

    private func recordPeak(_ name: String, _ delta: Int) {
        if abs(delta) > abs(peakDelta[name] ?? 0) { peakDelta[name] = delta }
    }

    private func finishStep() {
        let step = steps[stepIndex]
        // Extra bits identify only the six paddle and SAX keys; on any other control they are not attached (they are a
        // neighbouring key brushed, or the wrong key, and would tie the control to that key's signal).
        let bits = ControlMapping.identityBits(step.control.id) != 0 ? risenExtra : 0
        var assignment = LearnAssignment(controlId: step.control.id, target: step.target,
                                         binding: nil, physicalBits: bits)
        switch step.control.kind {
        case .button:
            if step.control.id.hasPrefix("dpad_"), let hat = hatCounts.max(by: { $0.value < $1.value })?.key {
                assignment.binding = .hat(hat)
            } else if let first = risenButtons.first {
                assignment.binding = .button(first)
            } else if let dir = hatDirections.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).first?.key {
                assignment.binding = .hat(UInt8((dir - 10) * 2))        // up 0, right 2, down 4, left 6
            }
        case .trigger:
            let best = ["lt", "rt"].compactMap { n in peakDelta[n].map { (n, $0) } }
                .max { abs($0.1) < abs($1.1) }
            if let (name, delta) = best, delta > triggerActivity { assignment.binding = .trigger(name) }
        case .stick:
            if step.target == .stickCircle {
                assignment.stick = circleBinding()
            } else {
                let best = GamepadFrame.axisNames.compactMap { n in peakDelta[n].map { (n, $0) } }
                    .max { abs($0.1) < abs($1.1) }
                if let (name, delta) = best, abs(delta) > axisActivity {
                    assignment.binding = .axis(name, sign: delta < 0 ? -1 : 1)
                }
            }
        }

        let label = step.control.label
        if let s = assignment.stick {
            let desc = (s.ranges ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value.min)...\($0.value.max)" }.joined(separator: ", ")
            lastResult = "\(label): \(desc)"
            if s.horizontal == nil || s.vertical == nil { lastResult += " (only one axis moved; rotate the full circle)" }
        } else if let b = assignment.binding {
            lastResult = "\(label): \(b.summary)" + (assignment.physicalBits != 0 ? " (+ extra bits)" : "")
        } else if assignment.physicalBits != 0 {
            lastResult = "\(label): only extra bits seen (stored as physical bits)"
        } else {
            lastResult = "\(label): nothing usable detected"
        }
        if let line = refusal?(assignment) {
            lastResult = line
        } else if assignment.binding != nil || assignment.physicalBits != 0 || assignment.stick != nil {
            onAssign(assignment)
        }
        advance()
    }

    /// From a full rotation: the two axes that travelled furthest are the stick. By HID convention
    /// X / Z are horizontal and Y / Rz vertical, with right and down positive, so the sign is +1.
    private func circleBinding() -> StickBinding? {
        let travelled = GamepadFrame.axisNames.compactMap { name -> (String, Int)? in
            guard let lo = axisMin[name], let hi = axisMax[name], hi - lo >= stickAxisTravel else { return nil }
            return (name, hi - lo)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(2)
        .map { $0.0 }
        guard !travelled.isEmpty else { return nil }
        var s = StickBinding()
        let horizontalNames = ["x", "z"]
        if let h = travelled.first(where: { horizontalNames.contains($0) }) { s.horizontal = .axis(h, sign: 1) }
        if let v = travelled.first(where: { !horizontalNames.contains($0) }) { s.vertical = .axis(v, sign: 1) }
        if s.horizontal == nil, travelled.count == 1 { s.horizontal = .axis(travelled[0], sign: 1) }
        s.ranges = Dictionary(uniqueKeysWithValues: travelled.map { ($0, AxisRange(min: axisMin[$0] ?? 0, max: axisMax[$0] ?? 0)) })
        return s
    }

    private func advance() {
        stepIndex += 1
        isCollecting = false
        if stepIndex >= steps.count {
            isFinished = true
            canGoBack = false
            instruction = "Done"
            currentControl = nil
            onFinish()
        } else {
            enterStep()
        }
    }

    private func enterStep() {
        let step = steps[stepIndex]
        baseline = lastFrame
        currentControl = step.control
        canGoBack = stepIndex > 0
        circleCovered = step.target == .stickCircle ? Array(repeating: false, count: Self.circleSectors) : []
        lastCircleSector = nil
        progress = LearnProgress(current: step.controlIndex + 1, total: progress.total)
        baseInstruction = Self.instruction(for: step.control, target: step.target)
        instruction = baseInstruction
    }

    /// Marks the sector the stick is currently in. Uses whichever axis pair (x,y) or (z,rz) is
    /// deflected further, so it works before the stick's axes are known.
    private func trackCircle(_ f: GamepadFrame) {
        guard !circleCovered.isEmpty else { return }
        func delta(_ n: String) -> Double { Double((f.axis(n) ?? 0) - (baseline.axis(n) ?? 0)) }
        let a = (dx: delta("x"), dy: delta("y")), b = (dx: delta("z"), dy: delta("rz"))
        let ma = (a.dx * a.dx + a.dy * a.dy).squareRoot(), mb = (b.dx * b.dx + b.dy * b.dy).squareRoot()
        let (dx, dy, m) = ma >= mb ? (a.dx, a.dy, ma) : (b.dx, b.dy, mb)
        guard m >= Double(circleEdge) else { lastCircleSector = nil; return }
        // Screen convention: x right, y down, so this angle runs clockwise from 9 o'clock at 0.
        let angle = atan2(dy, dx) + .pi
        let n = Self.circleSectors
        var sector = Int(angle / (2 * .pi) * Double(n)) % n
        if sector < 0 { sector += n }
        // Mark the sectors passed since the previous sample along the shorter way round, so a quick
        // sweep with few samples still counts every sector it crossed.
        var toMark = [sector]
        if let last = lastCircleSector, last != sector {
            let forward = (sector - last + n) % n, backward = (last - sector + n) % n
            if min(forward, backward) < n / 2 {
                let step = forward <= backward ? 1 : -1
                var s = last
                while s != sector { s = (s + step + n) % n; toMark.append(s) }
            }
        }
        lastCircleSector = sector
        let fresh = toMark.filter { !circleCovered[$0] }
        guard !fresh.isEmpty else { return }
        for s in fresh { circleCovered[s] = true }
        let pct = circlePercent
        if pct >= 100 {
            instruction = "Full circle captured (100%) - let go of the stick"
        } else {
            instruction = "\(baseInstruction) - \(pct)% covered, missing: \(missingDescription())"
        }
    }

    /// Compass description of the sectors not yet visited, e.g. "left, down-left".
    private func missingDescription() -> String {
        let names = ["left", "up-left", "up", "up-right", "right", "down-right", "down", "down-left"]
        var missing: [String] = []
        let per = Self.circleSectors / 8
        for (i, name) in names.enumerated() {
            let slice = circleCovered[(i * per)..<((i + 1) * per)]
            if slice.contains(false) { missing.append(name) }
        }
        return missing.isEmpty ? "nothing" : missing.joined(separator: ", ")
    }

    private static func instruction(for c: ControlLayout.Control, target: LearnTarget) -> String {
        switch c.kind {
        case .button:
            switch c.id {
            case "l3": return "Click the LEFT stick in (L3)"
            case "r3": return "Click the RIGHT stick in (R3)"
            default: return "Press \(c.label)"
            }
        case .trigger:
            return "Pull \(c.label) fully and hold"
        case .stick:
            let side = c.id.hasPrefix("left") ? "LEFT" : "RIGHT"
            switch target {
            case .stickVertical: return "Push the \(side) stick fully DOWN and hold"
            case .stickHorizontal: return "Push the \(side) stick fully RIGHT and hold"
            default: return "Rotate the \(side) stick slowly through a full circle at the edge, then let go"
            }
        }
    }
}
