import Foundation

struct LearnProgress: Equatable {
    var current: Int
    var total: Int
    var text: String { "\(current) of \(total)" }
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

    @Published private(set) var currentControl: ControlLayout.Control?
    @Published private(set) var instruction: String = ""
    @Published private(set) var progress: LearnProgress
    @Published private(set) var lastResult: String = ""
    @Published private(set) var isCollecting = false
    @Published private(set) var isFinished = false
    /// True when there is a previous step to return to.
    @Published private(set) var canGoBack = false

    let mode: Mode
    private let steps: [Step]
    private var stepIndex = 0
    private let onAssign: (LearnAssignment) -> Void
    private let onFinish: () -> Void

    private var baseline: GamepadFrame
    private var lastFrame: GamepadFrame
    private var startedAt = Date()
    private var lastActive = Date()

    // Accumulators for the current step.
    private var risenButtons: [Int] = []      // 1-based, in order of appearance
    private var risenExtra: UInt16 = 0
    private var hatCounts: [UInt8: Int] = [:]
    private var peakDelta: [String: Int] = [:] // field -> signed delta with largest magnitude

    init(controls: [ControlLayout.Control], mode: Mode, baseline: GamepadFrame,
         onAssign: @escaping (LearnAssignment) -> Void, onFinish: @escaping () -> Void) {
        self.mode = mode
        self.baseline = baseline
        self.lastFrame = baseline
        self.onAssign = onAssign
        self.onFinish = onFinish
        var steps: [Step] = []
        for (i, c) in controls.enumerated() {
            if c.kind == .stick {
                steps.append(Step(control: c, target: .stickHorizontal, controlIndex: i))
                steps.append(Step(control: c, target: .stickVertical, controlIndex: i))
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
            peakDelta = [:]
            instruction = "Got it - now release"
        }
        accumulate(frame)
        if quiet {
            if now.timeIntervalSince(lastActive) >= settleTime { finishStep() }
        } else {
            lastActive = now
        }
        if isCollecting && now.timeIntervalSince(startedAt) >= maxStepTime { finishStep() }
    }

    /// Call periodically so the 8 s limit also applies when frames stop arriving.
    func tick(now: Date = Date()) {
        guard !isFinished, isCollecting else { return }
        if now.timeIntervalSince(startedAt) >= maxStepTime { finishStep() }
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
        for name in GamepadFrame.axisNames {
            if let v = f.axis(name), let b = baseline.axis(name) { recordPeak(name, v - b) }
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
        var assignment = LearnAssignment(controlId: step.control.id, target: step.target,
                                         binding: nil, physicalBits: risenExtra)
        switch step.control.kind {
        case .button:
            if step.control.id.hasPrefix("dpad_"), let hat = hatCounts.max(by: { $0.value < $1.value })?.key {
                assignment.binding = .hat(hat)
            } else if let first = risenButtons.first {
                assignment.binding = .button(first)
            } else if let hat = hatCounts.max(by: { $0.value < $1.value })?.key {
                assignment.binding = .hat(hat)
            }
        case .trigger:
            let best = ["lt", "rt"].compactMap { n in peakDelta[n].map { (n, $0) } }
                .max { abs($0.1) < abs($1.1) }
            if let (name, delta) = best, delta > triggerActivity { assignment.binding = .trigger(name) }
        case .stick:
            let best = GamepadFrame.axisNames.compactMap { n in peakDelta[n].map { (n, $0) } }
                .max { abs($0.1) < abs($1.1) }
            if let (name, delta) = best, abs(delta) > axisActivity {
                assignment.binding = .axis(name, sign: delta < 0 ? -1 : 1)
            }
        }

        let label = step.control.label
        if let b = assignment.binding {
            lastResult = "\(label): \(b.summary)" + (risenExtra != 0 ? " (+ extra bits)" : "")
        } else if risenExtra != 0 {
            lastResult = "\(label): only extra bits seen (stored as physical bits)"
        } else {
            lastResult = "\(label): nothing usable detected"
        }
        if assignment.binding != nil || assignment.physicalBits != 0 {
            onAssign(assignment)
        }
        advance()
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
        progress = LearnProgress(current: step.controlIndex + 1, total: progress.total)
        instruction = Self.instruction(for: step.control, target: step.target)
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
            return target == .stickVertical
                ? "Push the \(side) stick fully DOWN and hold"
                : "Push the \(side) stick fully RIGHT and hold"
        }
    }
}
