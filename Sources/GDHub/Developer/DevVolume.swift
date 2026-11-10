import Foundation

// Volume checks of Developer mode (docs/plans/remap-plan.md, "Templates and checks (R4)"): did a G key leave the Mac's
// volume alone, or change it? Judged by counted change events between the step's Go and the end of its release tail,
// not by comparing two samples. Everything in this file is pure Foundation: the CoreAudio listeners sit behind
// `VolumeObserving` (the real one is `CoreAudioVolumeObserver`), so the judge and the runner are tested with a fake.

// MARK: - What the output device does

/// The default output device as far as the volume check cares: whether it has a software volume or a mute switch and
/// what they say. `deviceID` nil = there is no default output device.
struct VolumeState: Equatable {
    var deviceID: UInt32?
    var hasVolume = false
    var hasMute = false
    /// 0...1; nil when the device has no software volume (or it cannot be read).
    var scalar: Double?
    var muted: Bool?

    init(deviceID: UInt32? = nil, hasVolume: Bool = false, hasMute: Bool = false, scalar: Double? = nil, muted: Bool? = nil) {
        self.deviceID = deviceID; self.hasVolume = hasVolume; self.hasMute = hasMute; self.scalar = scalar; self.muted = muted
    }

    /// A device with both a software volume and a mute switch.
    static func device(_ id: UInt32 = 1, scalar: Double = 0.5, muted: Bool = false) -> VolumeState {
        VolumeState(deviceID: id, hasVolume: true, hasMute: true, scalar: scalar, muted: muted)
    }
}

enum VolumeEventKind: String, Equatable {
    case volume, mute, device
}

/// One real change on the default output device (a listener that fired without anything changing is dropped by
/// `VolumeChangeTracker`). `state` is what the device said right after.
struct VolumeEvent: Equatable {
    var tNs: UInt64
    var kind: VolumeEventKind
    var state: VolumeState
}

/// The seam to CoreAudio. `start` begins listening and calls `onEvent` (on any thread) for every real change of the
/// default output device's volume, mute or identity; `currentState` reads the device now. No permission is needed.
protocol VolumeObserving: AnyObject {
    func currentState() -> VolumeState
    func start(onEvent: @escaping @Sendable (VolumeEvent) -> Void)
    func stop()
}

/// Turns raw listener notifications into change events: a notification only counts when the value it is about really
/// differs from the one seen before. Pure, so the "does a repeated notification count twice" rules are unit-tested.
struct VolumeChangeTracker {
    /// Smaller steps than this are the same volume (CoreAudio scalars are 32-bit floats).
    static let scalarEpsilon = 1e-6

    private(set) var last: VolumeState

    init(initial: VolumeState) { last = initial }

    /// `kind` says which listener fired, `now` is the state read after it. Returns the event, or nil when nothing the
    /// listener is about has changed. A device change replaces the whole remembered state.
    mutating func note(_ kind: VolumeEventKind, now: VolumeState, tNs: UInt64) -> VolumeEvent? {
        defer { last = now }
        switch kind {
        case .device:
            return now.deviceID != last.deviceID ? VolumeEvent(tNs: tNs, kind: .device, state: now) : nil
        case .volume:
            guard now.deviceID == last.deviceID else { return VolumeEvent(tNs: tNs, kind: .device, state: now) }
            if let a = last.scalar, let b = now.scalar, abs(a - b) <= Self.scalarEpsilon { return nil }
            if last.scalar == nil && now.scalar == nil { return nil }
            return VolumeEvent(tNs: tNs, kind: .volume, state: now)
        case .mute:
            guard now.deviceID == last.deviceID else { return VolumeEvent(tNs: tNs, kind: .device, state: now) }
            return now.muted != last.muted ? VolumeEvent(tNs: tNs, kind: .mute, state: now) : nil
        }
    }
}

// MARK: - What the receiver's consumer interface says

/// One raw 0x11 report from the receiver's Consumer Control interface (interface 4): one byte, volume up (bit 0),
/// volume down (bit 1), mute (bit 2), the rest padding (`docs/protocol/envision-pro-receiver.md`). It arrives whether or
/// not the Mac acts on it, so it proves the key was pressed even when the system's volume stays put.
struct DevConsumerReport: Equatable {
    struct Keys: OptionSet, Equatable {
        let rawValue: UInt8
        static let volumeUp = Keys(rawValue: 1 << 0)
        static let volumeDown = Keys(rawValue: 1 << 1)
        static let mute = Keys(rawValue: 1 << 2)
    }

    var tNs: UInt64
    /// The report as read, ID byte first (`11 02`); a buffer without the ID byte (one byte) is read the same way.
    var bytes: [UInt8]

    static let reportID: UInt8 = 0x11

    /// The one data byte.
    var payload: UInt8 {
        if bytes.count >= 2, bytes[0] == Self.reportID { return bytes[1] }
        if bytes.count == 1, bytes[0] != Self.reportID { return bytes[0] }
        return 0
    }

    /// Any key down at all (a release is `11 00`).
    var isKeyDown: Bool { payload != 0 }
    var keys: Keys { Keys(rawValue: payload & 0x07) }
}

// MARK: - The verdict

/// `expect.volume`: what the step expects the Mac's volume to do while the key is pressed.
enum DevVolumeExpectation: String, Equatable, CaseIterable {
    /// Volume and mute stay as they were (a remapped or silenced key).
    case unchanged
    /// Volume or mute changes (a key that kept its built-in function).
    case changes

    static let words = "\"unchanged\" or \"changes\""
}

/// What was watched from the step's Go to the end of its release tail.
struct DevVolumeObservation: Equatable {
    /// The device state in force at Go and at the end (nil = no state was ever known).
    var atGo: VolumeState?
    var atEnd: VolumeState?
    /// Change events inside the span, in time order.
    var events: [VolumeEvent] = []
    /// 0x11 reports inside the span.
    var reports: [DevConsumerReport] = []

    /// The state in force at `t`: the last one at or before it, else the first one known.
    static func state(at t: UInt64, in timeline: [(tNs: UInt64, state: VolumeState)]) -> VolumeState? {
        // Events hop threads on their way in, so the list may be slightly out of order: pick by time, later entry on a tie.
        let sorted = timeline.enumerated().sorted { ($0.element.tNs, $0.offset) < ($1.element.tNs, $1.offset) }.map(\.element)
        return sorted.last(where: { $0.tNs <= t })?.state ?? sorted.first?.state
    }

    /// Everything inside `from...to` out of the run's raw streams.
    static func make(timeline: [(tNs: UInt64, state: VolumeState)], events: [VolumeEvent], reports: [DevConsumerReport],
                     from: UInt64, to: UInt64) -> DevVolumeObservation {
        DevVolumeObservation(atGo: state(at: from, in: timeline), atEnd: state(at: to, in: timeline),
                             events: events.filter { $0.tNs >= from && $0.tNs <= to }.sorted { $0.tNs < $1.tNs },
                             reports: reports.filter { $0.tNs >= from && $0.tNs <= to }.sorted { $0.tNs < $1.tNs })
    }
}

/// The volume part of an attempt in the run report. Absent from every attempt whose step has no `expect.volume`, so
/// reports of older templates are byte for byte what they were.
struct DevVolumeResult: Codable, Equatable {
    /// "unchanged" or "changes", as the step asked (an unknown word is kept as written).
    var expect = ""
    /// `pass`, `fail`, or `inconclusive` = cannot judge; the reason says why.
    var verdict: DevVerdict = .inconclusive("not judged")
    /// Reports from the receiver's consumer interface (0x11) in the span, and how many of them were a key going down.
    var consumerReports = 0
    var keyReports = 0
    /// Change events in the span, by kind.
    var volumeEvents = 0
    var muteEvents = 0
    var deviceEvents = 0
    var startScalar: Double?
    var endScalar: Double?
    var startMuted: Bool?
    var endMuted: Bool?
    var hasVolume = false
    var hasMute = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expect = try c.value(.expect, "")
        verdict = try c.value(.verdict, DevVerdict.inconclusive("not judged"))
        consumerReports = try c.value(.consumerReports, 0)
        keyReports = try c.value(.keyReports, 0)
        volumeEvents = try c.value(.volumeEvents, 0)
        muteEvents = try c.value(.muteEvents, 0)
        deviceEvents = try c.value(.deviceEvents, 0)
        startScalar = try c.decodeIfPresent(Double.self, forKey: .startScalar)
        endScalar = try c.decodeIfPresent(Double.self, forKey: .endScalar)
        startMuted = try c.decodeIfPresent(Bool.self, forKey: .startMuted)
        endMuted = try c.decodeIfPresent(Bool.self, forKey: .endMuted)
        hasVolume = try c.value(.hasVolume, false)
        hasMute = try c.value(.hasMute, false)
    }

    /// One sentence for the step's detail line.
    var summary: String {
        func level(_ s: Double?, _ m: Bool?) -> String {
            var parts: [String] = []
            if let s { parts.append(String(format: "%.0f %%", s * 100)) }
            if let m { parts.append(m ? "muted" : "not muted") }
            return parts.isEmpty ? "unknown" : parts.joined(separator: ", ")
        }
        let counts = "\(keyReports) volume-key report\(keyReports == 1 ? "" : "s") from the controller, \(volumeEvents) volume and \(muteEvents) mute change\(volumeEvents + muteEvents == 1 ? "" : "s") on the Mac, \(level(startScalar, startMuted)) before and \(level(endScalar, endMuted)) after"
        switch verdict {
        case .pass:
            return expect == DevVolumeExpectation.changes.rawValue
                ? "The volume or mute changed as it should (\(counts))."
                : "The volume stayed as it was, as it should (\(counts))."
        case .inconclusive(let why): return "The volume cannot be judged: \(why) (\(counts))."
        default: return "Volume check: \(verdict.reason ?? "failed") (\(counts))."
        }
    }
}

enum DevVolumeJudge {
    /// Below / above these the volume cannot go down / up any more.
    static let lowest = 0.0005
    static let highest = 0.9995

    /// Verdict by the plan's rules. "Cannot judge" (inconclusive, never a pass) when, in this order: no key report
    /// arrived; the device has no software volume and no mute; the volume was at its limit in the key's direction at Go;
    /// the default output device changed.
    static func judge(_ want: DevVolumeExpectation, _ obs: DevVolumeObservation) -> DevVolumeResult {
        var r = DevVolumeResult()
        r.expect = want.rawValue
        r.consumerReports = obs.reports.count
        let keyed = obs.reports.filter(\.isKeyDown)
        r.keyReports = keyed.count
        r.volumeEvents = obs.events.filter { $0.kind == .volume }.count
        r.muteEvents = obs.events.filter { $0.kind == .mute }.count
        r.deviceEvents = obs.events.filter { $0.kind == .device }.count
        r.startScalar = obs.atGo?.scalar; r.endScalar = obs.atEnd?.scalar
        r.startMuted = obs.atGo?.muted; r.endMuted = obs.atEnd?.muted
        r.hasVolume = obs.atGo?.hasVolume ?? false
        r.hasMute = obs.atGo?.hasMute ?? false

        func cannot(_ why: String) -> DevVolumeResult { r.verdict = .inconclusive(why); return r }

        if keyed.isEmpty {
            return cannot("no volume-key report (0x11) arrived from the controller while the step ran, so the press cannot be told from nothing")
        }
        guard let go = obs.atGo, go.deviceID != nil else {
            return cannot("there is no sound output device to watch")
        }
        if !go.hasVolume && !go.hasMute {
            return cannot("the sound output has neither a software volume nor a mute switch, so there is nothing to watch")
        }
        // Volume down at zero or volume up at full changes nothing, so "unchanged" would pass without proving anything.
        var pressed = DevConsumerReport.Keys()
        for report in keyed { pressed.formUnion(report.keys) }
        // A volume-up or volume-down key on an output without a software volume (a USB headset with its own volume
        // wheel, say) moves nothing whether it is silenced or not: only mute can be watched there. Found in the owner's
        // first run (2026-11-10, a headset as the output): "unchanged" passed without proving anything.
        if !pressed.contains(.mute), pressed.contains(.volumeUp) || pressed.contains(.volumeDown), !go.hasVolume {
            return cannot("this sound output has no volume the Mac can change (only mute), so a volume-up or volume-down key cannot be checked on it: choose the Mac's own speakers as the sound output and run the step again")
        }
        if !pressed.contains(.mute), pressed.contains(.volumeUp) || pressed.contains(.volumeDown), let s = go.scalar {
            let upStuck = !pressed.contains(.volumeUp) || s >= highest
            let downStuck = !pressed.contains(.volumeDown) || s <= lowest
            if upStuck && downStuck {
                return cannot(pressed.contains(.volumeDown) && !pressed.contains(.volumeUp)
                              ? "the volume was already at its lowest, so volume down could not change anything: set it to about half and run the step again"
                              : (pressed.contains(.volumeUp) && !pressed.contains(.volumeDown)
                                 ? "the volume was already at its highest, so volume up could not change anything: set it to about half and run the step again"
                                 : "the volume was already at its limit in the direction of the key: set it to about half and run the step again"))
            }
        }
        if r.deviceEvents > 0 {
            return cannot("the sound output device changed while the step ran")
        }

        let changes = r.volumeEvents + r.muteEvents
        switch want {
        case .unchanged:
            r.verdict = changes == 0 ? .pass
                : .fail("the Mac's volume changed although it should have been left alone (\(r.volumeEvents) volume and \(r.muteEvents) mute change\(changes == 1 ? "" : "s"))")
        case .changes:
            r.verdict = changes > 0 ? .pass
                : .fail("the volume key was pressed (\(r.keyReports) report\(r.keyReports == 1 ? "" : "s")) but neither the volume nor the mute changed on the Mac")
        }
        return r
    }
}
