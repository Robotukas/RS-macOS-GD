# Controller latency plan (SCUF → GDHub → virtual pad → Shadow PC)

Status: plan rev 2, 2026-11-09. Rev 1 came from four read-only investigations (app-pipeline, macos-scheduling, shadow-client, prior-art). Rev 2 resolves a review of fixes #2, #3 and #4: every review item was checked against the code and the probes, and §6 says where the reviewer was right and where not.
Evidence tags: **M** = MEASURED, **R** = READ-IN-CODE, **C** = CITED (URL), **G** = GUESS.
Probes: `SP = /private/tmp/claude-502/-Users-Interlinked-macOS-GD/bbe7901d-5437-4b8d-8eec-0eed565c733c/scratchpad`.

Not yet measured: end-to-end SCUF → virtual-pad latency under real stick motion. The controller sat untouched in every capture: 0 changes in 250,000+ reports and 0 virtual reports (send-on-change). Every GDHub number below is therefore a per-stage measurement or a code reading. None of them comes from a measured end-to-end run.

## 1. Verdict

What the user feels is mostly lag that Shadow adds. GDHub adds a smaller amount most of the time, plus a possible tail.

**What GDHub adds:**
- At the start of a movement with the app awake: ≈0.1–0.3 ms.
  - Main-thread hop p50 6–9 µs, p99 ≤70 µs (**M**).
  - Kernel timestamp → callback p50 76 µs, p99 0.6 ms (**M**).
  - The first change after rest is sent at once (**R**).
- During continuous motion, the 250 Hz cap adds ≈2 ms on average and 4–6 ms at worst (**R**). Part of the worst case is the trailing-flush timer firing late: p99 1.0–1.4 ms, max 2.4 ms (**M**).
- Tail risks:
  - GDHub is App-Napped while Shadow is fullscreen (**M**): every GDHub thread drops from priority 46 to 4, and timers move to Tier4. This held continuously from 00:24:12 to 00:27:56, during the Shadow session. The extra delay this causes is **G**: 1–10 ms of jitter, and up to ~100 ms for the final state, which only the coalescable flush timer delivers. The nap clamps every GDHub thread, vhidQueue included, so only fix #1 addresses it; moving work off main does not (**M** all threads at 4).
  - The input path runs on the main thread, in a Debug (-Onone) build. At rest the main thread is ≈9 % busy handling 1 kHz identical frames (**M**: `sample` of pid 12944, 942 of 1039 samples idle in `mach_msg2_trap`; rev 1 range 5–12 %). The HID callback, its `Array` copy and `main.async` make up ≈20 of those samples (**M**). Whether main-thread work ever stalls input during play is unknown: rev 1's "1–16 ms stalls" was a **G**, and with Shadow fullscreen the GDHub window is occluded (**M**, napwatch) so SwiftUI should draw little (**G**).

**What Shadow adds:**
- Shadow's SDL joystick thread polls on a hard-coded 10 ms wait (**R**, disassembly; **M**, 1249/1253 samples in that wait). That adds 0–10 ms, mean ≈5 ms, and only the gamepad pays it. Keyboard and mouse are event-driven on a separate UDP channel (**M**). This is the best explanation for "keyboard and mouse have no lag".
- macOS GameController adopts our pad and creates a synthetic Xbox 360 copy (045E:028E, 8 ms interval, an extra gamecontrollerd hop). Shadow forwards that copy as a second XInput pad, gamepad 2 (**M**). If the game reads "any pad" or "last active", it sees the later copy too (effect **G**: 4–12 ms plus jitter).
- The video path sets the floor for all inputs (**M**): 60 fps cap, a forced 3840x2160 H.264 stream at 50 Mbps, and decode max rising from 6 ms to 29 ms during the session.
- For reference, a real Xbox pad already measures 13–19 ms average stick latency (**C**).

**Bottom line:** GDHub's own steady-state share is ≈2 ms, almost all of it the 250 Hz cap. Its tail risk is App Nap (**M** that it happens). Main-thread stalls are an unmeasured possibility. Shadow's 10 ms poll, the duplicate pad and the 4K/60 stream are larger. Only the duplicate pad and the stream settings can be changed without Shadow's help.

## 2. Ranked fixes

Fix IDs are unchanged from rev 1 so references stay valid. Row order is the rank. #3 is split: **3a** is an unconditional micro-fix, **3b** (off-main HID path) is conditional and now ranked below #4 and #5.

| # | Cause | Ev. | Expected gain | Exact change | Risk | Measure before/after |
|---|---|---|---|---|---|---|
| 1 | App Nap clamps all GDHub threads to priority 4 and puts timers in Tier4 while Shadow is fullscreen | **M** (runningboardd log, napwatch) | Removes G 1–10 ms jitter and a G ≤100 ms tail on the last state | `DriverManager`: when `PadPublishState` becomes published, call `activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "virtual pad passthrough")`. Call `endActivity` on unpublish, shutdown and `prepareForTermination`. Hold one token only (idempotent). Interim test with no code: `defaults write com.interlinked.gdhub NSAppSleepDisabled -bool YES`, then relaunch GDHub | Low. Slightly higher idle power while the pad is published | `SP/padlat/napwatch <pid> 120` with GDHub occluded or behind fullscreen Shadow: base priority must never be 4. `log show --predicate 'process == "runningboardd"'` must show no `AppNap state: <enabled:Y` for GDHub |
| 2 | Synthetic Xbox 360 copy (AppleGCSyntheticDevice 045E:028E, `LOGICAL_DEVICE(GDHub-1)`) is forwarded by Shadow as gamepad 2 | **M** (ioreg, shadow.log); effect on the game **G** | 0 if the game reads slot 0 only; otherwise G 4–12 ms plus removal of jitter or rubber-banding | User side first: see §4. Product: a `SyntheticPadWatcher` (new, owned by `DriverManager`) on its **own** serial queue at QoS `.utility`. It uses `IONotificationPortCreate` + `IONotificationPortSetDispatchQueue`, then `IOServiceAddMatchingNotification(kIOFirstMatchNotification)` and `(kIOTerminatedNotification)` for `IOServiceMatching("AppleGCSyntheticDevice")`. Drain both iterators once at arm time. In the callback, read `_GCSyntheticDeviceIdentifier` and keep the services whose identifier contains our serial. Post the count to MainActor; the Driver menu then shows the warning "macOS made a 2nd pad (Xbox 360) from GDHub — Shadow forwards both". Event-driven, no polling, and nothing on vhidQueue. Not now: changing identity to avoid GC adoption. Adoption is intended (design §check 14 lists *non*-adoption as the failure, and GFN needs it). The shadow-client claim that check 14 is "violated" is wrong | Low (warning only) | `SP/probe/hidprobe 20` while moving the stick: per-change delay 028E vs 02E0. In the VM, `joy.cpl` shows 1 vs 2 pads |
| 4 | 250 Hz cap with a coalescable trailing-flush timer (`makeTimerSource` without `.strict`) | **R** (VirtualPadSink.swift:49-50, 110, 405-426) + **M** (timer lateness p99 1–1.4 ms, max 2.4 ms) | While moving: ≈1.5–2 ms mean, ≈3–4 ms worst-case staleness (**R** arithmetic: uniform 0–4 ms wait → 0–1 ms, plus the timer-lateness tail). Shadow's 10 ms poll samples at a random phase, so it does **not** shrink this: the staleness adds to the poll's. It is about one tenth of the 10 ms poll plus the 16.7 ms frame time (**G** that it is felt) | (a) Leave `VirtualPadSink.Config.maxRateHz` default at 250, so existing tests keep their meaning. (b) In `DriverManager.init`, build the sink with `config: Config(maxRateHz: rate)`, where `rate = (UserDefaults.standard.object(forKey: "vpadMaxRateHz") as? Double) ?? 1000`, clamped to 60…1000. Use `object(forKey:)`, not `double(forKey:)`, because the latter returns 0 when the key is unset. (c) `SinkScheduler.after(_:strict:_:)`: add `strict: Bool`, with a protocol-extension overload `after(_:_:)` that passes `false`. `DispatchSinkScheduler` uses `DispatchSource.makeTimerSource(flags: strict ? .strict : [], queue:)`. Only `submit(state:)` (line 410) and `flushTimerFired` (line 422) pass `true`. The 300 ms identity-switch (line 219) and 1 s recreate (line 466) timers and the `every` heartbeat stay non-strict. `ManualScheduler` in the tests gets the new signature. Keep the immediate first send and send-on-change | Low. ≤1000 IOConnectCalls/s while moving. Shadow may send more per-axis messages (G, prior-art) → A/B 125 vs 1000 | Meter: post rate (Hz) and kernel→send p50/p95. `padlat` cross-correlation lag of continuous stick motion |
| 5 | Debug (-Onone) build installed for play | **M** (GDHub.debug.dylib in `sample`; 8–12 % CPU at rest) | G 0.05–0.5 ms per frame on the main thread; most of the at-rest CPU | Install a Release build (`xcodebuild -configuration Release`) for play sessions | Low | `top -l 5 -s 1`: GDHub CPU at rest should drop to ≲2 % (G) |
| 3a | Per-report heap `Array` and a redundant `main.async` in the HID callback, which already runs on the main run loop | **R** (HIDMonitor.swift:80, 135, 138-140, 142) + **M** (≈20 of 1039 main-thread samples in that callback and its block) | ≈1 allocation + 1 hop less per report at 1 kHz. Small CPU win (**G**), latency ≈ main-hop p50 6–9 µs (**M**) | For reports from the 0xFF58 interface only: inside the callback, call the handler synchronously with `MainActor.assumeIsolated` (the callback runs on the main run loop, line 80/142), and pass `UnsafeBufferPointer(start: report, count: length)`. The handler parses `GamepadFrame` before it returns and keeps no reference to the buffer. Switch the registration to `IOHIDDeviceRegisterInputReportWithTimeStampCallback` so the meter gets `tK`. The Bragi interface (page 0x0C) keeps today's copy + `main.async`, because its handler can send output reports | Low. No threading change | `sample <pid> 3`: no `swift_allocObject` under the HID callback. Meter: kernel→cb unchanged or lower |
| 3b | *Conditional.* Main-thread work between the HID callback and the sink could stall input | **G** (no stall measured; main ≈91 % idle at rest, **M**) | Unknown. Implement **only if** the meter (§3), run while the user plays, shows **kernel→drain** (`tD−tK`) p99 > 1 ms or max > 5 ms, with the GDHub window occluded or visible | See §2.1 for the full recipe. It uses a dedicated `IOHIDManager` for the 0xFF58 interface on a dispatch queue (verified pattern). The per-frame hot path (lastReportAt, diff, sink.submit) runs on the HID queue. Main gets only status changes, batched events, every frame while learning, and a throttled UI frame | Medium: threading. `EnvisionProDevice` splits into a nonisolated hot path and a MainActor UI part | Meter `tD−tK` p99/max before vs after, with the window visible and occluded. `sample <pid> 3`: no `EnvisionProDevice.handle` on main |
| 6 | `reportIntervalUs` 4000 advertised on the pad (real SCUF: 1000) | **M** (ioreg) / effect **G** | ≈0 (G) | `PadIdentity.swift:29` `reportIntervalUs: 1000`, together with #4. The pad must be re-created | Low. Re-publish needed | Before/after with `hidprobe`: no change expected; keep only if neutral |
| 7 | Dext post: `postReport` is an RPC onto the pad's queue (one cross-queue hop) | **R** (GDHubVirtualPad.iig:19-20, UserClient.cpp:457-467) | G ≈0.03–0.1 ms | Optional: `LOCALONLY` `postReport`, or call `handleReport` from the user-client queue | Medium (dext rebuild + reactivation) | Meter: send→IOConnect-return p50 |
| 8 | Deadband 0.002, heartbeat 500 ms, poller 1 s on vhidQueue | **R** | ≈0 | None. Deadband can stay. Heartbeat and poller each make one IOConnect call per tick and can delay one frame by one call (G ≤0.1 ms). Rule: no IORegistry scan runs on vhidQueue while the pad is published. Today the only scan, `DuplicatePadGuard.conflict`, runs only in `createIfWanted` (publish, identity switch, recreate), not during play (**R**, VirtualPadSink.swift:72-93, 270-273) | – | Meter p99 across a poller tick (§3) |
| 9 | Future rumble (D5): SDL holds `dev_lock` during a synchronous `IOHIDDeviceSetReport`, so input updates are skipped while it is in flight | **C** (SDL 2.24.2 SDL_hidapi_rumble.c, SDL_hidapijoystick.c:1004) + **R** (dext completes at once today) | 0 today; prevents a regression | D5 rule: `setReport` must call `CompleteReport` immediately in the dext and forward the data to the app asynchronously | – | Shadow rumble test while moving the stick: meter shows no gaps |

Not fixable locally: Shadow's 10 ms SDL poll (**R**). File a feature request with Shadow to poll at 1–2 ms or on hidapi arrival. Do not change the pad identity to chase it. 02E0 BLE is the correct identity for SDL on macOS (**C**, SDL_hidapi_xboxone.c:278).

### 2.1 Fix 3b recipe (only if the gate in the table trips)

**HID plumbing.** Rev 1's recipe crashes, so it must not be used (**M**). It called `IOHIDDeviceSetDispatchQueue` + `Activate` on the device handed out by the main manager. But `IOHIDManagerScheduleWithRunLoop(main)` (HIDMonitor.swift:80) already schedules every matched device on the main run loop. Probe `SP/review/dq.c` mode 0 dies with SIGTRAP (exit 133, reproduced; reviewer log: "Device already scheduled"). The SDK header agrees (IOHIDDevice.h, `IOHIDDeviceSetDispatchQueue`: a device "should not be associated with both a runloop and dispatch queue"). A queue-based manager that calls `IOHIDManagerOpen` *after* `IOHIDManagerActivate` also aborts ("Device has already been activated/cancelled", `SP/review/mq.c`).

Use pattern **B** (`SP/review/mq2.c`, **M**: 2893 of 2893 reports on the queue in 3 s, QoS 0x21 = user-interactive):
1. Create a second `IOHIDManager` that matches `{VendorID 0x1B1C, ProductID 0x3A08, PrimaryUsagePage 0xFF58}`.
2. Call, in this order:
   - `RegisterDeviceMatchingCallback`
   - `RegisterDeviceRemovalCallback`
   - `RegisterInputReportWithTimeStampCallback`
   - `SetDispatchQueue(hidQueue)`
   - `SetCancelHandler`
   - `Open`
   - `Activate`
3. Change the main manager's matching to `[{1B1C, 3A08, PrimaryUsagePage 0x0C}, {1B1C, 3A09}]`. Matching only on VID/PID is not enough to exclude 0xFF58: `IOHIDManagerOpen` opens every matched device (IOHIDManager.h:131), so the main manager would still hold the gamepad interface.
4. The 3A08 receiver has exactly two interfaces, 0xFF58 and 0x0C (**M**, ioreg). The Bragi control channel sits on 0x0C: its usage pairs include 0xFF42 (**M**). It stays on main, unchanged.
5. The dedicated manager's match and removal callbacks hop to main for `interfaceConnected`/`interfaceDisconnected`. These are rare events.
6. On stop, call `IOHIDManagerCancel` and keep the context alive until the cancel handler runs.

Alternative **A** (`SP/review/dq.c` mode 1, **M**: 2897/2897 on the queue, QoS 0x21): call `IOHIDDeviceCreate(kCFAllocatorDefault, IOHIDDeviceGetService(dev))` on the 0xFF58 interface and work on that fresh device. Order: open it, register the timestamp callback, `SetDispatchQueue`, `SetCancelHandler`, `Activate`. Register no input callback on the manager-owned copy. On removal, call `IOHIDDeviceCancel` and keep the context until the cancel handler runs. Pattern A was not chosen because the main manager still opens the manager-owned copy, so the process holds the interface twice (**R**, IOHIDManager.h:131). Whether that copy wakes the main run loop at all is **G**.

**`hidQueue`.** Use `vhidQueue` (zero hops into the sink) or a dedicated serial `.userInteractive` queue (one hop via the sink's lock-free mailbox). Choose with the meter. vhidQueue is fine only while it carries no IORegistry scan during play (fix #2 is event-driven on its own queue; #8 rule).

**Hot path on `hidQueue`, every report (no early-out before these steps):**
1. Parse `GamepadFrame` from the IOKit buffer.
2. Store `lastReportAt` (mach time) in an atomic or `OSAllocatedUnfairLock`. This must happen for every report, including identical ones. Reason (**R**): `timerTick` (EnvisionProDevice.swift:343-347) sets `.asleep` when `lastReportAt` is >2 s old. `.asleep` → `driver.controllerStatusChanged` → `sink.neutral()` (DriverManager.swift:212). The SCUF sends identical 0x06 reports at ≈964/s while held still (**M**, traffic log). If identical reports were dropped before this step, a stick or trigger held steady for 2 s would drop the pad to neutral.
3. Call `sink.submit(frame:mapping:revision:)` for every report. The sink's mailbox already dedups identical frames cheaply. `sink.neutral()` clears it (VirtualPadSink.swift:476), so a held state is re-sent after any neutral (**R**).
4. Read `mapping` and `mappingRevision` from a lock-protected `(mapping, revision)` pair. `EnvisionProDevice.mapping`'s `didSet` writes this pair on MainActor (EnvisionProDevice.swift:61-62).
5. Compare with the previous frame (kept on hidQueue) and run `diff()` against it for every frame. This keeps the per-frame thresholds of EnvisionProReport.swift:70-93 (axis 2000, trigger 40) exactly as today.

**To main (`DispatchQueue.main.async` only; never `main.sync`).** `DriverManager` calls `vhidQueue.sync` from main (DriverManager.swift:172, 182, 217, 220), so a `main.sync` from vhidQueue would deadlock (**R**).
- **Status.** Hop when a report arrives while `status != .active`, for the first report after asleep, receiverIdle or disconnected. Use a hidQueue-side flag so it is one hop, not one per report. Active→asleep stays on main: `timerTick` reads the atomic `lastReportAt`. Status never depends on window occlusion.
- **Event log.** Batch the `diff()` events and send them at ≤10 Hz, with each event's own timestamp.
- **Learn mode.** While `learn != nil` (mirror it in a lock-protected flag), forward **every** frame with its timestamp. That is the same load as today, and only during learning. Forwarding only changed frames would break learning (**R**): `LearnSession.feed` finishes a step only when it sees *quiet* frames for `settleTime` 0.5 s (LearnSession.swift:139-147), and `tick()` only enforces the step time limit (lines 150-153). It also collects rising button bits frame by frame (lines 121-148), so sampling would miss short taps.
- **Controller view.** Only the `@Published frame` is throttled and occlusion-gated. Today `publish()` already caps it at ≈125 Hz (`publishInterval` 0.008, EnvisionProDevice.swift:86-89, 325-341, **R**). Keep 125 Hz while the window is visible, and send nothing while it is occluded. On becoming visible, send the latest frame once.

**Tests.**
- Identical frames for 3 s keep status `.active` and cause no `neutral()` (fake clock; transport records no neutral post).
- A 5 ms tap (press frame then release frame) produces one buttonDown/buttonUp pair in the batched event log, and is seen by a running `LearnSession`.
- A learn step finishes by settle (not by time limit) when only identical quiet frames follow the motion.
- A mapping change on MainActor is used by the next frame on hidQueue (revision bump reaches the sink).

## 3. Built-in latency meter

**Stages** (all `mach_absolute_time`, converted with `mach_timebase_info`, recorded only for frames whose mapped pad state changed):
- `tK`: IOHID kernel timestamp from `IOHIDDeviceRegisterInputReportWithTimeStampCallback` (fix 3a).
- `tC`: callback entry. Today the callback runs on the main run loop, so main-thread stalls appear in `tC−tK` (**R**, HIDMonitor.swift:80, 142).
- `tD`: sink `drainMailbox` entry on vhidQueue, before the cap. New in rev 2.
- `tS`: sink chooses the state to send (`flush()` entry; for a coalesced frame this is the flush that carried it, attributed to the oldest pending `tK`).
- `tR`: `IOConnectCallStructMethod` return.

**Plumbing:** `tK` and `tC` travel with the frame. Use `submit(frame:mapping:revision:tK:tC:)`, called from `onFrame`. The mailbox keeps the **oldest** `(tK, tC)` since the last drain, so coalesced frames are attributed to their oldest input (**R**: `m.slot` is overwritten on each submit, VirtualPadSink.swift:365-373).

**Metrics, per stage pair:**
- `kernel→cb = tC−tK`
- `kernel→drain = tD−tK`: everything before the cap, including main-thread delay. This is the **gate for fix 3b**.
- `cap = tS−tD` (rate cap + flush timer; fix #4 shrinks it)
- `ioconnect = tR−tS`
- `total = tR−tK`

**Counters:**
- frames in, frames changed, posts, coalesced (dropped) states, post rate (Hz)
- `napped`: own thread base priority, read via `proc_pidinfo(getpid(), PROC_PIDTHREADINFO)` or `thread_info(THREAD_BASIC_INFO)` on the hid thread; 4 means napped.
- `pollerTickWorst`: the max `total` among frames whose `tD` falls within 2 ms after a `DextStatusPoller` tick. This checks that the 1 Hz poller adds no jitter.

**Storage:** `LatencyMeter` (new file `Sources/GDHub/Output/VirtualPad/LatencyMeter.swift`):
- One fixed ring of 4096 `(tK, tC, tD, tS, tR)` UInt64 tuples, written only on vhidQueue. No allocation and no lock on write.
- The 1 Hz `DextStatusPoller` tick (already on vhidQueue) computes p50/p95/p99/max over the last 10 s by copying and sorting ≤4096 values. It publishes a `LatencySnapshot` to MainActor alongside `padStats`.

**UI:** `DriverCommands` (App.swift:102, `CommandMenu("Driver")`) adds disabled items:
- `Latency (10 s): total p50 0.21 · p95 0.80 · max 3.1 ms`
- `  HID→cb / →drain / cap / IOConnect: …`
- `Posts 812 Hz · coalesced 3 % · App Nap: no`

Before the first change it shows "Latency: no input yet".

**Log:** `os_log` subsystem `com.interlinked.gdhub`, category `latency`, once every 10 s while posts > 0. Format: `total p50/p95/p99/max drain p50/p99/max cap… posts=… coalesced=… nap=… pollerWorst=…`. Read with `log show --predicate 'subsystem == "com.interlinked.gdhub" AND category == "latency"' --last 1h`.

**Tests:** in `VirtualPadSinkTests`, a fake clock injected into `LatencyMeter` checks the percentile math and the coalesced-frame attribution (the oldest `tK` wins).

**Standalone observer probes** (observe only, no seize, no dext connection):
- `SP/padlat/padlat` (src `padlat.swift`): `./padlat 20 /abs/path/run.csv` while the user flicks the left stick ×10, taps A/B, pulls and releases a trigger, then circles a stick. It prints phys→virt stick-onset, digital and trigger-edge latency p50/p95/p99/max, the cross-correlation lag of continuous motion, and virtual inter-arrival jitter.
- `SP/padlat/napwatch` (src `napwatch.swift`): `./napwatch <gdhub-pid> 20`. Run it in parallel with padlat. It shows per-thread priorities, the frontmost app and whether GDHub windows are on screen. Base priority 4 means napped.
- `SP/probe/latprobe` (src `latprobe.c`): `./latprobe 30 out.csv`, then `python3 -I SP/probe/analyse.py out.csv`. It reports SCUF change → pad report latency, latency of the first change after rest, and pad inter-arrival.
- `SP/probe/hidprobe`: `./hidprobe 20`. It records both 02E0 and synthetic 028E reports, so the delay of the synthetic copy can be computed.
- `SP/probe/hops.swift`: microbenchmark of `main.async`, queue hops and timer lateness.
- `SP/review/mq2.c`, `SP/review/dq.c`: dispatch-queue HID patterns for fix 3b (mode 0 of `dq` is the crashing rev 1 recipe; keep it as a regression example).

## 4. User settings (evidence-backed only)

1. **Shadow USB: turn off auto-forward for the SCUF receiver** (**M**). The ShadowUSB daemon auto-forwarded 1B1C:3A08 at session start (00:22:14), even with `--no-usb`. Where: Shadow PC, during a session → USB menu (Shadow bar → USB devices) → "SCUF Envision Pro Wireless USB Receiver V2" → disable auto-forward / unforward. Do this for 3A08 and 3A09 if both are listed.
2. **Check for the duplicate pad** (**M** that it exists, **G** that it hurts). In the Windows VM: Win+R → `joy.cpl`. Two controllers means the game may read the 125 Hz copy. If the game has a controller selector, pick controller 1 (Xbox One S). Mac-side test, effect unverified (G):
   - Quit Shadow PC.
   - Run `launchctl setenv SDL_GAMECONTROLLER_IGNORE_DEVICES 0x045e/0x028e`.
   - Start Shadow PC.
   - Check `joy.cpl` shows one pad.
   - Undo with `launchctl unsetenv SDL_GAMECONTROLLER_IGNORE_DEVICES`.
   - Side effect: this also hides Razer's 028E pad.
3. **Stop GDHub from napping until fix #1 ships** (**M**). In Terminal, run `defaults write com.interlinked.gdhub NSAppSleepDisabled -bool YES`, then quit and reopen GDHub. Also minimise or close the GDHub window while playing. It redraws on the same thread as input (**R**); the benefit is **G**.
4. **Stream settings** (**M** current values; gains **G**). Where: Shadow PC → Settings → Video & Display (Advanced).
   - **Codec:** enable HEVC (H.265). AV1 is fine too if it is offered. The account allows h264, h265 and av1, but the client sends `hevc:false`.
   - **Frame-rate limit:** set it to Unlimited/120 (**C** support.shadow.tech FPS-Limitations). The Mac display is 60 Hz (**M**, EDID), so the gain is only fresher frames; this is a G, so try it and keep it only if it feels better.
   - **Resolution:** stop the 4K fallback. In the VM, Windows Settings → System → Display → set 2560x1440 (the VM offers 1440p@119.88). Alternatively set the Shadow display resolution to 2560x1440 instead of fit-to-screen. Today the client asked for 1440p, and Shadow logged "Wanted configuration not applied" and fell back to 3840x2160.
   - **Bitrate:** keep manual 50 Mbps, or try dynamic. Network is kGreat with 0 % drop (**M**), so bitrate is not the issue.
5. **In the game:** turn V-Sync and triple buffering off (**C** support.shadow.tech tips-to-improve-latency). If Steam is used in the VM, A/B Steam → Settings → Controller → Xbox Configuration Support off (**G**).
6. **Baseline in the VM (optional):** run chrizonix/XInputTest (**C** https://github.com/chrizonix/XInputTest). It shows the update rate and hiccups the game actually receives: about 100 Hz is expected from Shadow's poll.

## 5. Implementation order (one Sonnet implementer)

The repo builds with `xcodebuild`. Unit tests are in `Tests/GDHubTests`. Do not touch the dext except in step 7.

1. **Latency meter** (§3) plus **fix 3a** (the timestamp callback is the meter's `tK` source). Include the Driver-menu lines and the os_log line. Done-checks:
   - `LatencyMeter` percentile and attribution tests pass.
   - With the test pattern (`--test-pattern`) the menu shows non-zero posts and a total p50.
   - No allocation on the write path or in the 0xFF58 HID callback: `sample` shows no `swift_allocObject` under either.
   - Bragi control traffic (battery readout, sleep timer) still works.
2. **App Nap opt-out** (fix #1). Done-checks:
   - Publish the pad, occlude GDHub for 2 min, and run `napwatch`: base priority stays 46.
   - The runningboardd log shows no AppNap enabled for the GDHub pid.
   - The meter's `nap` field reads "no".
3. **Sink rate** (fix #4) plus `reportIntervalUs` 1000 (fix #6). Done-checks:
   - Every existing `VirtualPadSinkTests` test passes **unchanged**. The `Config` default stays at 250, so `testThousandDistinctStatesOverOneSecondStayUnderTheCap` (≤251/>240), `testCoalescedStatesDeliverOnlyTheLastOneWithTheTrailingFlush` (4_000_000 ns gap) and `testReturningToTheSentStateCancelsTheTrailingFlush` (+1 ms steps) keep their meaning.
   - New test, `maxRateHz = 1000`: 1000 distinct states over 1 s give ≤1001 posts and the last state is delivered. Two states 0.5 ms apart get a trailing flush exactly 1_000_000 ns after the first post.
   - New test: `ManualScheduler` records `strict: true` only for the flush timers, and `false` for the identity-switch and recreate timers.
   - The test pattern shows post rate ≤1000 Hz. Idle posts are 0.
4. **Synthetic-pad warning** (fix #2): Driver menu item plus a log line. Done-checks:
   - With GC adoption present, the warning shows; with the pad unpublished, it clears.
   - `sample` shows no IORegistry calls on vhidQueue while the pad is published.
5. **Release build install** (fix #5). Done-check: `/Applications/GDHub.app/Contents/MacOS` has no `GDHub.debug.dylib`, and the dext still connects.
6. **Gate check for fix 3b.** Run the §5 re-measure with the user playing, with the GDHub window visible once and occluded once. Implement 3b (§2.1) only if `kernel→drain` p99 > 1 ms or max > 5 ms in either run. If it is implemented, done-checks:
   - All tests pass, including the four §2.1 tests.
   - At rest, `sample <pid> 3` shows no 0xFF58 HID callback or `EnvisionProDevice.handle` on the main thread.
   - Main-thread busy is <2 % at rest.
   - Learn mode (including a quick tap and a settle-finished step), input monitor, event log and controller view still work. A stick held still for 10 s keeps the status Active and the pad deflected.
   - Unplugging and replugging the receiver still publishes neutral and recovers. The cancel handler runs before the context is freed.
7. *(Optional, later)* dext `postReport` hop (fix #7). Do it only if the meter's `ioconnect` p95 is above 0.3 ms.

**Re-measure with the user moving a stick.** Shadow must be fullscreen and in-game. Do this once on the current build (baseline), again after steps 2 and 3, and once more after step 5 (this run is also the step-6 gate):
- Run `SP/padlat/padlat 20 /abs/run-<step>.csv` and `SP/padlat/napwatch <pid> 20` in parallel, with this script: left-stick flicks ×10, A/B taps ×10, trigger pull and release ×5, then stick circles for 5 s.
  - Targets: phys→virt stick-onset p50 <0.5 ms, p99 <2 ms, max <5 ms.
  - Continuous-motion xcorr lag <1 ms.
  - Virtual inter-arrival ≈1 ms while moving.
  - Never base priority 4.
- Run `SP/probe/hidprobe 20` during the same motion to measure the 028E copy's delay relative to 02E0, until the duplicate is removed.
- Read the built-in meter (Driver menu and the `latency` log line) and compare it with padlat: total p50/p95/max must agree within ≈0.2 ms. `pollerWorst` must not exceed the overall p99.
- A/B `defaults write com.interlinked.gdhub vpadMaxRateHz -float 125` vs `1000` in the same game scene, relaunching GDHub between runs (the rate is read when the sink is built). The user picks by feel, because Shadow's per-axis message cost is unknown.
- Optionally run XInputTest in the VM before and after the §4 stream and duplicate-pad changes.

## 6. Review resolution (rev 2)

| Review item | Verdict | Notes |
|---|---|---|
| Blocker: #3 API recipe crashes | **Right** | Reproduced: `SP/review/dq 0` exits 133 (SIGTRAP) right after `SetDispatchQueue`. Mode 1 and `mq2` delivered 2897/2897 and 2893/2893 reports on the queue at QoS 0x21 (**M**). Recipe replaced (§2.1, pattern B preferred). Added: excluding 0xFF58 needs usage-page matching on the main manager, because `IOHIDManagerOpen` opens every matched device |
| Blocker: early-out on identical bytes neutralises a held input | **Right** | Chain confirmed: EnvisionProDevice.swift:142 (lastReportAt only in `handle`), 343-347 (2 s → `.asleep`), App.swift:66 → DriverManager.swift:212 `sink.neutral()`. Early-out removed: lastReportAt is stored and `sink.submit` is called for every report; the sink's mailbox does the dedup. Reviewer wording "hop to main for the active-to-asleep transition" is inverted: the hop is needed for non-active→active (first report). Active→asleep is detected on main by `timerTick` |
| Major: UI throttling breaks learn mode and the event log | **Right, but the fix was incomplete** | Learn mode needs *every* frame, not just changed ones: a step finishes only when `feed` sees 0.5 s of quiet frames (LearnSession.swift:139-147). `tick()` checks only the time limit. "Forward every changed frame" would make every step run to its limit. `diff()` is now run per frame on hidQueue. The no-`main.sync` rule is confirmed (DriverManager.swift:172, 182, 217, 220). Also, rev 1 overlooked that `frame` is already throttled to ≈125 Hz (EnvisionProDevice.swift:86-89) |
| Major: #3 gain is a guess; rank it lower and make it conditional | **Right, with one correction to the gate metric** | 942/1039 main samples idle confirmed in `SP/review/s.txt` (**M**). #3 split into 3a (micro, unconditional) and 3b (conditional, below #4/#5). Correction: the gate cannot be callback→send. Today the callback itself runs on the main run loop, so a main stall delays `tC`, not `tS−tC`. The gate is `kernel→drain` (`tD−tK`), and the meter gained a `tD` stage. "Fixed buffer" became "no copy": the callback is already on main, so the handler is called synchronously with the IOKit buffer. A fixed buffer could not survive the `main.async` hop anyway |
| Major: #4 default change breaks tests; `.strict` for every timer | **Right** | Tests at VirtualPadSinkTests.swift:142-158, 174-187 and 189-199 confirmed. With a 1 ms cap, `b` at +1 ms posts at once (`now < last+interval` is false), so `[a]` becomes `[a,b,a]`. The default stays at 250 and is overridden in DriverManager. `strict:` parameter added, used only on lines 410/422. Added: `object(forKey:)`, because `double(forKey:)` returns 0 when the key is unset. Rev 1's "felt gain is smaller because Shadow samples every 10 ms" was wrong, and the gain column is corrected |
| Major: hidQueue = vhidQueue shares IORegistry scans | **Partly right** | Fix #2 polling on vhidQueue would add a 1 Hz IORegistry scan; it is replaced by an event-driven watcher on its own `.utility` queue. But `DuplicatePadGuard`'s scan is not periodic: it runs only in `createIfWanted` (publish, identity switch, recreate), not while the pad is published and in use (VirtualPadSink.swift:270-273). The poller and heartbeat on vhidQueue each make one IOConnect call per tick. Their effect is checked by the meter's `pollerWorst` |

## 7. Measured under real play, 2026-11-09 01:31–01:37 (release build, meter on, Shadow fullscreen)

The user played for about six minutes. 110 ten-second meter windows with at least 30 changed frames:

| Metric | Median window | Best | Worst |
|---|---|---|---|
| GDHub total delay, p50 | 57 ms | 3 ms | 97 ms |
| GDHub total delay, p95 | 135 ms | 70 ms | 495 ms |
| GDHub total delay, max | 195 ms | 93 ms | 1476 ms |
| Kernel timestamp → HID callback, p50 | 55 ms | 0.3 ms | 89 ms |
| Driver call (IOConnect), p50 | 1.2 ms | 0.9 ms | 2.0 ms |
| Posts to the pad | 15 Hz | – | 26 Hz |
| States coalesced away | 76 % | – | 83 % |

`napwatch` over the same period: every GDHub thread at base priority 4 in 940 of 1316 samples, exactly the samples with no GDHub window on screen. **The lag the user felt was GDHub's own main-thread HID callback being starved by the background-role clamp**, not Shadow's 10 ms poll. Fix #1 (activity assertion) does not prevent the clamp.

**Experiment (01:42):** the same 1 kHz receiver stream read by `latprobe` running as a launchd agent with `ProcessType = Interactive`, Shadow fullscreen in front, GDHub clamped in part of the run: 19264 of ~19250 reports, kernel → callback p50 0.14 ms, p95 0.33 ms, p99 0.55 ms, max 8.9 ms. A legacy `launchctl submit` job (default process type) was bad: only 3072 reports in 20 s, p95 35 ms. A plain child process of a foreground app: p50 0.12 ms, p99 2.9 ms, max 37 ms.

**Decision:** move the hot path (HID read → mapper → sink → dext client) out of the GUI app into a headless engine process registered as an Interactive LaunchAgent. The GUI becomes a front end. This supersedes the conditional fix 3b. Interim workaround for the user: run Shadow windowed on the same Space as the GDHub window, where the clamp does not apply.
