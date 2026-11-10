import Foundation
import os

/// Builds and owns the engine's moving parts: queues, dext client, pad sink, HID reader, presence, power, mapping
/// watcher, throttle check and signal handling. No AppKit anywhere in this process.
final class EngineService: @unchecked Sendable {
    static let log = Logger(subsystem: "com.interlinked.gdhub", category: "engine")
    private static let latencyLog = Logger(subsystem: "com.interlinked.gdhub", category: "latency")

    let options: EngineOptions
    /// Serial, user-interactive: HID manager, dext client, sink and its timers, poller, presence, all core state.
    let vhidQueue = DispatchQueue(label: "com.interlinked.gdhub.vhid", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "com.interlinked.gdhub.control", qos: .userInitiated)
    private let meterQueue = DispatchQueue(label: "com.interlinked.gdhub.enginemeter", qos: .utility)

    private let dext: DextClient
    private let sink: VirtualPadSink
    private let core: EngineCore
    private let presence: ControllerPresence
    private let reader: GamepadHIDReader
    private let poller: DextStatusPoller
    private let tapSupervisor: TapSupervisor
    private let statusPublisher: TapStatusPublisher
    private let stat = CallbackStat()
    private let throttle: ThrottleCheck
    private let store = MappingStore.envisionPro
    private var watcher: MappingWatcher?
    /// Switches off the volume function of a remapped G2-G4. Its own queue; the engine is its one writer in engine mode.
    private let volumeKeys = ConsumerKeyMute()
    private var power: PowerObserver?
    private var signalSources: [DispatchSourceSignal] = []
    private var meterTimer: DispatchSourceTimer?
    private var lastSnapshot = LatencySnapshot()        // meterQueue
    private let logEverySeconds: Int

    init(options: EngineOptions) {
        self.options = options
        logEverySeconds = options.latencyLog ? 2 : 10
        let client = DextClient(queue: vhidQueue, supervised: true)      // the TapSupervisor below owns the forwarding state
        dext = client
        let ring = FrameRing()
        tapSupervisor = TapSupervisor(queue: vhidQueue, dext: client,
                                      parity: ParitySampler(ring: ring, log: { EngineService.log.error("\($0, privacy: .public)") }))
        var config = VirtualPadSink.Config()
        config.maxRateHz = VirtualPadSink.runtimeMaxRateHz()
        config.xlateCore = VirtualPadSink.runtimeXlateCore()
        let padSink = VirtualPadSink(queue: vhidQueue, transport: client, config: config)
        sink = padSink
        let mapping: ControlMapping
        do { mapping = try store.loadStrict() } catch {
            // Lenient on purpose (the pad must work); the unreadable file is left alone for the GUI to move aside.
            EngineService.log.error("mapping file cannot be read (\(String(describing: error), privacy: .public)); running with defaults")
            mapping = .default
        }
        core = EngineCore(queue: vhidQueue, dext: client, sink: padSink, scheduler: DispatchSinkScheduler(queue: vhidQueue),
                          mapping: mapping, options: options)
        presence = ControllerPresence(queue: vhidQueue)
        reader = GamepadHIDReader(queue: vhidQueue, presence: presence, core: core, stat: stat)
        reader.ring = ring
        let readerRef = reader
        tapSupervisor.engineFrames = { readerRef.framesSeen }
        let watch = LiveWatch()                                  // T7: the engine's shadow of the driver's output (F6)
        reader.liveWatch = watch
        tapSupervisor.liveWatch = watch
        // The Driver menu (a separate process) reads this file; the write is off vhidQueue, and only when the report changed.
        let publisher = TapStatusPublisher(queue: controlQueue)
        statusPublisher = publisher
        tapSupervisor.statusSink = { report in publisher.update(report) }
        poller = DextStatusPoller(queue: vhidQueue, dext: client, sink: padSink, latencyLogEvery: logEverySeconds)
        throttle = ThrottleCheck(queue: vhidQueue)
        Self.log.notice("virtual pad rate cap \(Int(config.maxRateHz)) Hz")
    }

    func start() {
        let bundle = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        Self.log.notice("engine started pid=\(getpid()) build=\(bundle, privacy: .public) home=\(NSHomeDirectory(), privacy: .public) mapping=\(self.store.url.path, privacy: .public) foreground=\(self.options.foreground)")

        core.onConnection = { [weak self] state in
            guard let self else { return }
            if case .connected = state { self.poller.start() } else { self.poller.stop() }
            if case .connected = state { self.tapSupervisor.connection(up: true) } else { self.tapSupervisor.connection(up: false) }
        }
        presence.onInterface = { [weak self] up in self?.tapSupervisor.controllerInterface(up: up) }
        // T7: the posting gate follows the supervisor (LIVE accepted / left), and an adopted pad that the tap drives is the supervisor's
        // cue to stay LIVE at startup.
        tapSupervisor.onDrive = { [weak self] on in self?.sink.setDriverDrives(on) }
        sink.onGateForcedOpen = { [weak self] in self?.tapSupervisor.gateForcedOpen() }
        tapSupervisor.sinkHasPad = { [weak self] in self?.sink.isPublished ?? false }
        tapSupervisor.padAdopted = { [weak self] in
            self?.sink.createdAdoptedTapPad ?? false
        }
        // T5: what the engine can offer the driver as a mapping (encoded for the pad that exists now), and when it changed.
        tapSupervisor.mappingOffer = { [weak self] revision in
            guard let self, let pad = self.sink.createdPad else { return .none }
            switch MapBlobEncoder.encode(self.core.mapping, identity: pad.identity, spec: pad.spec, revision: revision,
                                         axisDeadband: self.sink.axisDeadband, triggerDeadband: self.sink.triggerDeadband) {
            case .blob(let b): return .blob(b, spec: pad.spec)
            case .unsupported(let why): return .unsupported(why)
            }
        }
        core.onPadState = { [weak self] state in
            if case .published = state {
                self?.tapSupervisor.invalidateMapping()                                   // a new pad: the driver has no mapping for it
                self?.tapSupervisor.padPublished()                                        // adopted a pad the tap drives? stay LIVE
            }
        }
        presence.onChange = { [weak self] status in
            Self.log.notice("controller: \(status.rawValue, privacy: .public)")
            if status == .active { self?.tapSupervisor.controllerActive() }
            self?.core.controllerStatus(status)
        }
        poller.onLatency = { [weak self] snapshot in
            // utility queue (the poller's own); keep the newest snapshot for the combined meter line
            self?.meterQueue.async { if let snapshot { self?.lastSnapshot = snapshot } }
        }

        installSignalHandlers()

        vhidQueue.async { [self] in
            core.start()
            reader.start()
            presence.startTimer()
            tapSupervisor.start()
            statusPublisher.start()                        // rewrites the report file every 30 s on controlQueue
            throttle.start()
            startMeterTimer()
        }

        let w = MappingWatcher(store: store, initial: core.mapping, queue: controlQueue) { [weak self] m in
            guard let self else { return }
            self.volumeKeys.update(m)                              // enqueues on its own queue; before the frame-queue hop
            self.vhidQueue.async { self.core.setMapping(m); self.tapSupervisor.invalidateMapping() }
        }
        w.start()
        watcher = w
        volumeKeys.start(mapping: core.mapping)                    // the engine is up: switch off the volume of mapped G2-G4

        let p = PowerObserver(vhidQueue: vhidQueue,
                              willSleep: { [weak self] in self?.core.neutral() },
                              didWake: { [weak self] in self?.presence.didWake(); self?.tapSupervisor.didWake() },
                              wakeOffFrame: { [weak self] in self?.volumeKeys.didWake() })
        p.start()
        power = p
    }

    // MARK: Meter (all-frames callback delay)

    /// On vhidQueue: copies the window; sorting and logging happen on the utility queue.
    private func startMeterTimer() {
        let t = DispatchSource.makeTimerSource(queue: vhidQueue)
        t.schedule(deadline: .now() + .seconds(logEverySeconds), repeating: .seconds(logEverySeconds), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let window = self.stat.collect()
            let prio = LatencyMeter.currentThreadBasePriority()
            let napped = (prio ?? 31) <= 4
            // T3: the dext's own `hop` (user client stamp to pad entry) and `hr` (handleReport) of its last 10 s window.
            // status2 is a call on the dext connection, so it is made here on vhidQueue; nil on a dext without it.
            let shadowText = self.tapSupervisor.shadowText.map { " | " + $0 } ?? ""
            let dextText = (self.dext.status2()?.meterLogText.map { " | " + $0 } ?? "") + shadowText
            self.meterQueue.async {
                let s = CallbackStat.summary(of: window)
                let l = self.lastSnapshot
                let changed = l.samples > 0
                    ? " | changed-frames n=\(l.samples) total p50/p99/max \(LatencySnapshot.fmt(l.total.p50))/\(LatencySnapshot.fmt(l.total.p99))/\(LatencySnapshot.fmt(l.total.max)) ms posts=\(Int(l.postsHz.rounded()))Hz coalesced=\(Int(l.coalescedPercent.rounded()))%"
                    : ""
                Self.log.notice("meter: \(s.logText, privacy: .public)\(changed, privacy: .public)\(dextText, privacy: .public) napped=\(napped ? "yes" : "no", privacy: .public) vhidPrio=\(prio.map(String.init) ?? "?", privacy: .public)")
            }
        }
        t.resume()
        meterTimer = t
    }

    // MARK: Signals

    /// SIGTERM (bootout, logout, kickstart -k) and SIGINT (terminal): destroy the pad, close the connection, exit 0.
    /// launchd respawns the job after any exit unless it was booted out.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: controlQueue)
            s.setEventHandler { [weak self] in
                guard let self else { exit(0) }
                Self.log.notice("signal \(sig): shutting down")
                self.volumeKeys.stop()                     // clears UserKeyMapping (waits at most 1 s); not on vhidQueue
                self.vhidQueue.sync {
                    self.reader.stop()
                    self.tapSupervisor.shutdown()          // INERT first, then the pad is destroyed and the connection closed
                    self.core.shutdown()
                }
                exit(0)
            }
            s.resume()
            signalSources.append(s)
        }
    }
}
