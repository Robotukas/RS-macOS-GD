# Receiver takeover: controller input translated inside the dext

*File: docs/plans/receiver-takeover-plan.md · Revision 2, 2026-11-09 · Status: planning, not approved · Decision: owner, 2026-11-09 ("take it over anyway")*

*Revision 2 applies the api-truth, failure-modes and scope-and-proof reviews. No blocker showed that the HID-tap mechanism cannot work, so the mechanism is unchanged. The main changes:*
- *INERT now means "attached, interface not opened".*
- *The pad is the only arbiter, and nothing waits on the tap.*
- *T0 uses one probe build with run-time steps, and every T0 build runs with `--same-build`.*
- *The LIVE dext code ships in T7, together with the engine code that uses it.*
- *Upgrade and rollback are exact command lists.*

*The "Review resolution" section at the end lists each review issue and what was done.*

Evidence tags: **M** = measured on this Mac. **R** = read (file:line, SDK header or URL). **G·Tn** = guess, to be proven or refuted in phase Tn.

**Summary**
- What changes for you: the dext reads the controller's interface 3 and drives the virtual Xbox pad itself. The background engine stops posting reports and becomes the supervisor and the automatic fallback.
- Expected latency (**G·T8**): p50 from 1.19 ms to about 0.2–0.35 ms, p99 from 2.69 ms to about 0.5–1.0 ms.
  - About 0.65 ms of the p50 gain is GDHub's own rate limiter, and T1 also removes that from today's path.
  - Only the takeover gives the rest: about 0.2–0.35 ms at p50 (less if the in-dext hop goes through the kernel, **G·T3**) and about 1 ms at p99.
- The rare 5–9 ms spikes will probably stay, because a bare reader saw them too (**M**). No game running at 60–144 fps will feel the latency change.
- The real gains: input keeps working when the engine crashes or hangs, and the 220–360 IOConnect posts per second go away. The engine still reads about 955 reports/s as a hot standby.
- What stays in the app: live view, learn mode, mappings, battery and sleep timer (interface 4) and the Driver menu. Apple's USB HID driver stays on the receiver.
- Cost:
  - About 1,400 lines of dext C/C++ and 900 lines of Swift (**G**).
  - 4–5 production dext replacements before the gate, plus 4 probe operations in T0. Any of them may need a reboot.
  - A bug in the tap code now takes the pad down with it.
- The engine path stays the default until the T8 gate passes. `defaults write com.interlinked.gdhub inputPath -string engine` forces it at any time.

## Phases

| Phase | Title | Needs dext replacement? | Status |
|---|---|---|---|
| T0 | Probe dext: does it load, does it win the match, one process, raw reads intact, reports in-driver, crash relaunch, downgrade | Probe dext only (4 probe operations; production untouched) | ▶ current (T0.1: probe written, sign-only build passes; not installed) |
| T1 | Engine limiter fix (rank 5) and the new baseline | No | pending |
| T2 | One shared C translator; the engine runs it | No | pending |
| T3 | Root owns the pad; registry; fixed-length post buffers; DextClient matching fix | Yes | pending |
| T4 | Tap in production, INERT and COUNT only; soak; upgrade and rollback drills | Yes | pending |
| T5 | Translator inside the dext, SHADOW only; mapping blob | Yes | pending |
| T6 | Engine supervisor in SHADOW; input-path switch | No (app only) | pending |
| T7 | LIVE: pad arbitration, pinning, adopt, neutral paths (dext and engine together) | Yes (+1 fix replacement allowed) | pending |
| T8 | Gate and play test; LIVE becomes the default | No | pending |
| T9 | Shared Hot queue (only if G11 or G12 fails) | Yes (conditional) | pending |
| T10 | Rumble (after the 0x09 capture) | Yes | pending |
| T11 | Macro overlay (MERGE with TTL) and D8 slots under the root | Yes | pending |
| T12 | AutoArm: pad with no user process (optional; needs a measured relaunch signal) | Yes | pending |

---

## 1. Goal and measured justification

**Goal.** Move the per-report work (parse, map, deadband/hysteresis, build, post) from the engine process into the dext. Anything that changes often (mappings, profiles, macros) stays as data or stays in user space.

**Today (all M, engine-agent-plan.md §8.4, under Game Mode):**
- Total delay: p50 1.19 ms, p99 2.69 ms, worst max 8.88 ms.
- Stages at p50: kernel→callback 0.12 ms, rate limiter ("cap") about 0.65 ms, IOConnect 0.36 ms.
- Posts: median 217 Hz, peak 363 Hz. About 21 % of changed frames are coalesced.
- Thread priorities: dext 63, engine 37, GUI 46 (**M** `ps -axo pid,pri,comm` today).
- The receiver sends 946–961 reports/s while the controller is awake (**M**).

**Removed from the critical path** (detail in §4.4):
- the engine wake;
- the limiter;
- two engine queue hops;
- the IOConnect call;
- the per-post `SetLength` RPC (non-LOCAL: **R** IOBufferMemoryDescriptor.iig:93; called on every post: **R** GDHubVirtualHIDUserClient.cpp:135).

**Honest gain**

| Comparison | p50 | p99 | Tag |
|---|---|---|---|
| Today, engine path | 1.19 ms | 2.69 ms | **M** |
| After the T1 limiter fix, engine path | about 0.5 ms | unknown | **G·T1** (simulated, **R** other-controller-drivers.md:221-228) |
| After the takeover, in-dext total | 0.15–0.35 ms | 0.5–1.0 ms | **G·T8** |
| Unique to the takeover (against T1) | about 0.2–0.35 ms; less if the hop is a kernel round trip | about 1 ms | **G·T3, T8** |
| 5–9 ms spikes | probably unchanged | — | **G** (a bare reader saw them, **M**) |

**Non-latency gains**
- Input survives an engine hang. It also survives an engine crash while launchd restarts the engine (KeepAlive true, ThrottleInterval 2 s: **R** Xcode/Engine/com.interlinked.gdhub.engine.plist:21-24) and the new engine adopts the pad.
- No IOConnect traffic at 220–360 posts/s.
- The post path no longer depends on Game Mode demoting user processes (**M** engine-agent-plan.md:28-35).
- This is **not** a gain: in LIVE the engine still wakes about 955 times a second. Its reader is the hot standby and feeds stall checks F1 and F6 (§6.6).

**Costs**
- The dext now contains code that knows the receiver's report format.
- Production dext replacements: T3, T4, T5 and T7 (plus one fix build allowed in T7), then T9–T12 if they are done. Any of them may force a reboot (**R** driverkit-dext-design.md:1316-1320).
- Larger blast radius. The root, the user client, the pad and the tap share one process. A crash in any tap code (Start, Stop, SetPowerState, the timer, pool handling) kills the pad, and the engine fallback with it, until the dext relaunches (§7).
- macOS may reboot the Mac when a driver crashes too often (**R** DriverKit IOKitKeys.h:134-136). The opt-out entitlement `com.apple.private.driverkit.test-driver` is private. Whether this policy applies here is **G·T0.3**.

---

## 2. Chosen mechanism and why

### 2.1 Choosing between the judged designs

| Judge | safest-path | hid-tap | usb-claim | Winner |
|---|---|---|---|---|
| driverkit-correctness | 8 | 7.5 | 5 | safest-path |
| safety-and-rollback | 8.5 | 7.5 | 4.5 | safest-path |
| product-fit | 7 | 8 | 5 | hid-tap |
| **driverkit + safety** | **16.5** | 15.0 | 9.5 | **safest-path** |

The rule is to take the design that driverkit-correctness and safety-and-rollback rate highest together. That is **safest-path**. Product-fit's preferences are kept as grafts:
- an always-attached tap that does not open the interface until armed;
- a 250 ms silence neutral;
- getpid() as the one-process proof;
- `com.apple.kpi.iokit` as the kernel bundle for the tap personality;
- devTerminate terminates the tap first;
- a shared queue only if measurements call for it;
- a MERGE overlay for macros.

### 2.2 Mechanism: a HID tap on interface 3's IOHIDInterface

- A new service, `GDHubReceiverTap`, matches only interface 3's `IOHIDInterface`: VendorID 6940, ProductID 14856, PrimaryUsagePage 65368, PrimaryUsage 1. Interface 3 carries these values today (**M** ioreg).
- It competes with `AppleUserHIDEventDriver`, which scores 1201 on that interface (**M**). With IOProbeScore 1000 the tap should score about 8200 (**G·T0**). The score increments are VendorID +5000, ProductID +1000, page/usage +1100/+100 (**R** IOHIDFamily IOHIDFamilyPrivate.cpp, via review).
- Apple's stack stays: `IOUSBHostInterface@3 → AppleUserUSBHostHIDDevice → IOHIDDevice`. User-space readers (engine, GUI, padlat) attach an `IOHIDLibUserClient` to that IOHIDDevice, beside IOHIDInterface (**M** ioreg). They keep their data source whatever the tap does.
- Only one client can open an IOHIDInterface (**R** MacOSX27 Kernel IOService.h:655-664, single-owner handleOpen). The tap must therefore **win** the match.
- Opening IOHIDInterface also opens the owning IOHIDDevice. That open fails while a user-space client has seized the device (**R** MacOSX27 Kernel IOKit/hid/IOHIDDevice.h:255; upstream IOHIDInterface.cpp, via review). An Open failure can therefore mean "seized" rather than "not allowed" (§4.5).
- Reports arrive through `Open(this, 0, action TYPE(ReportAvailable))` (**R** HIDDriverKit IOHIDInterface.iig:110-115, 149-151).
- The kernel already delivers these reports today, to Apple's event driver: ReportAvailableCalls 31,483,360 against InputReportCount 31,483,370 (**M**).
- The tap attaches at every 3A08 enumeration but stays INERT until the engine arms it (§6.1). INERT means the interface is not opened.
- The pad moves from the user client to the root, so it survives 3A08↔3A09 re-enumeration and an engine crash.

### 2.3 Rejected alternatives

| Alternative | Why rejected |
|---|---|
| **USB claim**: an IOUserUSBHostHIDDevice subclass on IOUSBHostInterface@3 | It removes only Apple's dext leg, about 0.05–0.15 ms (**G**). In exchange, a crash, a failed load or a stuck replacement leaves interface 3 without a driver, so the controller and the engine fallback are both dead. It relies on unverified base-class internals (**R** IOUserUSBHostHIDDevice.iig:224-227 documents only the completion). It needs transport.usb. A forum case shows a 90000-score personality losing to Apple's 50001 (**R** developer.apple.com/forums/thread/717364). **Kept as the last resort** if neither Plan A nor Plan C can Open the IOHIDInterface. |
| Plain USB claim (CopyPipe/AsyncIO) | It removes the 0xFF58 IOHIDDevice from user space. The live view, learn mode, battery gating, padlat and the engine fallback would all go dead. |
| A tap that refuses Start until armed | After every boot or relaunch, the tap would be missing until the controller is power-cycled. An attached tap that does not open the interface runs no per-frame code and is just as safe (§6.1). |
| Subclassing IOUserHIDEventDriver | It parses game-controller elements on every report (**R** IOUserHIDEventDriver.iig:39-126). |
| The tap in a separate dext, with IPC to the pad | It adds a kernel round trip, which defeats the purpose. |
| Integer-only translator | Integers precomputed in raw units cannot reproduce Swift's Double results for learned asymmetric ranges (§5.1). |
| OVERRIDE lease for macros | Extra state that invites stuck inputs, and it puts user space back in the hot path. Macros use a MERGE overlay (T11). |

**Plan B.** Used if T0 shows the root and the tap in different processes. The tap hosts its own pad and the engine connects to the tap. The pad then disappears whenever the controller powers off. Stop and review the plan before going on.

**Plan C.** Used if a plain IOService cannot Open the interface while nothing has seized it (§4.5). The tap becomes an `IOUserHIDEventService` subclass (§3.4).

### 2.4 Documented decisions this reverses or amends

Each document is updated in the phase named.

| Decision | Change | Phase |
|---|---|---|
| G5 "Failure is safe": an app crash removes the devices (**R** driverkit-dext-design.md:30) | In LIVE, the pad survives an engine crash or hang. An unowned pad is removed after 30 s (orphan timer, §6.3). LEGACY keeps G5 exactly. | T7 |
| Dext design: the user client is the provider of every HID child | The root becomes the provider. | T3 |
| Dext design D5 output path: `GDHubUCDeliverOutput(uc, …)` through the pad's `ivars->uc` (**R** GDHubInternal.h:22; GDHubVirtualPad.cpp:31-37) | The pad looks up the current owner user client through the registry (+1 retained copy) when it delivers output. | T3 |
| Dext design §4.2: nothing in the dext is identity-specific | Softened. The output layout stays data (placements in the blob). The input parser is specific to the Envision Pro's report 0x06. | T5 |
| Output-layer decision 5: no seizing of FF58 (**R** output-layer-plan.md:84) | Kept in intent. GDHub never seizes the IOHIDDevice; it takes only the IOHIDInterface away from Apple's event driver. | T4 |
| Output-layer §3.1 Swift pipeline: EchoResolver, LayerStack, ActivatorMachine, MacroPlayer (**R** output-layer-plan.md:93-101) | Kept. The dext runs only what GDHM v1 can express: stateless rules with at most 2 OR'ed sources per output item. Anything else, including the done-check remap "paddle_outer_right → Y" with echo suppression (**R** output-layer-plan.md:515), runs on the engine path. The Driver menu then shows "Input path: App (mapping needs GDHM v2: <reason>)". Each new in-dext primitive costs one dext replacement. | T6 |
| Engine-agent R14: the engine reads defaults only at start (**R** engine-agent-plan.md:900) | Reversed for `inputPath` and `tapDrill` only, which are polled once per second. | T6 |
| Research ranks 6–7: rumble through the engine (**R** other-controller-drivers.md:235-276) | Superseded by T10, in-dext rumble. The engine writes only a single stop-only zero-rumble (T10). | T10 |
| Research §3 rejected in-dext forwarding (**R** other-controller-drivers.md:370) | Overridden by the owner's decision. A pointer to this plan is added. | with this plan |

### 2.5 Assumptions to prove

| # | Assumption | Proven in |
|---|---|---|
| A1 | With `IOUserServerOneProcess` and the same `IOUserServerName`, the root (on IOUserResources) and the tap (on IOHIDInterface) run in one process. Apple's own dext does this across providers (**M**: 21 services in pid 607); ours is untested. | T0.2, T4 |
| A2 | AMFI loads a development-signed dext that carries `transport.hid`. The profile grants it (**M** signing probe); loading is untested. | T0.2 |
| A3 | The tap personality wins on interface 3 only. Interfaces 0–2, interface 4 and 3A09 are untouched. | T0.2, T4 |
| A4 | A plain IOService may Open the IOHIDInterface and receive ReportAvailable. Success is judged by frames arriving at 940–970/s, never by Open's return code (§4.5). | T0.2 |
| A5 | Report 0x06 arrives as reportID 6 with length 16, ID byte first, and 0x58 reports can be told apart. | T0.2 |
| A6 | With a per-report `AddReportToPool` re-add (strategy B), CreatedBuffers stays flat. Without it (strategy A), CreatedBuffers grows by about one per report (**R** upstream IOHIDInterface.cpp handleReportGated, via review). | T0.2 |
| A7 | The ReportAvailable timestamp is in mach absolute time, close to USB completion. | T0.2 |
| A8 | When the tap's Start fails, IOKit attaches the next candidate, Apple's event driver. | T0.2 |
| A9 | After a crash, the dext is relaunched and interface 3 is matched again. To be recorded: by whom, after what delay, with what throttling, and any OS reboot response. | T0.3 |
| A10 | A new personality takes interface 3 only at the next 3A08 enumeration. | T0.2, every phase |
| A11 | Removing Apple's event driver from interface 3 changes nothing games use. GameController does not see the raw receiver today (**R** envision-pro-receiver.md:35). | T0.2, T4 |
| A12 | Whether the controller's sleep timer re-enumerates the receiver (to 3A09) or only stops the stream. | T0.1 |
| A13 | Mac sleep: which SetPowerState flags reach the tap (Off, On, Low or LPW, **R** IOService.h:58-61), and whether the receiver re-enumerates. | T0.2, T7 |
| A14 | No other personality competes for 1B1C on IOHIDInterface. Partly **M** today: 2,863 personalities scanned; the only 6940 entry is USB mass storage 6940:6659. | T0.1, after every macOS update |
| A15 | The root can Create the pad with `GDHubPadProperties` at root level (**R** IOService.iig:296-312). | T3 |
| A16 | handleReport works with buffers whose length was set once, with no SetLength per post. | T3 |
| A17 | Double-precision math in the shared C core runs correctly inside the dext. It compiles (**M** scratch); the in-dext self-test checks the results. | T5 |
| A18 | devTerminate lets the process exit with the tap attached, and a new tap attaches after a power cycle. | T4 |
| A19 | Cost and routing of the cross-queue hop (user client or tap queue → pad queue). The iig stub builds an IORPC message and calls `Invoke()`, and no header documents an in-process short cut (**R** generated stub, via review). | T3 |
| A20 | The engine sees a change to the `inputPath` defaults key, made by another process, within 1 s. | T6 |
| A21 | The engine LaunchAgent gets SIGTERM on logout and keeps running during fast user switching. | T6 |
| A22 | A user-space seize of the 0xFF58 device starves IOHIDInterface delivery (**R** upstream IOHIDDevice.cpp `!_seizedClient`, via review). | T6 |
| A23 | sysextd accepts activating a **lower** CFBundleVersion; the rollback depends on it. | T0.4 |
| A24 | `IODispatchQueue::DispatchAsync` (LOCALONLY, **R** IODispatchQueue.iig:133) onto another service's queue in the same process runs the block on that queue. | T4 |
| A25 | `IODEXTMatchCount` (**R** IOKitKeys.h:109; IOUserResources shows 4 today, via review) changes when a crashed dext relaunches. This would be the T12 relaunch signal. | T0.3 |

---

## 3. Personalities and entitlements (exact)

All edits go in `project.yml`. xcodegen regenerates Info.plist and .entitlements from it (**R** project.yml:31-58; build-xcode.sh:33).

### 3.1 Root (production): changed in T3 and T4

```yaml
GDHubVirtualHID:
  CFBundleIdentifier: $(PRODUCT_BUNDLE_IDENTIFIER)
  CFBundleIdentifierKernel: com.apple.kpi.iokit
  IOClass: IOUserService
  IOMatchCategory: $(PRODUCT_BUNDLE_IDENTIFIER)         # unchanged: own category on IOUserResources
  IOProviderClass: IOUserResources
  IOResourceMatch: IOKit
  IOUserClass: GDHubVirtualHID
  IOUserServerName: $(PRODUCT_BUNDLE_IDENTIFIER)
  IOUserServerOneProcess: true                          # T4 (R IOKitKeys.h:193)
  GDHubPadProperties: {IOClass: AppleUserHIDDevice, IOUserClass: GDHubVirtualPad}   # T3: moved up (today R project.yml:52)
  # T11: GDHubKeyboardProperties / GDHubPointerProperties move up the same way
  UserClientProperties:
    IOClass: IOUserUserClient
    IOUserClass: GDHubVirtualHIDUserClient
```

### 3.2 Tap (production): new in T4

```yaml
GDHubReceiverTap:
  CFBundleIdentifier: $(PRODUCT_BUNDLE_IDENTIFIER)
  CFBundleIdentifierKernel: com.apple.kpi.iokit         # same as the root (R project.yml:42)
  IOClass: IOUserService
  IOProviderClass: IOHIDInterface
  IOUserClass: GDHubReceiverTap
  IOUserServerName: $(PRODUCT_BUNDLE_IDENTIFIER)
  IOUserServerOneProcess: true
  VendorID: 6940          # integer
  ProductID: 14856        # integer; 3A08 only. 3A09 (14857) and wired 3A05/3A06 never match
  PrimaryUsagePage: 65368 # integer; interface 4 is page 0x0C and cannot match (M)
  PrimaryUsage: 1         # integer
  IOProbeScore: 1000      # about 8200 in total (G·T0). Leaves a margin over a future Apple VID/PID
                          # personality on IOHIDInterface, which would score about 7000 (R AppleGameControllerPersonality
                          # pattern 1000+VID+PID, via review). It changes nothing else.
  # no IOMatchCategory: competes in IODefaultMatchCategory. Never com.apple.null.driver.
```

- `Transport` is left out on purpose. The score is already far above 1201, and every extra key is one more way to miss the match.
- DextClient matches services by `IOUserServerName` (**R** DextClient.swift:93-97). The tap carries the same server name, because OneProcess needs it. T3 therefore adds `IOUserClass = GDHubVirtualHID` to DextClient's match before the tap exists (§8.2).

### 3.3 Probe (throwaway): T0 only, deleted in T0.5

- New target `GDHubTapProbe` (type driver-extension, `scheme: {}` as on the app target, **R** project.yml:9). Bundle ID `com.interlinked.gdhub.TapProbe`. It is a dependency of the app target only during T0.
- `CFBundleVersion: $(PROBE_BUILD)`, never `$(CURRENT_PROJECT_VERSION)`. build-xcode.sh passes `CURRENT_PROJECT_VERSION=$BUILD` on the xcodebuild command line, which overrides that setting for every target (**R** build-xcode.sh:34-35). The number lives in `Xcode/probe-build`.
- `GCC_PREPROCESSOR_DEFINITIONS: GDHUB_PROBE_CRASH=$(PROBE_CRASH)`. Default 0; build-xcode.sh passes `PROBE_CRASH`.
- `GDHubProbeRoot`: the root keys from §3.1, with IOUserClass `GDHubProbeRoot`, IOMatchCategory set to the probe's bundle ID, and `IOUserServerOneProcess: true`.
- `GDHubProbeTap`: the tap keys from §3.2, with IOUserClass `GDHubProbeTap` and **`IOProbeScore: 50`**. If a probe lingers, the production tap (1000) still wins.
- Behaviour, in one build:
  - The **first** tap Start in a process logs and declines with `kIOReturnUnsupported`.
  - Every **later** Start in that process runs (§11 T0.2).
  - With `GDHUB_PROBE_CRASH=1`, the tap never declines and crashes only on the owner's chord (§11 T0.3).
- Every log line starts `GDHubProbe: build=N crash=C pid=P`. Results count only when N matches the build under test.

### 3.4 Plan C variant: only if A4 fails while nothing is seized

- Tap keys: `IOClass: AppleUserHIDEventService`, `CFBundleIdentifierKernel: com.apple.iokit.IOHIDFamily`.
- The class subclasses `IOUserHIDEventService`. In handleStart it calls `SetProperties({IOHIDEventDriverHandlesReport: true})` (**R** IOUserHIDEventService.iig:159-182; key **R** IOHIDEventServiceKeys.h:147).
- `handleReport` receives raw bytes (**R** IOUserHIDEventService.iig:575-579). The §4.5 pool code does not apply.
- The fuse is weaker. Reports reach handleReport whether or not the tap is armed, so INERT becomes "return at the first line".

### 3.5 Entitlements

```yaml
# production dext, from T4
com.apple.developer.driverkit: true
com.apple.developer.driverkit.family.hid.device: true
com.apple.developer.driverkit.allow-any-userclient-access: true
com.apple.developer.driverkit.transport.hid: true      # R IOKitKeys.h:149; IOHIDInterface requires it (M IOServiceDEXTEntitlements)
# Plan C only: com.apple.developer.driverkit.family.hid.eventservice: true
# probe (T0): com.apple.developer.driverkit + com.apple.developer.driverkit.transport.hid only
```

- transport.usb is **not** needed.

### 3.6 Build checks (scripts/build-xcode.sh)

**T4: production checks.** `$DEXT` is defined at build-xcode.sh:38 (**R**). The script runs with `set -u` (**R** :10).
- Add `com.apple.developer.driverkit.transport.hid` to the `need` call for the dext (**R** :55-56).
- Add after the `need` calls:
  ```sh
  P="$DEXT/Info.plist"
  for k in VendorID ProductID PrimaryUsagePage PrimaryUsage IOProbeScore; do
    plutil -extract "IOKitPersonalities.GDHubReceiverTap.$k" xml1 -o - "$P" | grep -q '<integer>' \
      || { echo "tap $k is not an integer"; exit 2; }
  done
  for p in GDHubVirtualHID GDHubReceiverTap; do
    plutil -extract "IOKitPersonalities.$p.IOUserServerOneProcess" xml1 -o - "$P" | grep -q '<true/>' \
      || { echo "$p lacks IOUserServerOneProcess"; exit 2; }
  done
  ```

**T0: `--probe` mode** (removed in T0.5):
- While `Xcode/probe-build` exists, the script refuses to run without `--probe`. `--probe` is refused when the file is missing.
- `--probe` forces `SAME=1`, so the production version cannot be bumped (**R** :24).
- It passes `PROBE_BUILD=$(cat Xcode/probe-build) PROBE_CRASH=${PROBE_CRASH:-0}` to xcodebuild.
- It asserts that the embedded production dext's CFBundleVersion equals `$installed` (**R** :14), and stops otherwise. If they differed, the next GUI launch would replace the production dext (**R** DriverManager.swift:521-545).
- It asserts that the probe's CFBundleVersion equals `Xcode/probe-build` and is greater than the installed probe version, unless `--probe-downgrade` is passed. The installed probe version is read from `systemextensionsctl list`, as at :14.
- It runs `need` on the probe dext: driverkit, transport.hid and this Mac's UDID.

---

## 4. Classes, queues and the report path

### 4.1 Classes

| Class | Provider | Queue | Runs there | Phase |
|---|---|---|---|---|
| `GDHubVirtualHID` (root) | IOUserResources | root default + 30 s orphan timer | Start/Stop, NewUserClient, `CreatePad`/`DestroyPad`, orphan expiry, devTerminate sequence, pid log | T3, T4, T7 |
| `GDHubVirtualHIDUserClient` | root | UC default + 250 ms watchdog (**R** .iig:15) | selectors 0–12, GDHM validation, registry writes for arbitration | T3, T5, T7 |
| `GDHubVirtualPad` | **root** (today the UC, **R** GDHubVirtualPad.cpp:31-37) | pad default | handleStart; `submitInput(source, tSrc, md, len)` and `postNeutralFrom(source, reason)`, the only callers of handleReport; setReport/getReport | T3, T7 |
| `GDHubReceiverTap` | IOHIDInterface (interface 3, 3A08) | tap default + 50 ms timer | Start, Stop, SetPowerState, ReportAvailable, timer (silence, Open retry, state backstop), `applyDesired` (reached by DispatchAsync) | T4, T5, T7 |
| `GDHubRegistry` (plain C++) | — | none: private IOLock + atomic words | §4.3 | T3 |
| `GDHubXlate` (C99) | — | caller's | eval, snap, hysteresis, build, byte dedupe | T2 |

Notes:
- Each IOService gets its own default queue (**R** IOService.iig:171-175).
- A queue runs one block at a time (**R** IODispatchQueue.iig:69).
- `handleReport` is LOCALONLY and ends in the `_HandleReport` RPC (**R** IOHIDDevice.iig:60, 139).

### 4.2 Call-order invariant (checked in every build)

- Only these synchronous cross-object calls exist:
  - UC → root (`CreatePad`, `DestroyPad`);
  - UC → pad;
  - root → pad (orphan expiry neutral);
  - tap → pad.
- The pad calls no GDHub object.
- **Nothing calls the tap synchronously.** Control reaches the tap only through registry writes plus `tapQueue->DispatchAsync(...)` (A24), with the tap's 50 ms timer as a backstop.
- Ranks: UC 1 → root 2 → tap 3 → pad 4. Calls go only toward a higher rank. Kernel-initiated callbacks (Start, Stop, ReportAvailable, SetPowerState) are not calls.
- **Creation path.** UC calls `root->CreatePad`. The root blocks in `Create` while the kernel runs the pad's Start on the pad queue. The pad reads its spec from the registry and calls nothing. This is today's proven pattern with the UC (**R** GDHubVirtualPad.cpp:31-59; GDHubVirtualHIDUserClient.cpp:193-212).
- **Registry lock.** The IOLock is private to `GDHubRegistry.cpp`. Its functions copy values in and out, and release objects only after unlocking. No other code can hold the lock, so no RPC ever runs under it. This carries over today's rule "Do not hold the lock across Create" (**R** GDHubVirtualHIDUserClient.cpp:193). A build grep fails if `GDHubRegistry.cpp` calls a method of any GDHub class.
- **GDH_SYNC(rank)** wraps every cross-object call in every build. It is not DEBUG-gated, and it only logs. It counts `syncViolations` and logs the call when the current queue belongs to an object of equal or higher rank (`IODispatchQueue::OnQueue()`, **R** IODispatchQueue.iig:105).
- Result: the UC queue can block only on Create or on the pad queue, the same exposure as today's postReport. It never waits on the tap.

### 4.3 Registry (process-global)

- `gdh_registry()` returns a static struct. Its IOLock is installed by compare-and-swap (`__atomic_compare_exchange_n`), and the loser frees its own lock.
- Hot words use the `__atomic_load_n`/`__atomic_store_n` builtins. The DriverKit SDK does ship `<atomic>` and `math.h` (**M** `ls` of DriverKit27.0.sdk/System/DriverKit/usr/include). The builtins are a style choice that keeps the file free of libc++, and they compile with no undefined symbols (**M** scratch).
- **Under the lock:**
  - retained `root`, `pad`, `tap` and `tapQueue`;
  - the owner UC (for D5 output delivery);
  - the accepted map: OSData holding a validated `gdx_map`, plus `acceptedRevision` and `acceptedSpecCRC`;
  - `padSpecCRC`;
  - `instanceNonce`: `mach_absolute_time()` at root Start, used only as an identity. Its origin is arbitrary (**R** IOLib.h:177-188).
  - `selfTest`.
- **Atomic words:**
  - `padSource`: NONE / UC / TAP;
  - `desiredState`: INERT / COUNT / SHADOW / LIVE. It starts INERT on every launch; this is the fuse.
  - `appliedState` and `appliedRevision`, written only by the tap queue;
  - `holdNeutral`;
  - `mapGen`;
  - `pauseUntil`.
- **Accessors return +1 retained objects:** `gdh_copy_pad()`, `gdh_copy_owner_uc()`, `gdh_copy_map(&gen)`. The caller releases after its call.
- `gdh_register_tap(tap, queue, &desired)` sets the pointer and reads `desiredState` in **one** critical section, so no state change can be lost between the two.
- Whichever service starts first (root or tap) initialises the registry. The tap never dereferences the root.

### 4.4 Report path and user/kernel crossings

**Today (engine path)**

| # | Step | Crossing | Critical path |
|---|---|---|---|
| 1 | USB interrupt-IN completion reaches Apple's HID dext | K→U | yes (shared) |
| 2 | Apple's dext handleReport into the IOHIDDevice | U→K | yes (shared) |
| 3 | The IOHIDLibUserClient queue wakes the engine callback (priority 37, **M**) | K→U | yes |
| 4 | Mailbox → vhidQueue; limiter wait 0.65 ms p50 (**M**) | in-process ×2 | yes |
| 5 | IOConnectCallMethod postReport | U→K | yes |
| 6 | GDHub dext ExternalMethod on the UC queue | K→U | yes |
| 7 | `SetLength` on the post buffer (non-LOCAL, **R**; cost **G**) | U→K | yes |
| 8 | UC queue → pad queue (routing **G·T3**) | none, or U→K + K→U | yes |
| 9 | `_HandleReport` | U→K | yes: end |
| 10 | Replies to the dext and the engine | K→U ×2 | no |

**Critical path today: 7 crossings (2 of them shared), or 9 if step 8 goes through the kernel, plus the limiter.**

**Takeover, LIVE**

| # | Step | Crossing | Critical path |
|---|---|---|---|
| 1–2 | Same as today | K→U, U→K | yes (shared) |
| 3 | IOHIDInterface → tap ReportAvailable (today this goes to Apple's event driver, **M**) | K→U | yes |
| 4 | `gdx_step` on the tap queue (< 0.01 ms, **G·T5**) | none | yes |
| 5 | tap queue → pad queue, `submitInput` (routing and cost **G·T3**, histogram `hop`) | none, or U→K + K→U | yes |
| 6 | `_HandleReport` from a fixed-length buffer | U→K | yes: end |
| 7 | `AddReportToPool` re-add, once per frame (strategy B, non-LOCAL **R** IOHIDInterface.iig:129) | U→K | not for this frame, but it occupies the tap queue (G12) |

**Critical path after: 4 crossings (2 shared), or 6 if the hop goes through the kernel; no limiter.**
- T3's `hop` histogram decides the routing. A hop p50 in the tens of µs, similar to IOConnect, means a kernel round trip. T9 is the remedy.
- T3 also removes the `SetLength` crossing from the engine path.

### 4.5 Pool buffers and Open

- On entering COUNT (the first Open in this tap instance):
  1. Allocate 8 × 64 B `IOBufferMemoryDescriptor` (64 = MaxInputReportSize, **M**).
  2. Map each one once with `GetAddressRange` (LOCALONLY, **R** IOBufferMemoryDescriptor.iig:83).
  3. `AddReportToPool` each buffer.
  4. `Open`.
- In ReportAvailable, find the bytes:
  - If `report` is pointer-equal to one of our buffers, use its pre-mapped address (**G·T0**).
  - Otherwise use `OSDynamicCast(IOBufferMemoryDescriptor)` + GetAddressRange, and count `poolMiss`.
  - Otherwise use CreateMapping, and count `slowMap`.
- **After handling the frame** (after the post in LIVE), re-add our buffer with `AddReportToPool`. This is the baseline (strategy B).
  - Upstream IOHIDInterface removes a buffer from the pool for each report and never returns it (**R** upstream IOHIDInterface.cpp, via review).
  - Apple's event driver shows CreatedBuffers 3 over 31.5 M reports (**M**), which fits re-adding.
  - Kernel temporary buffers (`poolMiss`) are not re-added.
  - Strategy A (no re-add) runs only in the T0 probe, for 10 s, as a confirmation.
- **Open failure:**
  - The tap logs `GDHub: tap open failed 0x… try n` and retries from its timer every 500 ms. Start never fails because of it.
  - The engine and `receiver-check.sh` report the 0xFF58 device's seize-related state: its DebugState and IOUserClientCreator list (**M** both present in ioreg today).
  - Plan C applies only if Open fails while nothing has seized the device.
- **Success is gated on frames arriving at 940–970/s, never on Open's return code.** A second Open on an already-open interface returns success without installing the action (**R** upstream IOHIDInterface.cpp openGated, via review).

### 4.6 T9 option: shared Hot queue (only if G11 or G12 fails)

1. The root creates `Hot` with `IODispatchQueue::Create("GDHubHot", 0, 0, &q)` in Start, on its default queue. The priority must be 0 (**R** IODispatchQueue.iig:76-90).
2. The pad (in `handleStart`) and the tap (in `Start`) each get `Hot` from the registry (+1, no RPC). Each calls `SetDispatchQueue("Hot", q)` on itself before any `QUEUENAME(Hot)` method can run. Until then, methods fall back to the default queue (**R** IOService.iig:171-175).
3. **On Hot** runs every method that touches translator state or arbitration state:
   - `ReportAvailable`;
   - the tap timer (created on Hot);
   - `applyDesired` (the DispatchAsync target becomes Hot);
   - `submitInput`;
   - `postNeutralFrom`, which covers UC postReport, UC postNeutral, setForwarding switch neutrals and orphan neutrals;
   - hold and resync handling.
4. Kernel-invoked tap `Stop` and `SetPowerState` stay on the default queue. They `DispatchSync` onto Hot (**R** IODispatchQueue.iig:164) for their state changes, then continue. This is safe because Hot never calls out synchronously.
5. On Hot, the tap calls the pad through a plain C++ function, `GDHubPadPostLocal(pad, …)`, which calls the LOCALONLY `handleReport`.
6. New invariant: **Hot is the only caller of handleReport** and the only reader or writer of gdx state and the map pointer.
7. `Create` and `Terminate` run only on the root's default queue.
8. Check: 1000 inputPath toggles and 1000 mapping pushes at 50 Hz while frames flow. Pass: 0 stuck inputs (in the padlat CSV, the first 02E0 report after each switch neutral follows the new source's state), and no crash (same dext pid).

---

## 5. Translation and config protocol

### 5.1 One shared C translator

**Files:** `Dext/GDHubVirtualHID/Shared/GDHubXlate.{h,c}`.
- C99, no allocation, no DriverKit headers.
- Compiled into the dext (from T5), into a SwiftPM C target `GDHubXlate` (from T2) and into the Xcode app target (from T2).

**Double precision in Swift's operation order:**
- Swift computes in Double (**R** ControlMapping.swift:141-165; PadReportBuilders.swift:14-21).
- Doing the same in C gives byte-identical output for any learned range, including asymmetric ones. An integer precompute does not.

**Exactness rules:**
- Compile with `-ffp-contract=off` everywhere.
- Round half away from zero, matching Swift's `.rounded(.toNearestOrAwayFromZero)` (**R** PadReportBuilders.swift:14-21). The core may use C `round()`: math.h is in the SDK and libsystem_m exports `_round` (**M** DriverKit27.0.sdk/…/libsystem_m.tbd). v1 uses a hand-written version to keep the dext free of libm. The golden vectors decide in either case.
- Clamp and abs are written by hand.

**What is guaranteed:**
- Stateless output (`gdx_eval` + `gdx_build`) is identical in the engine and the dext, because it is the same C code.
- Posted sequences are identical only when the engine does not coalesce. The dext has no rate cap. The engine caps at 1 kHz and coalesces (**R** VirtualPadSink.swift:392-404, 448), so its hysteresis state can diverge (§10.1 sequence test).

**API:**
```c
int      gdx_validate(const uint8_t *blob, size_t len, const uint8_t *spec, size_t specLen, gdx_map *out); /* 0 = ok, else reason code */
void     gdx_reset(gdx_state *s);                                              /* next step posts full state */
int      gdx_eval(const gdx_map *m, const uint8_t *in, size_t len, gdx_pad *p); /* parse + map + snap; <0 = bad frame */
int      gdx_unchanged(const gdx_map *m, const gdx_pad *now, const gdx_pad *lastSent);  /* VirtualPadSink.unchanged */
void     gdx_build(const gdx_map *m, const gdx_pad *p, gdx_out *o);              /* placements -> report bytes */
uint32_t gdx_step(gdx_state *s, const gdx_map *m, const uint8_t *in, size_t len, gdx_out *o); /* mask of reports to post */
```

**v1 scope** is today's live semantics:
- 15 button rules, 4 axis rules, 2 triggers;
- deadband and hysteresis 0.002, with the end-stop rule (**R** VirtualPadSink.swift:537-560);
- per-report byte dedupe;
- xboxBT16 placements (0x01/16, 0x02/2).

Up to 2 OR'ed sources per output item are allowed, for the first remaps (§2.4). Echo suppression, overlay, and keyboard/pointer slots are reserved but not implemented. The dext has no rate cap.

### 5.2 Canonical behaviour decisions

Both are made before the parity tests can pass.
- **Paddles and SAX.** Today there is no explicit paddle/SAX → pad-button remap and no echo suppression (**R** PassthroughPadMapper.swift:5-37; PassthroughPadMapperTests.swift:94-116). Today's paddle behaviour relies on the onboard-profile echo, which changes between profiles (**R** host-identity-matrix.md:51,56). The blob applies `physMask` precedence to any control, as `ControlMapping.isActive` does (**R** ControlMapping.swift:105-133). Echo masks are reserved (`nEcho = 0`).
- **The "−1" quirk.** Without ranges, negative axis values come out one lower (**M** scratch axis.py). v1 reproduces this byte for byte. The live mapping has full int16 ranges, so the owner is not affected (**M**). A later fix is a deliberate change to the single core, with new golden vectors.

### 5.3 Mapping blob "GDHM" v1 (little-endian, ≤ 1024 B, read with memcpy, never cast)

**Header (64 B)**

| Off | Type | Field | v1 value |
|---|---|---|---|
| 0 | u32 | magic | bytes `G D H M` |
| 4 | u16 | version | 1 |
| 6 | u16 | length | total bytes |
| 8 | u32 | revision | engine-assigned, monotonic |
| 12 | u32 | specCRC32 | CRC32 of the pad spec it targets |
| 16 | u16 | sourceKind | 1 = Envision Pro report 0x06, 16 B |
| 18 | u16 | flags | 0 |
| 20 | u16 | silenceNeutralMs | **250** |
| 22 | u8 ×6 | nReports ≤ 4, nButtons ≤ 32, nAxes ≤ 4, nTriggers ≤ 2, nPlacements ≤ 32, nEcho = 0 | |
| 28 | u32 | reserved | 0 |
| 32 | f64 | deadband | 0.002 |
| 40 | f64 | hysteresis | 0.002 |
| 48 | f64 | stickActive | 0.5 |
| 56 | i32 | triggerActiveRaw | 100 |
| 60 | i32 | axisActiveRaw | 16000 |

**Sections** follow in this order, each 8-aligned:
- reports: `{u8 reportID, u8 length, u16 0}` × nReports
- buttons: `{u8 item, u8 kind, u8 arg, i8 sign, u16 physMask, u8 stickRef, u8 outSlot}` × nButtons (8 B each)
- axes: `{u8 stick, u8 component, u8 field, i8 sign, u8 hasRange, u8 pad[3], i32 min, i32 max}` × nAxes (16 B each)
- triggers: `{u8 item, u8 field (0 lt, 1 rt, 0xFF none), u16 0}` × nTriggers
- placements: `{u8 reportIndex, u8 item, u16 bitOffset, u8 bits, u8 encoding, u16 0}` × nPlacements
- echo: reserved

The maximum is about 670 B.

**Enumerations:**
- Items: 0 A, 1 B, 2 X, 3 Y, 4 LB, 5 RB, 6 VIEW, 7 MENU, 8 LS, 9 RS, 10 GUIDE, 11–14 DPAD U/R/D/L, 16 LX, 17 LY, 18 RX, 19 RY, 20 LT, 21 RT (**R** PassthroughPadMapper.swift:13-37).
- Kinds:
  - 0 NONE;
  - 1 BUTTON (arg = bit index);
  - 2 HAT (arg = direction; an even direction also accepts its adjacent diagonals);
  - 3 TRIGGER_GT;
  - 4 AXIS_GT;
  - 5 STICK_MAG.
  - A non-zero `physMask` overrides the kind (**R** ControlMapping.swift:105-133).
- Encodings (**R** PadReportBuilders.swift:44-68):
  - 1 AXIS16 = round((clamp(v)+1)·32767.5);
  - 2 AXIS16_NEG;
  - 3 TRIG10_U16 = round(clamp(t,0,1)·1023);
  - 4 HAT8;
  - 5 BIT.
- `outSlot`: 0 = pad. Other values are reserved.

**Validation** (`gdx_validate`, shared by the dext and the Swift encoder):
- magic, version and lengths are correct;
- kinds and encodings are known;
- each button item has 1 or 2 rules (OR'ed), and each axis and trigger item has exactly 1;
- placements fit their report;
- every `(reportID, length)` passes `GDHubSpecIsDeclaredInput` against the live pad spec (**R** GDHubSpec.cpp:154-163);
- `specCRC32` equals the live pad's spec CRC;
- `sourceKind` is 1.

Any failure returns `kIOReturnBadArgument` with a reason code, and the old table stays.

**Unsupported mappings.** `MapBlobEncoder` returns `.unsupported(reason)` when ControlMapping needs more than v1 can express. The engine then keeps the engine path (§6.6).

**Generated header.** A Swift test generates `Shared/GDHubDefaults.h` with:
- the factory GDHM (from `ControlMapping.default` + `xbox-bt16-02e0`);
- the default spec;
- 64 golden vectors `{frame[16], out01[16], out02[2]}`.

The test fails if the checked-in file differs.

### 5.4 Protocol additions (`GDHubProtocol.h`)

```c
#define GDHUB_PROTOCOL_VERSION    1          /* unchanged: hello stays an exact match (R GDHubProtocol.h:4) */
#define GDHUB_SPEC_VERSION        1          /* T3: spec validation checks this, not the protocol (R GDHubSpec.cpp:41) */
#define GDHUB_CAP_ROOT_PAD        (1u << 8)  /* T3; bits 0-2 stay the slot bits */
#define GDHUB_CAP_TAP             (1u << 9)  /* T4 */
#define GDHUB_CAP_XLATE           (1u << 10) /* T5 */
#define GDHUB_CAP_LIVE            (1u << 11) /* T7 */
#define GDHUB_SEL_SET_FORWARDING  9   /* scalars in: state, flags, argMs. out: appliedState, tapPresent, padSource, lastError */
#define GDHUB_SEL_SET_MAPPING     10  /* struct in: GDHM (<= 1024 B). scalar out: accepted revision, reason. T5 */
#define GDHUB_SEL_GET_STATUS2     11  /* struct out: GDHubStatus2 (<= 512 B) */
#define GDHUB_SEL_CREATE_DEVICE2  12  /* T7. struct in: spec. scalar out: adopted, padSource */
#define GDHUB_SEL_COUNT           13  /* was 9 */
#define GDHUB_FWD_INERT  0   /* tap attached, interface NOT opened: no per-frame code */
#define GDHUB_FWD_COUNT  1   /* T4: opened; counts frames, k2d; no translation */
#define GDHUB_FWD_SHADOW 2   /* T5: translates, parity sample, no posts */
#define GDHUB_FWD_LIVE   3   /* T7: translates and posts */
#define GDHUB_FWD_FLAG_STAMP_SOURCE_TIME (1u << 0)  /* pad timestamp = ReportAvailable timestamp; default off */
#define GDHUB_FWD_FLAG_DEV_PAUSE_TAP     (1u << 8)  /* every build, owner-only: tap ignores frames for argMs (<= 10000) */
#define GDHUB_FWD_FLAG_RELEASE_PAD       (1u << 9)  /* T7, owner-only: INERT, source UC, neutral, destroy the pad even if unowned */
```

- A state the dext does not support yet returns `kIOReturnUnsupported`. T3 accepts INERT only; T4 adds COUNT, T5 SHADOW and T7 LIVE.
- `CREATE_DEVICE2` exists because selector 1 has no scalar output (**R** GDHubVirtualHIDUserClient.cpp:340), and adding one would break old apps.
- Rule, written into the header: selectors are only ever added, each behind a capability bit. Blobs carry their own versions. `GDHUB_PROTOCOL_VERSION` changes only for a breaking change.
- `DextProtocolTests` checks every `#define` against the Swift mirror. Both are updated in the same commit.
- All new selectors are owner-only, behind the existing hello, team check and claim (**R** GDHubVirtualHIDUserClient.cpp:28-59, 76-88).

### 5.5 `GDHubStatus2` v1 (≤ 512 B, little-endian)

- **Identity:**
  - `u16 version, u16 size, u32 build, u64 instanceNonce`;
  - `u32 rootPid, tapPid` (getpid(): **R** IOLib.h:224-230).
- **State:**
  - `u8 tapPresent, opened, desiredState, appliedState, padSource, padLive, holdNeutral, powered, selfTest`;
  - `u32 lastPowerFlags`;
  - `u32 acceptedRevision, appliedRevision, padSpecCRC, acceptedSpecCRC`.
- **Counters (u64):** `framesIn, framesIgnored, framesBad, framesUnchanged, tapPosts, ucPosts, ucRejected, silenceNeutrals, stopNeutrals, switchNeutrals, powerNeutrals, holdNeutrals, poolMiss, slowMap, openFailures, adopts, orphanDestroys, syncViolations, parityChecks`.
- **Ages:** `u32 maxGapUs, lastFrameAgeMs, tapStartAgeMs`.
- **Parity sampler:** `u8 lastFrame[16], lastEval01[16], lastEval02[2]` (the stateless `gdx_eval` + `gdx_build` result for that frame), plus `u32 lastFrameRevision`.
- **Histograms stay inside the dext.** They reach the owner only through the meter log line (§9.1). That keeps them out of the ABI and out of the Swift mirror.

### 5.6 How mapping revisions are applied atomically

1. The engine's `MappingWatcher` sees a change (**R** MappingWatcher.swift). `MapBlobEncoder` emits GDHM with `revision + 1`, or `.unsupported(reason)`, in which case the engine path stays.
2. `setMapping` runs on the UC queue. It calls `gdx_validate` into a freshly allocated `gdx_map`; allocation is fine here because this is not the hot path. It refuses when `specCRC32` differs from the live pad's CRC.
3. The UC stores `{OSData(map), revision, specCRC}` in the registry, increments `mapGen` and pokes the tap with `DispatchAsync`. There is no synchronous call.
4. On the tap queue, at the next frame or apply: if `mapGen` changed, the tap calls `gdh_copy_map` (+1), swaps its private pointer and releases the old map. Only the tap queue reads that pointer, so the swap falls between two frames by construction.
5. The next frame is translated with the new map. Byte dedupe posts only if the output differs. Frames keep arriving at about 955/s even at rest (**R** envision-pro-receiver.md:33).
6. `appliedRevision` in status2 changes when the first frame is translated with the new map.
7. A tap that starts later loads the registry's map in Start.

### 5.7 Compatibility

| App | Dext | Result |
|---|---|---|
| old | new | Selectors 9–12 are never called. The tap stays INERT; this is today's behaviour. |
| new | old (build 17) | No cap bits. The engine path is used. |
| new | T3–T6 dext (no CAP_LIVE) | The engine path is used. COUNT or SHADOW follows `inputPath`. |
| new, in-app mode (engine crash-looped, **R** DriverManager.swift:191-209) | dext pinned LIVE | After hello, every DextClient that does not run TapSupervisor calls `setForwarding(INERT)` when CAP_TAP is set. Its posts then go out (DriverManagerModeTests case). |

---

## 6. Pad ownership, arbitration, watchdogs, fallback

### 6.1 States

**Tap state.** The registry holds `desiredState`; the tap applies it and reports `appliedState`.

| State | What runs |
|---|---|
| INERT | The tap is attached but the interface is **not opened**. Only the 50 ms timer runs, and it compares two atomic words. No per-frame code. **Every dext launch starts here.** |
| COUNT | Opened. Counts frames, k2d histogram, maxGap, pool re-add. No translation. |
| SHADOW | Translates and samples parity. Does not post. |
| LIVE | Translates and posts with `pad->submitInput(TAP, …)`. |

**Pad source** (`padSource`): NONE (no pad), UC or TAP. It is TAP exactly when the state is LIVE. Only the UC queue writes it (setForwarding, create, destroy), plus the root at orphan expiry and DestroyPad.

### 6.2 Arbitration (the pad is the only arbiter)

- The pad queue is the only caller of `handleReport`. For every submission, the pad compares the submitter's source with `padSource` **on its own queue**. That check is authoritative.
- Source `UC`: user-client posts go out. TAP submissions are dropped and counted.
- Source `TAP`:
  - UC `postReport` returns `kIOReturnBusy` and counts `ucRejected`.
  - UC `postNeutral` posts neutral and sets `holdNeutral = 1` (`holdNeutrals++`). While the hold is set, the tap translates but does not submit.
  - The hold clears on tap `SetPowerState(On)`, on a new tap Start, or on `setForwarding(LIVE)`. This makes the engine's willSleep neutral a real guard.
- **Switch to LIVE** (UC queue):
  1. Check the preconditions: CAP_LIVE, `selfTest == pass`, `acceptedSpecCRC == padSpecCRC`, `tapPresent`, `appliedState == SHADOW`. Otherwise return an error.
  2. Store `padSource = TAP`.
  3. `pad->postNeutralFrom(SWITCH)`.
  4. Store `desiredState = LIVE` and `holdNeutral = 0`.
  5. Poke the tap. On its queue the tap runs `gdx_reset`, so its next frame posts the full state.
- **Switch from LIVE to any other state** (UC queue):
  1. Store `padSource = UC`.
  2. `pad->postNeutralFrom(SWITCH)`.
  3. Store `desiredState = X`.
  4. Poke the tap.
  - It never waits on the tap.
- **Invariant:** after a switch neutral, nothing from the old source is posted. Any submission still queued on the pad queue is checked after the atomic store and dropped.
- **Engine side:** whenever `padSource` changes from TAP to UC, the sink calls `resetDeliveryState()` (made internal; **R** VirtualPadSink.swift:331-340). The next frame then posts the full state, so an input held across the switch is not lost.
- The test pattern needs source UC (INERT, COUNT or SHADOW).

### 6.3 Ownership

- The root owns the pad.
- **Pinned** means `desiredState == LIVE` when the UC stops. Only the pad slot can be pinned.
- **UC Stop:**
  - Pinned: the pad stays, the tap keeps posting, the claim is released, and the 30 s **orphan timer** starts.
  - Not pinned: `padSource = UC`, neutral, INERT, `DestroyPad`. This is G5 exactly as today.
  - Keyboard and pointer slots (T11) are never pinned and are always destroyed.
- **`createDevice2` (T7):**
  - **Adopt:** if a pad exists with a byte-identical spec (CRC, length and memcmp) and has no owner, the call returns `adopted = 1`. The caller now owns the slot, and the orphan timer is cancelled.
  - **Otherwise:** an existing pad with another spec is switched to UC, neutralised, set INERT and destroyed; then comes the 300 ms gap (**R** driverkit-dext-design.md §3.11) and the create.
  - A new pad starts with `padSource = UC` and `desiredState = INERT`.
  - A different spec CRC clears the accepted GDHM.
- **`destroyDevice`** always runs: `padSource = UC` → neutral → INERT → DestroyPad. Pinning applies only to UC Stop, never to an explicit destroy. This covers the sink's identity switch and unpublish (**R** VirtualPadSink.swift:238-262).
- **Orphan timer** (root queue): 30 s after a pinned UC Stop with no adopting owner, it runs `padSource = UC` → neutral → INERT → DestroyPad, and counts `orphanDestroys`.
  - It covers an unclean logout and a dead engine.
  - A launchd restart of the engine after about 2 s (**R** plist:21-24) is well inside 30 s (**G·T7**).
  - T12 AutoArm pads are exempt.
- **DestroyPad order:** `padSource = NONE` (atomic), clear the registry pad pointer, then Terminate. The pad's Stop sets `stopping` first, and every later submission returns NotReady.
- **No orphans:**

| Path | Result |
|---|---|
| Clean engine exit (SIGTERM, logout, `engine-agent.sh uninstall`) | `setForwarding(INERT)`, then `destroyDevice` |
| Uninstall after a crash | `engine-agent.sh uninstall` runs `GDHub --engine --engine-foreground --release-pad` after bootout. It sends hello, then `setForwarding(INERT, RELEASE_PAD)`, then exits. The `--engine-foreground` flag is required (**R** EngineMain.swift:18-22). |
| devTerminate | Destroys the pad first |
| Anything else | Orphan timer, 30 s |

- The single-owner claim, the team check and the InertDext GUI rule are unchanged (**R** DextControlling.swift:25-49).

### 6.4 Watchdog semantics (per slot)

| Guard | Pad slot, source UC | Pad slot, source TAP | Keyboard/pointer slots (T11) |
|---|---|---|---|
| UC heartbeat watchdog (250 ms period, 2 s timeout, **R** GDHubInternal.h:9-10) | Neutral (G5) | No effect; counted | Neutral, always |
| Tap silence (50 ms tick on the tap queue) | — | No frame for 250 ms (`silenceNeutralMs`): neutral + `gdx_reset`. The next frame reposts the full state. The longest measured gap is about 9 ms (**M**). | — |
| Tap Stop (3A08 disappears) | — | Order: set `stopping` → Close (**R** IOHIDInterface.iig:168) → neutral (if source is TAP) → cancel the timer → the cancel handler runs `Stop(SUPERDISPATCH)` (today's crash fix, **R** GDHubVirtualHIDUserClient.cpp:442-454). ReportAvailable and the timer return at once when `stopping` is set. The pad stays. | — |
| Tap `SetPowerState` (rule from the header: make the driver safe, then pass the call to super, **R** IOService.iig:253-262) | — | **Off:** `powered = 0`; neutral if TAP; `return SetPowerState(powerFlags, SUPERDISPATCH)`. **On:** `powered = 1`, clear `holdNeutral`, `gdx_reset`, super. **Low or LPW** (**R** IOService.h:58-61): log, keep processing frames, super. Frames that arrive while `powered == 0` count as `framesIgnored`. | — |
| Orphan timer (30 s) | — | Destroys an unowned pinned pad | — |
| Presence (2 s, engine ControllerPresence) | UI only | UI only | — |

### 6.5 Crash fuse and crash-loop defence

1. **In-dext fuse.** `desiredState` lives only in process memory and starts INERT. INERT does not open the interface, so no per-frame code runs. Only an owner's `setForwarding` can arm COUNT or higher.
2. **Self-test.** The first move to SHADOW in a process runs the 64 golden vectors through `gdx_step`. A mismatch sets `selfTest = fail` for the life of the process, and SHADOW and LIVE are refused.
3. **Engine breaker.** 3 or more `instanceNonce` changes within 120 s mean the engine stops arming: the tap stays INERT and the engine stays LEGACY. The engine writes `tapBreakerTrippedAt`, logs `breaker: tripped`, and clears it only when the owner re-selects "Input path: Driver" in the Driver menu.
4. **Fallback limiter.** 3 fallbacks (§6.6) within 10 min have the same effect as the breaker.
5. **What the fuse does not cover.** Tap Start, Stop, SetPowerState and the timer run in every state. Pool handling runs from COUNT up. A crash there kills the pad (one process) and comes back at every 3A08 enumeration.
   - **Loop-breaker:** switch the controller off (3A09 never matches, §3.2). Then roll back (§7.2) with the controller still off. Then power-cycle.
   - macOS may reboot the Mac when a driver crashes too often (**R** IOKitKeys.h:134-136). T0.3 records whether and when that happens.
6. **T12 AutoArm guard:** see §11 T12.

### 6.6 Engine fallback: automatic and forced

**Automatic.** The engine's `TapSupervisor` runs a 100 ms tick whenever `inputPath` is `count`, `shadow` or `driver`.

| Trigger | Condition | Falls back to |
|---|---|---|
| F1 stall | COUNT, SHADOW or LIVE: the engine reader counted ≥ 50 frames in the last 200 ms, and `status2.framesIn` did not increase | COUNT |
| F2 tap absent | The engine's 3A08 0xFF58 device is matched and `tapPresent == 0` for longer than the grace period: max(1 s, 3 × the p99 of interfaceUp→tapPresent measured in T4) | COUNT |
| F3 dext lost | Connection lost or nonce changed. After reconnect: LEGACY, and the breaker counts. | INERT |
| F4 errors | A `setMapping` or `setForwarding` error, or `selfTest = fail` | INERT |
| F5 parity | 3 or more stateless parity mismatches in 10 s (the 4 Hz sampler re-runs `gdx_eval`/`gdx_build` on `lastFrame`) | INERT |
| F6 output stall | LIVE only. The engine's own `gdx_step`, the same C core fed by its reader, would have posted ≥ 3 reports in 200 ms and `status2.tapPosts` did not increase. Or `appliedState ≠ desiredState` for more than 300 ms. Or `padSource ≠ TAP`. Or `framesIgnored` rises while `powered == 1`. | COUNT |

- **Action:** call `setForwarding`. This flips `padSource` to UC at once (§6.2). The engine calls `resetDeliveryState()`, posts again and logs `fallback: <reason>`.
- **Return to LIVE:** the trigger has been clear for 1 s, the breaker and the limiter have not tripped, and SHADOW then runs for 2 s with at least 100 frames and 0 mismatches. Then LIVE.
- **Engine startup in LIVE** (glitch-free restart): if status2 shows `padSource == TAP`, `appliedState == LIVE`, `selfTest == pass`, and the accepted revision has the same CRC as the engine's encoded GDHM, the engine stays LIVE without SHADOW. `createDevice2` returns `adopted = 1`, so the sink skips its post-create `postNeutral` (**R** VirtualPadSink.swift:312).
- **Seize:** when both the engine reader and the tap see nothing while 3A08 is present, the status says `silent: asleep or if3 seized by <IOUserClientCreator names on the 0xFF58 device>`. There is no fallback loop, because the engine path is starved too (A22). GDHub itself never seizes interface 3.

**Forced:**
- `defaults write com.interlinked.gdhub inputPath -string engine` → `setForwarding(INERT)` and engine posting within about 1 s (the engine polls the key once per second, A20).
  - Values: `engine` (default until T8), `count` (T4+), `shadow` (T5+), `driver` (T7+; on a dext without CAP_LIVE it runs as `shadow` and logs why).
  - Precedent: the engine already reads `vpadMaxRateHz` from this domain (**R** VirtualPadSink.swift:125-133).
- The Driver menu "Input path: App / Driver" writes the key.
- There is no launch argument. The agent's arguments are fixed in its plist (**R** plist:7-11).
- **Drill:** `defaults write com.interlinked.gdhub tapDrill -string pause5`. The engine sends `setForwarding(LIVE, DEV_PAUSE_TAP, 5000)` once and deletes the key. The flag works in every build.

---

## 7. Lifecycle

"LIVE" means `inputPath = driver` and armed. "LEGACY" covers INERT, COUNT and SHADOW.

| Event | LIVE | LEGACY | Proven in |
|---|---|---|---|
| Boot, before login | The root starts with no pad. At 3A08 enumeration the tap attaches INERT. No pad until the engine starts (unless T12). | Same | T4 |
| Login, engine starts | hello → status2 → `createDevice2` (adopt or create) → setMapping → SHADOW 2 s → LIVE. Or stay LIVE at once (§6.6 startup rule). | hello → create → engine posts; tap per `inputPath` | T6, T7 |
| Controller off (3A08→3A09) | Tap Stop (§6.4 order). Neutral; the pad stays (dext design failure table: "Controller switched off → pad stays, reports neutral"). 3A09 stays with Apple. Engine presence → receiverIdle. | Engine neutral (today) | T7 |
| Controller on (3A09→3A08) | New tap Start: `gdh_register_tap` reads `desiredState` in the same critical section; LIVE → Open, `gdx_reset`, `holdNeutral` cleared. Same pad registry ID. | Tap per `desiredState` | T7 |
| Controller sleep timer | If the stream only stops: silence neutral at 250 ms. If it re-enumerates: as controller off (A12). | Engine neutral after 2 s | T0.1, T7 |
| Mac sleep/wake | Engine willSleep → `postNeutral` → neutral + `holdNeutral`. Tap `SetPowerState(Off)` → neutral, frames ignored, super. On → hold cleared, `gdx_reset`, super. Engine didWake → `setForwarding(LIVE)`. PowerObserver waits at most 1 s for the dext call (§8.2). | Today | T7 |
| Logout, clean | The agent gets SIGTERM (A21) → INERT + destroyDevice → pad removed (G5) | Today | T6, T7 |
| Logout, unclean (crash during the 2 s throttle, or SIGKILL after ExitTimeOut 5 s, **R** plist:23-26) | The pinned pad stays at most 30 s, then the orphan timer destroys it | UC Stop destroys it | T7 |
| Fast user switch | User A's agent keeps running (A21; LimitLoadToSessionType Aqua, **R** plist:27-28). The pad stays. User B's hello gets `kIOReturnExclusiveAccess` (**R** GDHubVirtualHIDUserClient.cpp:76-88). | Same | T6 |
| Engine crash (SIGKILL) | The pinned pad stays and the tap keeps posting. launchd restarts the engine about 2 s later (**R** plist:21-24). The new engine adopts with no neutral and stays LIVE. | UC Stop destroys the pad (G5) | T7 |
| Engine crash loop → GUI takes over in-app | The GUI's DextClient (not supervised) sends `setForwarding(INERT)` after hello; GUI posts go out | Same | T7 |
| Engine hang (SIGSTOP) | Input unaffected. The watchdog has no effect on the TAP pad; keyboard and pointer go neutral. | Neutral after 2 s (G5) | T3, T7 |
| GUI quit | No effect. The GUI is not in the data path and holds InertDext in engine mode. | Same | T6 |
| Identity switch or unpublish in LIVE | destroyDevice: INERT → UC → neutral → destroy. The new pad starts UC/INERT. The supervisor re-arms through SHADOW if GDHM can express the new identity. | Today | T7 |
| Dext upgrade | §7.1 U1–U7 | Same | T3, T4 |
| Dext crash | Root, UC, pad and tap all die (one process); games see a disconnect. Relaunch and re-match are A9. If relaunched: tap INERT, engine F3, LEGACY, re-arm unless the breaker tripped. If not: no pad until reboot. A crash loop at enumeration: switch the controller off first (§6.5). | Same | T0.3, T7 |
| ShadowUSB auto-forward | Interfaces disappear, as on unlink. The engine labels UsbExclusiveOwner (**R** host-identity-matrix.md:62). | Same | — |
| User-space seize of 0xFF58 | A tap Open fails and retries; frames starve; the status labels it (§6.6) | Same | T6 |

### 7.1 Upgrade procedure (every dext-changing phase)

The build script does not replace the dext. The GUI submits the replacement when it launches (**R** build-xcode.sh:81; DriverManager.swift:521-545). The engine mode ignores `--dev-terminate-driver` (**R** DriverManager.swift:126-127), so the swap runs with the GUI in in-app mode.

- **U1** `scripts/engine-agent.sh uninstall`. The engine exits cleanly (INERT + destroyDevice). The GUI starts in in-app mode from its next launch (**R** engine-agent.sh:7, 97-100).
- **U2** `osascript -e 'quit app "GDHub"'`
- **U3** `scripts/build-xcode.sh --release --no-open`. This bumps the build to N+1 (**R** :24) and installs the app.
- **U4** `open /Applications/GDHub.app --args --dev-terminate-driver`. The in-app GUI connects to N and calls devTerminate after 1 s, then submits the replacement (**R** DriverManager.swift:212-223, 532-543). In the dext, devTerminate destroys the pad, then the tap (Close + Terminate), then the root.
- **U5** Wait until both of these match:
  - `systemextensionsctl list | grep -E 'gdhub\.VirtualHID \(0\.1\.0/<N+1>\).*activated enabled'`
  - `/usr/bin/log show --last 3m --predicate 'eventMessage CONTAINS "GDHub: root start build <N+1>"'` (log text **R** GDHubVirtualHID.cpp:33)

  If they do not match within 2 min, reboot (common rules).
- **U6** Power-cycle (PC, §10.2) so the new tap attaches, then run L1. Record whether the tap attached before the power cycle.
- **U7** `osascript -e 'quit app "GDHub"'`; `scripts/engine-agent.sh install`; `open /Applications/GDHub.app`.

### 7.2 Rollback procedure (L9)

- **RB1** `scripts/engine-agent.sh uninstall`
- **RB2** `osascript -e 'quit app "GDHub"'`
- **RB3** `rm -rf /Applications/GDHub.app && ditto ~/GDHub-rollback/<phase>-pre/GDHub.app /Applications/GDHub.app`. `rm -rf` does not uninstall the dext (**R** driverkit-dext-design.md:1322-1323).
- **RB4** `open /Applications/GDHub.app --args --dev-terminate-driver`. DriverManager answers `.replace` whatever the versions (**R** DriverManager.swift:484-490), and it replaces whenever the embedded build differs from the enabled one (**R** :521-545). That a **lower** version is accepted is A23, proven in T0.4.
- **RB5** Check both:
  - `/usr/bin/log show --last 3m --predicate 'subsystem == "com.interlinked.gdhub" AND category == "vhid"' | grep 'replacing dext'` shows `N -> N-1`;
  - `systemextensionsctl list` shows N-1 as `activated enabled`.
- **RB6** PC, then L1 shows the previous phase's binding.
- **RB7** If that phase used the agent: quit the GUI, then `scripts/engine-agent.sh install`.
- If a tap crash loop is the reason for rolling back: switch the controller off before RB1 and keep it off until RB6.

---

## 8. What changes, file by file

### 8.1 Dext

| File | Change | Phase |
|---|---|---|
| `project.yml` | T0: probe target (§3.3) + app dependency; removed in T0.5. T2: dext `excludes: [Shared/**]`; app sources, bridging header, cflags. T3: `GDHubPadProperties` to root level. T4: OneProcess on the root, tap personality (IOProbeScore 1000), transport.hid, `GDHUB_TAP_DECLINE=0` define. T5: excludes removed; `-ffp-contract=off` on the dext. | T0–T5 |
| `GDHubProtocol.h` | §5.4 defines, `GDHubStatus2`, GDHM constants, the additive rule | T3, T4, T5, T7 |
| `GDHubRegistry.{h,cpp}` (new) | §4.3: private lock, atomics, +1 accessors, `gdh_register_tap` | T3 (tap fields T4, arbitration words T7) |
| `GDHubVirtualHID.{iig,cpp}` | `CreatePad`/`DestroyPad` (DestroyPad order §6.3); nonce; pid log; Stop terminates the pad; devTerminate order pad → tap → root; orphan timer (T7) | T3, T4, T7 |
| `GDHubVirtualHIDUserClient.{iig,cpp}` | createDevice through the root; one fixed-length `IOBufferMemoryDescriptor` per input-table entry (SetLength once); selectors 9–12; GDHM validation; arbitration writes and pokes; watchdog per slot; adopt; pinning; `GDH_SYNC` | T3, T5, T7 |
| `GDHubVirtualPad.{iig,cpp}` | Provider = root; spec from the registry; `submitInput` and `postNeutralFrom` replace `postReport`; source check; `stopping`; hop/hr stamps; output delivery to the owner UC through the registry | T3, T7 |
| `GDHubReceiverTap.{iig,cpp}` (new) | T4: Start/Stop/SetPowerState, register, INERT/COUNT, pool B, Open retry, timer, counters, pid log, `GDHUB_TAP_DECLINE`. T5: SHADOW, map handoff, self-test, parity sampler, histograms, meter line. T7: LIVE, silence, hold, neutral paths, pause flag. | T4, T5, T7 |
| `GDHubInternal.h` | `GDH_SYNC` (every build); `GDHUB_TAP_DECLINE` (a build define, not DEBUG-gated, like `GDHUB_DEV_TERMINATE`, **R** :11-13) | T3, T4 |
| `GDHubSpec.cpp` | Check `GDHUB_SPEC_VERSION` (**R** :41); CRC32 helper | T3 |
| `Shared/GDHubXlate.{h,c}`, `Shared/GDHubDefaults.h` (new) | §5.1, §5.3 | T2 |
| `Dext/GDHubTapProbe/*` (new, then deleted) | Probe root + probe tap | T0 |

### 8.2 Engine (Swift)

| File | Change | Phase |
|---|---|---|
| `Output/VirtualPad/VirtualPadSink.swift` | `lastPostAt = tS` (T1). Uses the C core through `XlateCore` unless `xlateCore = swift` (T2). T7: posting gate off while `padSource == TAP`; `resetDeliveryState()` made internal and called on TAP→UC; post-create `postNeutral` skipped when adopted. | T1, T2, T7 |
| `Output/VirtualPad/XlateCore.swift` (new) | Swift wrapper over GDHubXlate; also the engine's F6 shadow step | T2, T7 |
| `Mapping/MapBlobEncoder.swift` (new) | ControlMapping + PadIdentity → GDHM, or `.unsupported(reason)` | T2, T6 |
| `Output/VirtualHID/DextProtocol.swift`, `DextClient.swift`, `DextControlling.swift` | Mirror. `matching()` adds `IOUserClass = GDHubVirtualHID` (T3). `setForwarding`/`setMapping`/`getStatus2`/`createDevice2`, caps. `supervised` flag: an unsupervised client sends INERT after hello when CAP_TAP is set (T4). | T3–T7 |
| `Engine/EngineCore.swift` | Control-plane sequence (§7 login row); pushes GDHM on every mapping change | T5, T7 |
| `Engine/TapSupervisor.swift` (new) | 100 ms tick, F1–F6, breaker, fallback limiter, re-arm, startup stay-LIVE, `inputPath` and `tapDrill` polling, interfaceUp→tapPresent timing | T4 (timing), T6, T7 |
| `Engine/EngineService.swift` | Meter line gains `dext: state framesIn tapPosts ucRejected parity`; T7 clean-exit order (INERT before destroyDevice) | T5, T7 |
| `Engine/EngineOptions.swift`, `EngineMain.swift` | `--release-pad` (only with `--engine-foreground`) | T7 |
| `Engine/PowerObserver.swift` | `willSleep`: `vhidQueue.async` + semaphore wait of at most 1 s before `IOAllowPowerChange` (today `vhidQueue.sync`, **R** :49-52). didWake → `setForwarding(LIVE)` when LIVE is wanted. | T7 |
| `Engine/GamepadHIDReader.swift`, `ControllerPresence.swift`, `MappingWatcher.swift` | Unchanged | — |
| `PassthroughPadMapper.swift`, `PadReportBuilders.swift` | Unchanged; test oracle | — |

Control-plane selectors stay on `vhidQueue`, because DextClient is confined to it (**R** DextClient.swift:6). With the dext no longer waiting on the tap (§4.2), a call can block only on the pad queue, exactly as today's postReport.

### 8.3 GUI

- `Output/VirtualHID/ProbeExtensionRequester.swift` (new in T0, deleted in T0.5): handles `--dev-probe-dext activate|deactivate`.
  - It sends activation and deactivation requests for `com.interlinked.gdhub.TapProbe` through its **own** delegate object, answers `.replace` and logs `probe: …`.
  - It never touches DriverManager state. DriverManager's delegate ignores the request identifier (**R** DriverManager.swift:492-519).
- `DriverManager.swift`: wires the probe flag (T0). In-app mode builds its DextClient with `supervised = false` (T4).
- `UI/DriverCommands.swift` (T6):
  - "Input path: App / Driver" writes `inputPath`.
  - It shows `Input path: App (mapping needs GDHM v2: <reason>)` when the encoder refuses a mapping.
  - It shows whether `GDHubReceiverTap` exists, through an IORegistry name lookup with no user client, so InertDext holds.
- `Xcode/App/GDHub-Bridging-Header.h` (new, T2): includes `GDHubXlate.h` for the Xcode app target. Swift uses `#if canImport(GDHubXlate)` (**G·T2**).
- Live view, input monitor, learn mode, event log and battery strip are unchanged. Interface 3's IOHIDDevice stays (**M**).

### 8.4 Package and tests

- `Package.swift` (T2): `.target(name: "GDHubXlate", path: "Dext/GDHubVirtualHID/Shared", publicHeadersPath: ".", cSettings: [.unsafeFlags(["-ffp-contract=off"])])`. The GDHub target depends on it.
- New tests: §10.1.

### 8.5 Scripts

| Script | Change | Phase |
|---|---|---|
| `scripts/receiver-check.sh` (new) | For the node `SCUF Envision Pro Wireless USB Receiver V2` (**M** ioreg), using `ioreg -rw0 -l -n …` (registry names only, the vhid-check convention, **R** vhid-check.sh:3). It prints: interfaces 0–4 with their bound children; interface 3's IOHIDInterface child (GDHubReceiverTap, GDHubProbeTap, AppleUserHIDEventDriver or none); interface 3's DebugState (Created/ReleasedBuffers, ReportAvailableCalls, and the rate from two samples 5 s apart); the 0xFF58 device's DebugState and `IOUserClientCreator` list; the interface 4 child (positive control); and the 3A09 device if present. | T0 |
| `scripts/tools/personality-scan.py` (new) | Lists every kext/dext personality with VendorID/idVendor 6940: system kexts and their plugins, /System/Library/DriverExtensions, /Library/SystemExtensions, /Library/Extensions. Run with `python3 -I`. | T0 |
| `scripts/build-xcode.sh` | `--probe`, `--probe-downgrade`, `PROBE_CRASH` (§3.6, T0; removed T0.5). transport.hid in `need`, plus the plutil assertions (T4). | T0, T4 |
| `scripts/dext-log.sh` | Adds the probe process (T0) and `--meter` (the `GDHub: tap meter` lines, T5) | T0, T5 |
| `scripts/engine-agent.sh` | `uninstall` runs `GDHub --engine --engine-foreground --release-pad` after bootout | T7 |
| `scripts/vhid-check.sh` | The pad's parent must be GDHubVirtualHID | T3 |

L5 uses the existing tools `scuf-envision/tools/gcprobe` (GameController list, **R** gcprobe.swift:4-5) and `scuf-envision/tools/sdlmatch` (SDL matching emulation, **R** sdlmatch.swift:1). No new list tool is written.

### 8.6 Docs

- `driverkit-dext-design.md`: provider rule and D5 lookup (T3); G5 amendment and §4.2 note (T7, T5).
- `output-layer-plan.md`: decision 5 note (T4); §3.1 GDHM-expressible note (T6).
- `engine-agent-plan.md`: R14 exception (T6); E2–E4 retargeting (T7).
- `other-controller-drivers.md`: §3 pointer (with this plan); ranks 6–7 superseded (T10).
- `envision-pro-receiver.md`: T0 facts.
- `HANDOFF.md`: T8.

---

## 9. Measurement

### 9.1 In-dext stamps (dext only)

All stamps are `mach_absolute_time()` (**R** IOLib.h:177-188) unless noted.

| Stamp | Where |
|---|---|
| t0 | ReportAvailable `timestamp` argument (mach units: A7) |
| t1 | Tap entry |
| t2 | After `gdx_step` |
| tPin | Pad `submitInput` entry |
| tPout | After `handleReport` returns |
| t3 | Tap, after `submitInput` returns |
| t4 | Tap, after `AddReportToPool` returns |

Histograms, each with 55 buckets (40 × 25 µs, 10 × 100 µs, then 2/3/5/10/20 ms), an overflow, max and count, in 10 s windows:

| Histogram | Formula |
|---|---|
| `k2d` | t1−t0 |
| `xlate` | t2−t1 |
| `hop` | tPin−t2. For UC posts, from T3: tPin minus the UC stamp before the call. |
| `hr` | tPout−tPin |
| `addPool` | t4−t3 |
| `total` | t3−t0 |
| `occ` (tap-queue occupancy) | t4−t1 |

Nothing is logged per report (**R** design rule §3.12). Every 10 s while frames flow, the dext writes one `.notice` line:

`GDHub: tap meter build=N state=S frames=… posts=… k2d p50/p99 … xlate … hop … hr … addPool … total p50/p99/max … occ p99 … poolMiss … ignored … unchanged …`

### 9.2 How the numbers are read

- **Dext:**
  ```sh
  /usr/bin/log show --start '<start>' --end '<end>' --info --predicate 'eventMessage BEGINSWITH "GDHub: tap meter"'
  ```
  or `scripts/dext-log.sh --meter`.
- **Engine:** `scripts/engine-agent.sh latency` (**R** engine-agent.sh:108-110). It shows `cb(all frames) n=… NNNHz` (**R** CallbackStat.swift:25) and, from T5, the `dext:` fields.
- **End to end:** padlat (**R** scuf-envision/tools/latency/README.md). Run `./padlat 20 /abs/path/run-<path>.csv` while doing its gesture script. Named metrics: `digital->virt (kernel ts)` and `stick onset->virt (kernel ts)` (**R** padlat.swift:122, 141). The CSV carries raw report bytes per row (**R** padlat.swift:189-191). The pad timestamp stays `mach_absolute_time()` at post by default (`STAMP_SOURCE_TIME` off), so padlat stays comparable before and after.
- **Game Mode confirmation.** gamepolicyd logs mostly `Game mode status is now on|paused|off` (**M**: 76 × paused, 63 × on, 13 × off, 26 × enabled, 28 × disabled in 24 h).
  1. Note the session start and end: `date '+%Y-%m-%d %H:%M:%S'`.
  2. Before the session:
     ```sh
     /usr/bin/log show --start '<start − 12 h>' --end '<start>' --style compact --predicate 'process == "gamepolicyd"' \
       | grep -E 'Game mode (enabled|disabled)|status is now (on|paused|off)' | tail -1
     ```
     The last line must be `status is now on` or `Game mode enabled`.
  3. During the session:
     ```sh
     /usr/bin/log show --start '<start>' --end '<end>' --style compact --predicate 'process == "gamepolicyd"' \
       | grep -E 'status is now (paused|off)|Game mode disabled'
     ```
     This must print nothing. Otherwise drop every 10 s window that overlaps a paused or off interval.

### 9.3 Gate (T8)

**Conditions:**
- Game Mode confirmed (§9.2);
- 3 sessions × 10 min of real play;
- 10 s windows with at least 30 changed frames;
- a same-session padlat A/B: 3 × 20 s with `inputPath = driver`, then 3 × 20 s with `engine`.

| # | Criterion | Pass |
|---|---|---|
| G1 | Dext `total`, median of the window p50s | ≤ 0.40 ms |
| G2 | Dext `total`, median of the window p99s | ≤ 1.5 ms |
| G3 | Worst `total` max | < 20 ms |
| G4a | padlat `digital->virt (kernel ts)` p50, driver | ≤ 0.5 ms |
| G4b | Same-session A/B, driver against engine (both after T1 and T3): `digital->virt (kernel ts)` p50 and `stick onset->virt (kernel ts)` p50 | Driver at least 0.2 ms lower on **both**. The T0.1 and T1 baselines are reported for context only. |
| G5g | tapPosts / changed frames (meter) | ≥ 98 % |
| G6 | Parity mismatches; framesBad | 0; 0 |
| G7 | poolMiss + slowMap | < 0.1 % of frames |
| G8 | ucRejected outside drills | 0 |
| G9 | Neutral after the stream stops. Controller switched off during padlat: time from the last `phys` CSV row to the first all-neutral `virt` 0x01 row. | ≤ 300 ms |
| G10 | `tapDrill pause5`: from the dext log line `tap pause start` to the engine log `fallback: tap stalled` | ≤ 300 ms |
| G11 | `hop` p50 | ≤ 50 µs, else T9 |
| G12 | `occ` p99 (frame interval is 1 ms) | ≤ 0.5 ms, else T9 |
| PC1 | Positive control: engine `cb(all frames)` rate | 940–970 Hz |
| PC2 | Positive control: engine `total` p50 in the A/B | within ±0.15 ms of the T1 baseline |
| PC3 | Pad count | 1 (vhid-check) |

**Play test:**
- all 15 controls;
- stick corners at 0 and 65535;
- triggers 0–1023;
- Guide;
- controller sleep → neutral, then wake;
- power off/on → same pad registry ID;
- hold RT at full while running `kill -9 $(pgrep -f 'GDHub --engine$')` twice. The padlat CSV must have no 02E0 row with RT = 0 during the hold, and status2 `switchNeutrals` must be unchanged.
- `engine-agent.sh uninstall` → pad removed;
- Mac sleep/wake ×2;
- GUI learn running at the same time;
- the interface 4 battery strip works;
- receiver audio works.

**Result table** (filled in at T8):

| Session | Game Mode | p50 total | p99 total | max | digital p50 (drv/eng) | stick p50 (drv/eng) | posts % | parity | Result |
|---|---|---|---|---|---|---|---|---|---|

---

## 10. Test plan

### 10.1 Unit tests (`swift test`)

- **`GDHubXlateParityTests`.** The Swift oracle is `GamepadFrame.parse` (**R** EnvisionProReport.swift:31-49) → PassthroughPadMapper → snapped/unchanged → PadReportBuilders. It runs against `gdx_*` on **raw 16-byte reports** and must be byte-identical. Cases:
  - every int16 value per axis × {full range, no range, asymmetric learned ranges (−28000/31000, −32768/20000, −100/100, −1/1)} × sign ±1;
  - every trigger raw value 0–1023;
  - hat 0–15 × D-pad rules, including the diagonals;
  - every button bit, and `physMask` precedence on every control (1- and 2-bit masks);
  - 2 OR'ed sources per item;
  - wrong report IDs and lengths: the C core counts them as framesBad, and `parse` returns nil;
  - hysteresis and end-stop sequences;
  - 10⁶ seeded random frames × {factory mapping, live-file fixture, 3 random learned mappings};
  - the −1 quirk reproduced exactly.
- **`GDHubXlateSequenceTests`.** The Swift sink on `ManualScheduler` (**R** VirtualPadSinkTests.swift:8), fed with frames spaced at least one cap interval apart, against `gdx_step`. 10⁵ random-walk frames; the posted bytes must be identical.
- **`GoldenVectorTests`.** Regenerates the `GDHubDefaults.h` content (factory GDHM, default spec, 64 vectors) and fails on drift. It also runs the 64 vectors through the SwiftPM C target. The **same** 64 vectors run inside the dext as the self-test (§6.5), which proves on the device that the dext's C translation equals the Swift one.
- **`MapBlobEncoderTests`.** Round trip; each validator rejection (§5.3); `specCRC32` mismatch; `.unsupported` for an echo/layer mapping.
- **`DextProtocolTests`.** Every new define, `GDHUB_SPEC_VERSION`, the status2 version and size, the GDHM magic, and that `DextClient.matching()` contains `IOUserClass = GDHubVirtualHID`.
- **`TapSupervisorTests`** (fake status source and clock):
  - F1–F6 each fall back within 2 ticks;
  - re-arm only after 1 s clear plus SHADOW;
  - the breaker trips on the 3rd nonce change in 120 s;
  - the fallback limiter;
  - `inputPath` and `tapDrill` polling;
  - startup stay-LIVE only when every condition holds;
  - the clean-exit order (INERT before destroyDevice);
  - `resetDeliveryState` on TAP→UC: hold LT = 1.0 across LIVE → fallback, and expect LT = 1023 to be posted on the next frame.
- **`DriverManagerModeTests`.** An in-app DextClient sends `setForwarding(INERT)` after hello when CAP_TAP is set; engine mode sends nothing (existing fake).
- **`VirtualPadSinkTests`.** The rank-5 change; adopt skips `postNeutral`; the posting gate. All 42 existing tests stay green (**M** `grep -c 'func test'`).
- **Oracle tests stay green:** GamepadFrameTests (4), ControlMappingTests (4), PadReportBuilderTests (8), PassthroughPadMapperTests (11) (**M**).

### 10.2 Live check toolkit

Run these exactly as written. Positive controls are included.

| Id | Check | Command and pass |
|---|---|---|
| PC | Power cycle | Run `scripts/receiver-check.sh` before the power cycle (record). Switch the controller off. Wait until `ioreg -p IOUSB -w0 -l \| grep -E '"idProduct" = 1485[67]'` shows 14857. Switch it on and wait for 14856. Run `scripts/receiver-check.sh` again (record). |
| L1 | Binding | `scripts/receiver-check.sh`: interface 3's child is what the phase expects; interface 4's child is `AppleUserHIDEventDriver` (positive control); interfaces 0–2 match the T0.1 snapshot. |
| L2 | One process | `pgrep -lf 'com.interlinked.gdhub.VirtualHID$'` prints exactly one line (**M** the pattern matches only the dext today); in T0 use `'com.interlinked.gdhub.TapProbe$'`. `/usr/bin/log show --last 10m --info --predicate 'eventMessage BEGINSWITH "GDHub" AND eventMessage CONTAINS "pid="'` shows root and tap with the same pid. |
| L3 | Rate and pool | receiver-check rate 940–970/s; `CreatedBuffers` unchanged across two runs 60 s apart (tap in COUNT or higher). |
| L4 | Raw readers intact | `scripts/engine-agent.sh latency` shows `cb(all frames)` 940–970 Hz; the GUI live view moves; the battery strip shows a value; padlat runs. |
| L5 | Device lists | `hidutil list > ~/GDHub-rollback/lists/hidutil-<phase>.txt`; `scuf-envision/tools/gcprobe > …/gc-<phase>.txt`; `scuf-envision/tools/sdlmatch > …/sdl-<phase>.txt`; diff against T0.1. **Accept:** unchanged, or only the raw SCUF entry is gone, with the 02E0 pad (and its synthetic copy) present exactly once. **Reject:** the 02E0 pad missing or duplicated, or the owner's test game losing the controller. |
| L6 | Latency | Game Mode check (§9.2), engine meter 3 × 10 min, padlat 3 × 20 s. |
| L7 | Pad | `scripts/vhid-check.sh` (pad count 1); `ioreg -rw0 -n GDHubVirtualHID -d 3` shows GDHubVirtualPad under the root. |
| L8 | Upgrade drill | §7.1 U1–U7 twice in a row without a reboot. Each time U5 shows the new build. Record whether the tap attached before the power cycle. |
| L9 | Rollback drill | §7.2 RB1–RB7 to the phase's `-pre` archive, then §7.1 forward again. |
| L10 | Fallback drill | `defaults write com.interlinked.gdhub tapDrill -string pause5`. The engine log shows `fallback: tap stalled` within 300 ms of the dext's `tap pause start`, and padlat keeps seeing 02E0 reports. |
| S1 | Soak | Before: `pgrep -lf 'com.interlinked.gdhub.VirtualHID$'` and `ls ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports \| grep -c 'com.interlinked.gdhub.VirtualHID'`. Then 20 controller off/on cycles (PC each), 10 sleep-timer cycles, 3 Mac sleep/wake cycles. After: the same pid, no new crash report, status2 `openFailures` 0 outside seizes, and L1 passes. |

---

## 11. Phased implementation

**Common rules for every phase:**
- Archive the current app before a dext-changing phase: `ditto /Applications/GDHub.app ~/GDHub-rollback/<phase>-pre/GDHub.app`.
- Builds:
  - App-only: `scripts/build-xcode.sh --release --same-build`.
  - Dext-changing: §7.1 U1–U7.
  - T0: `scripts/build-xcode.sh --release --probe`, which forces `--same-build`.
- Release builds only. No drill and no check depends on DEBUG: DEBUG=1 is set only in the Debug configuration (**R** build-xcode.sh:19, project via review). Drills are runtime, owner-only flags.
- Uninstall the engine agent before a dext-changing build (**R** build-xcode.sh:26-29).
- Never kill a dext process. Never run `systemextensionsctl uninstall|reset`.
- Reboot only when:
  - U5 or RB5 do not match within 2 min;
  - the request reports `.willCompleteAfterReboot`;
  - "terminated waiting to uninstall on reboot" appears;
  - sysextd wedges, or "terminating_for_upgrade" hangs (**R** driverkit-dext-design.md:1316-1320; engine-agent-plan.md:894).

  Budget one reboot per dext or probe replacement.
- Order of work: implement → `swift build && swift test` → build or upgrade → live checks → commit → update the ledger. The commit body holds the results, the test count, "Not yet verified:" and Co-Authored-By.
- Implementer models, always set explicitly:
  - Sonnet high for dext C++ and threading;
  - Sonnet medium for Swift and scripts;
  - Haiku low for mechanical steps, builds, test runs and log greps;
  - Opus high only for a dext bug Sonnet cannot fix.
  - No multi-agent fan-out.

### T0: Probe dext (production untouched)

**Scope**

- **T0.1 Facts and a sign-only probe build (no install).**
  1. `ditto /Applications/GDHub.app ~/GDHub-rollback/build17/GDHub.app`. Build 17 is live (**M** systemextensionsctl).
  2. L6 → the "today" baseline (engine meter + padlat).
  3. Snapshots into `~/GDHub-rollback/T0-facts/`:
     - `scripts/receiver-check.sh`
     - `ioreg -rw0 -l -n "SCUF Envision Pro Wireless USB Receiver V2"`
     - `hidutil list`
     - `scuf-envision/tools/gcprobe`
     - `scuf-envision/tools/sdlmatch`
  4. Sleep timer (A12):
     - Set the shortest timer in the battery strip and leave the controller idle.
     - Run `while sleep 1; do date +%T; ioreg -p IOUSB -w0 -l | grep -E '"idProduct" = 1485[67]'; done`.
     - Read the current timer value in the strip **before** changing it and write it down. Afterwards **restore that same value** and read it back. It was set to 3,600,000 ms (60 min) on 2026-11-09 (**R** envision-pro-receiver.md:102), but the value read at the start of the test is the one to restore.
  5. Competing personalities (A14): `python3 -I scripts/tools/personality-scan.py`. Expected: one hit, USB mass storage 6940:6659 (**M** today).
  6. Profile:
     - Add the probe target.
     - `print 1 > Xcode/probe-build`
     - `scripts/build-xcode.sh --release --probe --no-install`
     - This builds with the probe embedded, runs every §3.6 check on both dexts and installs nothing (**R** build-xcode.sh:71).
- **T0.2 Probe build 1.** Decline first, then run, in one process.
  1. `scripts/build-xcode.sh --release --probe --no-open`. The production version stays 17, which the script asserts.
  2. `ditto /Applications/GDHub.app ~/GDHub-rollback/T0-probe/GDHub.app`
  3. `open /Applications/GDHub.app --args --dev-probe-dext activate`. Approve in System Settings if asked (**G·T0**). Wait for `systemextensionsctl list | grep 'gdhub.TapProbe (0.1.0/1).*activated enabled'`.
  4. L1 **before** any power cycle. Record whether the probe took interface 3 (A10).
  5. **PC #1** → first Start: `tap start #1 rootSeen=1 rootPid=P vid=6940 pid=14856 page=65368 → decline`. Then L1 shows AppleUserHIDEventDriver on interface 3 (A8).
  6. **PC #2** → second Start runs:
     - Open with the pool.
     - Strategy B for 30 s, strategy A for 10 s, then B again. Run receiver-check in each window.
     - Log the first 3 frames once: reportID, length, bytes, and whether the descriptor is one of ours.
     - Every 10 s: count, k2d p50/p99/max, poolMiss, maxGap.
     - Log every SetPowerState with its flags and every Stop/Start time.
  7. One sleep-timer cycle and one Mac sleep/wake (A12, A13).
  8. L2 (probe pattern), L3, L4, L5.
- **T0.3 Crash drill (mandatory). Probe build 2.**
  1. `print 2 > Xcode/probe-build; PROBE_CRASH=1 scripts/build-xcode.sh --release --probe --no-open`
  2. `open /Applications/GDHub.app --args --dev-probe-dext activate`. This replaces build 1 with build 2. Reboot if the log never shows `build=2` after a power cycle.
  3. The tap runs and calls `__builtin_trap()` only after report 0x06 has held buttons 7, 8, 9 and 10 together for 2 s (View, Menu, L3, R3: **R** envision-pro-receiver.md:63-64). One crash per owner action. **At most 3 crashes, at least 2 min apart.**
  4. Within 60 s of each crash, record:
     - relaunch and new pid (`pgrep -lf 'com.interlinked.gdhub.TapProbe$'`) and the delay;
     - who holds interface 3 (receiver-check), and whether the probe re-matched without a power cycle;
     - `ioreg -rw0 -l -n IOUserResources -d1 | grep IODEXTMatchCount` and the same key on interface 3's IOHIDInterface (A25);
     - `ls -t ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports | grep -i TapProbe`;
     - `/usr/bin/log show --last 5m --predicate 'eventMessage CONTAINS[c] "TapProbe"'`.
  5. **Loop-breaker:** switch the controller off (no frames means no chord).
  6. **Stop the drill at once** on any reboot, panic, or "crashed too often" message. Record it.
- **T0.4 Downgrade (A23).**
  1. `print 1 > Xcode/probe-build; scripts/build-xcode.sh --release --probe --probe-downgrade --no-open`
  2. `open /Applications/GDHub.app --args --dev-probe-dext activate`
  3. The log shows `probe: replacing 2 -> 1`, and `systemextensionsctl list` shows 1 as `activated enabled`.
- **T0.5 Remove the probe.**
  1. `open /Applications/GDHub.app --args --dev-probe-dext deactivate`. Reboot if the list shows "terminated waiting to uninstall on reboot".
  2. `systemextensionsctl list | grep -c TapProbe` must print 0.
  3. Then remove the probe target, the app dependency, `Xcode/probe-build`, `ProbeExtensionRequester.swift` and `--probe` from the build script.
  4. `scripts/build-xcode.sh --release --same-build`
  5. PC; L1 shows Apple on interface 3.
  - **Never restore build 17 while the count is not 0.** Build 17 cannot deactivate the probe, and trashing the app in Finder also uninstalls production (**R** driverkit-dext-design.md:1321).

**Files:**
- `Dext/GDHubTapProbe/{GDHubProbeRoot,GDHubProbeTap}.{iig,cpp}`
- `project.yml`
- `ProbeExtensionRequester.swift`, `DriverManager.swift`
- `scripts/receiver-check.sh` (kept)
- `scripts/tools/personality-scan.py` (kept)
- `scripts/build-xcode.sh`
- `scripts/dext-log.sh`
- `docs/protocol/envision-pro-receiver.md` (facts)

**Do NOT:**
- change the production dext or bump its version;
- port translation code;
- change the engine;
- leave the probe installed;
- crash the probe more than 3 times.

**Live checks and pass criteria:**

| Step | Pass |
|---|---|
| T0.1 | Baseline recorded. A12 answered. The sleep timer reads its pre-test value again. Personality scan recorded. The probe build passes `need` (transport.hid + UDID). |
| T0.2 | The probe is enabled (A2). `tap start #1` has `rootSeen=1` and pids equal to the root's, with one probe process (A1). After PC #1, Apple holds interface 3 (A8). After PC #2, the probe tap holds interface 3 only (A3). Frames arrive at 940–970/s (A4). Framing is ID 6, length 16 (A5). k2d is small and positive (A7). CreatedBuffers is flat under B and grows under A (A6). L4 is unchanged. L5 accepts (A11). Power flags and Stop/Start are logged (A13). |
| T0.3 | A9 and A25 recorded for each crash. Either no OS reboot response, or its threshold is recorded. |
| T0.4 | A23 holds. |
| T0.5 | The probe count is 0 and Apple is back on interface 3. |

**Stop rules:**

| Finding | Action |
|---|---|
| AMFI refuses | Stop; report. |
| The probe never wins interface 3 | Check the integer types and the scores in ioreg; stop. |
| pids differ, or `rootSeen=0` | Plan B review. |
| Open fails while nothing is seized, in both Plan A and Plan C | USB-claim last-resort review. |
| L4 or L5 fail | Stop: the takeover would break the GUI or games. |
| A23 fails (a lower version is refused) | Stop. Redesign rollback before any production phase: an "N+1 that equals N-1" build. |
| The OS reboots or throttles after 1–2 crashes | Record. R9 becomes high severity. The owner decides whether to continue. |

**T0-alt** (if T0.1.6 fails because a new bundle ID gets no transport.hid profile):
- Skip T0.2–T0.5.
- Do T3, then T4 as the first live test. T4 first ships a `GDHUB_TAP_DECLINE=1` build, which proves A2, A8 and A10 in production, and then the INERT/COUNT build.
- A9 stays unknown. R9 is treated as high severity.
- Keep the build17 and T3-pre archives.

**Rollback:** `open /Applications/GDHub.app --args --dev-probe-dext deactivate`, then PC, and reboot if needed. Production is never touched.

**Reboot budget:** up to 4: after each probe activation or replacement (T0.2, T0.3, T0.4) and after the deactivation (T0.5).

**Commits:**
- `Takeover: probe dext answers load, match, one-process, pool and relaunch questions (T0)`
- `Takeover: remove the T0 probe dext (T0)`

**Models:** Sonnet high (probe C++); Sonnet medium (probe requester, scripts); Haiku low (builds, log greps).

### T1: Engine limiter fix and new baseline

- **Scope:** `lastPostAt = tS` (**R** other-controller-drivers.md:221-228; VirtualPadSink.swift:448, 491). Then L6 → the "T1 baseline".
- **Files:** `VirtualPadSink.swift`, `VirtualPadSinkTests.swift`.
- **Do NOT:** make other sink changes; touch the dext.
- **Live checks:**
  - L6 under confirmed Game Mode. **Pass:** the meter's `cap` stage p50 ≤ 0.05 ms (**R** LatencyMeter.swift:22, 53) and coalesced < 20 %.
  - Record total p50, p99 and max.
  - L4.
- **Rollback:** revert, then `scripts/build-xcode.sh --release --same-build`.
- **Reboot:** no.
- **Commit:** `Engine: rate cap measured from post start (T1, rank 5)`.
- **Models:** Sonnet medium; Haiku low for the runs.

### T2: One shared C translator; the engine runs it

- **Scope:** the §5.1–§5.3 core, the encoder (including `.unsupported`), the generated header, the parity, sequence and golden tests. The engine uses the core by default. `defaults write com.interlinked.gdhub xlateCore -string swift` selects the old path.
- **Files:** `Shared/GDHubXlate.{h,c}`, `Shared/GDHubDefaults.h`, `Package.swift`, `project.yml` (app sources, bridging header, cflags, dext `excludes`), `XlateCore.swift`, `MapBlobEncoder.swift`, `VirtualPadSink.swift`, the new tests.
- **Do NOT:** change the dext binary (Shared is excluded); delete the Swift mapper; implement echo, overlay or D8.
- **Live checks:**
  - `swift test` green, including the exhaustive and 10⁶-frame tests.
  - A per-frame microbenchmark (XCTest `measure`): C core ≤ Swift mapper + builder.
  - Same-session A/B, default against `xlateCore = swift`: engine total p50 within ±0.15 ms.
  - 10 min of play.
- **Rollback:** the `xlateCore = swift` key (runtime), or revert.
- **Reboot:** no.
- **Commit:** `Engine: one C translator shared with the dext; engine runs it (T2)`.
- **Models:** Sonnet high (C core, numerics); Sonnet medium (Swift); Haiku low (test runs).

### T3: Root owns the pad; registry; fixed-length buffers; DextClient matching

- **Scope:**
  - registry (§4.3);
  - `CreatePad`/`DestroyPad`; pad provider = root;
  - `submitInput` and `postNeutralFrom` (source UC only);
  - fixed-length per-entry post buffers;
  - `GDHUB_SPEC_VERSION`; `CAP_ROOT_PAD`;
  - selector 9 (INERT only) and selector 11 (identity, counters);
  - `hop`/`hr` stamps for UC posts in the meter line;
  - `GDH_SYNC` in every build;
  - root Stop terminates the pad;
  - D5 output lookup through the registry;
  - DextClient `IOUserClass` match + unit test.
- **Files:** the §8.1 rows marked T3; `DextProtocol.swift`, `DextClient.swift`; `vhid-check.sh`; `driverkit-dext-design.md`.
- **Do NOT:** add the tap, OneProcess, pinning or forwarding. G5 is unchanged.
- **Live checks** (after U1–U7):
  - L7.
  - L6: no regression. Record the gain from removing SetLength, and `hop`/`hr` p50/p99 (A16, A19). A hop p50 in the tens of µs means kernel routing; flag T9.
  - `kill -9` of the engine → `ioreg -rw0 -n GDHubVirtualPad` is empty within 1 s, and the root is still present.
  - SIGSTOP of the engine for 3 s → neutral at 2 s.
  - PC: the pad is unaffected.
  - L8.
  - The log shows no `syncViolations`.
- **Rollback:** §7.2 to `~/GDHub-rollback/T3-pre` (the T2 app).
- **Reboot:** only under the common rules.
- **Commit:** `Dext: root owns the pad; fixed-length post buffers; additive status2 (T3)`.
- **Models:** Sonnet high (dext); Sonnet medium (Swift mirror, DextClient).

### T4: Tap in production, INERT and COUNT only

- **Scope:**
  - Dext:
    - personalities and entitlement (§3.2, §3.5) and the build checks (§3.6);
    - the tap: Start/register, INERT, COUNT (pool B, Open with retry, counters, k2d), Stop order, SetPowerState rule, timer, pid log;
    - `GDHUB_TAP_DECLINE` define;
    - root pid log; devTerminate order pad → tap (Close + Terminate) → root;
    - `CAP_TAP`; selector 9 accepts COUNT; status2 tap fields.
  - Engine and app:
    - `inputPath = count` → `setForwarding(COUNT)` after hello;
    - unsupervised DextClients send INERT;
    - TapSupervisor timing only: interfaceUp→tapPresent, logged.
  - Docs: output-layer decision 5 note.
- **Precondition:** the probe is fully gone (T0.5), unless T0-alt applies.
- **Do NOT:** link the translator; post anything from the tap.
- **Live checks** (after U1–U7, then `inputPath = count`):
  - PC → L1 shows GDHubReceiverTap on interface 3 only; interface 4 still Apple.
  - L2 (root pid == tap pid; stop if they differ).
  - L3, L4, L5.
  - `inputPath = engine` → status2 `opened = 0` within 1 s (A24: the poke reached the tap queue).
  - L8 with the tap attached (A18: the process exits on devTerminate).
  - L9 to `T4-pre` and back.
  - S1 in COUNT.
  - Record the interfaceUp→tapPresent p99 (it sets the F2 grace).
- **Rollback:** §7.2. Alternatively a `GDHUB_TAP_DECLINE=1` build. Switching the controller off detaches the tap.
- **Reboot:** only under the common rules. Record every case.
- **Commit:** `Dext: receiver tap on interface 3, inert or counting only (T4)`.
- **Models:** Sonnet high (dext); Sonnet medium (engine flag, scripts); Haiku low (plutil, ioreg and soak checks).

### T5: Translator inside the dext, SHADOW only

- **Scope:**
  - Dext:
    - remove the Shared `excludes`;
    - SHADOW state; registry map handoff; selector 10;
    - self-test; parity sampler;
    - histograms and the meter line;
    - `CAP_XLATE`.
  - Engine:
    - pushes GDHM on every mapping change;
    - `inputPath = shadow` arms SHADOW;
    - 4 Hz sampler, which logs mismatches. There is no fallback yet, because SHADOW never posts.
  - Docs: the §4.2 note.
- **Do NOT:** implement LIVE, padSource arbitration, pinning, adopt or the Hot queue.
- **Live checks** (after U1–U7, then `inputPath = shadow`):
  - 30 min of play in SHADOW: 0 parity mismatches; framesIn ≈ engine frames.
  - `GDHub: selftest pass` in the log.
  - A GUI learn edit → `appliedRevision` in status2 within 100 ms.
  - L6 unchanged (the engine is still posting).
  - The fuse, checked during L8: after the new build's hello, status2 `desiredState == INERT` before the engine re-arms.
  - S1 in SHADOW.
  - L1.
- **Rollback:** `inputPath = engine`; §7.2 to `T5-pre`.
- **Reboot:** only under the common rules.
- **Commit:** `Dext: in-driver translation in shadow; mapping blob (T5)`.
- **Models:** Sonnet high (dext); Sonnet medium (engine push and sampler).

### T6: Engine supervisor in SHADOW (app only)

- **Scope:**
  - TapSupervisor F1–F5 for COUNT and SHADOW, the breaker, the fallback limiter;
  - `inputPath` and `tapDrill` polling (1 s);
  - Driver menu item and status;
  - encoder `.unsupported` → engine path with a reason;
  - doc rows: §2.4 R14 and output-layer §3.1.
- **Do NOT:** change the dext; request LIVE (`driver` runs as `shadow` until CAP_LIVE exists).
- **Live checks** (after `scripts/build-xcode.sh --release --same-build`):
  - A20: 20 toggles `engine ↔ shadow`. status2 `appliedState` follows within 1.2 s every time.
  - `tapDrill pause5` in SHADOW → `fallback: tap stalled` (F1) and re-arm after the pause.
  - Switch the controller on → no F2 fallback within the grace period.
  - A21: logout → the engine logs SIGTERM; fast user switch → the agent pid is unchanged.
  - A22: run a seizing scratch reader if one is available; otherwise record "untested".
  - GUI learn; the battery strip.
  - Breaker and limiter: TapSupervisorTests only. A live drill would need repeated dext crashes, which T0.3 already characterised on the probe.
- **Rollback:** `inputPath = engine`; revert the app.
- **Reboot:** no.
- **Commit:** `Engine: tap supervisor and input-path switch, shadow only (T6)`.
- **Models:** Sonnet high (TapSupervisor, threading); Sonnet medium (menu, options).

### T7: LIVE (dext and engine together)

- **Scope:**
  - Dext:
    - `padSource` arbitration (§6.2); LIVE state; `holdNeutral`;
    - pinning, orphan timer, `createDevice2` adopt, destroy/create rules, the spec-CRC arming check (§6.3);
    - watchdog per slot (§6.4); silence, Stop and SetPowerState neutrals;
    - `DEV_PAUSE_TAP`, `RELEASE_PAD`; `CAP_LIVE`.
  - Engine:
    - posting gate; `resetDeliveryState` on TAP→UC; adopt skips the neutral;
    - startup stay-LIVE; F6;
    - fallback to COUNT or INERT;
    - PowerObserver: async wait of at most 1 s, willSleep hold, didWake resume;
    - `--release-pad`; the `engine-agent.sh uninstall` cleanup.
  - Docs: G5 amendment; E2–E4 notes.
  - **One fix replacement is allowed inside T7** (budgeted), so defects in the LIVE code are fixed in the phase that first runs it.
- **Do NOT:** make LIVE the default; add Hot, rumble, overlay or AutoArm.
- **Live checks** (after U1–U7, with `inputPath = driver`):
  - Every §7 row marked T7. The RT-hold `kill -9` test from §9.3 (twice).
  - SIGSTOP of the engine for 5 s → input continues.
  - Orphan test: `kill -9 $(pgrep -f 'GDHub --engine$'); scripts/engine-agent.sh bootout_wait`. Then `ioreg -rw0 -n GDHubVirtualPad` still shows the pad at 10 s and is empty at 35 s. Then `scripts/engine-agent.sh install`.
  - `engine-agent.sh uninstall` → pad removed.
  - Controller sleep → neutral ≤ 300 ms (G9 method).
  - Controller off → pad stays, neutral; on → same pad ID, LIVE resumes.
  - Mac sleep/wake ×2: the log shows `hold` then `resume`; no stuck input.
  - L10.
  - 50 `inputPath` toggles `engine ↔ driver` at 1 Hz while holding RT. After each switch the next 02E0 row shows RT held, and after release, RT = 0.
  - In-app fallback: kill the engine, `bootout_wait`, open the GUI. The GUI adopts, sends INERT, and its posts move the pad (vhid-check, live view).
  - S1 in LIVE.
  - L6 (first numbers).
- **Rollback:** `inputPath = engine` (runtime); §7.2 to `T7-pre`.
- **Reboot:** only under the common rules.
- **Commit:** `Dext+Engine: driver input path (LIVE) with pad-side arbitration and pinning (T7)`.
- **Models:** Sonnet high (dext arbitration, TapSupervisor, PowerObserver); Sonnet medium (scripts, options).

### T8: Gate and play test; LIVE becomes the default

- **Scope:** §9.3. If it passes:
  - the `inputPath` default becomes `driver` (one line, app-only build);
  - `xlateCore` is removed, and the Swift mapper remains as the test oracle only;
  - update HANDOFF.
- **Do NOT:** change the default if any criterion fails (R15).
- **Rollback:** `inputPath = engine`.
- **Reboot:** no.
- **Commits:**
  - `docs: receiver takeover gate result (T8)`
  - `Engine: driver input path is the default (T8)`
- **Models:** Haiku low (runs and tables); the owner plays.

### T9: Shared Hot queue (only if G11 or G12 fails)

- **Scope:** §4.6, every listed method.
- **Do NOT:** make any synchronous call from Hot.
- **Live checks:**
  - `hop` p50 < 10 µs; `occ` p99 ≤ 0.5 ms;
  - the §4.6 step 8 toggle test;
  - the full T8 gate again;
  - L8.
- **Rollback:** §7.2 to `T9-pre`.
- **Reboot:** only under the common rules.
- **Commit:** `Dext: tap and pad share the Hot queue (T9)`.
- **Model:** Sonnet high.

### T10: Rumble

- **Scope:**
  1. Capture the 0x09 format from user space first (no build).
  2. The pad's `setReport` completes immediately (D5 rule, **R** latency-plan.md §2 row 9) and stores the latest (L,R).
  3. `DispatchAsync` to the tap's `QUEUENAME(Output)` → `IOHIDInterface::SetReport(0x09)` (**R** IOHIDInterface.iig:194), with one write in flight, coalesced.
  4. Auto-stop on tap Stop, Off, silence, source switch and pad destroy.
  5. Latch safety (the receiver latches the motors, **R** other-controller-drivers.md §4):
     - the tap sends one zero-rumble report at Start and at each Open;
     - the engine sends a single stop-only zero-rumble with IOHIDDeviceSetReport on the 0xFF58 device when it sees a nonce change.
  6. A GDHM v2 output-template section.
- **Do NOT:** write rumble to interface 4; make a synchronous SetReport on the input path; build engine-side rumble beyond the stop-only write (ranks 6–7 are superseded).
- **Live checks:**
  - the motors run;
  - each auto-stop path stops them;
  - devTerminate while rumbling → stop within one relaunch and PC.
- **Rollback:** §7.2.
- **Reboot:** only under the common rules.
- **Commit:** `Dext: rumble forwarded to the receiver (T10)`.
- **Model:** Sonnet high.

### T11: Macro overlay and D8 slots

- **Scope:**
  - a `setOverlay` selector `{buttonsSet, buttonsClear, axisMask, axes[4], triggers[2], ttlMs ≤ 2000}`, merged by `gdx_apply_overlay` (shared with the engine);
  - the overlay clears on UC Stop, watchdog fire, source switch and TTL expiry;
  - D8 keyboard and pointer under the root, posted by the engine outside tap arbitration, never pinned, neutralised by the watchdog (§6.4).
- **Live checks:**
  - stuck inputs at overlay end, source switch, re-enumeration and sleep;
  - **SIGSTOP the engine with a key held → key released ≤ 2.25 s.**
- **Rollback:** §7.2.
- **Reboot:** only under the common rules.
- **Commit:** `Dext: MERGE overlay with TTL; D8 slots under the root (T11)`.
- **Models:** Sonnet high (dext); Sonnet medium (engine).

### T12: AutoArm (optional, last)

- **Precondition:** T0.3 found a measured relaunch signal (A25). `mach_absolute_time()` cannot serve as a boot clock, because its origin is arbitrary and it stops during sleep (**R** IOLib.h:177-181). Without a measured signal, T12 is not done.
- **Scope:**
  - plist key `GDHubAutoArm: true`;
  - on the first launch (signal = no relaunch), the root creates the pad from the embedded default spec and the factory GDHM;
  - SHADOW, then LIVE after 2 s, only if the self-test passes;
  - a relaunched process never auto-arms;
  - the pad is exempt from the orphan timer;
  - the engine then adopts or recreates as usual.
- **Live checks:**
  - boot out the agent, quit the GUI, `pgrep GDHub` prints nothing → the pad exists and moves;
  - after a reboot, `/usr/bin/log show --last boot --predicate 'eventMessage CONTAINS "GDHub: tap autoarm"'` shows arming before the engine's first hello.
- **Rollback:** rebuild with `GDHubAutoArm: false` (§7.1).
- **Reboot:** one, for the check.
- **Commit:** `Dext: optional AutoArm at first launch (T12)`.
- **Model:** Sonnet high.

---

## 12. Risks (symptom → action)

| # | Symptom | Action |
|---|---|---|
| R1 | A dext stays "activated waiting", or amfid logs a denial | `scripts/dext-log.sh --load`. Stop. Roll back (§7.2). Recheck the profile. |
| R2 | Tap or probe not on interface 3 after PC | Check the §3.6 integer assertions, the scores in ioreg and the personality scan. Stop. |
| R3 | Tap seen on interface 4 or the audio interfaces | Should be impossible by keys. Roll back at once (§7.2). |
| R4 | Root and tap pids differ | Stop. Plan B review. |
| R5 | Open fails | Check the seize state (receiver-check). If something has seized the device: quit that app. Otherwise: Plan C probe. |
| R6 | CreatedBuffers grows, or "No report pool" | Check that the re-add runs after every frame (strategy B), and the poolMiss count. |
| R7 | GUI live view or engine callback rate drops after the tap attaches | `inputPath = engine` does not help. Switch the controller off, then roll back (§7.2). Stop. |
| R8 | A game loses the pad or sees a duplicate (L5 reject) | Roll back. The HID-tap mechanism fails; review the USB-claim last resort or abandon. |
| R9 | Dext crash loop (crash in Start, Stop, SetPowerState, the timer or the pool code runs at every enumeration; the fuse does not cover this) | **Switch the controller off first** (3A09 never matches). Roll back (§7.2) with the controller off, then PC. macOS may reboot the Mac if a driver crashes too often (**R** IOKitKeys.h:134-136). Fix with a new soak case. |
| R10 | `selfTest = fail` or a parity mismatch | Stays LEGACY. Compare cflags (`-ffp-contract=off`) and the golden vectors. |
| R11 | Stuck or held input after a switch, sleep or unlink | Check the neutral and hold counters in status2. `inputPath = engine`. Add a test. |
| R12 | `ucRejected > 0` in LIVE outside drills | Engine posting-gate bug; fix before the gate. |
| R13 | The process does not exit on devTerminate with the tap attached | Switch the controller off (that detaches the tap) and retry. Otherwise reboot. Record. |
| R14 | sysextd wedge or "terminating_for_upgrade" | Reboot (**R** engine-agent-plan.md:894). |
| R15 | The gate misses G1, G4 or G12 | T9 if the hop or occupancy is large. Otherwise keep `inputPath = engine`. If LIVE is not adopted within 4 weeks, ship one build without the `GDHubReceiverTap` personality (one replacement). Keep the T3 root-owned pad, so Apple's event driver is back on interface 3. |
| R16 | Silent while the controller is on | The status shows the seize label. Quit the seizing app. No fallback loop. |
| R17 | Orphan pad after an uninstall or an unclean logout | It is removed within 30 s (orphan timer), or run `GDHub --engine --engine-foreground --release-pad`. |
| R18 | `setMapping` BadArgument, or the encoder says `.unsupported` | The engine logs the reason and stays on the engine path; the Driver menu shows it. |
| R19 | The probe lingers before T4 | Do not start T4. Reboot until `systemextensionsctl list` shows no probe. |
| R20 | Deadlock (a dext queue stops) | `syncViolations` and the log name the call. Production: **reboot**. devTerminate runs on the UC queue and may be blocked too. |
| R21 | The OS reboots the Mac after repeated dext crashes | Switch the controller off, roll back, and record the count and spacing next to T0.3's numbers. |
| R22 | A pinned pad drives input at loginwindow or in another session | Expected for at most 30 s (orphan timer). If longer: a check of the orphan timer fails; fix it. |

---

## 13. Open questions

1. Does installing a personality re-probe interface 3 without a re-enumeration? (A10, T0.2)
2. Is a crashed dext relaunched, who gets interface 3, does `IODEXTMatchCount` move, and does the OS reboot policy apply? (A9, A25, T0.3)
3. Does the sleep timer re-enumerate the receiver (A12, T0.1)? Which SetPowerState flags arrive on Mac sleep (A13, T0.2)?
4. Does Xcode's automatic profile for a **new** bundle ID carry transport.hid and the UDID? (T0.1.6; otherwise T0-alt)
5. Is the cross-queue hop in-process or a kernel round trip? (A19, T3)
6. Does `DispatchAsync` onto another service's queue in one process work? (A24, T4)
7. Does the engine see `inputPath` changes from another process within 1 s? (A20, T6)
8. Does the agent survive fast user switching, and does it get SIGTERM on logout? (A21, T6)
9. When should the −1 quirk be fixed? A product decision, applied to the single core.
10. What is the SCUF 0x09 rumble format, and does it need init or keep-alive? (T10 capture)
11. Does Bragi software mode remove the onboard-profile echo? Needed before echo suppression (GDHM v2).
12. What causes the 5–9 ms spikes? Outside this plan; expected to persist.

Closed by the SDK headers:
- A SetPowerState override must make the driver safe and then pass the call to super (**R** IOService.iig:253-262). This is now a rule in §6.4.
- `mach_absolute_time()` has an arbitrary origin and does not count during sleep (**R** IOLib.h:177-181). This is now handled in T12.
- Whether an SDL tool exists: `scuf-envision/tools/sdlmatch` (**R**), now in L5.

---

## T0 results (2026-11-09, in progress)

All **M**, probe dext `com.interlinked.gdhub.TapProbe`. Raw captures are in `~/GDHub-rollback/T0-facts/` (not in the repo).

### T0.1 and T0.2 (probe build 1): passed

| # | Assumption | Result |
|---|---|---|
| A1 | Root and tap in one process | **Holds.** Every `tap start` line shows `rootSeen=1 rootPid=<pid>` equal to the tap's own pid; `pgrep` shows one probe process. |
| A2 | AMFI loads a dev-signed dext with `transport.hid` | **Holds.** Activated after one approval in System Settings; later replacements needed no approval. |
| A3 | The tap wins interface 3 only | **Holds.** `receiver-check`: interface 3 child `GDHubProbeTap`, IOProbeScore 7250 (= 50 + 5000 + 1000 + 1100 + 100, so the production tap at 1000 scores 8200); interface 4 child stays `AppleUserHIDEventDriver` (1151). |
| A4 | A plain IOService can Open the IOHIDInterface | **Holds.** Open returned 0 on the first try every time; frames arrive at the engine's rate (887–948/s in both, same 10 s windows). The "940–970/s" figure in §10.2 is too narrow: the receiver itself delivers 887–948/s. |
| A5 | Framing | **Holds.** `reportID=6 len=16 type=0`, ID byte first. No other report ID seen (`other=0`). |
| A6 | Pool | **Holds for behaviour, not for the counter.** Strategy B (re-add per frame): `poolMiss=0`, `readdFail=0`. Strategy A (no re-add): after 8 frames every report arrives in a kernel buffer (`poolMiss` ≈ all frames). The registry `DebugState` counters (`CreatedBuffers`, `ReportAvailableCalls`) stay 0 while the tap is the client, so L3 must use the tap's own counters. |
| A7 | Timestamp | **Holds.** Mach absolute time; kernel-to-driver delay p50 ≤ 55–85 µs, p99 ≤ 110–205 µs, max ≤ 0.41 ms (0.74 ms once right after wake). Engine callback in the same windows: p50 0.05–0.08 ms, p99 0.20–0.35 ms, max 0.84–4.19 ms. |
| A8 | After a declined Start, Apple's driver attaches | **Indirect only.** The declined first Start happened before the live capture ran; `receiver-check` 4 s after activation showed Apple's driver on interface 3. Repeat with capture in T0.4. |
| A10 | A new personality only takes interface 3 at the next enumeration | **Refuted.** Loading new personalities re-probes interface 3 at once: on the 1 → 2 replacement the tap was stopped and started again 6 ms later with the receiver linked throughout. |
| A11 | Games see no change | **Holds.** `gcprobe` identical; `sdlmatch` same four devices; `hidutil list` loses only the raw 0xFF58 `AppleUserHIDEventService` entry. Engine reader unaffected (`cb(all frames)` 887–945 Hz). |
| A12 | Controller sleep timer | **Answered.** The controller slept exactly 600 s after link; the receiver re-enumerated to 3A09 and the tap got `Stop`. Also: the 60 min timer written earlier was back at the factory 600000 ms after a controller power cycle, so the setting does not persist and must be re-applied at each link. |
| A13 | Mac sleep | **Answered.** `SetPowerState flags=0x0` (Off) arrives about 1 s after sleep starts. On wake the receiver re-enumerates (interface down 12:07:01, up 12:07:02) and a new tap instance opens; the engine recovers too. |
| A14 | Competing personalities | **Holds on disk.** 801 bundles / 2,868 personalities; the only vendor-6940 entry is USB mass storage 6940:6659. Kernel-collection kexts are not covered. |

Other findings:
- **Dext log lines are live-only.** `os_log` from a dext shows as `kernel () GDHub…` in `log stream` but is not kept in the log store, and `log stream` drops lines under load. A line is cut at about 256 characters. Checks that use `log show` for dext lines (L2) must use a running `log stream` capture instead.
- **Upgrade with `IOUserServerOneProcess` keeps the old process.** After the 1 → 2 replacement sysextd reported `activated enabled` for build 2 and `terminating for upgrade` for build 1, but the build-1 process stayed (its root service is still matched) and the re-probed tap started in it again, running build-1 code. The production upgrade path therefore depends on devTerminate ending the old process (A18); for the probe it takes a reboot.
- Parallels Desktop can capture the whole receiver for a VM; while it does, no macOS driver is attached to any interface.

### T0.3–T0.5: pending

---

## Appendix A: Judges' mustFix items and where each is handled

| Item (judge) | Where |
|---|---|
| getpid() as the one-process proof (dk, pf) | §2.5 A1, §5.5, T0.2, L2 |
| Tap CFBundleIdentifierKernel `com.apple.kpi.iokit`; IOHIDFamily only for Plan C (dk, sr) | §3.2, §3.4 |
| AddReportToPool after the post; CreatedBuffers measured (dk, sr, pf) | §4.4 row 7, §4.5, T0.2, L3 |
| No translator while disarmed; in-dext fuse; safe AutoArm (dk, sr) | §6.1, §6.5, T12 |
| Inert, always-attached tap instead of refusing Start (pf) | §2.3, §6.1, T4 |
| Silence neutral 250 ms; Stop and SetPowerState neutral (dk, sr, pf) | §5.3, §6.4 |
| Translator parity: the engine switches to the same core; asymmetric ranges tested (dk) | §5.1, T2, §10.1 |
| CAS registry; any Start order; no null dereference (dk) | §4.3 |
| Measure the hop and `_HandleReport`; numeric threshold for the shared queue (dk, sr) | §9.1, G11, G12, T3, T9 |
| Probe logistics: App ID/profile, embedding, DriverManager, approval, removal before production (dk, sr) | §3.3, §3.6, T0.1.6, T0.2, T0.5, §8.3 |
| Lower probe score; probe fully gone before production (sr) | §3.3, T0.5, T4 precondition, R19 |
| Attach only at the next enumeration; PC in every live check (dk, sr) | A10, PC, §7.1 U6 |
| hidutil/GC/SDL lists before and after, with accept/reject (dk, sr) | T0.1, L5 |
| devTerminate terminates the tap first; process exit verified; E1 rule; reboot rules (dk, sr, pf) | §7.1, T4 L8, common rules |
| G5 change documented; controller-off row checked (dk, sr) | §2.4, T7 |
| Unproven assumptions listed (dk) | §2.5 |
| Minimal arbitration; no OVERRIDE lease (sr) | §6.2 |
| Pinned pad destroyed on clean exit, uninstall and devTerminate (sr) | §6.3 |
| Seize detection and labelling; GDHub never seizes interface 3 (sr, pf) | §4.5, §6.6, A22, R16 |
| −1 quirk decided before parity (sr) | §5.2 |
| Rank-5 fix measured first; gate reports both deltas (sr) | T1, G4b |
| Sleep-timer re-enumeration answered early (sr, pf) | T0.1, A12 |
| Paddle facts stated correctly; echo masks reserved (pf) | §5.2, §5.3 |
| How the pad joins the Hot queue; checked deadlock invariant (pf) | §4.2, §4.6 |
| Macros use a MERGE overlay with TTL (pf) | §2.3, T11 |
| v1 scope limited; gain restated (pf) | §5.1, summary, §1 |
| padlat baseline before T1; padlat still valid after (pf) | T0.1, §9.2 |
| Edits in project.yml; integer keys checked; transport.hid in `need`; tap has no IOMatchCategory; root keeps its own and gains OneProcess (pf) | §3 |

dk = driverkit-correctness, sr = safety-and-rollback, pf = product-fit.

---

## Review resolution

AT = api-truth, FM = failure-modes, SP = scope-and-proof. Duplicates are marked "=".

| # | Issue | Done |
|---|---|---|
| AT-1 (major) | T0 never forced `--same-build`; the probe version counter could not work | Fixed. `--probe` forces SAME, the probe uses `$(PROBE_BUILD)`, and the script asserts the production version equals the installed one and that the probe version increases (§3.3, §3.6, T0). Verified at build-xcode.sh:24, 35 and DriverManager.swift:521-545. |
| AT-2 (major) | T8 Hot moved only two methods; races | Fixed in §4.6 (now T9): every state method on Hot, timer on Hot, DispatchSync from Stop and SetPowerState, the invariant restated, toggle test added. |
| AT-3 (major) | Crash drill could loop; reboot policy ignored | Fixed. Chord-triggered crash, at most 3, at least 2 min apart, loop-breaker = controller off, OS response recorded (T0.3). Policy note in §1, §6.5, R9, R21. Verified at IOKitKeys.h:134-136. |
| AT-4 (minor) | Open failure misread as "not allowed"; no retry; Open success proves nothing | Fixed. Retry from the timer, seize state reported, Plan C only when nothing is seized, success gated on frames (§4.5, A4, R5). |
| AT-5 (minor) | Pool re-add treated as optional | Fixed. Strategy B is the baseline, A only as a T0 confirmation; A6 restated; `addPool` and `occ` histograms; G12. |
| AT-6 (minor) | "SDK has no math.h/atomic" was false | Fixed in §4.3 and §5.1. Verified: math.h and c++/v1/atomic exist; libsystem_m exports `_round`. |
| AT-7 (minor) | SetPowerState rule already in the header; Low ignored | Fixed. Rule in §6.4; Low and LPW handled; question removed. Verified at IOService.iig:253-262 and IOService.h:58-61. |
| AT-8 (minor) | AutoArm boot window relied on mach_absolute_time origin | Fixed. Question closed from IOLib.h:177-181; T12 needs a measured relaunch signal (A25, T0.3). |
| AT-9 (minor) | In-process hop tagged as read | Fixed. Tagged G·T3; crossings "4, or 6 via kernel"; today's count also given both ways (§4.4). |
| AT-10 (minor) | Engine willSleep neutral overwritten by tap resync | Fixed. In TAP, postNeutral sets `holdNeutral` until SetPowerState(On), a tap Start or setForwarding(LIVE) (§6.2, §7). |
| AT-11 (minor) | Competing-personality scan too narrow | Fixed. `personality-scan.py` covers system kexts, plugins and DriverExtensions; measured today (2,863 personalities, one unrelated 6940 hit); production IOProbeScore 1000; re-run after macOS updates. |
| AT-12 (minor) | Citation errors | Fixed. Test counts (**M**), KeepAlive tagged R (plist:21-22), project.yml:42, SetProperties at iig:159-182, raw bytes in Plan C (§3.4). |
| FM-1 (major) | INERT still ran per-frame code; a tap crash kills the pad | Fixed. INERT = not opened; new COUNT state; R9 loop-breaker; cost stated in §1. |
| FM-2 (major) | Recovery waited synchronously on the tap queue | Fixed. Pad-only arbitration with an atomic `padSource`; the tap is reached only by registry + DispatchAsync; PowerObserver waits at most 1 s; R20 → reboot. Partly rejected: control-plane selectors stay on vhidQueue (DextClient.swift:6 confinement), because the dext no longer waits on the tap. |
| FM-3 (major) | Tap matches DextClient's lookup | Fixed in T3: `IOUserClass` added to the match, plus a unit test. Verified at DextClient.swift:93-97; vhid-check uses names only. |
| FM-4 (major) | F1 missed "frames arrive but nothing is posted" | Fixed. Registration and state read in one critical section; F6 output stall; `framesIgnored`; Low and LPW handled; §7 contradiction removed. |
| FM-5 (major) | Object lifetimes and the lock undefined | Fixed. +1 accessors; private registry lock, so no RPC can run under it (replaces thread-owner tracking, whose DriverKit API was not verified); DestroyPad order; tap `stopping` order (§4.3, §6.3, §6.4). |
| FM-6 (major) | destroyDevice/createDevice in LIVE; orphan pinned pad | Fixed in §6.3: destroy always unpins; a new pad starts UC/INERT; spec CRC gates arming; orphan timer 30 s. Rejected: "hello from a new owner drops to INERT", because it conflicts with SP-7's glitch-free restart; the orphan timer covers the case. |
| FM-7 (major) | = AT-2 | See AT-2. |
| FM-8 (major) | Watchdog exemption global | Fixed: per slot (§6.4), plus the T11 SIGSTOP key test. |
| FM-9 (major) | T0 cost and evidence validity | Fixed. One probe build sequencing decline then run; every line tagged build/crash/pid; a reboot budgeted per probe operation; separate PROBE_BUILD. |
| FM-10 (minor) | Probe touches DriverManager state; build-17 restore; sleep timer | Fixed. Separate ProbeExtensionRequester; T0-probe archive and the "never restore build 17 before count 0" rule; timer restored to its pre-test value (T0.1). |
| FM-11 (minor) | = AT-7 | See AT-7. |
| FM-12 (minor) | Stale sink dedupe after fallback | Fixed: `resetDeliveryState()` on TAP→UC, plus a TapSupervisorTests case; `holdNeutral` in the registry. |
| FM-13 (minor) | Breaker live drill impossible | Fixed: covered by TapSupervisorTests; T0.3 gives the real relaunch pattern; no live drill (T6). |
| FM-14 (minor) | "No 955 Hz wakes" claim false | Fixed in the summary and §1: the engine still reads at about 955 Hz as hot standby. |
| FM-15 (minor) | Rumble latch after a crash | Fixed in T10: zero-rumble at tap Start and Open, plus a stop-only engine write on a nonce change (a narrow exception to SP-21). |
| SP-1 (major) | Upgrade row: build-xcode.sh does not replace the dext | Fixed with exact steps U1–U7 (§7.1). Partly rejected: `--engine-install` was not used, because engine mode ignores `--dev-terminate-driver` (DriverManager.swift:126-127); the swap runs from an in-app GUI with devTerminate instead. |
| SP-2 (major) | = AT-1 | See AT-1. T0.1.6 is now the literal command. |
| SP-3 (major) | DEBUG-gated drills absent from Release | Fixed. DEV_PAUSE_TAP is a runtime flag, GDH_SYNC is always on, tap decline is a non-DEBUG define; replacement budget restated. |
| SP-4 (major) | One-shot engine invocations cannot run | Fixed. `tapDrill` defaults key; `--engine-foreground --release-pad` after bootout; launch argument dropped. Verified at EngineMain.swift:18-22. |
| SP-5 (major) | devTerminate does not relaunch | Fixed. Fuse checked during the L8 upgrade drill (T5); breaker in unit tests. |
| SP-6 (major) | LIVE code first ran in a no-dext-change phase | Fixed. LIVE dext and engine code ship together in T7, with one fix replacement budgeted; phases renumbered. |
| SP-7 (major) | Engine restart in LIVE not glitch-free | Fixed. `createDevice2` returns `adopted`; the sink skips the neutral; startup stays LIVE; RT-hold kill test. |
| SP-8 (major) | = FM-14 | See FM-14. |
| SP-9 (major) | Game Mode check could pass while paused | Fixed: start/end-bounded procedure (§9.2). |
| SP-10 (major) | G4 ambiguous | Fixed. G4a and G4b on named padlat metrics, same-session A/B, ≥ 0.2 ms; baselines for context only. |
| SP-11 (major) | Conflict with the output-layer plan | Fixed. §2.4 row; 2 OR'ed sources in v1; `.unsupported` → engine path with a Driver-menu reason; one replacement per new primitive. |
| SP-12 (major) | In-app fallback vs pinned LIVE | Fixed: unsupervised DextClients send INERT; §5.7 row; DriverManagerModeTests case. |
| SP-13 (major) | T0.4 optional; single power cycle checks | Fixed: crash drill mandatory (T0.3); soak S1 in T4, T5 and T7. |
| SP-14 (major) | Rollback not exact; lower version unproven | Fixed: §7.2 RB1–RB7; A23 proven in T0.4. |
| SP-15 (minor) | Oracle skipped the parser; sequences differ | Fixed: raw-report oracle through GamepadFrame.parse; sequence test; claim reworded (§5.1). |
| SP-16 (minor) | = FM-12 | See FM-12. |
| SP-17 (minor) | L2, §3.6 and G9 commands wrong | Fixed: `pgrep -lf '…VirtualHID$'` (verified today); `"$DEXT/Info.plist"`; G9 via the padlat CSV. |
| SP-18 (minor) | = AT-7 | See AT-7. |
| SP-19 (minor) | No way out if the gate fails | Fixed: R15 build without the tap personality after 4 weeks. |
| SP-20 (minor) | status2 over-built | Fixed. Histograms stay in the dext, read from the meter line; status2 ≤ 512 B. |
| SP-21 (minor) | Three undocumented contradictions | Fixed: §2.4 rows for R14, the D5 owner lookup and rumble ranks 6–7. |
| SP-22 (minor) | F2 had no grace | Fixed: grace = max(1 s, 3 × the T4-measured p99). |
| SP-23 (minor) | T1 had no pass; T2 tolerance too tight | Fixed. T1: cap p50 ≤ 0.05 ms and coalesced < 20 %. T2: microbenchmark plus A/B within ±0.15 ms. |

No reviewer claim was found false on checking. AT-6's correction was verified against the SDK, and FM-3's against DextClient.swift. Two suggested fixes were partly replaced, with reasons given in SP-1 and FM-2/FM-6.
