# GDHub engine LaunchAgent plan (headless hot path)

Status: plan, rev 2 (2026-11-09; rev 2 resolves the 11-issue review: launchd gate, bootout waiting, `.exclusive`
recovery, `/usr/bin/log`, GUI dext gating, KeepAlive, three GUI modes, agent-op ordering, dev swap, mapping reload,
E1 fallback). Supersedes latency-plan §2 fix 3b and finishes the decision in latency-plan §7.
Tags: **M** = measured on this Mac (macOS 27.0.1), **R** = read in code/SDK/man page, **C** = cited, **G** = guess.
"Research L" is the launchd report and "research C" is the codebase report from the 2026-11-09 investigation.
Their probes live in the session scratch dir (`…/scratchpad/la/`, `…/scratchpad/engprobe/`, `…/scratchpad/padlat/`).

## Phases

| Phase | Title | Status |
|---|---|---|
| E1 | Engine runs passthrough under launchd; GUI stops owning the dext; read-only engine status | done (gate passed 2026-11-09, §8.4) |
| E2 | XPC channel: live engine status and full Driver-menu control from the GUI, mapping push | pending |
| E3 | One engine core for both modes (in-app fallback through the same code); install/uninstall from the GUI | pending |
| E4 | Mapping-engine groundwork: profiles, output channels, self-throttle report, TCC probe | pending |

---

## 1. Goal and measured justification

**Goal.** Move the hot path (HID read → mapper → sink → dext client) into a headless process launched by launchd as an
Interactive agent, so the pad keeps up with the controller while a fullscreen game owns the screen. The GUI becomes a
front end for status, layout, learning and settings.

**Why this works:**
- **Cause of the lag.** Game Mode demotes GDHub, not App Nap.
  - gamepolicyd logged "Game mode enabled" at 01:30:56.774. 166 ms later, runningboardd set GDHub's darwin role to Background. Every pause and resume of Game Mode flips the role back and forth (**M**, research L §0).
  - ShadowPCDisplay.app has `LSApplicationCategoryType = public.app-category.games` (**M**), so running it fullscreen turns Game Mode on.
  - The App Nap opt-out was active the whole time (**M**), which is why `.latencyCritical` and `.accessory` did not help.
- **What the clamp costs.** HID callback p50 is 57 ms and p95 135 ms, the worst case is 1.5 s, and the pad gets about 15 posts per second (**M**, latency-plan §7).
- **Why a launchd agent escapes it.** RunningBoard manages processes that check in with LaunchServices.
  - An agent that never creates `NSApplication` writes no runningboardd log lines at all (**M**).
  - Third-party AppKit agents do get clamped under Game Mode (SteelSeries GG, Grammarly: "falling back … PRIO_DARWIN_BG", **M**).
  - With `ProcessType=Interactive` and a `.userInteractive` serial queue, a probe measured p50 0.108 ms, p99 0.46 ms and max 5.4 ms at 962 Hz (**M**).
  - Standard: p99 about 1.7 ms. Background: every thread at priority 4 (**M**).
- **Open point.** All probe runs, including the latency-plan §7 01:42 run, happened while Game Mode was off (01:41:01–01:46:43, **M**).
  - Immunity under Game Mode is therefore still a strong **G**.
  - The E1 play test (§8.3) is the gate, and §10 R1 lists what to do if it fails.

## 2. Process model and lifecycle

**Roles**

| | GUI (`GDHub`) | Engine (`GDHub --engine`, launchd job `com.interlinked.gdhub.engine`) |
|---|---|---|
| Owns the dext connection | Only in **in-app mode** (never in engine or display-only mode: no `DextClient` is started at all) | Always in **engine mode** |
| Reads the SCUF | Yes: display, learning, input monitor, Bragi control strip (non-exclusive `IOHIDManager`/`IOHIDDeviceOpen`) | Yes: gamepad interface 0xFF58 only, for the pad |
| Installs/updates the driver (OSSystemExtensionRequest) | Yes, always | Never |
| AppKit / SwiftUI / RunningBoard | Yes | **Never initialised** (§3.4) |

**Mode selection (GUI, decided once in `AppModel.init`, before `DriverManager` is built).** One enum
`GUIMode { engine, displayOnly, inApp }`, computed by `EngineAgent.guiMode(bundlePath:installed:)` (pure, unit-tested):

| Agent plist `~/Library/LaunchAgents/com.interlinked.gdhub.engine.plist` | This GUI copy | Mode |
|---|---|---|
| installed | `Bundle.main.bundlePath == "/Applications/GDHub.app"` | **engine** |
| installed | any other copy (`.build/GDHub.app` from `bundle.sh`, `.xcodebuild/…/GDHub.app` from `--no-install`, DerivedData) | **display-only** |
| absent | any copy | **in-app** (today's code path; a `bundle.sh` copy is refused by the dext with `rejected`, exactly as today, **R** DriverManager.swift:180-182, bundle.sh:34-36 signs with no entitlements) |

- **Engine mode.** The GUI starts no `DextClient` (§6.1 `DriverManager` row) and drives the agent through `EngineAgent`.
  - It does not call `ensureLoaded()` from `AppModel.init`. It calls it once `DriverManager`'s properties query has settled (`.active(match)`, `.notInstalled`, `.needsApproval` or `.failed`), so it can never race an update's bootout (§2 driver update, §4.3 ordering).
  - `ensureLoaded()` semantics (all on `EngineAgent`'s one serial `agentQueue`, **M** exit codes from a scratch gui-domain agent 2026-11-09):
    - `launchctl print` rc 113 (not loaded) → `bootstrap`. rc 5 or 37 from bootstrap → wait 200 ms, retry up to 3 times; rc 5 followed by `print` rc 0 counts as success (launchd loaded it at login in the meantime; a second bootstrap of a loaded job returns 5, **M**).
    - rc 0 and `state = running` → nothing.
    - rc 0, a `pid` and a state other than `running` (e.g. `state = SIGTERMed` while a bootout is still finishing, **M**) → `bootoutAndWait`-style poll until rc 113 (≤ 6 s), then bootstrap.
    - rc 0, `state = not running`, no pid → `kickstart`.
    - Skipped while `updateInFlight` is set (§2 driver update).
- **Display-only mode.** Like engine mode it starts no `DextClient`, but it also never runs `launchctl` (no bootstrap, bootout, kickstart or extension request; `DriverManager` already reports `.wrongLocation`/`.notBundled` for such copies). It shows the layout editor, learn mode, input monitor and the control strip, and the status line "Display-only: the background engine owns the pad". From E2 it may read engine status over XPC.
  - This is what keeps a properly signed non-`/Applications` Xcode build (valid entitlements) from racing the engine for the dext.
- **In-app mode.** The GUI runs today's code path unchanged in E1. From E3 it runs the same `EngineCore` in-process.
- **E1 fallback when the engine provably cannot run** (engine mode only). After `ensureLoaded()`, `EngineAgent` re-reads `launchctl print` three times over ~5 s. If the job is never `state = running` (not loaded rc 113 because bootstrap failed, e.g. BTM toggle off, or not running with a non-zero `last exit code`, e.g. AMFI kill R2 or exit 64 R15):
  1. run `bootoutAndWait` (so a `KeepAlive` respawn cannot grab the dext later in this session) and confirm `pgrep -f '/Applications/GDHub.app/Contents/MacOS/GDHub --engine'` is empty;
  2. switch this GUI session to in-app mode (build the real `DextClient`, `wireVirtualPad()`), log at `.error` and show "Engine unavailable: using in-app (relaunch GDHub to retry the engine)".
  - Race-free because the engine is booted out and not running. The plist stays installed, so the next GUI launch (or login) tries the engine again. If the engine were somehow started anyway, its `.exclusive` retry (§2 "Dext ownership recovery") takes the dext back once this GUI quits.
  - In this state **Restart engine** is replaced by the note "relaunch GDHub to retry the engine".
- Apart from that fallback, the GUI never falls back to in-app mode while the plist is installed. An unresponsive but running engine shows "Engine not responding" with **Restart engine** (`kickstart -k`) and, from E3, **Use in-app engine**.
- E1 always has a way out from the GUI: the Driver menu item **Uninstall background engine (relaunch to apply)** runs `bootoutAndWait` + `rm` of the plist (§4.4).
- Switching modes live is E3. In E1 and E2, a GUI relaunch picks up a change (except the fallback above).

**Single-instance guarantees (four layers)**
1. **launchd** runs one job per label.
2. **The engine refuses to run unless launchd started it as this job.** It checks only `ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.interlinked.gdhub.engine"`.
   - **M** (resolved): launchd sets `XPC_SERVICE_NAME` to the exact label for a gui-domain agent (scratch agents printed `XPC_SERVICE_NAME=com.interlinked.rvprobe.hello ppid=1` and `XPC_SERVICE_NAME=com.interlinked.rv2probe ppid=1`).
   - `getppid() == 1` is **not** used: the LaunchServices-launched GUI (pid 27619) also has ppid 1, with `XPC_SERVICE_NAME=application.com.interlinked.gdhub.176886480.176886485` (**M**), so `open GDHub.app --args --engine` would have passed a ppid test and run the engine as a RunningBoard-managed, Game-Mode-clamped app.
   - The dev flag `--engine-foreground` bypasses this check, for terminal tests while the agent is uninstalled.
   - Otherwise the engine exits 64 with a message on stderr.
3. **The Mach service.** Only the launchd-spawned instance can check in to `com.interlinked.gdhub.engine` (E2).
4. **The dext backstop.** `GDHubRootClaim` admits a single owner, and the second caller gets `kIOReturnExclusiveAccess` (0xE00002C5, **R** GDHubVirtualHIDUserClient.cpp `sHello`). In engine and display-only mode the GUI never creates IOKit notifications for the dext, so it never says hello (§6.1).

**Dext ownership recovery (engine).** `DextClient` does not retry after `.exclusive`: on 0xE00002C5 it closes, bumps
`failures` and sets `.exclusive`, and only a new service match or `retry()` reconnects (**R** DextClient.swift:204-206,
`handleMatched` skips nothing else; `retry()` :144). So `EngineCore` owns recovery:
- On `dext.onState` → `.exclusive` or `.failed(_)`, schedule `dext.retry()` on `vhidQueue` after 0.25, 0.5, 1, 2 s, then every 2 s while still not connected. Reset the schedule on `.connected`. Not for `.rejected` (signature problem, R3) or `.protocolMismatch` (needs a new build): those log at `.error` and wait.
- Log each attempt at `.notice` for the first 5, then every 30th (`exclusive: retry #n`), so a long hold-off (GUI in fallback in-app mode) does not flood the log.
- This heals every transient second owner: the old owner's user-client `Stop` not yet processed after `kickstart -k` or a crash respawn, a `--engine-foreground` shell copy, a fallback in-app GUI, or a GUI still in in-app mode when the agent was installed.

**GUI closed.**
- The engine keeps running, and the pad, auto-publish, sleep handling and latency logging continue.
- Quitting the GUI only closes XPC, from E2 on.
- The pad goes away only when the engine stops: `bootout`, logout, crash, or an uninstall of the agent.

**Engine stop (SIGTERM from `launchctl bootout`, logout, `kickstart -k`, or a stray `kill`/`pkill`).**
- A SIGTERM `DispatchSource` runs `vhidQueue.sync { reader.stop(); core.shutdown() }`. `core.shutdown()` is `sink.shutdown()` followed by `dext.stop()`, which destroys the pad and closes the connection.
- The engine then calls `exit(0)`.
- `KeepAlive=true` (§4.1): launchd respawns the engine after **any** exit, including this clean one, unless the job was booted out.
  - Why not `{SuccessfulExit=false}`: a TERM-trapping scratch agent that exits 0 after `kill -TERM` ended `state = not running`, `runs = 1`, `last exit code = 0`, never respawned (**M**, review). `scripts/bundle.sh`'s `pkill -f "GDHub.app/Contents/MacOS/GDHub"` (**R** bundle.sh:40), `killall GDHub` or Activity Monitor "Quit" on the second "GDHub" would each have removed the pad until the next login.
  - A final stop is `bootout` (unloads the job, so no respawn); a restart is `kickstart -k`. Nothing needs the SuccessfulExit escape.
- `launchctl bootout` returns before the job has exited (rc 0 in 0.01–0.03 s while the trapped probe ran 3 s more, `launchctl print` showing `state = SIGTERMed`), and a `bootstrap` during that window fails with `5: Input/output error` (**M**, review and re-measured 2026-11-09). Every caller therefore uses **`bootoutAndWait`**:
  1. `launchctl bootout gui/$UID/$L` (ignore rc);
  2. poll `launchctl print gui/$UID/$L` every 100 ms until it returns non-zero (113 = not loaded, **M**), for at most `ExitTimeOut + 1` = 6 s (the re-measure needed 2.8 s for a 3 s trap);
  3. if still loaded, `pkill -9 -f '/Applications/GDHub.app/Contents/MacOS/GDHub --engine'`, warn, and poll once more;
  4. only then submit an extension request or bootstrap.
  - Implemented once in Swift (`EngineAgent.bootoutAndWait()`) and once in `scripts/engine-agent.sh bootout_wait`, with the same steps.

**Crash or kill.**
- When the process dies, the dext's user client `Stop` tears down the child pads at once (**R**, research C). The dext's 2 s watchdog covers only a hung engine.
- launchd respawns the engine after `ThrottleInterval=2` s (the default is 10 s; **G** that 2 is honoured, checked in §8.2).
- After the restart, `sink.transportConnected()` re-creates the pad when `vhid.pad.enabled` is true. Otherwise auto-publish fires on the first active report.
- Expected gap in Shadow: about 2.5–3 s with no pad.

**Driver (dext) install, update or uninstall.** The GUI drives these in both modes. In engine mode it wraps each request:

1. On `agentQueue`: set `updateInFlight = true`, then `EngineAgent.bootoutAndWait()` (§2 "Engine stop"; it returns only once `launchctl print` says not loaded). Then hop back to main.
2. Submit the `OSSystemExtensionRequest` (activation or deactivation), unchanged.
3. On `didFinish` / `didFail` / `handleProperties → .active(match)` / `.notInstalled`, enqueue on `agentQueue`: clear `updateInFlight`, then `EngineAgent.ensureLoaded()`.
   - The engine's `DextClient` waits for the service (`waitingForService`) and connects when the new dext matches.
   - Because every `EngineAgent` operation runs on the one serial `agentQueue`, a launch-time `ensureLoaded` and an update's bootout can never interleave, and `ensureLoaded` is a no-op while `updateInFlight` is set.

Rules for driver changes:
- Stopping the engine replaces research C's `driverWillUpdate`/`driverDidUpdate` lease. That lease is not needed: the engine is not running during the swap, and if the GUI dies mid-update, the next GUI launch (or the next login, since the plist is still installed) loads the engine again.
- **The GUI never says hello in engine mode, by construction, not by call-site checks.** Today `dext.start()` is also called from `handleProperties(.active)` on every properties query (**R** DriverManager.swift:378), from `didFailWithError` (:360), and `retryConnection()` runs on a new build (:375). In engine and display-only mode `DriverManager` is built with an inert `DextControlling` stub (§6.1), so all of these become no-ops that log once at `.debug`.
- `devTerminate` (the dev dext swap) works differently in each phase:
  - **E1:** the menu item is disabled in engine mode. `--dev-terminate-driver` is ignored in engine and display-only mode: `devTerminateOutstanding` is cleared at init with the log "ignored in engine mode". Otherwise it would stay true forever (it is cleared only after the GUI's own client connects, **R** DriverManager.swift:75, 154-165) and `handleProperties` would defer every update by 3 s forever (:381-389).
  - **E1 enforcement:** `build-xcode.sh` refuses a dext-changing build (no `--same-build`) while the agent plist is installed and prints "dext build would change while the background engine is installed: run scripts/engine-agent.sh uninstall first (or pass --same-build)" (§6.3). A dext-rebuild session therefore runs in in-app mode, where `--dev-terminate-driver` works as today.
  - **From E2:** `devTerminate` is an engine command, `--dev-terminate-driver` in the GUI sends it over XPC, and the build-script refusal is lifted.

**App update (`scripts/build-xcode.sh`).**
- The script boots the engine out **before** `pkill -x GDHub` and `rm -rf` + `ditto`, then bootstraps it **after** the copy (§6.3).
- Order matters for two reasons:
  - `pkill -x GDHub` also matches the engine, which runs under the same process name (**R**, research C).
  - `rm -rf` + `ditto` gives the binary a new inode, so a still-running engine would keep executing the old code (**R**, research L).
- From E2 on, the GUI also compares Mach-O UUIDs at hello (§5.2) and runs `kickstart -k` once if the engine is stale. CFBundleVersion cannot do this check, because `--same-build` keeps it unchanged.

**Sleep / wake (engine).**
- The engine calls `IORegisterForSystemPower` and delivers its notifications on `powerQueue` through `IONotificationPortSetDispatchQueue`.
  - **`kIOMessageCanSystemSleep`:** call `IOAllowPowerChange`.
  - **`kIOMessageSystemWillSleep`:** run `vhidQueue.sync { core.neutral() }`, then call `IOAllowPowerChange` (**C** Apple QA1340).
  - **`kIOMessageSystemHasPoweredOn`:** run `vhidQueue.async { presence.didWake() }`. This clears `lastReportAt`, so the pad stays neutral until real reports arrive. The sink's heartbeat-gap re-send already covers the stall.
- `powerQueue` may `sync` onto `vhidQueue`, but never the other way round.
- In engine mode the GUI's `NSWorkspace.willSleep` and `willTerminate` observers are not installed.

## 3. Engine executable

### 3.1 Chosen form: the same binary, `GDHub.app/Contents/MacOS/GDHub --engine`

Both forms pass the dext check (**M**, research L §4 and research C). This one is chosen for these reasons:
- **No signing work.**
  - The nested-helper route needs `build-xcode.sh` to assemble a bundle, copy `embedded.provisionprofile`, run `codesign` by hand and re-sign the outer app.
  - Xcode's automatic signing alone would mint a `.engine` App ID that the dext rejects (**G**, research L).
- **Same identity everywhere.**
  - `Bundle.main` is GDHub.app, and `UserDefaults.standard` reads `com.interlinked.gdhub` (**M**, research C engprobe).
  - The XPC peer requirement is the same string on both sides (§5.5).
  - A future Accessibility grant probably covers the same code identity (**G**, §10 R12).
- **SwiftPM stays one `executableTarget`.** `swift build`, `swift test` and `bundle.sh` are untouched, and a `GDHubCore` library split with `public` everywhere is not needed.

What it costs, and the mitigations:
- **The engine links AppKit and SwiftUI.** That is harmless as long as `NSApplication` is never created (**M**: engprobe kept `NSApp == nil`; eprobe showed no LaunchServices check-in). §3.4 lists the rules, and a guard test enforces them.
- **A single `@main` dispatcher has to branch before `App.main()`.**
- **Fallback** if §8.3 shows Game Mode still clamps the engine: research L's nested bundle `Contents/Library/Helpers/GDHubEngine.app`, with a copy of the profile and entitlements `{application-identifier 79XF6HYX8A.com.interlinked.gdhub, team-identifier 79XF6HYX8A}` (**M**: passes with no dext rebuild). See §10 R1.

### 3.2 How it passes the dext entitlement check (no dext rebuild)

- `callerIsGDHub` requires both of these (**R**, GDHubVirtualHIDUserClient.cpp:39-59, GDHubInternal.h:7-8):
  - `com.apple.developer.team-identifier == "79XF6HYX8A"`;
  - `com.apple.application-identifier`, if present, `== "79XF6HYX8A.com.interlinked.gdhub"`.
- Xcode's automatic signing takes these from the profile and puts them into the signature. `Xcode/App/GDHub.entitlements` itself lists only `system-extension.install`.
- The installed app carries exactly these values (**M**, research C, `codesign -d --entitlements`).
- At exec, AMFI validates them against `Contents/embedded.provisionprofile`. This works because `GDHub` is the bundle's main executable, so it gets the bundle's profile.
- Measured results:
  - The main executable passes: 0xE00002C5 means the check passed and the owner was busy (**M**, research L).
  - A plain Mach-O, or a helper in `Contents/MacOS` / `Contents/Helpers`, is refused (0xE00002E2) or killed by AMFI with exit 137 and -413 (**M**).
- Launching by launchd instead of LaunchServices is **G** to still validate (research C). The first E1 bootstrap is the test (§8.2 check 2).
- `IOServiceOpen` itself is unrestricted for launchd agents, because the dext has `allow-any-userclient-access` (**M**/**R**).
- **New build-script check:** besides today's `need … team-identifier`, `build-xcode.sh` checks the **value** of `com.apple.application-identifier` in the app signature (§6.3).

### 3.3 Entry point

New `Sources/GDHub/Entry.swift`. Remove `@main` from `GDHubApp` in App.swift.

```swift
import SwiftUI   // only so GDHubApp.main() resolves; nothing here runs SwiftUI in engine mode

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--engine") {
            EngineMain.run()            // -> Never; calls dispatchMain()
        } else {
            GDHubApp.main()
        }
    }
}
```

`Sources/GDHub/Engine/EngineMain.swift`:
```swift
enum EngineMain {
    static let label = "com.interlinked.gdhub.engine"
    private static var service: EngineService?          // strong ref for the process lifetime
    static func run() -> Never {
        let args = CommandLine.arguments
        // launchd sets XPC_SERVICE_NAME to the job label (M). Do NOT test getppid() == 1: a LaunchServices-launched
        // app also has ppid 1 (M), so `open GDHub.app --args --engine` would pass.
        let asOurJob = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
        guard asOurJob || args.contains("--engine-foreground") else {
            FileHandle.standardError.write(Data("GDHub --engine must be started by launchd (or pass --engine-foreground)\n".utf8))
            exit(64)
        }
        let s = EngineService(options: EngineOptions(arguments: args))
        service = s
        s.start()
        dispatchMain()
    }
}
```

### 3.4 What the engine must never link or initialise

The binary links everything, so these are **runtime** rules. A guard test enforces them in source.

- **Never touch any of these:**
  - `NSApplication.shared`, `NSApp`, `NSRunningApplication.activate`, `NSWorkspace` (any use), windows, or the SwiftUI `App`/`Scene`/`@StateObject`. Any of them can cause a LaunchServices check-in, which puts the process under RunningBoard and the Game Mode clamp (**M**, research L §2).
  - `ProcessInfo.beginActivity` / `PadActivity`. RunningBoard implements it as the "AppNap adapter assertion" that it tracked for GDHub (**M**, log). Keep the engine invisible to RunningBoard.
  - The GameController framework (`GCController`) and `UNUserNotificationCenter`.
  - Any `@MainActor` type: `AppModel`, `DriverManager`, `HIDMonitor`, `EnvisionProDevice`, `EnvisionProControl`, `LearnSession`, `PadActivity`, `LayoutEditor`, `DeviceModule`.
  - `Task { @MainActor … }`.
- **Allowed shared files**, used as they are:
  - `DextClient` (plus the new `DextControlling` protocol it conforms to), `DextProtocol`, `DextStatusPoller`, `HIDReportSizer`;
  - everything in `Output/VirtualPad/`;
  - `ControlMapping`, `MappingStore`;
  - `EnvisionProReport.swift` (`GamepadFrame`).
- **`SyntheticPadWatcher` stays in the GUI only.** It is display-only and has no dext dependency.
- **Guard test** `EngineIsolationTests`:
  - Files checked: every file under `Sources/GDHub/Engine/` plus the allowed shared files above.
  - It fails on `import SwiftUI`, `import AppKit`, `import GameController`, `@MainActor`, `NSApplication`, `NSApp`, `NSWorkspace`, `beginActivity` or `PadActivity`.
  - It finds the files with `URL(fileURLWithPath: #filePath)` → `../../Sources/GDHub/...`.

### 3.5 Hot-path threading (pattern B, **M** best variant)

- **Queue.** `vhidQueue = DispatchQueue(label: "com.interlinked.gdhub.vhid", qos: .userInteractive)` is serial. It holds:
  - the HID manager;
  - `DextClient` (IOKit notifications and the output-report port);
  - `VirtualPadSink` with its flush, heartbeat and pattern timers;
  - `DextStatusPoller` (1 Hz);
  - `ControllerPresence` and its 0.5 s timer;
  - all `EngineCore` state.
- **`GamepadHIDReader.start()`** runs on `vhidQueue`, in this exact order:

```swift
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x1B1C, kIOHIDProductIDKey: 0x3A08,
                                    kIOHIDPrimaryUsagePageKey: 0xFF58] as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(mgr, matched, ctx)     // presence.interfaceUp()
IOHIDManagerRegisterDeviceRemovalCallback(mgr, removed, ctx)      // presence.interfaceDown() -> neutral
IOHIDManagerRegisterInputReportWithTimeStampCallback(mgr, report, ctx)
IOHIDManagerSetDispatchQueue(mgr, vhidQueue)
IOHIDManagerSetCancelHandler(mgr) { /* release ctx; signals stop() completion */ }
let kr = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))   // non-exclusive; GUI keeps its own open
IOHIDManagerActivate(mgr)
// stop(): IOHIDManagerCancel(mgr) on vhidQueue; IOHIDManagerClose after the cancel handler runs
```

- **Report callback** (on `vhidQueue`). It never allocates the report or keeps it.

```swift
guard reportID == 6, let frame = GamepadFrame.parse(UnsafeBufferPointer(start: report, count: len)) else { return }
let tC = LatencyMeter.nowNs(); let tK = LatencyMeter.machToNs(timeStamp)   // same conversion HIDMonitor uses today
presence.report(atNs: tC)                       // may flip to .active -> core.controllerStatus(.active)
core.sink.submit(frame: frame, mapping: core.mapping, revision: core.mappingRevision, tK: tK, tC: tC)
```

- **Keep the sink's mailbox,** even though the reader and the sink share a queue.
  - It costs one same-queue `async` and no thread hop.
  - When an IOConnect post (0.6–1.8 ms against a 1.04 ms report interval, **M** meter) makes the queue fall behind, the mailbox coalesces to the newest frame.
- **Other queues:**
  - `powerQueue` (`.userInitiated`, serial);
  - `controlQueue` (`.userInitiated`), for signals;
  - `ipcQueue` (`.utility`, E2), which carries XPC replies and pushes;
  - the latency sort on the meter's existing utility queue.
- **Rule:** `vhidQueue` never `sync`s onto another queue, and the hot path never touches XPC, logging above `.debug`, or UserDefaults.
- **If the meter shows callback p99 > 2 ms in §8.3:**
  - move the HID manager to its own `hidQueue` (`.userInteractive`), one hop through the existing mailbox;
  - then try `defaults write com.interlinked.gdhub vpadMaxRateHz -float 250`.
- **Not in the engine:** `PadActivity`. Nothing on the hot path depends on RunningBoard.

## 4. LaunchAgent

### 4.1 Plist (verbatim)

Source: `Xcode/Engine/com.interlinked.gdhub.engine.plist`. It is copied into the app at
`Contents/Resources/com.interlinked.gdhub.engine.plist`, and the script or GUI installs it to
`~/Library/LaunchAgents/com.interlinked.gdhub.engine.plist`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.interlinked.gdhub.engine</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Applications/GDHub.app/Contents/MacOS/GDHub</string>
		<string>--engine</string>
	</array>
	<key>MachServices</key>
	<dict>
		<key>com.interlinked.gdhub.engine</key>
		<true/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>2</integer>
	<key>ExitTimeOut</key>
	<integer>5</integer>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>com.interlinked.gdhub</string>
	</array>
</dict>
</plist>
```

Notes on the keys:
- **`ProcessType=Interactive` is mandatory.** Standard and Background were measurably worse, and a legacy `launchctl submit` job was terrible (**M**).
- **`MachServices` is present from E1** even though the listener only arrives in E2, so the plist never changes between phases.
  - launchd holds the port. Nothing connects to it in E1.
- **`KeepAlive=true`**: respawn after any exit, clean or not (§2 "Engine stop"); only `bootout` stops it for good.
- **`ExitTimeOut` 5** bounds the time launchd waits after SIGTERM before SIGKILL. `bootout` itself does not wait (**M**), hence `bootoutAndWait` (§2).
- **`AssociatedBundleIdentifiers`** attributes the item to GDHub in Login Items for a legacy plist (**R**, research L).
- **No `StandardOutPath`/`StandardErrorPath`:** launchd does not expand `~`, and the engine logs through `os.Logger` (subsystem `com.interlinked.gdhub`, category `engine`). Crashes land in `~/Library/Logs/DiagnosticReports/GDHub-*.ips`.

### 4.2 Registration: a legacy plist with `launchctl bootstrap gui/$UID`, not SMAppService

Why:
- **It was measured on this Mac.** Every research agent ran this way (**M**).
- **It is deterministic across rebuilds.** `build-xcode.sh` replaces the app with `rm -rf` + `ditto` on every build. SMAppService would need unregister and register after every executable change, which is "must be re-registered or it may not launch", **R** SDK header.
- **SMAppService behaviour here is unknown.** It was never exercised with dev-signed apps and several copies of GDHub.app (DerivedData plus /Applications), all **G**.
- **The plist stays SMAppService-ready.** Migrating later (only if GDHub is ever distributed) means:
  - move the file to `Contents/Library/LaunchAgents/`;
  - replace `ProgramArguments` with `BundleProgram = Contents/MacOS/GDHub` plus `ProgramArguments = [GDHub, --engine]`;
  - drop `AssociatedBundleIdentifiers`;
  - call `SMAppService.agent(plistName:)`.
- **Background Task Management** may still post "Background Items Added" and show a toggle under Login Items & Extensions (**C/G**).
  - If the user switches the toggle off, the job will not load at login. Whether the GUI's own `launchctl bootstrap` then still loads it is untested (**G**); if it does not, the E1 fallback (§2) runs the GUI in in-app mode.
  - From E3, the GUI detects this with `SMAppService.statusForLegacyPlist(at:)` returning `.requiresApproval` (**R**) and offers `SMAppService.openSystemSettingsLoginItems()`.

### 4.3 `scripts/engine-agent.sh` (new; the one implementation shared by the build script and the user)

Usage: `scripts/engine-agent.sh install|uninstall|restart|status`. `L=com.interlinked.gdhub.engine`,
`DST=~/Library/LaunchAgents/$L.plist`, `SRC=/Applications/GDHub.app/Contents/Resources/$L.plist`.

All log reads use **`/usr/bin/log`**, never bare `log`: in zsh (this script, every `scripts/*.sh`, and the user's shell)
`log` is a builtin (`whence -w log` → `log: builtin`, **M**), so `log show …` fails with `log:1: too many arguments` and
an "empty output" check would pass without reading anything. `scripts/dext-log.sh` already does this (**R** :6).

- **`bootout_wait`** (used by `install`, `uninstall` and `build-xcode.sh`), the shell twin of `EngineAgent.bootoutAndWait()` (§2):
  1. `launchctl bootout gui/$UID/$L 2>/dev/null`.
  2. Poll `launchctl print gui/$UID/$L >/dev/null 2>&1` every 0.1 s until it fails, for at most 6 s.
  3. If still loaded: `pkill -9 -f '/Applications/GDHub.app/Contents/MacOS/GDHub --engine'`, print a warning, poll 1 s more.
- **`bootstrap_retry`:** `launchctl bootstrap gui/$UID "$DST"`; on rc 5 or 37 sleep 0.2 s and retry, up to 3 times; rc 5 followed by `launchctl print` rc 0 counts as loaded.
- **`install`:**
  1. `plutil -lint "$SRC"`, then `mkdir -p ~/Library/LaunchAgents`, then `cp "$SRC" "$DST"`.
  2. `bootout_wait`, then `bootstrap_retry`. (A plain bootout + bootstrap fails with rc 5 whenever the job was running, **M**.)
  3. `wait_connected` (below, up to 5 s).
  4. Print `status`.
- **`uninstall`:** `bootout_wait; rm -f "$DST"`. The `/Applications` GUI is in in-app mode from its next launch on.
- **`restart`:** `launchctl kickstart -k gui/$UID/$L`, then `wait_connected`.
- **`status`:** `launchctl print gui/$UID/$L | grep -E '^\s*(state|pid|spawn type|last exit code|runs) ='`, or "not loaded", plus the engine's last `connection:` log line since the process started.
  - The log line: `START=$(date -j -f '%a %b %d %T %Y' "$(ps -o lstart= -p $PID | xargs)" '+%Y-%m-%d %H:%M:%S')` (`xargs` trims the trailing padding `date` warns about, **M**), then `/usr/bin/log show --style compact --start "$START" --predicate 'subsystem == "com.interlinked.gdhub" AND category == "engine" AND eventMessage BEGINSWITH "connection: "' | tail -1`.
  - `EngineCore` logs every connection transition as `connection: <state>` at **`.notice`**, because `.info` lines are not persisted to the log store by default (**C** https://developer.apple.com/documentation/os/logger), and an engine may have connected hours ago.
  - Exit 0 only when `state = running`, `spawn type = interactive (4)` **and** that last line contains `connection: connected(`. A padless engine (`exclusive`, `rejected`, `waitingForService`) fails.
- **`wait_connected`:** repeat `status` quietly every 0.5 s for up to 5 s until it exits 0.

### 4.4 Where the GUI exposes it

- **E1**, a section at the top of the Driver menu (read-only):
  - The status line "Engine: running (pid N, launchd)", "Engine: loaded, not running (last exit X)" or "Engine: installed but not loaded".
  - **Restart engine**, which runs `kickstart -k` (replaced by a note in the §2 fallback state).
  - **Uninstall background engine (relaunch to apply)**: `bootoutAndWait` + remove the plist, then the note "Quit and reopen GDHub to use the in-app engine". This is the E1 way out without a shell.
  - The driver install, update and uninstall items keep working (§2).
  - The pad items are disabled, with the note "Pad is controlled by the background engine".
  - In display-only mode: only the status line "Display-only: the background engine owns the pad"; no `launchctl` items, no driver items.
  - In the fallback state: "Engine unavailable: using in-app" plus the in-app pad items.
- **E2:** the full Driver menu works in engine mode over XPC (§5).
- **E3:** a new **Engine** submenu with these items:
  - **Install background engine**: copy the plist and bootstrap, live-switching from in-app mode.
  - **Uninstall background engine**: bootout and remove the plist, live-switching to in-app mode.
  - **Restart engine**.
  - **Open Login Items…**.
  - The status line.
- The GUI runs `launchctl` through `Process` (`/bin/launchctl`; the app is not sandboxed) **off the main thread**, in `EngineAgent` (§6.1), and **only on its one serial `agentQueue`**, so no two agent operations ever overlap.
- The GUI offers install only when `Bundle.main.bundlePath` starts with `/Applications/` and the bundled plist exists.

### 4.5 Update and uninstall

- **App update:** handled by `build-xcode.sh` (§6.3). If the bundled plist differs from the installed one (`cmp`), `install` copies it over.
- **Uninstall of GDHub:**
  1. `scripts/engine-agent.sh uninstall`.
  2. The Driver menu's "Uninstall Driver".
  3. Delete the app.
- **A forgotten plist** whose app is missing makes launchd fail to spawn the job, which is harmless. `status` reports it.

## 5. IPC (E2)

### 5.1 Transport

- **`NSXPCConnection`** to the Mach service `com.interlinked.gdhub.engine` declared in the plist.
  - A GUI connection launches the engine on demand if it is loaded but idle.
- **Why not the alternatives:**
  - `XPCSession`/`XPCListener` are macOS 14+, but `XPCPeerRequirement` needs macOS 26.
  - `NSXPCConnection.setCodeSigningRequirement` / `NSXPCListener.setConnectionCodeSigningRequirement` are macOS 13+ (**C**, SDK swiftinterface, research C).
- **The wire format is two `@objc` methods carrying JSON `Data`.** Encoding is pure Swift and testable in SwiftPM, and new commands for the mapping engine need no new `@objc` selectors.

```swift
@objc protocol EngineXPC {                       // exported by the engine
    func request(_ payload: Data, reply: @escaping (Data) -> Void)   // EngineCommand -> EngineReply
}
@objc protocol EngineClientXPC {                 // exported by the GUI on the same connection
    func event(_ payload: Data)                  // EngineEvent
}
```

### 5.2 Codable types (`Sources/GDHub/Engine/IPC/EngineIPC.swift`, shared)

```swift
enum EngineIPC {
    static let version = 1
    static let machService = "com.interlinked.gdhub.engine"
    static let peerRequirement =
        #"anchor apple generic and certificate leaf[subject.OU] = "79XF6HYX8A" and identifier "com.interlinked.gdhub""#
    static func encode<T: Encodable>(_ v: T) throws -> Data          // JSONEncoder, .sortedKeys
    static func decode<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T
}

enum EngineCommand: Codable, Equatable, Sendable {
    case hello(ipcVersion: Int, guiBinaryUUID: String)
    case subscribe(live: Bool)                   // live = 1 Hz stats + latency
    case publish(identityID: String)
    case unpublish
    case setAutoPublish(Bool)
    case runTestPattern(loop: Bool)
    case stopTestPattern
    case setMapping(ControlMapping)              // GUI is the only writer of the mapping file; sent after each save
    case retryConnection
    case devTerminateDriver
    case setMaxRate(hz: Double)                  // E3 (needs VirtualPadSink.setMaxRate)
}

struct EngineReply: Codable, Equatable, Sendable {
    var ok: Bool
    var error: String?                           // e.g. "unsupported ipcVersion 2", "unknown identity xbox-foo"
    var status: EngineStatus?                    // always set on hello; set after any state-changing command
}

struct EngineStatus: Codable, Equatable, Sendable {
    var ipcVersion: Int
    var binaryUUID: String                       // LC_UUID of the running executable (BuildIdentity.current)
    var engineBuild: String                      // CFBundleVersion, display only
    var pid: Int32
    var seq: UInt64                              // increments on every push
    var connection: DextClient.State             // gains Codable
    var pad: PadPublishState                     // gains Codable
    var testPatternRunning: Bool
    var autoPublish: Bool
    var autoPublishHeldOff: Bool
    var controller: ControllerStatus             // new top-level enum, see §6.1
    var mappingRevision: Int                     // engine's own counter
    var maxRateHz: Double
    var throttled: Bool                          // self-check, §10 R1
    var lowPowerMode: Bool                       // ProcessInfo.isLowPowerModeEnabled
    var lastError: String?
}

struct EngineLive: Codable, Equatable, Sendable {
    var stats: PadStats?                         // gains Codable
    var latency: LatencySnapshot?                // gains Codable (incl. Percentiles)
}

enum EngineEvent: Codable, Equatable, Sendable {
    case status(EngineStatus)
    case live(EngineLive)
}
```

- Swift synthesises `Codable` for these enums with associated values.
- `DextClient.State` uses `kern_return_t` (`Int32`), so it codes as it is.
- **Versioning:**
  - A command that fails to decode gets `EngineReply(ok:false, error:"unsupported command")`.
  - A `hello` with another `ipcVersion` gets `ok:false`, and the GUI shows "Engine and app versions differ: Restart engine".
  - New cases are additive. Bump `version` only on breaking changes.

### 5.3 Flow and cadence

- **Engine `EngineListener`:**
  1. `NSXPCListener(machServiceName:)`.
  2. `setConnectionCodeSigningRequirement(EngineIPC.peerRequirement)`.
  3. Then `delegate.shouldAcceptNewConnection` sets `exportedInterface = EngineXPC`, `remoteObjectInterface = EngineClientXPC`, and one `EngineSession` per connection.
  4. NSXPC delivers on its own private queue; every handler's first act is `ipcQueue.async`, so all session state is confined to `ipcQueue`.
- **Command handling:** decode on `ipcQueue`, then `vhidQueue.async { let r = core.apply(cmd); ipcQueue.async { reply(encode(r)) } }`.
- **Status push:**
  - `EngineCore` callbacks on `vhidQueue` mark the status dirty.
  - The `ipcQueue` coalescer pushes `EngineEvent.status` at most every 100 ms (≤10 Hz) while dirty.
  - It also pushes a **2 s keep-alive** status, even when nothing changed, so the GUI can detect a dead engine.
  - A `vhidQueue.async` snapshot builds the payload; the hot path itself never builds it.
- **Live push:**
  - `EngineEvent.live` goes out at 1 Hz, from the poller tick, only while at least one session has `subscribe(live: true)`.
  - The GUI subscribes live only while the Driver menu or a status view is open; otherwise `live: false`.
- **No subscribers:** nothing is encoded. Pushes use `remoteObjectProxyWithErrorHandler`, and an error drops that session.

### 5.4 GUI side and error handling

- `protocol EngineChannel: AnyObject`: `func send(_ c: EngineCommand) async -> EngineReply`, `var onEvent: ((EngineEvent) -> Void)?`.
  - `XPCEngineChannel` in E2.
  - `LocalEngineChannel` in E3, which wraps an in-process `EngineCore`.
- **`EngineProxy`** is a `@MainActor final class EngineProxy: ObservableObject` that publishes `status: EngineStatus?`, `live: EngineLive?` and `reachability: .connecting | .up | .notResponding(since:) | .versionMismatch`.
  - `DriverCommands` reads it instead of `DriverManager`'s runtime fields.
- **Engine absent or dead:**
  - Each send has a 2 s timeout, built with a `DispatchWorkItem`.
  - On `interruptionHandler`, re-send `hello` after 1 s. launchd relaunches the engine on demand.
  - On `invalidationHandler`, create a new connection after 2 s.
  - With no event for more than 5 s, set `.notResponding` and show "Engine not responding" with **Restart engine** / **Use in-app engine** (E3).
  - Commands while not `.up` return `ok:false, "engine not running"`, and the menu items are disabled.
- **Stale binary:** if the engine's `binaryUUID` differs from the GUI's own `BuildIdentity.current`, the GUI runs `EngineAgent.restart()` once per GUI launch and logs it.
- **Security:**
  - Both sides set the same requirement string (§5.2): Apple anchor, team OU 79XF6HYX8A, identifier `com.interlinked.gdhub`. It matches because the engine is the same signed binary.
  - Correction (rev 2): `bundle.sh` signs with the first Apple Development identity, not ad hoc (**R** bundle.sh:34-36), and its `CFBundleIdentifier` is `com.interlinked.gdhub`, so such a build probably **does** satisfy this requirement (**G**). That is acceptable: with the agent installed it is a display-only GUI (§2) and only reads status. Only `GDHUB_SIGN_IDENTITY=- scripts/bundle.sh` (ad hoc) is refused.
  - Because of `--engine-foreground`, a dev engine started from the shell is reachable only in-process, since it has no Mach service.
  - Payloads are plain data. The engine validates identity IDs, rate ranges (60–1000 Hz) and mapping decode before applying.

## 6. Source layout and build

### 6.1 Files

**New (engine side, under `Sources/GDHub/Engine/`, AppKit-free):**

| File | Contents |
|---|---|
| `EngineMain.swift` | §3.3 |
| `EngineOptions.swift` | Parses `--engine-foreground`, `--latency-log`, `--publish-pad <id>`, `--test-pattern`, `--unpublish-after`, `--switch-pad-after` (moved semantics from DriverManager) |
| `EngineService.swift` | Owns the queues, `EngineCore`, `GamepadHIDReader`, `ControllerPresence`, the SIGTERM/SIGINT sources, `PowerObserver`, and `EngineListener` (E2); `start()` |
| `EngineCore.swift` | Runtime half of today's `DriverManager`, confined to `vhidQueue` and not MainActor. It owns `DextClient`, `VirtualPadSink` and `DextStatusPoller`, the `dext.onState` → sink/poller wiring, the `.exclusive`/`.failed` retry schedule (§2 "Dext ownership recovery"), the `.notice` `connection: <state>` log line on every transition (§4.3 `status`), `setMapping(_:)`, `evaluateAutoPublish(retryBlocked:)`, `controllerActive`, `autoPublishHeldOff`, `mapping`/`mappingRevision` (loaded with `MappingStore.envisionPro.load()`), the dev aids, `apply(_ EngineCommand) -> EngineReply` (E2), `status()`, `shutdown()` and `neutral()`. Its callbacks are `onConnection`, `onPadState`, `onTestPattern`, `onStats`, `onLatency` and `onStatusDirty`, all called on `vhidQueue` |
| `GamepadHIDReader.swift` | §3.5 |
| `ControllerPresence.swift` | `interfaceUp/Down`, `report(atNs:)`, a 0.5 s `DispatchSourceTimer` with 50 ms leeway, and an asleep-after-2 s rule that mirrors `EnvisionProDevice.timerTick`. It emits `ControllerStatus` changes to `core.controllerStatus(_:)` (not active → `sink.neutral()`; becoming active → auto-publish with `retryBlocked: true`). The clock is injectable |
| `PowerObserver.swift` | §2 sleep/wake |
| `MappingWatcher.swift` | E1 live mapping reload (§7). `open(dir, O_EVTONLY)` on `~/Library/Application Support/GDHub/` (created with `withIntermediateDirectories` if missing) and `DispatchSource.makeFileSystemObjectSource(fileDescriptor:eventMask: .write, queue: controlQueue)`. It watches the **directory**, because `MappingStore` writes `.atomic` (**R** MappingStore.swift:31), which renames a new inode into place, so a watch on the file itself would go deaf after the first save. On an event: debounce 50 ms, `MappingStore.envisionPro.load()` on `controlQueue`, then `vhidQueue.async { core.setMapping(m) }`, which bumps `mappingRevision` only if `m != mapping` and logs `mapping reloaded (rev N)` at `.notice`. File I/O stays off `vhidQueue` (§3.5 rule). Kept after E2 as a fallback to `setMapping` |
| `ThrottleCheck.swift` | Runs once per second on `vhidQueue` (E1 logs only; E2 sets `status.throttled`). It reads `getpriority(PRIO_DARWIN_PROCESS, 0)` and `thread_info(mach_thread_self(), THREAD_EXTENDED_INFO)` → `pth_priority` (base), deallocating the thread port. Throttled when PRIO_DARWIN_BG is set or the base priority is ≤ 4. It logs at `.error` on each transition (**G** on the exact fields; verify against napwatch in §8.2) |
| `IPC/EngineIPC.swift` | §5.2 (E2) |
| `IPC/EngineListener.swift` | §5.3 (E2) |

**New (shared / GUI):**

| File | Contents |
|---|---|
| `Sources/GDHub/Entry.swift` | §3.3 |
| `Sources/GDHub/Shared/ControllerStatus.swift` | `enum ControllerStatus: String, Codable, Sendable { case disconnected, receiverIdle, asleep, active }` plus `label`. `EnvisionProDevice` uses `typealias Status = ControllerStatus` |
| `Sources/GDHub/Shared/BuildIdentity.swift` | `static let current: String`, the LC_UUID of `_dyld_get_image_header(0)` |
| `Sources/GDHub/Output/VirtualHID/EngineAgent.swift` | GUI-only, not MainActor. Every operation runs on one serial `agentQueue` (`.utility`). It holds `label`, `installedPlistURL`, `bundledPlistURL`, `isInstalled`, the pure `guiMode(bundlePath:installed:) -> GUIMode` (§2), `status() -> AgentStatus {loaded, state, pid, lastExit, spawnType}` (parses `launchctl print`; rc 113 = not loaded), `bootstrap()` (rc 5/37 retry, §2), `bootoutAndWait()`, `restart()`, `ensureLoaded()` (state table in §2, no-op while `updateInFlight`), `fallbackCheck()` (§2 E1 fallback), `uninstallAgent()` (E1 menu item) and `install()` (E3) |
| `Sources/GDHub/Output/VirtualHID/DextControlling.swift` | `protocol DextControlling: AnyObject { func start(); func retry(); func stop(); func devTerminate() -> kern_return_t; var onState: ((DextClient.State) -> Void)? { get set } }`, i.e. exactly the members `DriverManager` calls today (**R**: `start`, `stop`, `retry`, `devTerminate`, `onState`). `DextClient` conforms. `InertDext` conforms with no IOKit at all: every call logs once at `.debug` and does nothing, the state stays `.stopped`, `devTerminate` returns `kIOReturnNotReady`. The sink and poller in engine/display-only mode are never wired (`wireVirtualPad()` skipped), so they need no stub. Used by `DriverManager` in engine and display-only mode |
| `Sources/GDHub/UI/EngineProxy.swift` | §5.4 (E2) |
| `Sources/GDHub/UI/XPCEngineChannel.swift` | E2 |
| `Xcode/Engine/com.interlinked.gdhub.engine.plist` | §4.1 |
| `scripts/engine-agent.sh` | §4.3 |

**Modified:**

| File | Change |
|---|---|
| `App.swift` | Drop `@main`. `AppModel.init` computes `mode = EngineAgent.guiMode(…)` once. In engine and display-only mode it skips `wireVirtualPad()` (no `onFrame` → sink, no sleep/terminate observers). It does **not** call `ensureLoaded()`; `DriverManager` does, once its properties query settles (§2). On the §2 fallback it switches this session to in-app (`DriverManager.becomeInApp()` + `wireVirtualPad()`) |
| `DriverManager.swift` | Init takes `mode: GUIMode` and `dext: DextControlling` (default `DextClient`); engine and display-only mode pass `InertDext`, so `start()`, `didFailWithError` (:360), `handleProperties(.active)` (:378), `retryConnection()` (:375/279), `devTerminateDriver`, publish/unpublish and the test pattern can never say hello: the gate sits at the source, not at each call site. The same `mode` flag also: clears `devTerminateOutstanding` at init with the log "--dev-terminate-driver ignored in engine mode"; ignores `--publish-pad`/`--unpublish-after`/`--switch-pad-after`/`--test-pattern` (one log line); makes `publishPad`/`unpublishPad`/`runTestPattern` return early so the GUI's sink never `persist`s `vhid.pad.*`. Display-only additionally never runs `queryProperties`, extension requests or `EngineAgent`. In engine mode `installOrUpdate`/`uninstall` first run `bootoutAndWait` on `agentQueue` (setting `updateInFlight`), then the request; `didFinish`/`didFail`/`handleProperties(.active | .notInstalled | .needsApproval)` → `ensureLoaded()` on `agentQueue`. `becomeInApp()` swaps in a real `DextClient` (fallback only). `devTerminateDriver` routes through `EngineProxy` from E2. From E3 the runtime half is deleted and the class becomes the installer only |
| `DriverCommands.swift` | E1: engine status line plus Restart, pad items disabled in engine mode. E2: reads `EngineProxy` |
| `VirtualPadSink.swift` | Add `Codable` to `PadPublishState`. E3: `setMaxRate(_ hz: Double)` (queue-confined; recompute the interval, reset `lastPostAt`). `PadIdentity.spec(defaults:)` takes the sink's `defaults` instead of `.standard` |
| `DextClient.swift`, `DextStatusPoller.swift`, `LatencyMeter.swift` | Add `Codable` to `State`, `PadStats`, `LatencySnapshot`/`Percentiles` (E2) |
| `EnvisionProDevice.swift` | `Status` → typealias. E2: on mapping save, `engineProxy.send(.setMapping(mapping))` in engine mode |

### 6.2 `project.yml`

There is no new target. Add the plist as a resource of `GDHub`, and keep it out of the SwiftPM target. The SwiftPM target's path is `Sources/GDHub`, so `Xcode/Engine` is already outside it.

```yaml
    sources:
      - Sources/GDHub
      - Xcode/App/BundleModule+Xcode.swift
      - path: Xcode/Engine/com.interlinked.gdhub.engine.plist
        buildPhase: resources            # -> Contents/Resources/com.interlinked.gdhub.engine.plist
```

- `Info.plist` and the entitlements do not change.
- `bundle.sh` changes one line. Its `pkill -f "GDHub.app/Contents/MacOS/GDHub"` (**R** bundle.sh:40) also matches `/Applications/GDHub.app/Contents/MacOS/GDHub --engine`. Narrow it to its own copy: `pkill -f '\.build/GDHub\.app/Contents/MacOS/GDHub$' 2>/dev/null && sleep 0.5`. (With `KeepAlive=true` a stray TERM would only cost a ~2–3 s respawn gap, but the script has no reason to touch the engine.)
- A `bundle.sh` app is display-only while the agent is installed and in-app (refused with `rejected`, as today) when it is not (§2).

### 6.3 `scripts/build-xcode.sh`

0. **Before the build (E1 only), right after the `BUILD=` line (:21):**
   ```zsh
   AGENT=~/Library/LaunchAgents/com.interlinked.gdhub.engine.plist
   if [[ -f $AGENT ]] && (( ! SAME )); then
     echo "dext build would change while the background engine is installed:"
     echo "run scripts/engine-agent.sh uninstall first (or pass --same-build)"; exit 2
   fi
   ```
   This enforces the §2 E1 dev-swap rule (in engine mode the GUI has no `devTerminate`, so a second consecutive dext swap would hit R8). Lifted in E2.
1. **After `need "$APP" …`, add the checks:**
   - `[[ -f $APP/Contents/Resources/com.interlinked.gdhub.engine.plist ]] && plutil -lint` on it.
   - `codesign -d --entitlements :- "$APP" > $T; /usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' $T` must equal `79XF6HYX8A.com.interlinked.gdhub`. The same check runs for `:com.apple.developer.team-identifier` == `79XF6HYX8A`. These are the dext's exact rules (§3.2).
2. **Replace** `pkill -x GDHub 2>/dev/null && sleep 1 || true` (:55) with:
   ```zsh
   [[ -f $AGENT ]] && scripts/engine-agent.sh bootout_wait  # waits until launchctl print says not loaded (§2)
   pkill -x GDHub 2>/dev/null && sleep 1 || true          # only the GUI is left to match
   ```
3. **After `ditto`:**
   ```zsh
   if [[ -f $AGENT ]]; then
     scripts/engine-agent.sh install                      # refreshes the plist, bootout_wait, bootstrap_retry, wait_connected
     scripts/engine-agent.sh status || { echo "engine not connected: /usr/bin/log show --last 1m --predicate 'subsystem == \"com.interlinked.gdhub\" AND category == \"engine\"'"; exit 1; }
   fi
   ```
4. **Add a usage line:** `--engine-install`, which runs `scripts/engine-agent.sh install` after `ditto` even when the agent is not yet installed. This is the one-time switch to engine mode. (Pass it with `--same-build`, or the check in step 0 does not apply because the plist is not yet installed; a dext bump on the switch build is then handled by the GUI's bootout/ensureLoaded wrapper, §2.)

### 6.4 SwiftPM

- Keep the single `executableTarget` and `testTarget`. Everything new lives inside `Sources/GDHub`, so `@testable import GDHub` covers `EngineCore`, `ControllerPresence`, the IPC types and the `EngineAgent` parser.
- `swift build` must link `IOKit` power APIs (`IORegisterForSystemPower`), which `import IOKit.pwr_mgt` covers. No manifest change.
- `swift test` runs 120 tests today; about 25 new ones are expected (§8.1).

## 7. Settings and data sharing

- **UserDefaults domain `com.interlinked.gdhub`, through `UserDefaults.standard`, in both processes.**
  - The engine's `Bundle.main` is GDHub.app (**M**).
  - **Never** use `UserDefaults(suiteName: "com.interlinked.gdhub")` inside the bundle: it returns nil values and logs "does not make sense" (**M**).
  - `CFPreferencesCopyAppValue(key, "com.interlinked.gdhub" as CFString)` also works (**M**), for any future non-bundle tool.
- **Who writes what:**

| Key | Writer in engine mode | Reader |
|---|---|---|
| `vhid.pad.enabled`, `vhid.pad.identity` | Engine (sink `persist`) | Engine at start (`transportConnected`) |
| `vhid.pad.autoPublish` | Engine on `setAutoPublish` (E2); the user's `defaults write` in E1 | Engine at start; status |
| `vpadMaxRateHz` | User `defaults write` (E1/E2); engine on `setMaxRate` (E3) | Engine at start |
| `vhid.pad.productOverride` | User (dev) | Engine at `createDevice` |
| `showInputMonitor`, layout and Bragi keys | GUI | GUI |

- **The engine reads defaults only at start.** Cross-process `UserDefaults` caching makes later reads unreliable without a notification (**G**), so live changes travel as commands that carry the value. Each command handler writes the key itself, so a restart picks it up.
- **Mapping file:** `~/Library/Application Support/GDHub/envision-pro-mapping.json` (`MappingStore.envisionPro`).
  - The GUI is the only writer.
  - The engine loads it at start. A launchd gui-domain agent's `HOME` is the user's home (**G**; E1 logs the resolved path).
  - **E1:** `MappingWatcher` (§6.1) watches the directory and reloads on every save, so a learn or remap result reaches the pad within ~50–100 ms, as it does in-app today (where `EnvisionProDevice.mapping`'s `didSet` bumps `mappingRevision` and the next `onFrame` applies it, **R** EnvisionProDevice.swift:61-62, App.swift:70). No XPC needed.
  - From E2, the GUI also sends `setMapping(mapping)` after every save. XPC preserves message order on one connection, so the engine applies them in arrival order and bumps its own `mappingRevision`. That makes the sink re-send the current frame under the new mapping, and no revision comparison across processes is needed. The watcher's reload of the same file then compares equal and does not bump.
- **Future (E4):** profiles live as files in `~/Library/Application Support/GDHub/profiles/<id>.json`.
  - The engine holds the active profile.
  - The GUI edits files and then sends `profileChanged(id)` / `activateProfile(id)`.
  - No Darwin notifications are needed while XPC is up. The engine re-reads all profiles at start.

## 8. Test plan

### 8.1 Unit tests (`swift test`, all 120 existing tests plus these)

- **`EngineIPCTests`:**
  - JSON round-trip of every `EngineCommand` case, `EngineEvent.status` and `.live`, and `EngineReply`.
  - An unknown command fails to decode, which maps to an `ok:false` reply.
  - `DextClient.State`, `PadPublishState`, `PadStats` and `LatencySnapshot` round-trips.
- **`ControllerPresenceTests`** (injected clock):
  - disconnected → active on the first report;
  - active → asleep at 2.0 s without reports, not at 1.9 s;
  - identical frames keep it active;
  - `interfaceDown` → disconnected;
  - `didWake` clears `lastReportAt`.
- **`EngineCoreTests`** (fake `PadTransport` and `SinkScheduler` from `VirtualPadSinkTests`, fake `DextClient` state injection):
  - auto-publish fires on `.connected` plus active;
  - no auto-publish while `autoPublishHeldOff`;
  - `unpublish` holds off until `publish`;
  - a `.blockedDuplicate` retry on re-activation;
  - neutral on asleep;
  - `transportConnected` restores an enabled pad;
  - `setMapping` bumps the revision, and the sink re-posts;
  - `apply(.publish(identityID: "nope"))` → `ok:false`;
  - `.exclusive` schedules `retry()` at 0.25/0.5/1/2 s then every 2 s (injected scheduler), stops on `.connected`; `.rejected` schedules nothing;
  - `setMapping` with an equal mapping does not bump the revision.
- **`EngineIsolationTests`:** §3.4.
- **`EngineAgentTests`:**
  - parsing of captured `launchctl print` samples: running, `state = not running` (no pid), `state = SIGTERMed` with a pid, not loaded (rc 113); and the `ensureLoaded` decision for each (§2 table), including bootstrap rc 5 then print rc 0 → success;
  - `guiMode`: installed + `/Applications/GDHub.app` → engine; installed + `.build/GDHub.app` or `.xcodebuild/…` → displayOnly; not installed → inApp;
  - the template plist parses, with `ProcessType == Interactive`, `ProgramArguments == ["/Applications/GDHub.app/Contents/MacOS/GDHub", "--engine"]`, `KeepAlive == true`, the MachServices key `com.interlinked.gdhub.engine`, and `LimitLoadToSessionType == Aqua`.
- **`DriverManagerModeTests`** (`@MainActor`, a recording `DextControlling` fake): in `.engine` and `.displayOnly` mode, `start()`, `request(_:didFailWithError:)`, `handleProperties` with an `.active` build (first and changed build), `retryConnection()`, `devTerminateDriver()`, `publishPad`, `unpublishPad` and `runTestPattern` record **zero** calls on the fake after draining `vhidQueue` (`vhidQueue.sync {}`); `--dev-terminate-driver` leaves `devTerminateOutstanding == false`. In `.inApp` the same `start()` records one `start`. (Requires `handleProperties` to become `internal` for `@testable` access.)
- **`MappingWatcherTests`:** in a temp dir, an `.atomic` write of a changed mapping fires one reload; a second `.atomic` write fires again (proves the directory watch survives the inode swap); an identical rewrite does not bump.
- **`EntryTests`:** an `EngineOptions` parse of the dev aids.

### 8.2 Live checks without the controller (after E1)

All log commands below are written as **`/usr/bin/log`**: bare `log` is a zsh builtin and silently "passes" an
empty-output check (§4.3, **M**). Every "must be empty" capture has a positive control in the same capture.

1. **Build and install.** `scripts/build-xcode.sh --release --same-build --no-open --engine-install` passes all checks. Then `scripts/engine-agent.sh status` exits 0, which now means `state = running`, `spawn type = interactive (4)` **and** a `connection: connected(` engine line since the engine started (§4.3).
2. **Entitlements under launchd (§3.2 G).** `/usr/bin/log show --last 2m --predicate 'subsystem == "com.interlinked.gdhub" AND category == "engine"'` shows "engine started" (with the resolved mapping path, §7) and `connection: connected(dextBuild: 17)`.
   - It must **not** show `rejected`, or `exclusive` that is not followed by `connected` within 3 s.
   - The real pass criterion is the `connected` line. `/usr/bin/log show --last 2m --predicate 'process == "amfid" AND eventMessage CONTAINS[c] "gdhub"'` is diagnostic only (an amfid kill would also show as exit 137 in `launchctl print`, R2), since there is no positive control for amfid.
3. **No RunningBoard / LaunchServices.**
   - `lsappinfo list | grep -c com.interlinked.gdhub` is 0 with only the engine running.
   - Capture by RunningBoard identity, not pid substring (a 5-digit pid matched an unrelated runningboardd line, **M**, review), with the GUI as positive control:
     ```zsh
     /usr/bin/log stream --style compact --predicate 'process == "runningboardd" AND eventMessage CONTAINS "com.interlinked.gdhub"' > ~/gdhub-rb.txt &
     open /Applications/GDHub.app; sleep 5; osascript -e 'quit app "GDHub"'; sleep 2; kill %1
     grep -c 'osservice<com.interlinked.gdhub.engine' ~/gdhub-rb.txt    # must be 0
     grep -c 'application.com.interlinked.gdhub' ~/gdhub-rb.txt          # must be > 0, else the capture is invalid
     ```
     (**G** on the exact RunningBoard identity spellings; check them against the GUI lines in the same file before trusting a 0.)
4. **GUI coexists.**
   - `open /Applications/GDHub.app` starts a GUI: `pgrep -x GDHub | wc -l` = 2, and `lsappinfo` count = 1.
   - The Driver menu shows "Engine: running (pid N)".
   - `scripts/dext-log.sh` shows no new hello and no exclusive refusal while the GUI starts, and the GUI's own `category == "vhid"` log has no `DextClient` lines (it runs `InertDext`).
   - Quit and reopen the GUI 3 times in a row: `engine-agent.sh status` still exits 0 with the same engine pid.
5. **Pad and test pattern from the shell.**
   1. Run `scripts/engine-agent.sh uninstall`.
   2. Run `/Applications/GDHub.app/Contents/MacOS/GDHub --engine --engine-foreground --publish-pad xbox-bt16-02e0 --test-pattern --latency-log`.
   3. `scripts/vhid-check.sh` must show a pad count of 1, and posts must appear in the latency log.
   4. Ctrl-C (SIGINT, same handler as SIGTERM) must make the pad count 0 within 1 s.
   5. Then `scripts/engine-agent.sh install`.
   - This also confirms that the main executable passes `hello` from the shell, as research L measured.
   - Also: `open /Applications/GDHub.app --args --engine` must **not** run an engine (the LaunchServices copy has `XPC_SERVICE_NAME=application.…`): it exits 64 and logs the refusal (§2 layer 2).
6. **Crash and TERM restart.** Beforehand `defaults write com.interlinked.gdhub vhid.pad.enabled -bool YES` (the `--publish-pad` dev aid does not persist, **R** DriverManager.swift:140), then `kickstart -k`.
   - `kill -9 <engine pid>`: the pad count drops to 0, a new pid starts within 4 s, the pad returns, `runs` increments.
   - `kill -TERM <engine pid>` (clean exit 0): same result, because `KeepAlive=true`.
   - `scripts/bundle.sh` (narrowed `pkill`, §6.2): the engine pid is unchanged.
7. **Stop is final.** `scripts/engine-agent.sh bootout_wait` (or the `Uninstall background engine` menu item without the `rm`): returns only after `launchctl print` fails; the pad disappears, there is no respawn, and the GUI shows "installed but not loaded". Relaunching the GUI reloads it. (Still holds with `KeepAlive=true`, because bootout unloads the job.)
8. **Sleep.** `pmset sleepnow`, then wake: same engine pid, the log has "will sleep: pad neutral", and the pad is still present.
9. **Rebuild.** `scripts/build-xcode.sh --release --same-build --no-open`: the engine pid changes, `install` does not fail with `Bootstrap failed: 5`, and E2+ shows a matching binary UUID in the menu. Without `--same-build` the script exits 2 with the uninstall hint (§6.3 step 0).
10. **Throttle self-check sanity.** Run `$SP/padlat/napwatch <engine pid> 20` while the GDHub window is occluded.
    - The engine's `vhid` thread base priority must be > 4 (expected 31/47).
    - `ThrottleCheck` must log nothing.
    - Copy `napwatch.swift` from the scratch dir into `scripts/tools/napwatch.swift` in E1 so the tool survives the session (**G** that it builds with `swiftc -O`).
11. **`.exclusive` heals.** `bootout_wait`; start a `--engine-foreground --publish-pad xbox-bt16-02e0` copy in a terminal (it owns the dext); `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.interlinked.gdhub.engine.plist`. The engine logs `exclusive: retry #n` and `engine-agent.sh status` exits non-zero. Ctrl-C the foreground copy: within ≤ 2.5 s the engine logs `connection: connected(` and `status` exits 0, with no manual Retry.
12. **Display-only copy.** With the agent installed, `scripts/bundle.sh` and an `.xcodebuild/…/GDHub.app` (`build-xcode.sh --same-build --no-install`) each open with "Display-only: the background engine owns the pad"; `scripts/dext-log.sh` shows no hello from them, and the engine pad is untouched (`vhid-check.sh` pad count unchanged, same engine pid).
13. **Live mapping reload.** With the engine publishing, change one binding in learn mode in the GUI: within 1 s the engine logs `mapping reloaded (rev N)`; a second change logs `rev N+1` (directory watch survived the atomic replace).
14. **E1 fallback.** `launchctl disable gui/$UID/com.interlinked.gdhub.engine; scripts/engine-agent.sh bootout_wait`, then open the GUI: bootstrap fails, the GUI shows "Engine unavailable: using in-app" within ~6 s and publishes the pad itself. Quit it, `launchctl enable gui/$UID/com.interlinked.gdhub.engine`, reopen: engine mode again, engine `connected`. (**G** on the bootstrap error code for a disabled job; the fallback keys on "never `state = running`", not on the code.) Then the **Uninstall background engine** menu item: after a GUI relaunch the GUI is in in-app mode, and `engine-agent.sh install` restores engine mode.

### 8.3 The measurement: the user plays fullscreen Shadow (E1 gate)

Setup:
- Controller on. `scripts/build-xcode.sh --release --same-build` with the engine installed. Shadow PC fullscreen.
- **Confirm that Game Mode is ON:** `/usr/bin/log stream --predicate 'process == "gamepolicyd"'` must show "Game mode enabled" or "Game mode status is now on". This is the run research L could not do.

Run in parallel for the whole session (`SP` = the directory holding `padlat/napwatch`, or `scripts/tools` once copied):
```zsh
PID=$(launchctl print gui/$UID/com.interlinked.gdhub.engine | awk '/^\tpid =/{print $3}')
$SP/padlat/napwatch $PID 600 > ~/gdhub-nap-engine.txt &
$SP/padlat/napwatch $(pgrep -x GDHub | grep -v $PID | head -1) 600 > ~/gdhub-nap-gui.txt &      # control: GUI should clamp
/usr/bin/log stream --style compact --predicate 'process == "runningboardd" AND eventMessage CONTAINS "com.interlinked.gdhub"' > ~/gdhub-rb.txt &   # engine + GUI (positive control)
/usr/bin/log stream --style compact --predicate 'subsystem == "com.interlinked.gdhub" AND (category == "latency" OR category == "engine")' > ~/gdhub-lat-engine.txt &
```

The user plays for at least 6 minutes, with stick flicks, taps, trigger pulls and circles.

Pass criteria, over 10 s meter windows with at least 30 changed frames:
- **Total delay:** median-window p50 **< 2 ms**, median-window p99 **< 5 ms**, worst-window max **< 20 ms**. Baseline: 57 / 135 / 1476 ms (§7).
- **Kernel → callback:** median-window p50 < 0.5 ms.
- **Posts follow the input rate:**
  - during motion, `postsHz` is at least 90 % of the changed-frame rate, up to the 1000 Hz cap;
  - `coalescedPercent` is < 20 %, against 76 % before;
  - never the old ~15 Hz.
- **napwatch (engine):** the base priority is never 4 in any sample, and `ThrottleCheck` logs nothing.
- **napwatch (GUI):** priority 4 in the occluded samples. This confirms the clamp was active, so the test is valid.
- **`~/gdhub-rb.txt`:** `grep -c 'osservice<com.interlinked.gdhub.engine'` = 0, **and** the GUI's `application.com.interlinked.gdhub` lines are present (positive control: the role flips Background ↔ foreground with Game Mode). A file with no GUI lines invalidates the criterion. (Matching on the identity, not `$PID`, because a pid substring matched unrelated lines, **M** review.)
- **Subjective:** the user reports no lag.

If it fails, see §10 R1 and R6.

### 8.4 Result: gate passed, 2026-11-09 07:59–08:07 (Game Mode on)

The user played fullscreen Shadow. gamepolicyd logged "Game mode enabled" at 07:59:06 and "Game mode status is now paused" at 08:07:39, so the whole 8.5 minutes ran under Game Mode. Engine pid 41185 (up since 02:45, release build, dext build 17). 34 ten-second meter windows with at least 30 changed frames, 71 599 changed frames in total:

| Criterion | Limit | Measured | Verdict |
|---|---|---|---|
| Total delay, median-window p50 | < 2 ms | 1.19 ms (windows 0.80–1.72) | pass |
| Total delay, median-window p99 | < 5 ms | 2.69 ms (worst window 3.47) | pass |
| Total delay, worst-window max | < 20 ms | 8.88 ms | pass |
| Kernel → callback, median-window p50 | < 0.5 ms | 0.12 ms | pass |
| Posts vs changed-frame rate | ≥ 90 % | 100 % (median 217 Hz, peak 363 Hz) | pass |
| Coalesced | < 20 % | median 21 %, worst window 32 % | marginal miss |
| Engine thread priority | never 4 | `vhidPrio=37` and `napped=no` in all 51 windows; napwatch lowest 20 in 2352 samples; `ThrottleCheck` logged nothing | pass |
| runningboardd tracks the engine | 0 lines | 0 `osservice<com.interlinked.gdhub.engine` lines | pass |
| Positive control (GUI is clamped) | present | GUI pid 41283 "Set darwin role to: Background" at 07:59:06, back to UserInteractiveNonFocal at 08:07:39 | valid |
| Subjective | no lag | not yet reported by the user | open |

Notes:
- Baseline for the same play in the GUI app (latency-plan §7): 57 ms p50, 135 ms p95, 1476 ms max, 15 Hz posts, 76 % coalesced.
- The coalescing that remains comes from the sink's 1000 Hz rate cap: the `cap` stage adds about 0.65 ms p50 of the 1.19 ms total, `io` (IOConnect) about 0.36 ms. Posting on the leading edge when the minimum interval has already elapsed would remove most of it. That is worth at most 0.6 ms against Shadow's 10 ms joystick poll, so it is not scheduled.
- The napwatch GUI control run in the recipe above was replaced by the runningboardd role log, which shows the same clamp directly. `napwatch`'s `front=` column stayed on the launching app for the whole run (no run loop, so `frontmostApplication` never updates); only its priority columns are reliable.
- Shadow kept the receiver unforwarded across its restart: the engine received 946–961 reports per second in every window, with no gap.
- §10 R1 (real-time thread, dext-side forwarding) is not needed.

## 9. Phased implementation (one Sonnet implementer)

Run each phase as: implement, then `swift build && swift test`, then `scripts/build-xcode.sh --release --same-build --no-open`, then the phase's live checks, then commit. Do not start the next phase until the done-checks are green.

### E1: Engine runs passthrough; GUI stops owning the dext (tonight)

Scope, kept deliberately small:
- **Do:**
  - `Entry.swift` and `Engine/{EngineMain, EngineOptions, EngineService, EngineCore, GamepadHIDReader, ControllerPresence, PowerObserver, ThrottleCheck, MappingWatcher}`, including the `.exclusive` retry and the `.notice` `connection:` lines.
  - `Shared/ControllerStatus.swift`.
  - `EngineAgent` on its serial `agentQueue` (guiMode, status, bootstrap with rc 5/37 retry, bootoutAndWait, restart, ensureLoaded, fallbackCheck, uninstallAgent) and `DextControlling`/`InertDext`.
  - The plist and its `project.yml` resource entry.
  - `scripts/engine-agent.sh` (with `bootout_wait`, `bootstrap_retry`, `wait_connected`, log-checked `status`), the `build-xcode.sh` changes (§6.3, including the step-0 refusal) and the one-line `bundle.sh` `pkill` narrowing (§6.2).
  - The three GUI modes and the E1 fallback in `App.swift`, `DriverManager` (injected `DextControlling`, `devTerminateOutstanding` cleared) and `DriverCommands` (§4.4 E1, including **Uninstall background engine (relaunch to apply)**).
  - Unit tests: `ControllerPresenceTests`, `EngineCoreTests` (auto-publish, neutral, restore, exclusive retry), `EngineIsolationTests`, `EngineAgentTests`, `DriverManagerModeTests`, `MappingWatcherTests`.
- **Don't:**
  - Add XPC, or change the `DriverManager` runtime logic used by in-app mode (E1 only injects `DextControlling` and adds the `mode` gate; in-app passes the real `DextClient`, so its behaviour is unchanged). `EngineCore` *copies* the about 80 lines of auto-publish and wiring logic, and that debt is removed in E3.
  - Change in-app behaviour. Engine mode keeps today's user-visible behaviour too: a learn/remap result reaches the pad live through `MappingWatcher` (§7).
- **Settings:** the engine uses the existing `vhid.*` and `vpadMaxRateHz` defaults and the mapping file as they are.

Done-checks:
- `swift build`, `swift test` (all green, 120+), `scripts/bundle.sh` still bundles and launches.
  - With the agent installed, the `bundle.sh` GUI is display-only: no hello in `scripts/dext-log.sh`, the engine's pad untouched (§8.2 check 12).
  - With the agent uninstalled, the `bundle.sh` GUI shows `rejected`, exactly as today (it never could publish: unsigned entitlements, **R** DriverManager.swift:180-182).
  - In-app regression: `scripts/engine-agent.sh uninstall` + `scripts/build-xcode.sh --release --same-build`; the `/Applications` GUI publishes the pad as before, and learn mode changes apply live.
- `build-xcode.sh --engine-install` passes, including the app-identifier value check.
- §8.2 checks 1–14 except 9's E2 part.
- §8.3 play measurement passes, **with Game Mode confirmed on**.
- Commit message: `Engine: headless Interactive LaunchAgent runs the pad hot path (E1)`.

### E2: XPC status and full Driver-menu control

- **Do:**
  - `Engine/IPC/{EngineIPC, EngineListener}`, `UI/{EngineProxy, XPCEngineChannel}`.
  - `Codable` on the status types.
  - `BuildIdentity`, the stale-binary restart, and the 2 s keep-alive with "not responding".
  - `DriverCommands` reads `EngineProxy` in engine mode: connection, pad, stats, latency lines, autoPublish toggle, publish/unpublish, test pattern, retry and devTerminate (also `--dev-terminate-driver`).
  - `setMapping` on every mapping save.
  - `EngineIPCTests`.
- **Done-checks:**
  - The menu in engine mode shows live posts/s and latency lines that match the engine log.
  - Every Driver-menu action works, checked against the pad count in `vhid-check.sh`.
  - Learn a mapping change and see it take effect through `setMapping` (engine log shows the command; the watcher's reload of the same file then does not bump the revision).
  - `kill -9` the engine: the menu shows "not responding" within 5 s, then recovers.
  - A rebuild with `--same-build` triggers exactly one stale-binary restart.
  - Quitting the GUI leaves the pad published, and reopening it shows the status again.
  - A peer-requirement check: a `GDHUB_SIGN_IDENTITY=- scripts/bundle.sh` copy (ad hoc) gets its connection refused, and the engine logs it. (A default `bundle.sh` copy is Apple-Development-signed and may be accepted as a display-only reader, §5.4.)
  - The build-script dext-bump refusal (§6.3 step 0) is removed, and a consecutive dext swap with `--dev-terminate-driver` works in engine mode.

### E3: One core, live mode switching

- **Do:**
  - `DriverManager` loses its runtime half. In-app mode runs `EngineCore` through `LocalEngineChannel` on its own `vhidQueue`, and the GUI keeps feeding frames from `HIDMonitor` exactly as today.
  - `EngineProxy` is the only thing the UI reads in both modes.
  - The Engine submenu (§4.4): Install, Uninstall, Restart, Open Login Items, and `statusForLegacyPlist` detection.
  - `VirtualPadSink.setMaxRate` plus a "Pad rate" submenu (250/500/1000 Hz).
  - `PadIdentity.spec(defaults:)`.
- **Done-checks:**
  - The duplicated logic is gone: grep finds `evaluateAutoPublish` only in `EngineCore`.
  - Live install and uninstall switch the dext owner with no "exclusive" error and a pad gap under 3 s.
  - All earlier checks still pass.

### E4: Mapping-engine groundwork

- **Do:**
  - Profile files and the `activateProfile`/`profileChanged` commands.
  - GUI-forwarded `frontmostAppChanged(bundleID:)`: the engine may not use `NSWorkspace`, and games inside Shadow cannot be told apart from the Mac anyway (research C).
  - An output-channel abstraction in `EngineCore` (pad today; keyboard and pointer later through the dext's D8 slots or `CGEvent`).
  - `status.throttled` and `lowPowerMode` surfaced in the GUI.
  - A one-off **TCC/CGEvent probe**: run `CGEvent.post` from the engine, then check (a) whether it needs its own Accessibility grant (**G**) and (b) with napwatch, that posting events does not bring RunningBoard tracking (**G**).
- **Done-checks:**
  - Per-profile passthrough variants switch live.
  - The probe results are recorded in this plan (§10 R12).

## 10. Risks (symptom → action)

| # | Symptom | Action |
|---|---|---|
| R1 | Under Game Mode the engine still lags: napwatch shows base priority 4, `ThrottleCheck` logs, or §8.3 totals are far above target | 1. Check `launchctl print` `spawn type = interactive (4)`. 2. Check `~/gdhub-rb.txt` for `osservice<com.interlinked.gdhub.engine` lines (§8.3, `/usr/bin/log`, identity match) and `lsappinfo` for a check-in; if there is one, find the AppKit/`beginActivity`/GameController call (guard test gaps). 3. If RunningBoard ignores the engine but it is still clamped: build research L's nested `GDHubEngine.app` helper as a separate SwiftPM `executableTarget` that does not link AppKit or SwiftUI, with a profile copy and manual codesign (**M**: passes the dext check). 4. Last resort (**G**): a dedicated HID thread with `THREAD_TIME_CONSTRAINT_POLICY` running the manager on its own run loop |
| R2 | The engine dies at spawn with exit 137 or an amfid "-413 No matching profile" | launchd exec of the main executable did not get the profile (§3.2 **G**). Check `codesign -dv --entitlements :- /Applications/GDHub.app` and that the `ProgramArguments` path is the real main executable, not a copy or symlink. Fallback: nested helper bundle (R1 step 3) |
| R3 | Engine log `connection: rejected(-536870174 / 0xE00002E2)` | The signature has no team or app-id entitlement, or has the wrong value. The build-script value check (§6.3) should have caught it; rebuild with Xcode signing, not `bundle.sh` |
| R4 | Engine `exclusive` (0xE00002C5) that does not heal (`exclusive: retry #n` keeps climbing) | Another owner still holds the dext: a GUI in in-app or fallback mode, or a `--engine-foreground` shell copy. `pgrep -lf GDHub`, quit the other one; the engine's own retry (§2) reconnects within 2 s, no manual step. `engine-agent.sh status` exits non-zero meanwhile |
| R5 | Pad missing after a rebuild, or old behaviour after a rebuild | The engine still runs old code, or bootout failed. `scripts/engine-agent.sh status` (pid changed?), `restart`. From E2, the binary-UUID mismatch auto-restarts it |
| R6 | Callback p99 > 2 ms with no clamp | IOConnect cost on the same queue. Move HID to `hidQueue` (§3.5), then `vpadMaxRateHz` 250 |
| R7 | Crash loop (`runs` climbing, pad flapping) | Read `~/Library/Logs/DiagnosticReports/GDHub-*.ips` and the `launchctl print` `last exit code`. Run `scripts/engine-agent.sh uninstall` to fall back to in-app mode tonight |
| R8 | A driver update hangs ("terminating_for_upgrade", `krUnsupported`) | The engine still held the dext during activation. Check that the GUI's `bootoutAndWait` completed before the request (`/usr/bin/log show --last 5m --predicate 'subsystem == "com.interlinked.gdhub" AND category == "vhid"'`). Manual fix: `engine-agent.sh uninstall` → update → `install`. In E1 a dext-bumping build is refused while the agent is installed (§6.3 step 0) |
| R9 | The engine does not start at login, or the "Background Items Added" toggle is off | `launchctl print` says not loaded. Turn on Login Items & Extensions → GDHub; `sfltool dumpbtm` shows how BTM attributed it. Whether the GUI's `ensureLoaded` bootstrap overrides the toggle is untested (**G**, rev 1 wrongly implied it does); if it does not, the E1 fallback (§2) runs the GUI in-app and says so |
| R10 | `open GDHub.app` focuses nothing or does not start the GUI while the engine runs | LaunchServices treated the engine as the running app (**G** that it will not). Fallback: nested helper bundle (R1 step 3) |
| R11 | The pad is not neutral after wake, or stuck input after sleep | Check the "will sleep: pad neutral" log. Make sure `IOAllowPowerChange` is called on both messages and the notification port has a dispatch queue |
| R12 | Future: `CGEvent.post` from the engine does nothing, or the engine becomes RunningBoard-tracked after posting | TCC Accessibility is per code identity: grant "GDHub" in Privacy & Security → Accessibility (same binary, **G** that it covers the engine). If posting brings WindowServer/RunningBoard tracking, post from a separate tiny helper and keep the HID→pad path in the engine (E4 probe decides) |
| R13 | Low Power Mode slows the engine (**G**) | `status.lowPowerMode` (E4) explains it; the user turns LPM off while playing |
| R14 | Stale settings in the engine after a GUI `defaults write` | By design the engine reads defaults only at start; use the E2 commands or Restart engine. **Amended in T6 (receiver takeover, plan 2.4):** three keys are the exception and are polled once per second on `vhidQueue`: `inputPath` (`engine`, `count`, `shadow`, `driver`), `tapDrill` (read once, then deleted) and `tapBreakerTrippedAt` (the breaker / limiter latch the engine writes and the owner clears). `defaults write com.interlinked.gdhub inputPath -string shadow` therefore needs no restart; every other key, `vpadMaxRateHz` included, still does |
| R15 | The engine exits 64 under launchd (respawn loop every 2 s, `last exit code = 64`) | Resolved as a design question: launchd sets `XPC_SERVICE_NAME` to the exact label (**M**), so the only cause is a plist `Label` that differs from `EngineMain.label`; fix the plist. The `getppid() == 1` fallback is deleted: LaunchServices apps also have ppid 1 (**M**). The E1 fallback (§2) keeps the pad working meanwhile |
| R16 | `launchctl bootstrap` fails with `5: Input/output error` | The job is still loaded: either a bootout has not finished (`state = SIGTERMed`) or launchd already loaded it at login (**M** both). Always `bootoutAndWait` before bootstrap, and treat rc 5 followed by `print` rc 0 as loaded (§2, §4.3) |

**Review notes (rev 2): where the review was adjusted, and why**
- All 11 review issues were checked and confirmed: code claims against DriverManager.swift:75/154-165/180-182/279/360/375/378/381-389, DextClient.swift:144-160/204-206, EnvisionProDevice.swift:61-65, MappingStore.swift:31, bundle.sh:34-40, build-xcode.sh:21/55 (**R**); launchd claims re-measured 2026-11-09 with a TERM-trapping scratch gui-domain agent (`XPC_SERVICE_NAME` = label with ppid 1; bootout rc 0 in 0.014 s with `state = SIGTERMed`; immediate and duplicate bootstrap both rc 5; not loaded rc 113 after 2.8 s; the GUI pid 27619 has ppid 1 and `XPC_SERVICE_NAME=application.com.interlinked.gdhub.…`) (**M**).
- **Retry schedule** (issues 3 and 5 proposed different ones): one schedule, 0.25/0.5/1/2 s then every 2 s, with log thinning. Not applied to `.rejected`/`.protocolMismatch`, which cannot heal by retrying.
- **Bundle.sh done-check** (issue 7): the suggested "bundle.sh GUI shows `rejected`" holds only with the agent uninstalled. With the agent installed that copy is display-only and never says hello, which is the stronger check (§8.2 check 12).
- **Mapping watcher** (issue 10): the review put the dispatch source on `vhidQueue`; it runs on `controlQueue` instead and hops only the decoded mapping onto `vhidQueue`, because the hot-path rule (§3.5) keeps file I/O off that queue.
- **E1 fallback condition** (issue 11): "not running with a non-zero last exit and `pgrep` empty" alone is not race-free under `KeepAlive=true` (issue 6), since launchd respawns after `ThrottleInterval`. The fallback therefore boots the job out (`bootoutAndWait`) before going in-app.
- **Dev swap** (issue 9): chose the refusal over auto-uninstall in `build-xcode.sh`, so mode changes stay explicit.
- **Log checks** (issue 4): the amfid "must show nothing" check has no possible positive control, so it is demoted to diagnostic. The `connected` engine line is the pass criterion. Research L's "amfid shows nothing" (scratch `la/sig/amfi.log` holds the zsh `log:1: too many arguments` error) was never a measurement.
- **Also corrected:** §5.4 claimed `bundle.sh` builds are ad hoc, but they are Apple-Development-signed (**R**). §8.2 check 6 relied on `--publish-pad` to set `vhid.pad.enabled`, but that dev aid does not persist (**R** DriverManager.swift:140).
