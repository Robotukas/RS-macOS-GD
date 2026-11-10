import Foundation
import CoreAudio
import os

/// The real `VolumeObserving`: property listeners on the default output device (volume scalar on the main element, or on
/// channels 1 and 2 when the main element has none; mute) and on the system's default-output-device property. Reading and
/// listening need no permission. Nothing here sets a volume or a mute: the owner's Mac is only ever observed.
///
/// No AppKit, no UI. Every listener runs on one private serial queue, which also owns the tracker, so `onEvent` is called
/// from that queue only. Tests never create one of these; they use a fake `VolumeObserving`.
final class CoreAudioVolumeObserver: VolumeObserving, @unchecked Sendable {
    private static let log = Logger(subsystem: GDHubID.subsystem, category: "volume-watch")

    private let queue = DispatchQueue(label: "\(GDHubID.subsystem).volume-watch", qos: .userInitiated)
    private var onEvent: (@Sendable (VolumeEvent) -> Void)?
    private var tracker = VolumeChangeTracker(initial: VolumeState())
    private var bound: AudioObjectID = 0
    private var deviceListeners: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var systemListener: (address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)?
    private var running = false

    init() {}

    // MARK: VolumeObserving

    func currentState() -> VolumeState { Self.readState(Self.defaultOutputDevice()) }

    func start(onEvent: @escaping @Sendable (VolumeEvent) -> Void) {
        queue.sync {
            guard !running else { return }
            running = true
            self.onEvent = onEvent
            tracker = VolumeChangeTracker(initial: currentState())
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.defaultDeviceChanged() }
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            if status == noErr { systemListener = (address, block) } else {
                Self.log.error("default output device listener refused (\(status, privacy: .public))")
            }
            bind(to: Self.defaultOutputDevice())
        }
    }

    func stop() {
        queue.sync {
            guard running else { return }
            running = false
            unbind()
            if var l = systemListener {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &l.address, queue, l.block)
            }
            systemListener = nil
            onEvent = nil
        }
    }

    // MARK: On the queue

    private func defaultDeviceChanged() {
        guard running else { return }
        let device = Self.defaultOutputDevice()
        let now = Self.readState(device)
        let event = tracker.note(.device, now: now, tNs: LatencyMeter.nowNs())
        bind(to: device)
        if let event { onEvent?(event) }
    }

    private func fired(_ kind: VolumeEventKind) {
        guard running else { return }
        let now = Self.readState(bound == 0 ? nil : bound)
        if let event = tracker.note(kind, now: now, tNs: LatencyMeter.nowNs()) { onEvent?(event) }
    }

    private func bind(to device: AudioObjectID?) {
        unbind()
        guard let device else { return }
        bound = device
        var watched: [(AudioObjectPropertyAddress, VolumeEventKind)] = []
        for element in Self.volumeElements(device) {
            watched.append((Self.address(kAudioDevicePropertyVolumeScalar, element: element), .volume))
        }
        if let element = Self.muteElement(device) {
            watched.append((Self.address(kAudioDevicePropertyMute, element: element), .mute))
        }
        for (address, kind) in watched {
            var a = address
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.fired(kind) }
            let status = AudioObjectAddPropertyListenerBlock(device, &a, queue, block)
            if status == noErr { deviceListeners.append((a, block)) } else {
                Self.log.error("listener on device \(device, privacy: .public) refused (\(status, privacy: .public))")
            }
        }
    }

    private func unbind() {
        if bound != 0 {
            for var l in deviceListeners { AudioObjectRemovePropertyListenerBlock(bound, &l.address, queue, l.block) }
        }
        deviceListeners = []
        bound = 0
    }

    // MARK: Reading the device

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != AudioObjectID(kAudioObjectUnknown) ? device : nil
    }

    private static func has(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Bool {
        var a = address(selector, element: element)
        return AudioObjectHasProperty(device, &a)
    }

    /// Where the software volume lives: the main element, else channels 1 and 2 (both, when both have one); empty when the
    /// device has none (a digital output, say).
    static func volumeElements(_ device: AudioObjectID) -> [AudioObjectPropertyElement] {
        if has(device, kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { has(device, kAudioDevicePropertyVolumeScalar, element: $0) }
    }

    static func muteElement(_ device: AudioObjectID) -> AudioObjectPropertyElement? {
        [kAudioObjectPropertyElementMain, 1].first { has(device, kAudioDevicePropertyMute, element: $0) }
    }

    private static func float(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Double? {
        var a = address(selector, element: element)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr ? Double(value) : nil
    }

    private static func flag(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Bool? {
        var a = address(selector, element: element)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    static func readState(_ device: AudioObjectID?) -> VolumeState {
        guard let device else { return VolumeState() }
        var state = VolumeState(deviceID: device)
        let elements = volumeElements(device)
        state.hasVolume = !elements.isEmpty
        let values = elements.compactMap { float(device, kAudioDevicePropertyVolumeScalar, element: $0) }
        // Two channels move together on a Mac's volume keys; their mean is the number to compare.
        if !values.isEmpty { state.scalar = values.reduce(0, +) / Double(values.count) }
        if let element = muteElement(device) {
            state.hasMute = true
            state.muted = flag(device, kAudioDevicePropertyMute, element: element)
        }
        return state
    }
}
