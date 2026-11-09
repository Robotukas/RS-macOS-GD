import Foundation
import Combine
import os

/// Controller sleep setting as the app presents it.
enum SleepSetting: Hashable {
    case off
    case minutes(Int)

    /// The presets offered in the UI, in display order.
    static let presets: [SleepSetting] = [.off, .minutes(5), .minutes(10), .minutes(15), .minutes(30), .minutes(60)]

    var isPreset: Bool { Self.presets.contains(self) }

    /// Segment / menu label for a preset.
    var presetLabel: String {
        switch self {
        case .off: return "Off"
        case .minutes(let n): return "\(n) min"
        }
    }

    /// What is shown for the value the controller holds ("Custom (N min)" when it is not a preset).
    var displayText: String {
        isPreset ? presetLabel : "Custom (\(minutesValue) min)"
    }

    private var minutesValue: Int {
        if case .minutes(let n) = self { return n }
        return 0
    }

    /// Property writes that apply this setting, in order: (property, value).
    var propertyWrites: [(property: UInt8, value: UInt32)] {
        switch self {
        case .off:
            return [(BragiProperty.sleepEnabled, 0)]
        case .minutes(let n):
            return [(BragiProperty.sleepEnabled, 1), (BragiProperty.sleepTimerMs, UInt32(max(n, 0)) * 60_000)]
        }
    }

    /// Interprets what the controller reports. Timers that are not a whole number of minutes round to nearest.
    static func from(enabled: UInt32, timerMs: UInt32) -> SleepSetting {
        if enabled == 0 { return .off }
        return .minutes(Int((Double(timerMs) / 60_000).rounded()))
    }
}

enum BragiProperty {
    static let mode: UInt8 = 0x03
    static let sleepEnabled: UInt8 = 0x0D
    static let sleepTimerMs: UInt8 = 0x0E
    static let battery: UInt8 = 0x0F
}

enum BragiTarget {
    static let receiver: UInt8 = 0x08
    static let controller: UInt8 = 0x09
}

/// Pure packet encode / decode for the Corsair "Bragi" control channel.
enum BragiPacket {
    static let outputReportID: UInt8 = 0x02
    static let inputReportID: UInt8 = 0x01
    static let reportLength = 64
    static let cmdSet: UInt8 = 0x01
    static let cmdGet: UInt8 = 0x02
    static let statusOK: UInt8 = 0
    static let statusRejected: UInt8 = 9

    struct Reply: Equatable {
        /// Reply source: false = receiver (00), true = controller (01).
        let fromController: Bool
        let echo: UInt8
        let status: UInt8
        let value: UInt32
        var isOK: Bool { status == BragiPacket.statusOK }
    }

    static func get(target: UInt8, property: UInt8) -> [UInt8] {
        frame(target: target, command: [cmdGet, property])
    }

    static func set(target: UInt8, property: UInt8, value: UInt32) -> [UInt8] {
        frame(target: target, command: [cmdSet, property, 0x00] + le32(value))
    }

    /// `02 <target> <command…>` zero-padded to 64 bytes (report ID included).
    static func frame(target: UInt8, command: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: reportLength)
        out[0] = outputReportID
        out[1] = target
        for (i, b) in command.enumerated() where 2 + i < reportLength { out[2 + i] = b }
        return out
    }

    static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// Decodes `01 <00|01> <echo> <status> <value LE…>`; `bytes` includes the report ID.
    static func decode(_ bytes: [UInt8]) -> Reply? {
        guard bytes.count >= 4, bytes[0] == inputReportID, bytes[1] <= 1 else { return nil }
        var value: UInt32 = 0
        for i in 0..<4 where 4 + i < bytes.count { value |= UInt32(bytes[4 + i]) << UInt32(8 * i) }
        return Reply(fromController: bytes[1] == 1, echo: bytes[2], status: bytes[3], value: value)
    }

    /// Does `reply` answer a request sent to `target` with command byte `command`?
    static func matches(_ reply: Reply, target: UInt8, command: UInt8) -> Bool {
        reply.fromController == (target == BragiTarget.controller) && reply.echo == command
    }
}

/// Serial request/response client and published controller state (battery, sleep timer).
@MainActor
final class EnvisionProControl: ObservableObject {
    @Published private(set) var batteryPercent: Double?
    @Published private(set) var sleepSetting: SleepSetting?
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?

    /// Sends a 64-byte output report (ID first). Returns false if there is no control interface or the send failed.
    var send: (([UInt8]) -> Bool)?
    var timeout: TimeInterval = 0.6
    var batteryRefreshInterval: TimeInterval = 60

    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "control")

    private struct Pending {
        let id: Int
        let target: UInt8
        let command: UInt8
        let continuation: CheckedContinuation<BragiPacket.Reply?, Never>
    }

    private var pending: Pending?
    private var nextId = 0
    private var chain: Task<Void, Never>?
    private var queuedOps = 0
    private var isActive = false
    private var refreshTimer: Timer?

    // MARK: Lifecycle

    func statusChanged(_ status: EnvisionProDevice.Status) {
        let active = status == .active
        guard active != isActive else { return }
        isActive = active
        if active {
            Self.log.info("controller active: reading sleep and battery")
            enqueue { await $0.readAll() }
            let t = Timer(timeInterval: batteryRefreshInterval, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshBattery() } }
            }
            RunLoop.main.add(t, forMode: .common)
            refreshTimer = t
        } else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            batteryPercent = nil
            sleepSetting = nil
            lastError = nil
            Self.log.info("controller not active: cleared values")
        }
    }

    /// Routes an input report; returns true if it answered the request in flight.
    func handleInputReport(_ bytes: [UInt8]) -> Bool {
        guard let p = pending, let reply = BragiPacket.decode(bytes),
              BragiPacket.matches(reply, target: p.target, command: p.command) else { return false }
        pending = nil
        p.continuation.resume(returning: reply)
        return true
    }

    // MARK: Public operations

    func refreshBattery() {
        guard isActive else { return }
        enqueue { control in
            if let v = await control.getValue(BragiProperty.battery) { control.setBattery(v) }
        }
    }

    func apply(_ setting: SleepSetting) {
        guard isActive else { return }
        enqueue { await $0.runApply(setting) }
    }

    // MARK: Serialisation

    private func enqueue(_ op: @escaping (EnvisionProControl) async -> Void) {
        queuedOps += 1
        isBusy = true
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await op(self)
            self.queuedOps -= 1
            if self.queuedOps == 0 { self.isBusy = false }
        }
    }

    private func request(target: UInt8, command: [UInt8]) async -> BragiPacket.Reply? {
        let packet = BragiPacket.frame(target: target, command: command)
        return await withCheckedContinuation { cont in
            nextId += 1
            let id = nextId
            pending = Pending(id: id, target: target, command: command[0], continuation: cont)
            guard send?(packet) == true else {
                pending = nil
                cont.resume(returning: nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let p = self.pending, p.id == id else { return }
                    self.pending = nil
                    p.continuation.resume(returning: nil)
                }
            }
        }
    }

    private func getValue(_ property: UInt8) async -> UInt32? {
        guard let r = await request(target: BragiTarget.controller, command: [BragiPacket.cmdGet, property]) else {
            Self.log.error("GET \(property, format: .hex) no reply")
            return nil
        }
        guard r.isOK else {
            Self.log.error("GET \(property, format: .hex) status \(r.status)")
            return nil
        }
        return r.value
    }

    private func setValue(_ property: UInt8, _ value: UInt32) async -> Bool {
        guard let r = await request(target: BragiTarget.controller,
                                    command: [BragiPacket.cmdSet, property, 0x00] + BragiPacket.le32(value)) else {
            Self.log.error("SET \(property, format: .hex)=\(value) no reply")
            return false
        }
        if !r.isOK { Self.log.error("SET \(property, format: .hex)=\(value) rejected, status \(r.status)") }
        return r.isOK
    }

    private func setBattery(_ tenths: UInt32) {
        guard isActive else { return }
        batteryPercent = Double(tenths) / 10
        Self.log.info("battery \(Double(tenths) / 10, format: .fixed(precision: 1))%")
    }

    // MARK: Sequences

    private func readAll() async {
        let enabled = await getValue(BragiProperty.sleepEnabled)
        let timer = await getValue(BragiProperty.sleepTimerMs)
        if let battery = await getValue(BragiProperty.battery) { setBattery(battery) }
        guard isActive else { return }
        if let enabled, let timer {
            let s = SleepSetting.from(enabled: enabled, timerMs: timer)
            sleepSetting = s
            lastError = nil
            Self.log.info("sleep enabled=\(enabled) timer=\(timer) ms -> \(s.displayText, privacy: .public)")
        } else {
            lastError = "Could not read the controller's sleep setting"
        }
    }

    private func runApply(_ setting: SleepSetting) async {
        guard isActive else { return }
        Self.log.info("applying sleep setting \(setting.displayText, privacy: .public)")
        var failure: String?
        if await setValue(BragiProperty.mode, 2) {
            for w in setting.propertyWrites where failure == nil {
                if !(await setValue(w.property, w.value)) { failure = "The controller did not accept the sleep setting" }
            }
        } else {
            failure = "The controller did not accept the change"
        }
        // Always return to hardware mode, retrying once.
        var restored = await setValue(BragiProperty.mode, 1)
        if !restored { restored = await setValue(BragiProperty.mode, 1) }
        if !restored {
            failure = (failure.map { $0 + "; " } ?? "") + "could not restore hardware mode"
            Self.log.error("hardware mode NOT restored")
        }
        await readAll()
        if let failure { lastError = failure }
        if let mode = await getValue(BragiProperty.mode) {
            Self.log.info("mode after apply: \(mode)")
        }
    }
}
