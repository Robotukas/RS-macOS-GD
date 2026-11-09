# GDHub output layer: implementation plan

*Target file: `docs/plans/output-layer-plan.md` · Written 2026-11-08 · Status: proposed, waiting on the decisions in §8*

## 1. Context

The user's goal, in their words: *"steam, shadow pc and geforce now must see"* the SCUF Envision Pro. It must *"work with keyboard mapping or xbox mapping"* and *"have function like macros"*.

**Where GDHub is today.** GDHub reads the Slipstream receiver over IOHIDManager. It reads 1B1C:3A08 when the controller is linked and 1B1C:3A09 when the receiver is idle. It decodes report 0x06 into `GamepadFrame` and has a learned `ControlMapping` that includes paddles and SAX as extra bits 0–5 (`docs/protocol/envision-pro-receiver.md`). It produces no output of any kind.

**What this plan relies on.** Facts checked locally are marked *local*. Web sources are linked.

**What the hosts accept**
- **The hosts never see the raw receiver.** Its primary usage page is 0xFF58. SDL's IOKit backend requires Generic Desktop as the primary page, and GameController does not see the receiver either. Steam's `logs/controller.txt` and GFN's `geronimo.log` contain no 1B1C or SCUF entry (*local*). The only way to make a host "see" the controller is a **virtual pad**, or **USB-forwarding the receiver** into the Shadow VM.
- **All three hosts read pads through SDL**, and also through the GameController/MFi path. Steam bundles SDL3 3.4.0-1576. GeForce NOW bundles `SDL2.framework` 2.32.10, plus a GameController-only backend called "Forge" that a remote flag can switch on. Shadow's `ShadowPCDisplay` statically links SDL2 2.24.2 (*local*: otool and strings). A virtual pad therefore has to satisfy the oldest of these, SDL2 2.24.2, and also GameController.
- **GameController accepts a *virtual* HID pad only if its personality has `GCIOMatchVirtual=true`.** On macOS 27 that is 14 VID:PIDs, including 045E:0B13, 0B20, the Elite 2 IDs 0B05/0B22, DS4 and DualSense. 045E:028E is not on the list (*local*: `AppleGameControllerPersonality.kext/Contents/Info.plist`).
- **SDL2 picks its report path by PID, SDL3 by transport.** In SDL2, both 2.24 and 2.32, the HIDAPI Xbox One driver decides whether a pad is Bluetooth from its PID, so a 0B13 pad is parsed as BT report 0x01. SDL3 decides from the transport, so a "Virtual" transport sends it down the GIP 0x20 path ([2.32 source](https://raw.githubusercontent.com/libsdl-org/SDL/release-2.32.x/src/joystick/hidapi/SDL_hidapi_xboxone.c), [2.24 source](https://raw.githubusercontent.com/libsdl-org/SDL/release-2.24.x/src/joystick/hidapi/SDL_hidapi_xboxone.c)).
  - This is why OJD's two identities behave differently: its 0B0C identity works in Steam, and its 0B13 identity works in GameController apps ([OJD wiki](https://github.com/xsyetopz/OpenJoystickDriver/wiki/Playing-Games)).
  - A dual-collection 0B13 descriptor (0x01 + GIP 0x20) is the best single recipe for a virtual pad ([libvirtualhid PR #208](https://github.com/LizardByte/libvirtualhid/pull/208)), but nobody has tested it in Steam.

**What publishing a pad requires**
- **There are only four ways to publish a pad**, each with its own account requirement:
  - **CoreHID `hid.virtual.device`**: restricted, has no development variant, and approval has taken anywhere from days to months ([thread 820708](https://developer.apple.com/forums/thread/820708), [thread 845599](https://developer.apple.com/forums/thread/845599)).
  - **Your own DriverKit dext** with the development-only entitlements: self-serve on a paid account, but it runs only on Macs registered in the profile ([thread 818358](https://developer.apple.com/forums/thread/818358)). A dext needs `driverkit` + `driverkit.family.hid.device` ([thread 843327](https://developer.apple.com/forums/thread/843327)).
  - **On a free account**, a dext loads only with SIP off and usually AMFI off as well ([thread 847647](https://developer.apple.com/forums/thread/847647)). That is not acceptable on this Mac.
  - **OpenJoystickDriver (OJD)**, which is already installed and Developer ID–signed with `hid.virtual.device`, can publish the pad for us (*local*: codesign).

**Signing and installed software on this Mac**
- **This Mac has no app signing identity.** The keychain holds only "Apple Configurator: INTERLINKED GROUP LTD". There is no Apple Development or Developer ID certificate and no Xcode account (*local*).
- **`scripts/bundle.sh` ad-hoc signs every build** (`codesign --sign -`), so a TCC grant such as PostEvent will not survive a rebuild.
- **OJD 0.5.0-beta.4 already has a full headless mapping CLI.** I checked this read-only today in the binary's help strings:
  - `compat show|reset|set <generic-hid|sdl2-3|apple-gamecontroller|xbox360-hid|dualshock4|dualsense|switchpro>`
  - `controller state|watch|trace|disconnect|resume`
  - `map list|show|create <name> --vid --pid (--target-app <bundle-id>|--global)`, and `map bind|unbind|import|export|enable|disable`
  - `map chord add`, `sequence add`, and `layer create --mode hold|toggle`
  - Binding behaviours: `--behavior hold|toggle|tap_on_press|tap_on_release|pulse|press|release`, plus `--long-hold`, `--double-tap`, and `--turbo-rate/--turbo-duty` (keyboard and mouse targets only)
  - Stick modes: aim, flick, pointer, scroll, with curves linear, ease_in, ease_out, smooth_step
  - Output policy: `--virtual-gamepad disabled|mapped|passthrough` and `--physical-input shared|exclusive`. The help text says "Virtual gamepad output requires exclusive physical input ownership."
  - Targets: `key:<k>[:mods=…]`, `mouse:<b>`, `move:x|y`, `scroll:x|y`, `gamepad:button|dpad|axis:<name>`
  - There is no timed macro step. `--actions-json` exists, but I could not verify what it does.
  - The bundled SCUF records are 0.5-schema `GenericHID` records for 2E95 only. There is none for 1B1C, and the folder for user records does not exist yet.
- **Other software on this Mac affects the hosts:**
  - Razer's dext publishes a non-virtual 045E:028E v0x0114 pad with Transport USB, which is a phantom pad in the hosts.
  - ShadowUSB (a root LaunchDaemon) has already auto-forwarded this receiver into the Shadow VM. Its log `/var/log/tech.shadow.shadowusb.daemon.log` is world-readable.
  - GFN reads the keyboard and mouse as raw IOHID (`HIDKeyboardManager` and `HIDRawMouseManager` are enabled), so keystrokes injected with CGEvent probably do not reach a GFN stream while "Direct mouse input" is on ([NVIDIA a_id 4868](https://nvidia.custhelp.com/app/answers/detail/a_id/4868)).
  - Posting CGEvents needs only the user's PostEvent approval, not an entitlement ([thread 724603](https://developer.apple.com/forums/thread/724603)).

---

## 2. Decision summary

### 2.1 Routes

| Route | Account | Who owns the receiver | Steam sees pad | GFN sees pad | Shadow sees pad | Xbox remap | Keyboard mapping | Timed macros |
|---|---|---|---|---|---|---|---|---|
| **R1 OJD pad, configured by GDHub** | Free (works now) | OJD (exclusive) | ✓ `sdl2-3` (wiki-verified) | ✓ expected with `apple-gamecontroller`, P0 confirms | ✓ expected with `apple-gamecontroller` | ✓ OJD `map` (incl. layers, chords, long/double, turbo) | ✓ OJD `key:` targets | Partial: GDHub runs them through the "macro trigger key" bridge (§3.6), speculative |
| **R2 GDHub engine, keyboard/mouse output** | Free | GDHub | — (no pad) | — | — | — | ✓ CGEvent. For GFN, Direct mouse input must be off, or use Karabiner (R2+) | ✓ full |
| **R3 GDHub engine + own DriverKit dext** (pad + NKRO keyboard + pointer) | Paid | GDHub | ✓ identity from the P0/P7 matrix | ✓ | ✓ | ✓ full | ✓ full, including GFN raw HID | ✓ full, including pad steps |
| **R4 ShadowUSB forward** | Free | ShadowUSB (whole USB device) | — | — | ✓ native Windows drivers/iCUE in the VM | in-VM iCUE | in-VM | in-VM |
| R5 CoreHID publisher | Paid + Apple approval | GDHub | Replaces R3 later, only to distribute to other Macs | | | | | |

**The fork, stated plainly**

- **Free account (or not yet known).** You get a visible controller in all three hosts **tonight** through R1, and GDHub becomes its control panel: identity per host, remaps, keyboard binds, layers. Keyboard-only profiles and full timed macros come from GDHub's own engine (R2). The one limit: **while OJD publishes the pad, GDHub cannot read the receiver**, because OJD needs exclusive ownership. Pad remapping is therefore limited to what OJD's `map` can express. GDHub's own timed macros work alongside the visible pad only if the trigger-key bridge in P0.8 passes.
- **Paid account ($99 ADP, Account Holder or Admin role).** GDHub owns everything (R3): one dext publishes a pad with a data-driven identity, plus a keyboard and a pointer. There is no OJD dependency and no Karabiner. It runs on this Mac only until Apple approves distribution entitlements.

**What you need to do**

| Step | Free | Paid |
|---|---|---|
| Stable signing identity (keeps Accessibility/PostEvent grants across rebuilds) | Either create a self-signed "Code Signing" certificate in Keychain Access → Certificate Assistant, or add your Apple ID in Xcode → Settings → Accounts (Personal Team), then `export GDHUB_SIGN_IDENTITY="…"` | Sign Xcode into the ADP team. Let it register this Mac and create the Apple Development certificate |
| OJD | Allow GDHub to write an OJD controller record and OJD map profiles. Grant OJD Input Monitoring + Accessibility if it asks (`--headless permissions request`) | Optional. Used only in P0 |
| Approve System Extension | Only if you choose Karabiner (P6): approve it under System Settings → General → Login Items & Extensions → Driver Extensions | Approve **GDHub Virtual HID** at the same place, after GDHub.app is installed in `/Applications` |
| Developer portal | — | Create App IDs `com.interlinked.gdhub` and `com.interlinked.gdhub.VirtualHID` with the DriverKit **development** capabilities: DriverKit, Family HID Device, Allow Any UserClient (development), and System Extension on the app. Create a DriverKit development profile, which needs the Account Holder or Admin role ([Apple help](https://developer.apple.com/help/account/provisioning-profiles/create-a-driverkit-development-provisioning-profile/)) |
| Entitlement requests (optional, for distribution only) | — | File the CoreHID `hid.virtual.device` request and the DriverKit HID distribution request (https://developer.apple.com/system-extensions/) on the day you start P7. Don't wait for them |
| Permissions in GDHub | Accessibility (PostEvent) for output. Input Monitoring only for the trigger-key bridge or for recording keyboard macros | Same |

### 2.2 Design decisions

1. **One owner of the receiver at a time:** GDHub, OJD or ShadowUSB. GDHub detects the current owner, shows it, and hands ownership over explicitly (`controller disconnect` / `controller resume`). It never fights for the device. Ownership changes only when a host app launches, never in the middle of a stream.
2. **The engine never depends on the output.** `MappingCore` decides what happens and `OutputSink`s deliver it. Profiles compile to whichever backend owns the receiver (GDHub engine or OJD), and each backend declares its capabilities. The UI greys out anything the active backend cannot do and says why.
3. **The pad identity is data, not code.** The P0 matrix decides the OJD identity for each host. The P7 dext takes VID, PID, version, transport, serial and descriptor from the app, so changing identity needs no driver rebuild.
4. **Never use** 045E:028E with version 0 or 1 (Steam-virtual markers), the name "GamePad-N", or two publishers at once. GDHub's own devices carry serial `GDHub-<n>`.
5. **No seizing of the gamepad interface (FF58).** No host sees it, and seizing would lock out OJD and iCUE. GDHub seizes the Consumer interface only when G2–G4 are remapped, so they stop changing the system volume.
   - *Note (receiver takeover, T4):* the intent is unchanged. GDHub never seizes the 0xFF58 IOHIDDevice from user space. What the dext's `GDHubReceiverTap` takes is the receiver's interface 3 `IOHIDInterface` (the kernel object under that device), which Apple's own event driver held before; user-space readers (the engine, the GUI, OJD's reader) keep their `IOHIDDevice` and their data. The tap opens that interface only while an owner has asked for `inputPath = count` (T4 counts frames and posts nothing). Interface 4 (battery, Consumer page) is not matched. See `docs/plans/receiver-takeover-plan.md` section 2.4.
6. **Keys are stored as HID usages** (page 0x07, plus 0x0C for media keys). The CGEvent sink converts to `kVK` codes; the dext and Karabiner use the usages directly. The UI shows names for the current layout via `UCKeyTranslate`. The layout here is British ISO, so test the §/` swap.
7. **`ControlMapping` and `LearnSession` stay the input-decoding layer.** Output bindings live in separate, versioned profile files and are never written into `envision-pro-mapping.json`.

---

## 3. Architecture additions

### 3.1 Data flow

```
IOHID (hidQueue, timestamped) ──► EnvisionProInputAdapter ──► PhysicalSnapshot
   │                                                              │
   └─(8 ms throttle)─► MainActor UI / LearnSession                ▼
                                   EchoResolver → AnalogConditioner (derived controls: left_stick.up, rt.full, …)
                                   → edge detect → LayerStack (binding owned at press time) → ActivatorMachine
                                   → Scheduler (min-heap, 1 ms strict timer) → MacroPlayer → OutputAccumulator (refcounts)
                                   → OutputDiff ─► CGEventSink | KarabinerSink | DextHIDSink(keyboard/pointer) | VirtualPadSink
Profile (MainActor edits) ─compile─► CompiledProfile ─► MappingEngine (GDHub owner)
                                                     └► OJDProfileCompiler → `OJD --headless map import/enable` (OJD owner)
```

> **Note (receiver takeover, T6).** This pipeline stays the engine's. The driver's own translator (`Shared/GDHubXlate.c`, GDHM v1) runs only what a mapping blob can say: stateless rules with at most two OR'ed sources per output item. Anything else, including the done-check remap "paddle_outer_right -> Y" with echo suppression, `MapBlobEncoder` refuses (`.unsupported(reason)`), and that mapping runs on this pipeline, i.e. on the engine path. The Driver menu then shows `Input path: App (mapping needs GDHM v2: <reason>)`. Each new in-driver primitive costs one driver replacement. In T6 the engine posts in every input-path mode; `shadow` only lets the driver translate the same frames for comparison.

### 3.2 Files under `Sources/GDHub` (new unless marked *mod*)

```
App.swift (mod)                          create MappingEngine, HostEnvironment, ProfileRouter; menu-bar profile pin
HID/HIDMonitor.swift (mod)               hidQueue: IOHIDManagerSetDispatchQueue + IOHIDManagerActivate + cancel handler;
                                         per device IOHIDDeviceSetDispatchQueue + RegisterInputReportWithTimeStampCallback
                                         + IOHIDDeviceActivate (remove all CFRunLoop scheduling, header forbids mixing);
                                         onRawReport on hidQueue; open/close per interface (seize option); setReport()
HID/ReportCapture.swift                  .gdcap writer/reader (mach timestamp + bytes) in ~/Library/Application Support/GDHub/captures
Devices/DeviceModule.swift (mod)         + protocol MappableDevice { nonisolated func makeInputAdapter() -> EngineInputAdapter }
Devices/EnvisionPro/EnvisionProInputAdapter.swift  GamepadFrame + ControlMapping snapshot → PhysicalSnapshot
Devices/EnvisionPro/EchoResolver.swift   paddle/SAX echo suppression (B3Mac edge rule); also used by ControlMapping.isActive
Devices/EnvisionPro/EnvisionProDevice.swift (mod)  Status + .ownedByOJD, .forwardedToShadow; pushes mapping copies to engine
Engine/PhysicalSnapshot.swift            t: UInt64 (mach), digital: Set<ControlID>, triggers 0…1, sticks −1…1 (y down+)
Engine/AnalogConditioner.swift           scaled-radial deadzones, curves, stick→directions/mouse/scroll/ring, trigger soft/full + hysteresis
Engine/ActivatorMachine.swift            press/start/release/long/double/triple/chord, toggle, turbo, delays, interruptible, cycle
Engine/LayerStack.swift                  hold/toggle/oneShot/switchBase, sparse inherit, .block
Engine/Scheduler.swift                   min-heap of due items; DispatchSourceTimer(.strict, 1 ms), suspended when idle
Engine/MacroPlayer.swift                 per-instance output ownership, repeat/retrigger policies, cancel
Engine/OutputAccumulator.swift           refcount per OutputKey, axis contributions, per-tick mouse/scroll sums → OutputDiff
Engine/CompiledProfile.swift             flatten layers, resolve macros, detect cycles and no-way-back layers, clamp timings,
                                         validate against BackendCapabilities
Engine/MappingCore.swift                 pure: mutating func step(_ s: PhysicalSnapshot?, now: UInt64) -> [OutputEvent]
Engine/MappingEngine.swift               owns hidQueue state, timer, sinks, failsafes, emergency chord, os_signpost
Engine/HeldJournal.swift                 held.json of currently-down outputs; replayed as key-ups at next launch (crash safety)
Output/OutputSink.swift                  protocol OutputSink: AnyObject { func apply(_ d: OutputDiff, at t: UInt64); func releaseAll();
                                         var capabilities: SinkCaps { get } }
Output/KeyCodes.swift                    HID usage ↔ kVK (ISO §/` swap), display names via UCKeyTranslate
Output/CGEventSink.swift                 .hidSystemState source, post at .cghidEventTap, flagsChanged for modifiers, *Dragged
                                         while a button is held, kCGMouseEventDeltaX/Y + clamped location, subpixel carry,
                                         kCGEventSourceUserData = 'GDHU', min tap 20 ms
Output/KarabinerSink.swift               client of gdhub-vhid-helper (P6, free only)
Output/VirtualPad/PadState.swift         XInput-style state (y up+), buttons, triggers
Output/VirtualPad/PadIdentity.swift      catalog: x360-usb (045E:028E v0x0114), xbox-bt-dual (045E:0B13 v0x0513), generic
Output/VirtualPad/PadReportBuilders.swift 360Controller 20-byte report; Xbox BT 0x01; GIP 0x20 (pure, unit-tested)
Output/VirtualPad/VirtualPadSink.swift   send on change + keepalive ≤250 Hz; neutral across controller sleep; rumble → SCUF out 0x09
Output/VirtualPad/DextClient.swift       IOServiceOpen on GDHubVirtualHID user client: hello/create/send/destroy/readOutput (P7)
Profiles/Profile.swift, Macro.swift      model in §3.4, explicit "type" discriminators (custom Codable, never synthesized `_0`)
Profiles/ProfileStore.swift              profiles/<uuid>.json + profiles/index.json (rule order, default, fallback); atomic, 40 backups
Profiles/ProfileRouter.swift             NSWorkspace didLaunch/didActivate; bundle id rules + opt-in AX window-title regex
Profiles/DefaultProfiles.swift           "Desktop", "WASD + mouse", "Xbox 1:1", "Steam passthrough"
Profiles/MacroRecorder.swift             controller edges → down/up/wait steps; quantize 1/5/10 ms; trim idle
Host/HostEnvironment.swift               receiver owner (gdhub|ojd|shadowUSB|none), installed hosts, phantom pads
Host/ShadowUSBWatcher.swift              tails /var/log/tech.shadow.shadowusb.daemon.log ("Automatically forwarding device : SCUF…",
                                         "Successfully unforwarded") + 3A08 disappearance
Host/OJDBridge.swift                     runs /Applications/OpenJoystickDriver.app/Contents/MacOS/OpenJoystickDriver --headless …
                                         (compat set/show, controller state/disconnect/resume, map import/enable/export); writes the
                                         1b1c record with consent; never mid-stream
Host/OJDProfileCompiler.swift            CompiledProfile → OJD map JSON / bind commands; unsupported features listed
Host/MacroTriggerBridge.swift            active CGEventTap swallowing F13–F19(+mods) emitted by OJD → runs GDHub macros (§3.6)
Host/PhantomPadDetector.swift            IOHIDManager on GD 1/4, 1/5: VID/PID/Transport/HIDVirtualDevice/serial; flags Razer
                                         028E + 1532:27DB, Steam "GamePad-N", OJD pads, ours ("GDHub-…")
Host/SteamConfigReader.swift             read-only config.vdf: stale SDL_GamepadBind for the active pad GUID → warning
Host/Permissions.swift                   CGPreflight/RequestPostEventAccess, IOHIDCheckAccess, AXIsProcessTrusted, sysext state
UI/ControllerView.swift (mod)            mode picker Live | Learn | Assign; HotspotView.onTap routed by mode; callouts show
                                         binding summary in the shown layer's colour; latency badge on disambiguating controls
UI/AssignInspector.swift, StickZoneEditor.swift, TriggerZoneEditor.swift, LayerBar.swift, MacroEditorView.swift,
UI/ProfilesView.swift, OutputMonitorView.swift, HostStatusView.swift (owner chip, per-host checklist, permission banners)
```

**Outside SwiftPM:**
- `project.yml` (XcodeGen) defines the GDHub.app target and its entitlements, and later the dext target. `Package.swift` stays for `swift build` and `swift test`.
- `scripts/bundle.sh` (*mod*) signs with `$GDHUB_SIGN_IDENTITY` and bumps `CFBundleVersion` on every build.
- `Driver/GDHubVirtualHID/` (P7):
  - `GDHubRoot.iig/.cpp`: an IOService on IOUserResources.
  - `GDHubUserClient.iig/.cpp`
  - `GDHubHIDDevice.iig/.cpp`: an IOUserHIDDevice whose properties and descriptor come from the client.
  - `Info.plist` and `GDHubVirtualHID.entitlements`.
- `Helpers/gdhub-vhid-helper/` (P6): a C++23 root daemon around Karabiner's `client.hpp`.
- `Tools/gcprobe.swift` lists the `GCController.controllers()` entries.
- `scripts/vhid-check.sh` filters ioreg output.
- `Tools/sdl-harness/` (optional) builds `testcontroller` from SDL2 2.24.2, SDL2 2.32.10 and SDL3 3.4.x at pinned tags. Downloading them needs your approval.

**Tests (`Tests/GDHubTests`):** EchoResolverTests, MappingCoreGoldenTests (replays `.gdcap`), ActivatorMachineTests, LayerStackTests, MacroPlayerTests, OutputAccumulatorTests, ProfileCodingTests, OJDProfileCompilerTests, PadReportBuilderTests, KeyCodesTests, and DextProtocolVersionTests (the header version must match Swift).

### 3.3 Ownership state machine

| State | How it's detected | What GDHub does |
|---|---|---|
| `gdhub` | GDHub has the if3 handle and reports are arriving | The engine runs. OJD is suspended with `controller disconnect` if it is running |
| `ojd` | OJD process is running, `controller state` lists 1b1c:3a08, and GDHub gets no reports while the controller is awake | Close GDHub's if3 handles. The engine is inactive and the profile is compiled to OJD. The live view is optional, fed from `controller watch` |
| `shadowUSB` | The receiver is gone from the IORegistry, and the daemon log's last line for the SCUF is "Automatically forwarding" | Show "Forwarded to Shadow PC". Warn that a 3A08↔3A09 flip drops the forward |
| `none` | Receiver absent | — |

A profile's `backend` field selects the owner it wants. `ProfileRouter` switches owner only when a host app launches or GDHub is frontmost.

### 3.4 Data model (Swift)

```swift
typealias ControlID = String   // layout ids ("a", "paddle_outer_left", "sax_right", "left_stick", "rt" …)
                               // + derived: "left_stick.up|down|left|right", "left_stick.ring", "lt.soft", "lt.full"
enum Backend: String, Codable { case gdhub, ojd }              // who should own the receiver for this profile
enum OutputMode: String, Codable { case keyboardMouse, xbox, mixed }
enum KeySinkKind: String, Codable { case cgEvent, virtualHID } // virtualHID = Karabiner (free) or GDHub dext (paid)

struct Profile: Codable, Identifiable {
  var schemaVersion = 1
  var id: UUID; var name: String; var device = "envision-pro"
  var match: [AppRule]                  // empty = manual only
  var backend: Backend; var output: OutputMode
  var padIdentity: String?              // backend .gdhub: "x360-usb" | "xbox-bt-dual" | "generic"
  var ojdIdentity: String?              // backend .ojd: "sdl2-3" | "apple-gamecontroller" | "xbox360-hid" | …
  var keySink: KeySinkKind
  var timing = TimingDefaults()
  var layers: [Layer]                   // [0] = base
  var macros: [Macro]
  var seizeConsumer = false
}
struct AppRule: Codable { var bundleId: String; var windowTitle: String? }   // regex; title needs AX opt-in
struct TimingDefaults: Codable { var tapHoldMs = 30, longPressMs = 300, doubleTapMs = 250, tripleTapMs = 350,
                                 turboPeriodMs = 80; var hysteresis = 0.03 }
struct Layer: Codable, Identifiable { var id: String; var name: String; var color: String
  var releaseHeldOnEnter = false        // true = Steam "action layer" style; false = mode-shift style
  var assignments: [ControlID: ControlAssignment] }   // sparse: missing key inherits from the layer below
enum ControlAssignment: Codable { case digital([Activator]), trigger(TriggerAssignment), stick(StickAssignment), block }

struct Activator: Codable, Identifiable {
  var id: UUID; var on: ActivatorKind; var actions: [Action]
  var toggle = false; var turbo: Turbo?; var interruptible = true
  var startDelayMs = 0, endDelayMs = 0; var cycle = false; var cycleResetMs: Int?
}
enum ActivatorKind: Codable { case press, start, release, long(ms: Int?), double(windowMs: Int?), triple(windowMs: Int?),
                              chord(with: ControlID) }
struct Turbo: Codable { var periodMs: Int; var dutyPct = 50 }
enum Action: Codable {
  case pad(PadButton), padAxis(PadAxis, value: Double, mode: AxisMode)
  case key(KeyChord), mouseButton(MouseButton), scroll(dx: Int, dy: Int)
  case macro(UUID), layer(String, LayerMode), profile(ProfileSwitch), passthrough, none
}
struct KeyChord: Codable, Hashable { var page: UInt16 = 0x07; var usage: UInt16; var modifiers: Set<Modifier> }
enum PadButton: String, Codable { case a, b, x, y, lb, rb, view, menu, guide, share, ls, rs, dpadUp, dpadDown, dpadLeft, dpadRight }
enum PadAxis: String, Codable { case lx, ly, rx, ry, lt, rt }
enum AxisMode: String, Codable { case absolute, relative }
enum LayerMode: String, Codable { case hold, toggle, oneShot, switchBase }
enum ProfileSwitch: Codable { case next, previous, id(UUID) }

struct StickAssignment: Codable {
  var mode: StickMode                   // .pad(left|right, swap) | .directions(ways: 4|8, threshold: 0.35)
                                        // | .mouse(speedPxPerSec: 1500, accelRampMs: 0) | .scroll(linesPerSec) | .none
  var deadzone = Deadzone(inner: 0.08, outer: 0.97, shape: .scaledRadial)
  var antiDeadzone = 0.0                // pad output only
  var curve: Curve = .linear; var sensitivity = 1.0; var invertX = false, invertY = false
  var ringRadius: Double?               // emits "<stick>.ring"
}
enum Curve: Codable { case linear, enhancedPrecision, quadratic, cubic, power(Double), bezier(Double, Double, Double, Double) }
struct TriggerAssignment: Codable {
  var output: PadAxis?                  // .lt/.rt passthrough, or nil
  var deadzone = 0.02, maxZone = 0.98; var curve: Curve = .linear
  var softPoint = 0.30, fullPoint = 0.95; var hipFire: HipFire = .off   // .off | .normal(ms) | .exclusive(ms)
}
struct Macro: Codable, Identifiable {
  var id: UUID; var name: String; var steps: [MacroStep]
  var mode: MacroMode                   // .executeAtOnce | .holdUntilRelease
  var repeatPolicy: MacroRepeat         // .once | .count(Int) | .whileHeld | .toggle
  var repeatGapMs = 0, stepGapMs = 0    // editor warns below 20 ms
  var retrigger: Retrigger = .ignore    // .ignore | .restart | .queueOne | .stop
  var cancelOnLayerChange = false       // always cancelled on profile change
}
indirect enum MacroStep: Codable {
  case down(OutputKey), up(OutputKey), tap(OutputKey, holdMs: Int), wait(ms: Int), waitForNextPress
  case axis(PadAxis, value: Double, mode: AxisMode, holdMs: Int?)
  case mouseMove(dx: Int, dy: Int, overMs: Int), scroll(dx: Int, dy: Int), text(String)
  case rumble(ms: Int, strength: Double), layer(String, LayerMode), loop(count: Int, steps: [MacroStep]), releaseAll
}
enum OutputKey: Codable, Hashable { case pad(PadButton), key(KeyChord), mouse(MouseButton) }
```

**JSON shape.** Every enum has a `"type"` discriminator. An abbreviated example:

```json
{"schemaVersion":1,"name":"WASD + mouse","backend":"gdhub","output":"keyboardMouse","keySink":"cgEvent","match":[{"bundleId":"com.blade.shadow-macos"}],"layers":[{"id":"base","name":"Base","color":"yellow","assignments":{"a":{"type":"digital","activators":[{"on":{"type":"press"},"actions":[{"type":"key","usage":44}]}]},"left_stick":{"type":"stick","mode":{"type":"directions","ways":8,"threshold":0.35},"deadzone":{"inner":0.15,"outer":0.97,"shape":"scaledRadial"}},"left_stick.up":{"type":"digital","activators":[{"on":{"type":"press"},"actions":[{"type":"key","usage":26}]}]},"right_stick":{"type":"stick","mode":{"type":"mouse","speedPxPerSec":1600},"curve":{"type":"power","value":2}},"rt.full":{"type":"digital","activators":[{"on":{"type":"press"},"actions":[{"type":"mouseButton","button":"left"}]}]}}}],"macros":[]}
```

### 3.5 Engine rules

The activator semantics follow [Steam Input activators](https://partner.steamgames.com/doc/features/steam_controller/activators) and [reWASD](https://help.rewasd.com/basic-functions/activators.html).

- **Timing comes only from report timestamps.** Replaying a capture therefore gives byte-identical output.
- **Direct bindings add no latency** (target: report to post under 1 ms). Controls with long, double or triple activators hold back interruptible presses until their window closes, and the UI marks them with a badge. Start fires first and release fires last.
- **Bindings are resolved against the layer stack at press time.** The instance that handled the press owns it until release, so a layer change never strands or retriggers a held output, unless `releaseHeldOnEnter` is set.
- **Outputs are reference-counted across sources** (bindings, macros, turbo). A down is sent on 0→1 and an up on 1→0. Taps last at least 20 ms.
- **Echo suppression.** A standard button or hat direction that rises within N reports of a paddle or SAX extra-bit edge is attributed to that paddle until it is released ([B3Mac rule](https://raw.githubusercontent.com/B3Mac/ScufEnvisionPro_macOS/main/Sources/ScufCore/EnvisionDecoder.swift)). Start with N = 2; the P1 captures set the real value.
- **Failsafes call `releaseAll()`** on:
  - 150 ms without a report
  - 3A08 → 3A09
  - device removal
  - an owner change
  - sleep or screen lock
  - a profile switch
  - PostEvent being revoked
  - app quit
  - a crash: replay `held.json` at the next launch
  - the emergency chord, View + Menu + Profile held for 2 s, which also disables mapping
- **Own-window guard.** GDHub sends no output while it is frontmost, unless Test mode is on.
- **Mixed mode.** A control bound to a key is left neutral in the pad report. In `.keyboardMouse` mode no pad is published at all.
- **Profile button 17 is unbound by default**, because it also switches the onboard profile.

### 3.6 Backend capabilities (what the UI allows per profile)

| Feature | GDHub + CGEvent (free) | GDHub + dext (paid) | OJD backend (free) |
|---|---|---|---|
| Visible pad | — | ✓ | ✓ (identity per host) |
| Xbox remap, any control | — | ✓ | ✓ for controls OJD can read. Paddles and SAX appear only as their onboard echo (D-pad, A/B) unless an OJD 0.6 bit-offset record exposes extra bits 115–120 |
| Keys, mouse, scroll | ✓ | ✓ | ✓ |
| press/release/toggle, long, double, chord, layers | ✓ | ✓ | ✓ (mapped to `--behavior`, `--long-hold`, `--double-tap`, `chord add`, `layer create`) |
| triple, start/end delays, cycle, interruptible tuning | ✓ | ✓ | — (greyed out) |
| Turbo | ✓ | ✓ | keys and mouse only |
| Timed macros | ✓ | ✓ incl. pad steps | Via **MacroTriggerBridge**: the control is bound in OJD to an unused key (F13–F19 + modifiers). GDHub's active event tap swallows that key and plays the macro through CGEvent. Needs Accessibility + Input Monitoring, and P0.8 must pass |

---

## 4. Host acceptance procedure (H1–H7, used by every phase)

| # | Check | How |
|---|---|---|
| H1 | Exactly one new pad, with the intended keys | `ioreg -r -c IOHIDDevice -l \| grep -E '"(Product\|VendorID\|ProductID\|Transport\|HIDVirtualDevice\|SerialNumber)"'` (wrapped as `scripts/vhid-check.sh`) |
| H2 | GameController sees it (when the identity should) | `swift Tools/gcprobe.swift` lists name, productCategory, extendedGamepad |
| H3 | Steam | Settings → Controller test screen, every input. `grep -nE 'device opened\|Controller using\|type:' ~/Library/Application\ Support/Steam/logs/controller.txt \| tail -20`: one "device opened", and no second MFi copy (bus 05, 045e:02e0 or 05ac:0004) |
| H4 | GeForce NOW | Controller works in the in-stream overlay and in a game. `grep -nE 'Opened controller named\|Skipping (SDL\|Forge) gamepad' ~/Library/Application\ Support/NVIDIA/GeForceNOW/geronimo.log \| tail`: opened once, no "Skipping" line |
| H5 | Shadow PC | Alt+Cmd+O → Controllers & USB lists the pad. Inside the VM, `joy.cpl` shows one controller with every input |
| H6 | Duplicates and slots | Repeat H3–H5 with Razer's virtual controller on and off, and with Steam open and closed |
| H7 | Rumble | One game per host |

Results go into `docs/research/host-identity-matrix.md`. Re-run the matrix after any macOS, Steam, GFN or Shadow update, because SDL's macOS 27.4 GameController gate and GFN's Forge flag can change the results.

---

## 5. Phases

**Order if the account is free:** P0 → P1 → P2 → P3 → P4 → P5 → P6 → P8.
**Order if it is paid:** P0 → P1 → P2 (without 2c) → P3 → **P7** → P4 → P5 → P8. P6 is skipped because the dext keyboard replaces Karabiner.

**Model and effort (your rule).** Implementation runs on sonnet/medium. Delicate parts (HID threading, sinks, dext, root helper) run on sonnet/high. `swift build`, `swift test` and log greps run on haiku/low. Opus/high is used only for a bug sonnet cannot fix. No multi-agent fan-out.

### P0: Play tonight with the installed tools (no repo code; you perform the steps, Claude reads the logs; one evening)

1. Turn the controller on and keep it linked, so GDHub shows "Connected" (3A08). Then quit GDHub.
2. Set a shell variable: `OJD=/Applications/OpenJoystickDriver.app/Contents/MacOS/OpenJoystickDriver`. Run `$OJD --headless controller state`.
   - If 1b1c:3a08 is not listed, run `$OJD --headless diagnose report` to find the records folder. Then write `1b1c-3a08.json` in the 0.5 schema, mirroring the bundled `2e95-434d.json`: `{"vendorID":6940,"productID":14856,"transport":"hid","protocol":{"driver":"GenericHID","variant":"genericHID"}}`.
   - The 0.6 path is `~/Library/Application Support/OpenJoystickDriver/Controllers/` ([wiki](https://github.com/xsyetopz/OpenJoystickDriver/wiki/Controller-Records)). The 0.5 path is unverified.
3. Run `$OJD --headless controller watch` and press every control. Record:
   - the source names OJD uses (needed for 2c)
   - the Y-axis sign
   - whether buttons 11–17 appear
   - that paddles show up as the D-pad (factory echo)

   **If 0.5 misreads report 6**, upgrade to 0.6.0-alpha.2, which is PolyForm Noncommercial (fine for personal use; never bundle it). Write a v1alpha2 `HIDReportLayout` record:
   - report 6, length 16, bit 0 = LSB of the ID byte
   - X/Y/Z/Rz at bits 8/24/40/56, int16 LE, Y inverted
   - LT at bit 72 and RT at bit 82, 10 bits each
   - hat at bit 92, 4 bits, EightWay
   - buttons 1–19 at bits 96–114
   - paddles at 115–118 and SAX at 119–120
   - rumble on output 0x09, length 13
4. **Build the identity matrix.** For each `id` in `sdl2-3 apple-gamecontroller xbox360-hid dualshock4 generic-hid`, run `$OJD --headless compat set $id`, then H1–H6.
   - Expected: Steam works with `sdl2-3`, and GFN and Shadow work with `apple-gamecontroller` ([OJD wiki](https://github.com/xsyetopz/OpenJoystickDriver/wiki/Playing-Games)).
   - `dualshock4` is worth checking for GFN, which reports "Supports DS4: yes".
5. **OJD mapping smoke test.**
   - `map create "GDHub probe" --vid 0x1b1c --pid 0x3a08 --global --virtual-gamepad mapped --physical-input exclusive`
   - Bind G1 (button 12) to `gamepad:button:y`, and G2 to `key:r` with `--long-hold 500:key:t`.
   - Run `map enable`, then confirm in a Steam game.
   - Run `map export "GDHub probe" --output …` and keep the JSON. It is the schema sample for 2c.
   - Record what `--actions-json` accepts, and the exact syntax of `controller disconnect` and `controller resume`.
6. **Razer probe.** In the same sessions, note whether any host lists Razer's 045E:028E v0x0114 or its 1532:27DB pad. This is free evidence for the `x360-usb` identity in P7. If either takes a player slot, disable the Razer virtual driver (in Synapse, or under Driver Extensions).
7. **ShadowUSB trial** (Shadow only). Forward the receiver from Alt+Cmd+O, then check `joy.cpl`, Device Manager and iCUE inside the VM, paddles included. Note any audio-interface errors and the 3A08↔3A09 drops ([Shadow USB doc](https://support.shadow.tech/hc/en-us/articles/33567978572305-How-to-connect-a-USB-device-to-Shadow-PC)). Unforward afterwards.
8. **Trigger-key bridge probe.** Bind G5 to `key:f13` in OJD. Confirm that a key viewer sees F13 while OJD's pad stays visible in Steam. Note whether GFN's log shows a new keyboard device; if it does, OJD posts through a virtual HID keyboard.

**Exit:** you play one game each in Steam, GFN and Shadow with the SCUF. `docs/research/host-identity-matrix.md` is filled in. These decisions are recorded:
- paid account yes or no
- for Shadow: OJD pad or USB forward
- P0.8 pass or fail

### P1: Foundations (2–3 days)

**Scope**
- **Stable signing.** Add `project.yml` (XcodeGen). `bundle.sh` signs with `$GDHUB_SIGN_IDENTITY` and auto-increments `CFBundleVersion`.
- **Threading.** `HIDMonitor` moves to `hidQueue` with timestamped callbacks. The main-run-loop scheduling of both the manager and the devices (`HIDMonitor.swift` lines 76 and 120) is removed. UI and learning keep 8 ms MainActor delivery.
- **Captures.** Add `ReportCapture` and a replay harness. Capture 30 s of idle, and each paddle and SAX in onboard profiles 1–3. Write the idle report rate and the echo window into `docs/protocol/envision-pro-receiver.md`.
- **Echo suppression.** Add `EchoResolver`. `ControlMapping.isActive` uses it.
- **Host awareness.** Add `HostEnvironment`, `ShadowUSBWatcher`, `PhantomPadDetector`, `Permissions`, and `OJDBridge` (detection only). Add the owner chip in the device row.
- **CGEvent reachability spike.** A Debug menu item, "Send test input in 5 s", types `gdhub`, moves the mouse 200 px in 10 steps with deltas set, and left-clicks. All events are tagged.
- **Tools.** `Tools/gcprobe.swift` and `scripts/vhid-check.sh`.
- **Docs.** Fix `docs/ARCHITECTURE.md`: the "no virtual gamepad" non-goal, and the stale `LearnPanel.swift` entry.

**Verify**
- `swift test` is green, including a golden replay test.
- Pressing SAX-left lights only `sax_left`, not A.
- Starting OJD shows "In use by OpenJoystickDriver". A ShadowUSB forward shows "Forwarded to Shadow PC".
- `codesign -dv --verbose=4 .build/GDHub.app 2>&1 | grep Authority` shows a non-ad-hoc authority. `codesign -d -r- .build/GDHub.app` gives the same designated requirement across two rebuilds. The PostEvent grant survives a rebuild.
- **Spike matrix.** Run the spike in four setups:
  - TextEdit
  - GFN with Direct mouse input on
  - GFN with Direct mouse input off
  - Shadow, with Input Monitoring granted and with it denied for Shadow PC

  Record the results in the matrix doc. They decide whether P6 (Karabiner) or the dext keyboard is required.

### P2: Profiles, Assign UI, OJD backend (3–4 days; 2c only on the free path)

- **2a Model.** `Profile` and `Macro` with custom Codable, `ProfileStore`, `CompiledProfile` validation, `BackendCapabilities` (§3.6), `DefaultProfiles`.
- **2b UI, mockup first.** Per your rules, build mockups in `docs/mockups/` before writing UI code: `assign-mode.html`, `profiles.html`, `host-status.html`. Attach each HTML file in chat for mobile review, and implement only after you approve. Then build:
  - the Live | Learn | Assign picker
  - `AssignInspector` (activator list and action picker: Xbox grid, key capture, mouse, macro, layer, profile)
  - `StickZoneEditor` and `TriggerZoneEditor` drawn over the live dot and fill bar
  - `LayerBar`, `ProfilesView`, `HostStatusView` with per-host checklists
- **2c OJD backend.** `OJDProfileCompiler`, plus the `OJDBridge` actions, each behind a consent sheet:
  - write the 1b1c record
  - `compat set`
  - `map import` / `map enable`
  - the ownership hand-off with `controller disconnect` / `resume`

  Optional: a read-only live view fed from `controller watch`.

**Verify**
- `ProfileCodingTests` round-trip every case.
- `OJDProfileCompilerTests` against the JSON exported in P0.5.
- Create "Steam Xbox remap" (G1 → Y, G2 → R, long G2 → T) in GDHub and apply it. `$OJD --headless map show "Steam Xbox remap" --json` matches, and H3 shows G1 acting as Y.
- Unsupported features (triple, cycle) are greyed out with a reason when the backend is OJD.

### P3: GDHub engine and keyboard/mouse output (3–4 days; CGEventSink on sonnet/high)

- **Engine.** `MappingCore`, `MappingEngine`, `AnalogConditioner`, `OutputAccumulator`, `CGEventSink`, `KeyCodes`, `HeldJournal`, and `OutputMonitorView` next to `InputMonitorView`.
  - Stick → 4/8-way directions: inner deadzone 0.15, threshold 0.35.
  - Stick → mouse: inner 0.08, curve m^γ with γ = 2, subpixel carry, deltas always set.
  - Stick → scroll.
  - Triggers: soft 0.30, full 0.95, hysteresis 0.03 ([deadzone practice](https://www.gamedeveloper.com/disciplines/doing-thumbstick-dead-zones-right)).
- **Safety and UX.** Failsafes, the emergency chord, the own-window guard, a Secure Event Input banner, and the PostEvent permission flow (`CGPreflightPostEventAccess` / `CGRequestPostEventAccess`).

**Verify**
- The golden replay emits the expected events.
- `os_signpost` p99 from report to post is under 1 ms.
- TextEdit receives mapped keys, and a native Mac Steam game responds.
- In GFN with Direct mouse input off, keys and mouse-look reach a game. Also record the result with it on.
- Shadow: keys reach Notepad in the VM, and relative mouse works in a game.
- Switching the controller off while a key is held releases the key.
- After `kill -9` of GDHub mid-hold, the next launch releases the key.

### P4: Activators, layers, macros (4–5 days; sonnet/high)

- **ActivatorMachine.** Press, start, release, long, double, triple, chord, toggle, turbo, start and end delays, interruptible, cycle.
- **LayerStack.** Hold, toggle, oneShot and switchBase, with inheritance and `.block`.
- **Scheduler.**
- **MacroPlayer.**
  - Steps: down, up, tap, wait, waitForNextPress, text, mouseMove, scroll, layer, loop, releaseAll. Pad steps are defined but disabled until a pad sink exists.
  - Modes: executeAtOnce and holdUntilRelease, with repeat and retrigger policies.
- **Editing.** `MacroEditorView`, and `MacroRecorder` for controller edges.
- **Cycle checks** in `CompiledProfile`, plus a "no way back to base" warning.
- **Free path only:** `MacroTriggerBridge`, if P0.8 passed.
- **Macro UI note** about anti-cheat and terms of service. Macros are off in the default profiles.

**Verify**
- Unit tests on synthetic timestamped snapshots give exact sequences: long vs tap, double-tap, turbo period.
- The macro "R, wait 120 ms, right-click" shows in OutputMonitor within ±2 ms, and works in Notepad inside Shadow and in a GFN game.
- A 10-minute turbo soak leaves no stuck keys.
- Free path: with OJD's pad visible in Steam, G5 triggers a GDHub macro.

### P5: Auto-switch and host checklist (2 days)

- **`ProfileRouter`.**
  - Rules on bundle ids: `com.valvesoftware.steam`, `com.nvidia.gfnpc.mall`, `com.nvidia.gfnpc.streamer`, `com.electron.shadow`, `com.blade.shadow-macos`. GFN's `.gfnpc` shortcuts are deep links into the same app, so telling games apart needs the opt-in AX window-title regex.
  - Fallback: revert to default, or keep the last profile.
  - A menu-bar pin, and next/previous profile bindable to G-keys.
- **Owner and identity switching** happens only at host launch: `compat set <ojdIdentity>`, or the GDHub/OJD hand-off.
- **`SteamConfigReader`** warns about a stale `SDL_GamepadBind`.
- **Checklist entries:**
  - Steam: turn Steam Input for Xbox off when GDHub or OJD maps ([Valve](https://partner.steamgames.com/doc/features/steam_controller/steam_input_gamepad_emulation_bestpractices)).
  - GFN: remap paddles locally (the remote side is XInput), and show a hint about Direct mouse input.
  - Shadow: "forward OR virtual pad, never both", plus a warning about the saved ShadowUSB auto-forward.
  - Phantom pads.

**Verify**
- Launching GeForceNOW.app activates the GFN profile, and `compat show` reports `apple-gamecontroller` before the stream starts. H4 passes.
- Launching Steam sets `sdl2-3`, and H3 passes.
- Switching apps never leaves a key held.

### P6: Virtual HID keyboard and mouse via Karabiner (free only; 2–3 days; sonnet/high)

Run this only if the P1 spike shows CGEvent fails with GFN's Direct mouse input on, and you want to keep it on.

- **Components.** `KarabinerSink` plus `gdhub-vhid-helper`, a root LaunchDaemon installed through an admin-authorised `.pkg`. It talks over a root-owned Unix socket and checks the peer's audit token against GDHub's designated requirement ([Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice), Unlicense).
- **Protocol handling.** Pin `client_protocol_version` 7. Handle the version-mismatch, activated and connected signals.
- **Keyboard and pointer.** ISO keyboard type for the British layout. Pointer deltas are split to ±127 per report.
- **Sensitivity.** Separate presets for CGEvent and virtual HID.

**Verify**
- GFN with Direct mouse input on receives keys and mouse, and `geronimo.log` shows "Device added … Karabiner".
- A GCKeyboard probe sees the keys.
- The helper rejects an unsigned client.

### P7: Own virtual pad, keyboard and pointer via DriverKit (paid; 6–10 days; sonnet/high, opus/high only for a dext bug)

- **7a Dext.** `GDHubVirtualHID.dext`, an IOService on IOUserResources with a user client.
  - Selectors: `hello(version)`, then `create(spec)`, `send(id, bytes)`, `destroy`, and async `outputReport` for rumble.
  - It tears down all children on ClientClose, and sends a neutral report after 2 s of silence.
  - Dext entitlements: `com.apple.developer.driverkit`, `driverkit.family.hid.device`, and `driverkit.allow-any-userclient-access` (development). The dext checks the caller's Team ID itself.
  - App entitlements: `system-extension.install`, plus `driverkit.userclient-access` once granted ([thread 849054](https://developer.apple.com/forums/thread/849054)).
  - Activation uses `OSSystemExtensionRequest` from `/Applications/GDHub.app`, followed by an "Update driver" state when the version changes.
- **7b Pad.** `PadIdentity`, `PadReportBuilders`, `VirtualPadSink`. Product string "SCUF Envision Pro"; serial `GDHub-1`.
- **7c Keyboard and pointer.** The dext also publishes an NKRO keyboard (country code 32, ISO/UK) and a 16-bit relative pointer. `KeySinkKind.virtualHID` routes to it.
- **7d Identity spike.** Test each candidate against H1–H6:
  - `x360-usb`: Razer-style 360Controller descriptor plus an output report, Transport USB, v0x0114.
  - `xbox-bt-dual`: 0x01/0x03 plus a vendor collection carrying GIP 0x20/0x09, tried with Transport "Bluetooth Low Energy" and with "USB".
  - `generic`: usage 5.

  Keep the winner per host in `PadIdentity`. The P0.6 Razer result predicts `x360-usb`.
- **7e Rumble.** Host output → SCUF output report 0x09. Mixed-mode routing. GDHub refuses to publish while an OJD pad exists.

**Verify**
- H1–H7 in every host: exactly one controller, every input working, and ioreg shows the intended Transport and no `HIDVirtualDevice` key.
- A remap (paddle_outer_right → Y) and a pad macro work in all three hosts.
- Rumble works in one game.
- GFN with Direct mouse input on receives keys from the dext keyboard.

### P8: Later

- **CoreHID publisher**, once Apple approves it, behind the same sink. Its transport is forced to Virtual, so use `xbox-bt-dual`. Pick dext or CoreHID for distribution.
- **Developer ID and notarization.**
- **Elite-2 identity** (045E:0B05/0B22) for native paddles in Steam, behind a flag. Speculative.
- **Bragi onboard key-assignment writes** to unassign paddles and remove the echo. Borrow ideas from OpenLinkHub, not code, since it is GPL-3.
- **Bezier curves and flick stick.**
- **Keyboard/mouse macro recording** through a listen-only event tap (Input Monitoring).
- **Profile import and export.**

---

## 6. Risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | OJD 0.5 ignores the record or misreads report 6 (Y inverted, buttons 11–19 missing; [issue #33](https://github.com/xsyetopz/OpenJoystickDriver/issues/33)) | 0.6 bit-offset record. For Shadow, ShadowUSB. For Steam, generic + "Begin Setup" |
| 2 | OJD and GDHub cannot share the receiver | Explicit owner state machine, the trigger-key bridge, the paid dext route |
| 3 | No single identity works in all hosts | Identity per host, switched at launch. The data-driven dext means no rebuild. Re-run the matrix after updates |
| 4 | Phantom or duplicate pads: Razer 028E/27DB, Steam "GamePad-N", the SDL 2.24 MFi+HIDAPI duplicate in Shadow ([SDL #11002](https://github.com/libsdl-org/SDL/issues/11002)) | PhantomPadDetector, one publisher at a time, serial `GDHub-…`, checklist |
| 5 | GFN raw-HID input ignores CGEvent | Turn Direct mouse input off, or use P6 Karabiner, or the P7 dext keyboard |
| 6 | GFN switches to Forge (GameController only), which drops non-GameController identities | Prefer GameController-accepted identities (0B13) for GFN. Watch for "Skipping SDL/Forge gamepad" |
| 7 | A stale Steam `SDL_GamepadBind` for our GUID scrambles buttons | SteamConfigReader warning plus reset steps |
| 8 | CoreHID approval takes months; `userclient-access` is restricted | Dext with development entitlements first. Request a team grant early. The dext checks the Team ID itself |
| 9 | TCC grants reset on rebuild | Stable signing in P1 |
| 10 | Stuck keys or runaway macros | Refcounts, failsafes, crash journal, emergency chord, watchdogs in the helper and the dext |
| 11 | Paddle echo attributed wrongly | Window measured in P1. Long term, Bragi unassign (P8) |
| 12 | ShadowUSB forwarding is fragile (3A08↔3A09 flips, isochronous audio over UHCI) | Keep the controller awake, show the forward status, prefer the virtual pad |
| 13 | The root helper becomes a keystroke-injection backdoor | Audit-token and code-signing check, root-owned socket, pinned protocol version |
| 14 | Licences: OJD is PolyForm-NC from 0.6, OpenLinkHub is GPL-3 | Drive OJD only through its CLI and records. Never bundle it or port its code |
| 15 | Anti-cheat or terms of service | Macros off by default; per-profile note |
| 16 | 1 kHz reports overload the main thread | `hidQueue` for the engine; the UI stays throttled |

## 7. Open technical questions (settled during the phases)

- Do the paddle extra bit and its echo rise in the same report? (P1)
- Is the idle report stream continuous at 1 kHz? (P1)
- What exactly does OJD's `--actions-json` do, and what are the `controller disconnect` options? (P0.5)
- Does an OJD key target reach GFN's raw-HID path? (P0.8)
- Does the dext `xbox-bt-dual` pad with Transport BLE get matched by GameController, and is it parsed as BT by SDL3? (P7d)
- Where are Steam's "Steam Input for Xbox" toggles stored? (P5; until then, checklist text only)

## 7b. User observation 2026-11-08: Shadow PC latency

The user reports Shadow PC already recognises the controller but it is **very laggy**, while keyboard and mouse have no lag. This matches the USB-forwarding path (R4): ShadowUSB tunnels the receiver's raw USB traffic over the network and the receiver emits a 16-byte report every millisecond even when idle, so every frame becomes a network packet. Keyboard and mouse use Shadow's own low-latency input channel; a virtual pad presented on the Mac goes through that same channel.

**Decisions taken from this:**
- Shadow PC gets the **virtual pad (R1 / R3)**, not USB forwarding. Decision 5 in §8 is closed.
- Every GDHub output sink sends **only on change**, with a rate cap (default 250 Hz, configurable down to 125 Hz) and analogue deadbands, so idle streams never flood a network channel. The same applies to the pad GDHub feeds through OJD if OJD exposes a rate option; otherwise GDHub owns the pad only through its own engine (R3).
- P0 step 7 (ShadowUSB trial) becomes a measurement only: unforward the receiver before testing the virtual pad in Shadow, and record the difference.

## 8. Decisions needed from you

1. **Paid Apple Developer membership?** Do you have one with the Account Holder or Admin role? The Apple Configurator certificate for INTERLINKED GROUP LTD suggests an organisation account may exist. This decides between P7 and the OJD path.
2. **May GDHub change OpenJoystickDriver's setup?** That means writing its controller record and map profiles, and switching its identity per host. Is upgrading to 0.6.0-alpha.2 (PolyForm Noncommercial) OK if 0.5 cannot read the receiver?
3. **GeForce NOW keyboard and mouse:** turn GFN's "Direct mouse input" off, or install the Karabiner VirtualHIDDevice (a system extension plus a root daemon)? On the paid path the dext covers this.
4. **Razer's virtual controller driver:** should it be disabled if it takes a player slot?
5. ~~Shadow PC: virtual pad or USB forward?~~ Closed: virtual pad (see §7b; USB forwarding is the laggy path the user already experienced).
6. **Games:** which ones per host? That sets the default profiles and the anti-cheat caution for macros.