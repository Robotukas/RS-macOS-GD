# How other controller drivers run, and what GDHub should take from them

*Research for GDHub. Date 2026-11-09. Mac: macOS 27.0.1 (26A434), Apple Silicon, SIP on. Research only: nothing in the repo or on the system was changed.*

Each claim carries one of three tags:

- **(measured)**: a command was run on this Mac and the result was seen.
- **(read)**: taken from source code or documentation, cited.
- **(guess)**: inference.

Three facts were checked again while writing this document. They are marked "re-checked".

**Verdict.** GDHub's current design is already the best placed of the ones studied for avoiding lag under Game Mode. It has three parts: a thin DriverKit dext that only publishes the virtual pad, an engine that runs as a plain launchd LaunchAgent that RunningBoard does not manage, and a direct IOConnect call from the engine to the dext. The others compare like this:

- **Razer** runs its remap engine inside an Electron app. RunningBoard demotes that app to Background in every Game Mode session (measured).
- **iCUE and OpenJoystickDriver** also run their device work inside apps. Their behaviour under Game Mode was not measured.
- **Karabiner** uses root launchd daemons but adds a socket hop and about four thread handoffs per report (read).
- **Apple's own controller daemons** run at ordinary priority with no real-time threads (measured).

Of the 32 candidate lessons, 14 were refuted in review. Most of the others turned out to be already in GDHub's code or plans. What is left is a short list of cheap fixes, not a redesign:

- run the sleep/wake path, which has never been tested;
- detect when Login Items has switched the engine off;
- correct the runningboardd regression check;
- stop replacing the dext on every app build;
- measure the rate cap from the start of a post;
- build rumble as a coalescing path that stays off the input queue and stops on its own.

Five bigger ideas were rejected: moving work into the dext, real-time threads, task QoS tiers, moving the engine to SMAppService, and swapping the user-client entitlement. At p50 1.19 ms against Shadow's 10 ms joystick poll, each would cost far more than it could return.

**Owner direction, 2026-11-09 (after this research was started).** The owner asked for the dext to take over the receiver's controller interface (interface 3), on the grounds that only this controller uses the receiver. The review below rejected that as a latency fix (§3, *in-dext-usb-interface-claim*): about 0.5 ms of typical gain, with the app's raw-data reads to rebuild. Whether to go ahead anyway is the owner's decision and is open.

---

## 1. How each one runs

| Product | Driver(s) | What does the forwarding | How it is started | Priorities / real-time | Evidence level |
|---|---|---|---|---|---|
| **GDHub** (reference) | `com.interlinked.gdhub.VirtualHID`: an IOUserService on IOUserResources that publishes `GDHubVirtualPad` (AppleUserHIDDevice, 045E:02E0) | Engine (`GDHub --engine`): IOHIDManager on the serial `.userInteractive` `vhidQueue` → `IOConnectCallMethod` | Legacy plist in `~/Library/LaunchAgents`, ProcessType=Interactive, KeepAlive. Not managed by RunningBoard | Engine hot threads 37T. Dext worker 63R. No RT | measured |
| **Razer Synapse 4 / App Engine** | Two dexts in a stub app. `com.razer.appengine.driver` is a HID event service on IOHIDInterface for keyboards and mice; it is not running because no Razer device is attached. `com.razer.appengine.virtual.driver` is an IOUserService on IOUserResources and publishes 3 AppleUserHIDDevices, one of them 045E:028E "Xbox 360 Controller" | `libmapping_engine.dylib` inside the Electron main process (pid 1132): IOHIDManager callbacks, IOConnect calls, CGEventPost | An SMAppService login item launches Razer.app through LaunchServices, so RunningBoard treats it as an "app" | Mapping threads 37T, main thread 46T, no RT. Set to role **Background** in every Game Mode session. Virtual dext 63R | measured. Priorities during Game Mode not measured |
| **Corsair iCUE 5.36.80** | `com.corsair.cue.main.VirtualHIDDeviceDriver`, on IOUserResources. It creates a virtual keyboard and pointer only while a client is connected. No gamepad | The iCUE Qt GUI does the device I/O. Keyboard/mouse output goes over QtRemoteObjects on TCP 127.0.0.1 to "iCUE Virtual Device.app", which calls IOConnect | A legacy LaunchAgent (which starts the GUI) and a LaunchDaemon (updates). Both are disallowed in BTM on this Mac. iCUE is not running | No QoS/RT calls in iCUE's own libraries. Dext 63R | measured from static files and logs dated 2026-09; iCUE was not run |
| **OpenJoystickDriver 0.5.0-b4** | `com.openjoystickdriver.XboxUSBDevice`: a thin generic USB pipe proxy on IOUSBHostInterface for 7 Microsoft GIP PIDs. It publishes no HID device | A menu-bar app does parsing, mapping, IOHIDUserDevice virtual pads and rumble | Menu-bar app. No launchd job found | Default-QoS queues and Swift actors. No RT | read, plus measured metadata. Not running |
| **360Controller / drewbadour sample** | Kext: everything in the kernel. Sample: an IOUserHIDDevice subclass on IOUSBHostInterface | The driver itself: pipe read → `handleReport` | Kext (dead since Big Sur) / sample code | n/a | read |
| **Karabiner-Elements + VirtualHIDDevice** | A dext on IOUserResources. Virtual keyboard and pointer are children of each user client | A root Core-Service daemon seizes devices and remaps, then sends reports to a root VHID daemon over a UNIX socket; that daemon calls `IOConnectCallStructMethod` | Root LaunchDaemons registered with SMAppService.daemon, ProcessType=Interactive, KeepAlive, plus per-user agents | No thread-level RT or QoS. Task QoS tier 0 on Core-Service | read. Not installed |
| **Apple controller path + Game Mode** | AppleUserHIDDrivers (the USB HID dext), AppleGCHIDUserEventDriver (AppleGameControllerPersonality.kext), AppleGCSyntheticDevice | `gamecontrollerd` → GameController apps over XPC. Raw-IOHID readers (SDL HIDAPI, Steam) go to the HID device directly | `gamecontrollerd` is a LaunchDaemon started on demand by IOKit matching, ProcessType Adaptive. `gamepolicyd` decides Game Mode | gamecontrollerd 31T/37T, GameControllerConfigService 4, hidd 31T. No user-space RT | measured |
| **Steam (macOS)** | None installed. A 2018 package bundles kexts, but they are not installed | `libsteaminput`: a user-space IOHIDUserDevice virtual pad | Steam app, plus launchd jobs `ipctool` and `steamclean` | Not measured | measured (metadata) |
| **SDL** (GFN 2.32.10, Shadow 2.24.2, Steam SDL3) | none | A library inside the game or client. Backend order HIDAPI → IOKit → MFi. Reads happen at the app's pump rate | In-process | Sets no priority (read). Shadow's own threads include 54R/47R (measured) | read |
| **Windows / Linux peers** | ViGEmBus (retired), HidHide filter, xpadneo (kernel HID) | DS4Windows input thread; InputPlumber Tokio loops | n/a | AboveNormal at most. No MMCSS, no RT | read |

**GDHub (reference)**
- The engine is "not RunningBoard jetsam managed" and "will not be managed". No role line exists for it in 24 h (measured). Under Game Mode its total delay is p50 1.19 ms and p99 2.69 ms, with rare spikes of 5–9 ms (read, engine-agent-plan §8.4).
- The engine's `.userInteractive` threads run at 37, not 46. XNU squashes USER_INTERACTIVE to USER_INITIATED for daemon and dext process types (read: xnu `osfmk/kern/task_policy.c` ~886–888; measured: `ps -M` shows 31T/20T/37T/37T).
- Reports are posted with `IOConnectCallMethod` (scalar + struct), not `IOConnectCallStructMethod` (read: `DextClient.swift:271`).
- The pad 045E:02E0 (Transport "Bluetooth Low Energy", no HIDVirtualDevice key) is matched by AppleGCHIDUserEventDriver with GameControllerSupport=Yes (measured).
- gamecontrollerd also creates a synthetic copy, `GamePad-1` (045E:028E, version 0, HIDVirtualDevice=Yes, ReportInterval 8000) (measured).

**Razer**
- The engine sits exactly where GDHub's GUI sat before the LaunchAgent. RunningBoard set Razer.app (pid 1132) to darwin role Background 93 ms after "Game mode enabled" at 08:41:10 (measured). There were 13 demotions from 10 Game Mode enables in about 6 h; the extras were re-demotions inside a session (measured).
- `libmapping_engine.dylib` is loaded in pid 1132 (measured). That it is the remap and feed engine is a guess from its name. Razer thread priorities during Game Mode were not measured, so a clamp to 4 like GDHub's GUI saw is a guess.
- The virtual 360 pad is 045E:028E, version 276 (0x0114), USB, with a 20-byte input report and MaxOutputReportSize 0. All 3 host SetReports failed (3/3). It gets the generic AppleUserHIDEventDriver with GameControllerSupport=No (measured).
- Apple's 028E personality lacks `GCIOMatchVirtual=true`. On this Mac the key is set for Microsoft 02E0, 02FD, 0B02, 0B05, 0B13, 0B20, 0B22, 0B23 and 0B3C, and absent for 028E, 02EA, 0B00, 0B0C, 0B12 and 0B21 (measured, re-checked; one reviewer's list that included 0B12/0B0C/02EA was wrong). This is the likely reason the pad gets the generic driver (guess).
- Three virtual devices hang under one user client through nested `UserClientProperties` keys, which is the pattern GDHub uses (measured). The virtual dext holds only `driverkit`, `allow-any-userclient-access` and `transport.hid`, not `family.hid.device`, yet it publishes AppleUserHIDDevices. Why that works was not established (measured).
- The HID event-service dext is a separate bundle that matches keyboards and mice (usage 1/6 and 1/2, VID 0x1532/0x068E). Nothing shows it forwarding inside the driver into a virtual pad (measured).
- How it starts:
  - SynapseHelper is a login item managed by ServiceManagement and is not running now (measured).
  - `com.razer.gms`, `elevationservice` and `UninstallerWatcher` are legacy items marked **disallowed** in BTM and are not loaded (measured).
  - The stub app (0.8.11, 2.5 MB) holds both dexts. The engine lives separately in `~/Library/Razer` (measured). Both Info.plists carry the same date, so the claim that the two update at different rates is a guess.

**Corsair iCUE**
- The GUI app does all physical-device I/O with per-device IOHIDDevice APIs on QThreads. It makes no IOUSBHost, hidapi or GameController calls, and its own libraries make no thread_policy or QoS calls (measured, `nm -u`).
- Keyboard and mouse output takes an extra process hop: QtRO over TCP 127.0.0.1 to an LSUIElement helper, which is the only process holding `driverkit.userclient-access`. The helper exits with its last client (measured, iCUE's own log files). Whether that TCP endpoint is authenticated is unknown (guess).
- The dext loads at boot and runs as pid 604 even with iCUE closed. The root service currently has no children (measured).
- iCUE's own log files show the virtual pointer as VID/PID 5824/10202 (0x16C0/0x27DA), which is Karabiner's ID, and the keyboard as 6940/65535 (measured, re-checked: 25 sessions, plus "Removed" lines for both devices). Two reviewers searched only ioreg and the unified log and missed these files. That the dext is derived from Karabiner is a guess, based on that ID plus identical class and key names.
- Dext entitlements: `family.hid.device`, `family.hid.eventservice`, `transport.hid` and the app sandbox. It does not have `allow-any` (measured).
- Text actions import `CGEventKeyboardSetUnicodeString` + `CGEventPost`, and `libPowerStateListener` imports `IORegisterForSystemPower` / `IOAllowPowerChange` (measured; how they are used at run time is a guess).
- No gamepad or SCUF support on macOS: the 351-package catalog has no SCUF or Envision package, and no log mentions 3A08 (measured). There is no Game Mode evidence for iCUE.

**OpenJoystickDriver (OJD)**
- Everything runs in one LSUIElement app. The dext exists only to take 7 Microsoft GIP pads away from Apple's `XboxGamepad.dext` (read). Its `transport.usb` grant names exact Microsoft VID/PIDs, is Developer ID signed, and has ProvisionsAllDevices (measured). So Apple granted Microsoft IDs to a team other than Microsoft.
- Virtual pads are made with IOHIDUserDevice, and the app holds `com.apple.developer.hid.virtual.device` (measured). On macOS 27 their Transport is always "Virtual" (read). In OJD's GameController haptics test, `GCController.controllers()` returned none (read).
- Steam reads every control and drives rumble with the "SDLCompatible" profile, which is the Xbox Adaptive Controller over Bluetooth (SDL ID 0x0B0C). The README does not print 045E:0B0C (read).
- On sleep it tears everything down and calls `IOAllowPowerChange` only after teardown, exactly once. On wake it re-runs `start()`. A revoked session token drops late events (read).
- Known problems (read):
  - A macOS 27.0 main-thread trap, `CFRelease(NULL)` inside `__IOHIDManagerDeviceRemoved`, with the manager on the main run loop and no OJD frame on the stack. The trigger is unconfirmed: a whole-hub disconnect preceded one of the two crashes.
  - Stale dext processes after an upgrade. `diagnose.sh` says reboot; `repair.py` runs `sudo kill -9` on them.
- That Game Mode would clamp its app-hosted pipeline is a guess.

**360Controller / drewbadour DriverKit sample**
- 360Controller did everything in the kernel: the pipe read, conversion, remap, and setReport→QueueWrite for rumble. It died at Big Sur, wireless pads panicked the kernel on sleep, and it never worked with GameController (read).
- The drewbadour sample is an IOUserHIDDevice subclass on IOUSBHostInterface using `CopyPipe` → `AsyncIO` → `handleReport(completionTimestamp)` (read).
  - It sets `IOMatchCategory = com.apple.null.driver`. That works only when no Apple driver competes for the interface (read).
  - Its `transport.usb` idVendor 1118 is an integer, not "*" (read).

**Karabiner**
- The report path has about 4 thread handoffs: client dispatcher → asio thread → UNIX socket → daemon asio thread → daemon dispatcher → a synchronous `IOConnectCallStructMethod` (read). The root-only socket exists for privilege separation. The dext's `NewUserClient` does no caller check of its own (read).
- Both root daemons use ProcessType=Interactive and KeepAlive. Core-Service also calls `task_policy_set(TASK_BASE_QOS_POLICY, tier 0)`. There is no thread-level RT or QoS anywhere (read).
- Sleep handling (read):
  - It stops its components and waits a **fixed** 3 s before `IOAllowPowerChange`, then rebuilds on WillPowerOn, HasPoweredOn or WillNotSleep.
  - In 16.1.x the keyboard was dead for about 11 s after wake (#4491). The maintainer blamed repeated IPC timeouts; commenters blamed the 10 s heartbeat.
  - Fixes: 16.1.3 relaxed the timeouts, 16.1.8 shut the receiver down during sleep, 16.1.9 fixed a tap leak. 16.3.0 fixed a 30 s stall when waking right after sleeping.
- Readiness (read):
  - It calls `driver_version` after each `IOServiceOpen`. On a mismatch it keeps the connection but every call returns `kIOReturnError`.
  - It polls readiness every 1 s and recreates the device after 5 s, because initialisation goes asynchronously through the daemon.
  - It rescans periodically in case IOKit notifications are missed.
- Seizing (read):
  - It requires Input Monitoring even as root, by its own policy. Accessibility is required only for its own app-switch, focus and event-tap features.
  - It starts the queue before `IOHIDDeviceOpen` and retries a failed open every 1000 ms.
- Activation (read):
  - An equal version cancels even when forced; `forceActivate` only allows a downgrade.
  - Its labels are versioned (`-v3`), with the new label registered before old ones are booted out.
  - Leaked CGEventTaps (#4507/#4524) caused system-wide input latency that grew with uptime.

**Apple controller path and Game Mode**
- gamepolicyd labels a game by Info.plist category (GeForce NOW, ShadowPCDisplay), `LSSupportsGameMode` (WoW), or by launcher (Battle.net "Relauncher") (measured).
- When Game Mode starts, other GUI apps are demoted, including GDHub's GUI, Razer and Shadow (measured). Plain launchd jobs get no role: the GDHub engine, gamecontrollerd, gamecontrolleragentd, and the XPC service GameControllerConfigService, which still runs at priority 4 (measured). Not being managed is not the same as high priority.
- The "Game Mode Critical Service" assertion goes to (measured):
  - IDs on the Apple-signed asset list;
  - Dock and NotificationCenter, which look hard-coded from strings in gamepolicyd (guess);
  - launcher personalities. Battle.net got it on 2026-11-07, so "only Apple services" is wrong.
- That assertion is gated by the private entitlement `com.apple.private.runningboard.roles`. It grants role UserInteractive, coalition High and termination resistance (measured). gamecontrollerd is named on the list but never received it (measured).
- An RBS role is not a scheduling class. App-type critical services run UI threads at 46/47 (Dock 47T, NotificationCenter 46T; measured). The engine is capped at 37 by the daemon-type squash whatever its role (read; guess that a role would not lift it).
- The synthetic `GamePad-1` is hidden from IOHIDManager unless the user turns on "Increase controller compatibility" for a game (read, Apple doc). A plain IOHIDManager on this Mac does not list it (measured).
- The gamecontrollerd lines `Apply button … (system:, app:)` all concern button 0xc0223 (AC Home) and track who owns the Home button. They are not System Settings remaps (measured, 1,275/1,275 lines).

**Steam and SDL**
- Steam builds its virtual pad in user space. `libsteaminput` imports `IOHIDUserDeviceCreateWithProperties` and `HandleReportWithTimeStamp`, and `steam_osx` holds `hid.virtual.device` (measured). How Steam reads physical controllers is unconfirmed (guess: SDL3 HIDAPI or libusb).
- Every SDL backend is read only when the app pumps it. HIDAPI's per-device reader thread is event-driven but sets no priority (read). Shadow's 10 ms cadence is most likely Shadow's own loop (guess; closed source).
- For 045E:02E0, SDL2 HIDAPI claims the pad and the MFi and IOKit backends step aside (read; that this happens in a running game is a guess). SDL3 chooses the Bluetooth parser from a Transport string starting with "Bluetooth" (read, via GDHub's design doc).
- The "Steam virtual gamepad" signature on macOS (read):
  - SDL2: 045E:028E with version 0. Ignored unless `SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD` is set.
  - SDL3: also requires `kIOHIDVirtualHIDevice` to be true. Otherwise it resets the version to 1.
- Rumble throttling (read):
  - SDL 2.32.10 (GFN) and SDL main (Steam): one send per 50 ms busy window on Bluetooth.
  - SDL 2.24.2 (Shadow): no busy window. It sends each change and only coalesces a request still queued.
- An unentitled process can set `THREAD_TIME_CONSTRAINT_POLICY` and get 97R (measured). A 1 ms timer then wakes about 5 µs late at p50, against about 130 µs at fixed 63 and about 255 µs at timeshare (measured, idle, not under Game Mode).

**Windows and Linux peers**
- DS4Windows: a blocking `ReadFile` on an AboveNormal thread, sending on every report. Rumble auto-stop works around ViGEm losing notifications. No MMCSS (read, schmaldeo fork; the Ryochan7 repo returns 404).
- HidHide is a kernel filter that hides a device from apps not on its allow list. macOS has no equivalent (read).
- xpadneo coalesces rumble on an ordered **WQ_HIGHPRI** workqueue with a pending flag and skips motors that have not changed. It has no auto-stop (read).
- InputPlumber's 2.5 ms default sleep applies only to evdev and a few other sources. Most hidraw gamepad drivers use 0 ms and blocking reads (read).

---

## 2. Lessons that survived review, ranked

Ranking is benefit to the real goals (no felt lag; reliable start at login and after sleep; rumble, remaps and keyboard output later; Steam/GFN compatibility) divided by cost. Ranks 1–13 are changes. The last five rows are "keep doing this" and need no change.

| Rank | Lesson | Gain for GDHub | Cost | Verdicts (truth / fit) |
|---|---|---|---|---|
| 1 | Run the sleep/wake path; stop rumble on sleep (narrowed from *sleep-wake-teardown-rebuild*) | The sleep path has never run on this Mac (measured). Proves recovery after sleep | One manual test now; a few lines once rumble exists | partly / partly |
| 2 | Detect a Login-Items-disabled engine (narrowed from *smappservice-registration-and-btm-check*) | Explains a dead pad after login. All 5 third-party legacy launchd items on this Mac are BTM-disallowed (measured) | Low: pull the planned E3 check forward. No migration | partly / partly |
| 3 | Fix the runningboardd regression check; keep the engine unmanaged (*engine-stays-unmanaged-launchd-job*) | Protects the 57 → 1.2 ms Game Mode fix from false alarms and false "fixes" | One doc/script edit | partly / partly |
| 4 | Version the dext separately from the app build (from *minimise-dext-churn*) | Fewer dext replacements, reboots and update hangs during development | Low: build-script change | partly / partly |
| 5 | Measure the rate cap from post start: `lastPostAt = tS` (*rate-cap-no-systematic-wait*) | About 0.5 ms off p50 during continuous motion (guess). Probably brings coalescing under the 20 % E1 target. Not felt against a 10 ms poll | One line plus a meter re-run | partly / partly |
| 6 | Finish the rumble path D5/P7e (*rumble-output-path*) | Rumble works for SDL/HIDAPI and GameController hosts | Medium to high: dext forwarding, decoder, **capture of the SCUF rumble report** | partly / partly |
| 7 | Rumble as a coalescing, off-queue path with auto-stop (*rumble-coalescing*) | Rumble never stalls input. Motors cannot stay stuck on | Low on top of rank 6 | partly / partly |
| 8 | Virtual keyboard/pointer D8: plan entitlements, create early, consider doing it before CGEvent (*virtual-keyboard-pointer-devices*) | Keyboard/mouse output that reaches GFN with direct mouse input (untested) | Medium. Possibly new entitlements and re-provisioning | partly / partly |
| 9 | Release the dext when the session leaves the console (*console-user-gating*) | Fixes a fast-user-switching lockout (only if 2 accounts run GDHub) | Low | partly / partly |
| 10 | Report the receiver's device-level `UsbExclusiveOwner` when the interface drops (narrowed from *usb-ownership-diagnostics*) | Explains "controller gone" when Shadow forwards the receiver | Trivial, read-only | partly / partly |
| 11 | Consumer-interface seize checklist: TCC check, open retry, release on sleep (narrowed from *seize-receiver-tcc-and-open-pattern*) | Avoids surprises when G2–G4 remapping seizes the Consumer interface | Low, only when that feature is built | partly / partly |
| 12 | Plist-based "is this a game?" as a fallback for profiles (*game-classification-for-profiles*) | Default game profile for apps with no rule | Low, GUI only | partly / partly |
| 13 | Unicode CGEvent only for off-layout typed text (*text-macros-unicode-cgevent*) | Emoji and accents in native Mac text fields | Low, but adds a PostEvent grant to the engine | partly / partly |
| keep | Direct IOConnect, no broker hop (*no-ipc-hop-before-ioconnect*) | Already the design | none | partly / partly |
| keep | Keep 045E:02E0 BT identity, no virtual flag (*keep-xbox-bt-identity*) | Already the design | none | partly / partly |
| keep | Send on change, no fixed tick; keep the heartbeat (*send-on-change-no-tick*) | Already the design (subject to rank 5) | none | partly / partly |
| keep | Don't chase the Game Mode critical list (*no-game-mode-critical-list*) | Avoids a dead end | none | partly / partly |
| keep | IOHIDUserDevice stays a "later" option (*iohiduserdevice-later-option*) | Already parked as P8 | none | partly / partly |

### 2.1 Run the sleep/wake path (rank 1)
- **Already in place (read):** `Sources/GDHub/Engine/PowerObserver.swift` runs on its own `powerQueue`.
  - `kIOMessageCanSystemSleep` → `IOAllowPowerChange` at once.
  - `kIOMessageSystemWillSleep` → `vhidQueue.sync { core.neutral() }`, then `IOAllowPowerChange` once.
  - `kIOMessageSystemHasPoweredOn` → `presence.didWake()`.
  - `VirtualPadSink` and `EngineCore` already use generation tokens.
  - The dext watchdog only posts neutral and never re-handshakes (`GDHubVirtualHIDUserClient.cpp` ~470–485). Both sides use uptime clocks, so Karabiner's heartbeat-across-sleep failure has no counterpart here.
- **Not exercised (measured):** no "will sleep" or "woke" lines from the engine in 7 days, no Sleep/Wake entries in the retained `pmset -g log`, and `pmset -g` reports sleep prevented by powerd, Amphetamine and Claude.
- **Change:**
  1. Run engine-agent-plan step 8 (`pmset sleepnow`, then wake). Include a cancelled sleep, because `kIOMessageSystemWillNotSleep` is unhandled; that is probably harmless since nothing is torn down (guess).
  2. Once rumble exists, `willSleep`, controller-asleep, controller-disconnect and engine shutdown must send L=R=0 to the receiver and drop pending dext output.
  3. Optional: clear the sink's `lastSent` and rate state on wake. The uptime-based heartbeat-gap re-send may not fire across sleep (guess).
- **Files:** `Sources/GDHub/Engine/PowerObserver.swift`, `EngineService.swift`, `EngineCore.swift`, `ControllerPresence.swift`.
- **Proof:** after wake the engine has the same pid, the log has the will-sleep line, the pad is still in ioreg, and the pad stays neutral until input. After rumble lands, no motor runs on after sleep.
- **Dropped:** destroying and rebuilding the pad on every sleep. It would make games, Steam and GFN see a disconnect and reconnect on each wake (see §3).

### 2.2 Detect a Login-Items-disabled engine (rank 2)
- **Facts:**
  - The engine is BTM `[enabled, allowed, notified]` today (measured).
  - Corsair's two items and Razer's `gms`, `elevationservice` and `UninstallerWatcher` are all `disallowed` and not loaded (measured).
  - Why they are disallowed is unknown; the user may have switched them off (guess).
  - SMAppService items sit behind the same switch and then report `.requiresApproval` (read, Apple docs). So migrating would not prevent this.
- **Already in place (read):** `EngineAgent.swift` `status()`, `ensureLoaded()` and `fallbackCheck()` fall back to in-app mode. engine-agent-plan §2 names "BTM toggle off". §4.2 plans the BTM check for E3 and deliberately keeps the legacy plist.
- **Change:** in the GUI, call `SMAppService.statusForLegacyPlist(at:)` on `~/Library/LaunchAgents/com.interlinked.gdhub.engine.plist` (macOS 13+). On `.requiresApproval`, show "re-enable GDHub in Login Items" and offer `SMAppService.openSystemSettingsLoginItems()`. Also test whether the GUI's `launchctl bootstrap` loads a BTM-disallowed legacy job (untested, plan §4.2 marks it G).
- **Remaining gap (guess):** the fallback only runs when the GUI is opened. If the engine is disallowed and the GUI is not opened after login, there is no pad.
- **Files:** `Sources/GDHub/Output/VirtualHID/EngineAgent.swift`, the GUI status view.
- **Proof:** switch GDHub off in Login Items, log out and in, open the GUI: it shows the message. Switch it back on: `launchctl print` shows the job running, `spawn type = interactive`.

### 2.3 Fix the regression check; keep the engine unmanaged (rank 3)
- **Already in place (read):**
  - ProcessType=Interactive in `Xcode/Engine/com.interlinked.gdhub.engine.plist`.
  - `EngineMain` refuses to run unless `XPC_SERVICE_NAME` equals the label (exit 64). A ppid==1 check would be wrong, because apps launched through LaunchServices also have ppid 1.
  - Restarts use only `launchctl bootstrap` and `kickstart` (`EngineAgent.swift`, `scripts/engine-agent.sh`).
  - `EngineIsolationTests` bans NSApplication, NSWorkspace, beginActivity, GameController and similar on the engine path.
- **Correction:** the engine binary links AppKit and SwiftUI (same binary as the GUI) and is still unmanaged (measured). The trigger is how the process is spawned and whether it creates NSApplication, not what it links.
- **Change:** engine-agent-plan §8.3 (line 721), §8.4 (line 780) and the results table (line 798) require zero `osservice<com.interlinked.gdhub.engine` lines. runningboardd writes such lines about hourly with "This process will not be managed" (measured: 03:41, 05:12, 06:13, 07:44). New check:
  - expect osservice lines together with "will not be managed";
  - **fail** only on a `role:` or "Calculated state" line for the engine, or on an `app<…>` / `application.…` identity.
- **Proof:** the new predicate passes on the current engine and on a Game Mode session.

### 2.4 Version the dext separately from the app (rank 4)
- **Facts:**
  - `Xcode/build-number` is 17 and the active dext is 0.1.0/17 (measured), yet only 3 commits touch `Dext/` (measured).
  - `build-xcode.sh` sets the dext `CFBundleVersion` to the app build unless `--same-build` is passed (read). `handleProperties` updates the dext whenever the builds differ (read).
  - So almost every build replaces an unchanged dext, which risks stale processes, a reboot, or the R8 update hang.
- **Change:** bump the dext version only when a hash of `Dext/` sources changes. This also keeps "a changed dext always gets a new version", which an equal-version check needs.
- **Keep** the existing rule: a stale old dext process means reboot, never kill it (driverkit-dext-design.md:1316–1320, :1467). OJD's `repair.py` runs `sudo kill -9`; GDHub should not.
- **Side note:** the GUI's `HIDMonitor` schedules on the main run loop (`HIDMonitor.swift:86`, `:162`), the same pattern as OJD's macOS 27 crash. The engine already uses a dispatch queue (`GamepadHIDReader.swift:53`). That moving the GUI off the main run loop would avoid the crash is a guess; KeepAlive does not cover the GUI.
- **Files:** `scripts/build-xcode.sh`, `Xcode/build-number`.
- **Proof:** two builds with no `Dext/` change leave `systemextensionsctl list` unchanged, and no activation request appears.

### 2.5 Measure the rate cap from post start (rank 5)
- **Facts (read):**
  - `VirtualPadSink.swift:448` compares `now < lastPostAt + intervalNs`.
  - Posting on the leading edge already exists (line 455).
  - `tS` is taken at line 476, but `lastPostAt = tR` (after IOConnect) at lines 490–491.
  - With 1 kHz input and a 1 kHz cap, the next frame usually lands inside the window and waits for the strict timer. That is the 0.65 ms "cap" stage (engine-agent-plan §8.4).
  - Strict timers fire about 125–129 µs late at p50 and 155–237 µs at p99 (measured, idle). The 0.27–0.38 ms figures belong to non-strict timers.
- **Change:** `lastPostAt = tS`. It still allows at most one post start per ms. Keep the strict DispatchSource on `vhidQueue`.
- **Not:** an RT-thread trailing flush, a burst-2 token bucket (briefly exceeds 1 kHz), or a 250 µs tolerance (it must exceed the IOConnect time to help).
- **Expected (guess, simulation):** total p50 drops from about 1.4 to about 0.5 ms during continuous motion. p99 and the 5–9 ms spikes are untouched. engine-agent-plan line 804 had declined this as worth ≤0.6 ms; the cost is one line.
- **Tests:** `VirtualPadSinkTests` use a manual clock where tS == tR, so their meaning is kept.
- **Files:** `Sources/GDHub/Output/VirtualPad/VirtualPadSink.swift`.
- **Proof:** re-run the latency meter under Game Mode. Cap stage p50 should be about 0, and coalesced states under 20 % (now 21 %).

### 2.6 Finish the rumble path D5/P7e (rank 6)
- **Already built (read):**
  - The dext stores an `OSAction` from `registerOutput` (`GDHubVirtualHIDUserClient.cpp:301–315`) and releases it at Stop.
  - The engine registers with `IOConnectCallAsyncScalarMethod` on every connect (`DextClient.swift:218`, `317–330`). `handleOutput` checks for sequence gaps.
  - The wire format carries up to 64 payload bytes in 10 args (`GDHubProtocol.h:56–58`).
  - Design: driverkit-dext-design.md §3.8 / D5 / P7e. latency-plan item 9 requires `CompleteReport` at once and forwarding afterwards.
- **Missing (read):**
  - the body of `GDHubUCDeliverOutput` (declared at `GDHubInternal.h:22`, about 10 lines specified in §3.8);
  - the call to it from `GDHubVirtualPad::setReport` (stub at `GDHubVirtualPad.cpp:70–80`);
  - wiring `DextClient.onOutput` in the engine (nothing assigns it);
  - a `RumbleDecoder` for `03 0F LT RT L R FF 00 EB` with durationMs;
  - the SCUF rumble format: output report 0x09 on receiver interface 3. Its length conflicts: 13 B in `slipstream-prior-art-brief.md:330`, 12 B in `HANDOFF.md:47`. **A capture is required.**
- **Interfaces (measured):**
  - Interface 3 is page 0xFF58, MaxOutput 64, read by the engine.
  - Interface 4 (Consumer 0x0C + 0xFF42) is the GUI's Bragi control channel (SetReportCount=550). The engine must not write rumble there; that would break single ownership.
- **Verification:** **not** `SetReportFailCount`. The stub completes with success, so it stays 0 even when nothing is forwarded. Use SetReportCount > 0 on GDHubVirtualPad's DebugState (a host wrote), `getStatus` outputCount/outputDrops, a decoded RumbleCommand in the log, and a felt test, including while GFN is streaming.
- **Caveats:**
  - Steam rumble with GDHub's 02E0 identity is unproven. OJD's success used the Adaptive Controller identity.
  - That GFN reads the pad through HIDAPI is a guess.
  - That gamecontrollerd's `.haptics` service turns CoreHaptics requests into output reports is a guess; only the service name was seen.

### 2.7 Rumble as a coalescing, off-queue path (rank 7)
- **Risk (read):** `onOutput` would arrive on `vhidQueue`, the same serial queue as the HID reader and the sink (`IONotificationPortSetDispatchQueue`). The existing synchronous `IOHIDDeviceSetReport` (`HIDMonitor.swift:114–115`) on that queue would stall input.
- **Change:**
  1. Write to the receiver on a separate queue, or with `IOHIDDeviceSetReportWithCallback`. Whether another queue may write to a device scheduled on `vhidQueue` is untested.
  2. Keep only the latest **(L, R) pair** for report 0x09; it has no trigger-motor fields. Skip a write when the pair is unchanged. Allow one write in flight; xpadneo does the same with a high-priority ordered queue plus a pending flag.
  3. Auto-stop: the receiver's motors latch until a zero report (read, `slipstream-prior-art-brief.md:331`). Honour durationMs, and send L=R=0 on shutdown, pad destroy, sleep, controller asleep or disconnected, and loss of the dext connection. DS4Windows `rumbleAutostopTime` is the model; xpadneo has none.
- **Why coalesce in GDHub:** host throttles differ (read). SDL 2.32.10/main allow one send per 50 ms on Bluetooth, Shadow's SDL 2.24.2 has no throttle, and GameController hosts are outside SDL (guess). That the receiver needs protecting from too many writes is a guess.
- **Dropped:** a shared-memory mailbox in the dext. Rumble runs at tens of Hz, so coalesce in the engine.
- **Proof:** a stress test from an SDL rumble tool while moving sticks shows unchanged input p99 and outputDrops staying low.

### 2.8 Virtual keyboard and pointer (D8) (rank 8)
- **Already designed and partly built (read):**
  - driverkit-dext-design.md G4, §3.1, §3.2, §4.7, D8.
  - `kSlotKey = {GDHubPadProperties, GDHubKeyboardProperties, GDHubPointerProperties}` exists, and per-slot `createDevice` and `post(slot:)` already exist.
  - IDs 1209:4744 / 1209:4745 (pid.codes), CountryCode 32.
  - Missing: the two Info.plist entries and the `GDHubVirtualKeyboard` / `GDHubVirtualPointer` classes.
- **New: entitlement gap (measured).** GDHub's dext has `driverkit`, `allow-any-userclient-access` and `family.hid.device`. Every dext here that publishes a keyboard also has more:
  - Corsair: + `family.hid.eventservice` + `transport.hid`.
  - Razer appengine.driver: the same, + allow-any.
  - Karabiner: + `family.hid.virtual.device` (read).
  - The repo cites DTS thread 843327 saying `family.hid.device` alone is enough. Test that first, and budget re-provisioning, a version bump and reactivation if it is not.
- **Change:**
  - Create the keyboard at setup or at engine start with a keyboard profile, not lazily mid-game. A new keyboard may bring up the Keyboard Setup Assistant over a fullscreen game (guess).
  - Consider moving D8 ahead of `CGEventSink` (P3). GFN with Direct mouse input probably ignores CGEvents (output-layer-plan:45, untested), and the dext is already deployed.
  - Do not reuse Karabiner's IDs (keyboard 0x16C0/0x27DB, pointer 0x27DA).
- **Unverified benefits:** avoiding Accessibility or Input Monitoring prompts, and visibility to GCKeyboard/GCMouse. Razer imports CGEvent APIs (measured); whether it uses them for output is a guess.
- **Proof:** the D8 tests, including a key held during `kill -STOP` being released within 2.5 s, plus a GCKeyboard probe and a GFN test.

### 2.9 Release the dext when the session leaves the console (rank 9)
- **Facts:**
  - The agent is per user. Another account runs an engine only if it also installed GDHub (read).
  - Fast user switching is on and there are 3 interactive accounts (measured). Whether the other accounts run GDHub is unknown.
  - IOHIDFamily turns off report queues for non-privileged clients that are off the console, so the backgrounded engine goes silent (read).
  - `GDHubRootClaim` is first-come and released only in `Stop`, and the 500 ms heartbeat keeps the watchdog from firing. So the backgrounded engine keeps the claim, and the console user's engine retries `kIOReturnExclusiveAccess` forever. This is a lockout, not a fight (read; outcome guess).
- **Change:** watch the session from the engine without AppKit: `CGSessionCopyCurrentDictionary` (`kCGSessionOnConsoleKey`) polled every 1 s, or SCDynamicStore `State:/Users/ConsoleUser` (untested in an Aqua agent). When the session leaves the console, post neutral and close `DextClient`. When it returns, reconnect. Apply the same to the GUI's in-app mode (`DriverManager.becomeInApp`).
- **Proof:** a second login; this needs the user and was not tested.

### 2.10 Report the receiver's owner when the interface drops (rank 10)
- **Facts (measured):**
  - The receiver's device node has no `UsbExclusiveOwner`.
  - Interfaces 3 and 4 list "AppleUserUSBHostHIDDevice", which is normal. Interfaces 0–2 list usbaudiod.
  - Razer (pid 1132) and ShadowUSB (pid 808, root) attach user clients to all 12 USB devices. These are not conflicts.
  - A seize at the HID level shows up as silence, not in this property (guess).
- **Change:** when the engine logs "controller interface down" but an IOUSBHostDevice 1B1C:3A08 is still present, read the device-level `UsbExclusiveOwner` with `IORegistryEntryCreateCFProperty` (no parent search) and print it in `engine-agent.sh status` or a doctor command. The likely case is ShadowUSB forwarding (latency-plan §4 item 1). That the property is set during forwarding is a guess.
- Decide from the property, not the error code. On macOS 27 an open of a held interface can fail with `kIOReturnInternalError` (read, OJD).
- **Proof:** forward the receiver in Shadow; status names the owner.

### 2.11 Consumer-interface seize checklist (rank 11)
- **Scope:** hosts never see the raw receiver. Its primary page is 0xFF58 (output-layer-plan.md:14). The plan forbids seizing FF58 and seizes Consumer 0x0C only when G2–G4 are remapped (lines 84, 212) (read).
- **Facts:**
  - The receiver's 0xFF58 and 0x0C interfaces do not carry `RequiresTCCAuthorization` (measured).
  - An unprivileged seize is refused only for keyboards (read, per output-layer-findings.json). So Input Monitoring is probably not needed (guess, untested).
  - GDHub already registers callbacks and the queue before the open (`GamepadHIDReader.swift:38–59`). A failed open is logged once and never retried (lines 55–58).
- **Change when building `seizeConsumer`:**
  - call `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` and show the result;
  - retry a failed open on a 1 s timer and ignore callbacks while it is failed;
  - if a grant is needed, exit after the grant and let KeepAlive restart (already `KeepAlive=true`, `ThrottleInterval=2`);
  - release the seize on sleep and quit, and take it again on wake and respawn.
  Accessibility is **not** needed. That was Karabiner's own feature requirement.
- **Costs:**
  - ad-hoc `bundle.sh` builds lose TCC grants (output-layer-plan.md:30);
  - whether a grant to "GDHub" covers `--engine` is unproven (engine-agent-plan R12);
  - the seize hides Consumer reports from the GUI learning view and from iCUE.

### 2.12 "Is this a game?" fallback for profiles (rank 12)
- **Facts (measured):**
  - GFN and GFN Streamer have category `games`.
  - The frontmost `Shadow PC.app` is `developer-tools`. Only the nested `ShadowPCDisplay.app` (`com.blade.shadow-macos`) is `games`.
  - WoW retail is `role-playing-games` with no `LSSupportsGameMode`. WoW forever has both keys, and gamepolicyd reported `LSSupportsGameMode`, so that key seems to take precedence (guess).
  - The launcher plists are mostly **Block** lists. The Custom bundle blocks browsers.
  - There are two asset copies with different hashes; prefer the downloaded one under `/System/Library/AssetsV2/com_apple_MobileAsset_GamePolicy_DB1/`.
- **Change (GUI only; the engine may not use NSWorkspace):**
  - The primary rule stays the planned explicit frontmost-bundle-ID rules (E4 `frontmostAppChanged`).
  - As a fallback for unknown apps, read `Bundle(url: app.bundleURL)?.infoDictionary`, not NSRunningApplication. Treat it as a game if any of these hold: `LSSupportsGameMode == true`; category `public.app-category.games` or ending in `-games`; the executable path contains a launcher Allow path such as `steamapps/common`; the parent is a known launcher.
  - Match `com.blade.shadow-macos` explicitly, and check that it really is frontmost while streaming (untested).
  - This cannot tell apart games inside GFN or Shadow. It is game classification, not Game Mode state, which also needs fullscreen.

### 2.13 Unicode text macros (rank 13)
- **Already planned (read):** `MacroStep.text(String)` with `CGEventKeyboardSetUnicodeString` in output-layer-plan P4. iCUE imports the same APIs and also ships a virtual keyboard dext (measured; how iCUE uses them is a guess).
- **Limits:**
  - `CGEvent.h` warns that frameworks may ignore the Unicode string and translate from the keycode instead (read).
  - GFN and Shadow read the keyboard as raw IOHID during a stream, so CGEvent text likely never reaches them (read, findings).
- **Change:** use the dext keyboard with a UCKeyTranslate-derived table for every character on the UK ISO layout. Use Unicode CGEvent only for characters outside it, such as emoji, chunking long strings and setting a sane keycode. This adds a PostEvent grant to the launchd-run engine binary (untested from an Aqua agent).

### Keep doing (no change)
- **Direct IOConnect, no broker hop.**
  - engine-agent-plan line 292 says the hot path never touches XPC. The plist already declares MachServices. E2 plans `NSXPCListener` with a code-signing requirement (lines 427–431, 515–518).
  - Keep rumble off XPC too: it already returns through `IOConnectCallAsyncScalarMethod`.
  - iCUE's hop applies to keyboard/mouse output only. Whether its TCP endpoint is authenticated is a guess.
  - Karabiner's hop is about 4 handoffs (read). A 0.1 ms hop is noise next to the 10 ms poll. The real cost of a hop would be a second scheduling point exposed to spikes (guess).
- **Keep 045E:02E0, Transport "Bluetooth Low Energy", no `HIDVirtualDevice`.**
  - Already done: `PadIdentity.default = xboxBT16_02E0`, and `GDHubSpec.cpp` never sets virtual keys (read).
  - Report 0x01 must be **exactly** 16 bytes; longer selects SDL's gapped parser.
  - Do not switch to 0B13 just for a share button: that needs the 17-byte report.
  - No second simultaneous 360-style pad: x360-usb is fallback 3, one identity at a time.
  - An Apple engineer says only that "some existing checks" ignore virtual HID devices (read).
- **Send on change, no fixed tick.** GDHub is event-driven behind a 1 kHz cap (see rank 5). The 500 ms heartbeat must stay: the dext watchdog depends on it.
- **Don't chase the Game Mode critical list.** It is closed: an Apple-signed asset plus a private entitlement. For the engine the daemon-type squash caps priority at 37 whatever the role (guess that a role would not help). The remaining spikes need a scheduling lever, not a role.
- **IOHIDUserDevice stays parked (P8 Later in output-layer-plan).**
  - The plan records it as restricted with no development variant (not re-checked against Apple docs).
  - The Transport is forced to "Virtual" on macOS 27, which sends SDL3 down the GIP 0x20 path.
  - GameController adopts a virtual pad only for the GCIOMatchVirtual PIDs listed in §1.
  - The device lives only as long as its process, whereas the dext keeps the pad and its 2 s watchdog.
  - The gain is at most part of the 0.36 ms IOConnect call, since HandleReport is also a kernel call (guess).

---

## 3. Lessons rejected or parked

| Lesson | Why |
|---|---|
| Exclude Apple's synthetic GamePad-1 from HID matching (*exclude-synthetic-gamepad*; fit **refuted**) | GDHub's matches are tied to VID:PID (3A08, 02E0, 0B13), and a plain IOHIDManager here does not list the synthetic pad (measured). `SyntheticPadWatcher` and the 028E ignore-devices workaround already exist. "Leave compatibility off" was unverified and may be backwards. Keep the literal `"GCSyntheticDevice": false` only for any future broad IOService enumeration. |
| Rumble by looping output back as an input report (*rumble-loopback-alternative*; fit **refuted**) | The async plumbing is already built. SDL3 reads vendor-page input 0x20, so a vendor collection is not safely ignored. Karabiner's loopback sits in a standard keyboard collection anyway. |
| Swap `allow-any-userclient-access` for `userclient-access` (*restrict-userclient-access*; fit **refuted**) | The dext already refuses every selector until `hello` passes a `CopyClientEntitlements` team/app-ID check and the single-owner claim (`callerIsGDHub`, `sHello`, `ExternalMethod`). The swap needs a restricted grant and risks locking the engine out. |
| In-dext forwarding through an IOUserHIDEventService on the receiver (*in-dext-hid-event-service-forwarding*; fit **refuted**) | The 0.65 ms cap is GDHub's own limiter (rank 5 fixes it in user space). The kernel→callback hop is replaced, not removed. An event service and the IOUserResources pad would likely be separate processes. Razer does not forward inside its driver. Costs: probe score against AppleUserHIDEventDriver, a C++ mapper port, the single-owner claim, watchdog semantics. Corrections kept: development entitlements come from the Xcode team profile (DTS 818358), and `IOUserServerOneProcess` is public (forum 680181). |
| In-dext USB claim of interface 3 (*in-dext-usb-interface-claim*; fit **refuted**; parked as last resort) | The real gain is about 0.5 ms p50, and §8.4 says R1 is not needed. It breaks the GUI's FF58 reads, ControllerPresence, LatencyMeter and identity switching, and needs a new `transport.usb` profile. If ever revived: omit `IOMatchCategory com.apple.null.driver`, use an integer idVendor, and note interface 4 (Bragi) is unaffected. |
| Real-time hot-path thread (*realtime-hid-thread*; fit **refuted**; parked as R1 step 4) | RT works without entitlement (measured), but the engine is not clamped (vhidPrio 37, napped=no in all 51 windows; read). The cause of the spikes is unknown: a minimal Interactive-agent reader (latprobe) saw the same 8.9 ms max (read). XNU demotes RT threads under the priority-4 clamp (read), so RT gives no protection against it. It is a large refactor, and per-frame allocations exist. `thread_policy_set` on a GCD worker returns KERN_SUCCESS but does nothing (measured). `AudioWorkIntervalCreate` is unavailable in Swift. Revisit only if the engine is clamped again or callback p99 > 2 ms under Game Mode. |
| Task-wide latency/throughput QoS tier 0 (*task-latency-qos-tier0*; fit **refuted**) | A thread's effective tier = MAX(thread, task, QoS-implied), so the task tier cannot tighten anything. Latency QoS only affects timer coalescing, and the flush timers are already strict. It needs no root (measured: kr=0 as uid 502), but it is a no-op. |
| Version launchd labels / re-bootstrap on plist change (*launchd-definitions-cached*; fit **refuted**) | `engine-agent.sh install` already copies, boots out and bootstraps on every `build-xcode.sh` build, and `status` fails unless spawn type is interactive. Bumping the label is harmful: it is hard-coded in about 9 files, it is the Mach service name, and two KeepAlive engines would fight. |
| Neutral report and release on client loss (*neutral-and-release-on-client-loss*; fit **refuted**) | Already done: `Stop` terminates the children; SIGTERM/SIGINT post neutral then destroy; ExitTimeOut 5; 2 s watchdog. |
| Dext readiness polling and 5 s recreate (*dext-readiness-gating*; fit **refuted**) | Already done: match/terminate notifications, hello plus version, back-off, recreate on loss. `createDevice` is synchronous, so a readiness poll adds nothing. Karabiner polls because of its daemon hop. |
| Version handshake and activation policy (*version-handshake-and-activation-policy*; fit **refuted**) | Already done: the hello protocol check, the `.protocolMismatch` UI, auto-update by build comparison on every GUI launch, `.rebootRequired`. The headless engine cannot submit system-extension requests. |
| Input Monitoring check in the engine (*input-monitoring-visibility*; fit **refuted**) | The receiver's interfaces lack `RequiresTCCAuthorization` (measured), so the check would report a misleading unknown/denied. Page 0xFFC0 is the Arctis headset. ListenEvent matters only for macro recording and trigger taps, already planned in `Host/Permissions.swift` (output-layer-plan:159). |
| Test whether hosts adopt the raw receiver as a pad (*receiver-may-appear-as-pad*; fit **refuted**) | Already answered (measured): gamecontrollerd checked 3A08 9× in 3 days and never claimed it, GameControllerSupportedHIDDevice=No, and Steam/GFN logs show no 1B1C. SDL IOKit rejects a non-GenericDesktop primary page (read). A user-space seize of a non-keyboard HID interface is possible, which contradicts "needs a USB dext". Keep as a check after OS updates. |
| Warn on Apple per-game customisation from the log (*apple-per-game-customisation*; fit **refuted**) | The log lines track Home-button ownership, not remaps (measured). The real state is the undocumented `~/Library/Preferences/com.apple.GameController.plist`. Today only the default profile exists, which maps Back Left/Right Button 0 → shoulders (measured). Remapping in the engine is already the design. At most a docs note. |
| Move the engine to `SMAppService.agent` (part of rank 2) | Plan §4.2 rejects it on purpose: rebuilds do rm -rf + ditto, re-registration is needed, several dev copies exist, and it is **untested whether a ServiceManagement agent stays outside RunningBoard**. It also would not prevent BTM switch-off. |
| Tear down and rebuild the pad on every sleep (part of rank 1) | Games, Steam and GFN would see a disconnect and reconnect on each wake. Nothing shows IOKit objects fail to survive wake here. |
| "Engine must not link AppKit/SwiftUI" (part of rank 3) | It already links them and is unmanaged (measured). A separate executable is R1 step 3, with a new target, helper bundle and manual codesign. |
| Razer-style separate stub host app for the dext (part of rank 4) | An activated dext lives in `/Library/SystemExtensions`, so app replacement does not touch it. A stub adds a signed bundle, a profile and an approval for no gain in a personal app. |
| RT-thread trailing flush, burst-2 token bucket, 250 µs tolerance (part of rank 5) | `lastPostAt = tS` is enough. The others need new threading, exceed 1 kHz, or do not help. |
| Shared-memory rumble mailbox in the dext (part of rank 7) | Rumble rates are tens of Hz; coalesce in the engine. |
| Accessibility gate and depth-1024 IOHIDQueue before seizing (part of rank 11) | Accessibility was Karabiner's own feature need. GDHub reads whole reports through a report callback, not element queues. |
| "Profiles switch exactly when Game Mode does" (part of rank 12) | False: Game Mode also needs fullscreen and gamepolicyd's private DB. |

**Small gaps the reviews found inside rejected lessons** (cheap and worth a ticket; each from the cited review):
- `createIfWanted` sets `PadPublishState.error` when `createDevice` fails, and nothing retries it. The single 1 s re-create after `deviceLost` is not retried either (`VirtualPadSink.swift` 294–322, 507–519; `EngineCore.swift` 214–221). Add a bounded retry.
- `DextClient` has no periodic rescan if a match or terminate notification is missed. Karabiner's `iokit_service_monitor` uses a scan timer. Its value for GDHub is a guess.
- `actionForReplacingExtension` always returns `.replace` (`DriverManager.swift:484–490`). Add a downgrade guard, and warn when the connected `dextBuild` (hello out[1]) differs from the embedded `CFBundleVersion`.
- `EngineAgent.ensureLoaded` never compares the bundled plist with the installed one (`bundledPlistURL` is unused) and ignores `spawnType`. `kickstart -k` does not pick up plist changes. This matters once E3 adds a GUI install/update path.
- `callerIsGDHub` passes a caller with no `application-identifier`; consider requiring it. The installed app carries `get-task-allow=true`; drop it from release builds.
- The engine's `IOHIDManagerOpen` failure is only logged. Forward the `kern_return` to the GUI status.
- Optional and of unproven value: post neutral reports in the dext's `Stop` before `Terminate` (for crash or `kill -9`).

---

## 4. Things to avoid

- **Running the remap/feed engine inside an app that LaunchServices launches.** Razer pays for this with a Background demotion in every Game Mode session (measured). iCUE and OJD have the same exposure (guess).
- **Adding a process or socket hop on the report path.** iCUE uses TCP loopback to a helper for keyboard/mouse; Karabiner uses about 4 handoffs plus a socket (read).
- **Shipping a 045E:028E USB 360 pad with no output report.** Razer's pad gets no GameController support and every SetReport fails (measured). Nor a 028E version-0 pad, which SDL treats as Steam's virtual pad (read).
- **Fixed polling ticks.** InputPlumber's 2.5 ms default for evdev sources; Shadow's own 10 ms loop (read; Shadow's source is a guess).
- **Timeouts that run across sleep.** Karabiner lost about 11 s of input after wake and fixed it by shutting the receiver down during sleep (read). GDHub's watchdog only neutralises and uses uptime clocks (read). Keep it that way.
- **Killing stale dext processes.** OJD's `repair.py` uses `sudo kill -9` (read). Reboot instead.
- **IOHIDManager on the main run loop.** This was OJD's crash setting (read; trigger unconfirmed). GDHub's GUI `HIDMonitor` does this today (read).
- **Assuming a legacy launchd item stays enabled.** Every third-party legacy item on this Mac is BTM-disallowed and silently not loaded (measured).
- **Rumble with no auto-stop.** ViGEm loses notifications and motors stick (read, DS4Windows workaround). The SCUF receiver's motors latch (read).
- **Synchronous `IOHIDDeviceSetReport` on the input queue** (read, design risk).
- **Reusing another project's VID/PID.** iCUE's pointer uses Karabiner's 0x16C0/0x27DA (measured, re-checked in iCUE logs).
- **Copying `IOMatchCategory com.apple.null.driver`** from the drewbadour sample, if GDHub ever claims an interface that Apple's driver also matches (read).
- **Leaking CGEventTaps** when macro recording is added. Karabiner #4507/#4524 saw input latency grow with uptime (read).
- **`thread_policy_set` on a GCD worker.** It reports success and does nothing (measured). If RT is ever used, use a pthread you created yourself and check with `thread_info`.
- **Chasing private Game Mode levers.** The critical list, RunningBoard domains and CLPC are all private entitlements (measured).

---

## 5. Open questions

- **What causes the 5–9 ms spikes?** A minimal Interactive-agent reader saw the same 8.9 ms max on kernel→callback (read), so scheduling is not proven. A per-core trace (`powermetrics`) needs root and was not run.
- **Does Game Mode or RunningBoard touch RT threads in a LaunchAgent, or dext processes at 63R?** Neither was measured under Game Mode.
- **Does GFN read GDHub's pad through SDL HIDAPI or through GameController?** Check the IOHIDLibUserClient creators on GDHubVirtualPad while streaming. This decides which rumble path GFN uses.
- **Steam rumble with the 02E0 identity.** OJD only shows it working with the Adaptive Controller identity.
- **The SCUF rumble report.** 0x09 is 12 or 13 bytes (the repo docs disagree), the payload format is uncaptured, and it is unknown whether the receiver needs init or keep-alive.
- **Is `family.hid.device` alone enough for a virtual keyboard/pointer**, and does a `family.hid.eventservice` development capability exist in the portal?
- **Does the GUI's `launchctl bootstrap` load a BTM-disallowed legacy plist?** Would an SMAppService agent still be unmanaged by RunningBoard?
- **Does a TCC grant to "GDHub" cover the `--engine` process (R12)?** Can an Aqua LaunchAgent use `CGEventPost`? Does Secure Input block HID-level keyboard output (probably not; guess)?
- **Does SDL's PlayStation detection probe the receiver?** Corsair's VID is on that list, so SDL's PS4/PS5 drivers send a Sony feature-report query (read). Does that probe disturb the receiver?
- **What gates the synthetic GamePad-1** ("Check Process Enabled") outside the compatibility switch?
- **With fast user switching, does the backgrounded engine leave its last report latched** on the pad until the heartbeat stops? (guess)
- **Does GCHIDLib load for an 0xFF58 match on 3A08?** That decides whether OJD's macOS 27 crash can reach GDHub.

**Could not be covered**
- Razer's HID event-service dext at run time: no Razer device is attached.
- iCUE at run time and under Game Mode: launching GUI apps was not allowed.
- Karabiner: not installed. Everything about it is from source.
- OJD at run time: no GIP pad attached and the app is not running.
- Steam Input's physical-controller path and update rate.
- reWASD: closed and undocumented.
- Shadow's 10 ms loop: closed source.
- Anything needing root: `sfltool dumpbtm`, `powermetrics`, sampling root daemons.
- Some citations failed:
  - `gh` is not installed, so some repo-wide Karabiner searches could not be done.
  - Karabiner's `examples/SMAppServiceExample` path does not exist; the real logic is in `ServiceManagementHelper.swift`.
  - One OJD `signing.md` raw URL returned 404 for one reviewer.
  - The Ryochan7 DS4Windows repo returns 404; the schmaldeo fork was used.
- Nothing was measured during a Game Mode session for this review, apart from the existing log history.