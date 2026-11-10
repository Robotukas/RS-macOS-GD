# Remap: a button sends what you pick (step 1 of the approved mockup)

Status: plan v1 (2026-11-10). Mockup: `docs/mockups/remap-buttons.html` v5, approved 2026-11-09 with decisions
**A** build order (step 1 ordinary buttons + G1–G5 + Start + Profile + volume off; step 2 paddles and SAX; step 3 keyboard,
mouse, macros), **B** linked buttons light up in the app, **C** a click in the live view no longer starts a learn.
Written from four code maps of 2026-11-10 (mapping model, translator, volume-key channel, UI).
Owner's rules that shape it: "Mapping should be very simple. When I press on Text label or button it should bring
menu"; "allow to map all buttons in controller not just extra"; "if mapped, it means it is mapped; you must disable the
volume"; "Of course light up any linked buttons"; every hands-on test is a Developer-mode template.

## Phases

| Phase | Title | Driver replacement? | Status |
|---|---|---|---|
| R0 | Volume-key spike: does a per-service key mapping silence G3 and leave G2 alone? (owner presses two keys) | No | ▶ current |
| R1 | Model and translators: `outputs` in the mapping, mapper OR, encoder 0–2 rules, strict reload, learn guard | No | pending |
| R2 | UI: Mapping mode, click menu, view tabs, "G1 → Y" labels, linked lighting, no learn on click | No | pending |
| R3 | Volume off for a mapped G2–G4 (engine, per key), re-applied at every link | No | pending |
| R4 | Templates `remap-g1-as-y`, `remap-swap-a-b`, `gkeys-volume`; install; owner runs them on App and Driver | No | pending |
| R5 | Results, docs, HANDOFF | No | pending |
| R6 | Step 2: paddles and SAX by their physical bits, echo hidden; GDHM v2 (3+ sources, button → trigger) | Yes | pending |
| R7 | Step 3: keyboard keys, mouse buttons, macros in the same menu (with takeover T11) | Yes | pending |

## What step 1 delivers

- **Mapping** mode next to Edit layout and Developer (one mode at a time). While it is on, a click on a label or on a
  drawn button opens a native menu: `<Label> sends` · the pad buttons in groups (A B X Y · LB RB LT RT · View Menu L3 R3 ·
  D-pad up/down/left/right · Guide) · Nothing · Reset to default · Re-learn button…. A tick marks the current choice,
  "default" marks the factory one. Sticks: only "Re-learn stick…". Paddles and SAX: a note "Remapping paddles and SAX
  comes next." and "Re-learn button…".
- Remappable in step 1: a b x y lb rb lt rt view menu l3 r3, the four D-pad directions, start, profile, g1–g5 (23 controls).
- A remapped control does only what it is mapped to; its default function goes away. Two controls may send the same pad
  button (OR: "Y by Y or by G1"). A swap is two picks.
- The label shows it ("G1 → Y", orange; "View → Nothing", grey arrow); pressing G1 lights G1 (bright) and Y (dim).
- G2/G3/G4: the menu's default entry reads "Volume down / Volume up / Mute (built in)". Any other pick, **including
  Nothing**, switches that key's volume function off; the keys left alone keep it.
- Saved in the one mapping file and applied at once on both paths. View tabs All / Front / Back / Sides.
- A click in the live view does nothing (decision C); learning is "Learn all (guided)" or "Re-learn…" in the menu.

## Model (R1)

`ControlMapping` gains `outputs: [String: ControlOutput]`, keyed by control id; absent = default.

```
enum PadOutput: String, Codable, CaseIterable   // raw values = layout control ids where one exists
  a b x y lb rb lt rt view menu l3 r3 guide dpad_up dpad_right dpad_down dpad_left
  gdxItem: a 0 … r3 9, guide 10, dpad U/R/D/L 11–14; lt, rt are triggers (isAnalog)
  drawingControl: the same id; guide → "start"
enum ControlOutput: Hashable { case pad(PadOutput), nothing }      // on disk a plain string: "y", "dpad_up", "nothing"
```

- `defaultOutput(id)`: the 16 pad-named controls send themselves; `start` → guide; g1–g5, profile → nothing; paddles
  and SAX → nothing (they reach the pad through the controller's own echo until R6); sticks: not applicable.
- `effectiveOutput(id) = outputs[id] ?? defaultOutput(id)`; for controls with non-zero `physicalBits` (paddles, SAX)
  `outputs` is ignored in step 1.
- `setOutput(_:for:)` removes the key when the value equals the default — **except g2, g3, g4**, where an explicit
  `nothing` is kept (it means "volume off"). `isRemapped(id)` = key present. "Reset all remaps" = `outputs = [:]`.
- A digital pad item is held when **any** control whose effective output is that item is held (`isActive`, unchanged).
  LT/RT value = max over its sources: a trigger-bound source gives its analog value, a digital source 1.0 while held.
- **Codable, hand-written**: `init(from:)` with `decodeIfPresent` for all four keys (Swift's synthesized decoding throws
  on a missing key even with a default — verified — and `MappingStore.load` would then silently hand out factory
  defaults); `outputs` decoded as `[String: String]`, unknown values dropped with a log line; `encode(to:)` omits
  `outputs` when empty, so an un-remapped mapping writes today's JSON, today's GDHM bytes and today's `mappingHash`.
- Learn (`apply(LearnAssignment)`) never touches `outputs`; a remap never touches `buttons`/`sticks`/`physicalBits`.
- **Learn guard** (the G1/Y incident): a single-control learn whose result has no physical bits and equals another
  control's binding is not applied; the result line says "That is Y's button. To make G1 send Y use Mapping → Y."
- **Strict reload**: `MappingStore.loadStrict()` throws on an undecodable file; `MappingWatcher` uses it and keeps the last
  good mapping (today a bad file would push factory defaults to the engine and the driver). `load()` stays for start-up.

## Translators (R1)

No change to `Shared/GDHubXlate.{c,h}` or `Shared/GDHubDefaults.h` → **no driver replacement**. GDHM v1 already takes 0, 1
or 2 OR-ed rules per pad button, any receiver button (1–19) as a source, hat and trigger-threshold sources.

- `PassthroughPadMapper.padState`: per pad item, OR `isActive(cid)` over the controls whose effective output is that
  item; triggers as above. It stays the oracle for the parity/golden tests, the runtime fallback, and what Developer
  mode predicts with — it is **not** removed with the `xlateCore` key (correction to the T8 follow-up).
- `MapBlobEncoder.table`: per item, sources = the default-owner control first, then the others sorted by id; 0 sources →
  one `KIND_NONE` rule (byte-identical to today when nothing is remapped); `.unsupported(reason)` with owner-readable
  reasons for what v1 cannot say: "three buttons send Y: g1, g2, y", "g1 sends LT: a button cannot pull a trigger in
  this driver version", "two controls send LT". Those mappings run on the App path through the Swift mapper, and the
  status line says so ("Driven by: App (mapping needs a driver update: …)"). LT→RT, LT→A, LT→Nothing are expressible.
- The menu marks such picks before they are made: LT/RT targets on a digital source, and a target that already has two
  sources, carry "(App path until the next driver update)".
- Applied like a learn edit: file → watcher (50 ms) → engine `setMapping` → blob push → the tap reloads at the next
  frame and reposts the full state. Crossing between expressible and not costs one switch neutral (< 1 ms, measured in T7).
- `DevRunCore` `requires.mapping {g1: "y"}` compares **effective outputs** (today it compares learned bindings);
  `DevExpectation` already simulates the mapper, so expectations and linked lighting in Developer mode follow remaps.

## UI (R2)

- **Mode**: `EnvisionProDevice.isRemapping` (+ `remapMenuControl` for the selection outline), `beginRemapping()` /
  `endRemapping()`; a pure `ModeGate(isEditing:devOn:remapping:learning:)` decides what each mode disables, used by the
  guards and by the toolbar. Toolbar: [Edit layout] [Mapping → "Mapping ✓ Done"] [Developer] [Reset all remaps (only in
  Mapping, disabled when there are none)] + hint. Layout menu items follow the same gate.
- **Menu**: a native `NSMenu` popped with `popUp(positioning:at:in:)` from one small anchor `NSView` per drawn view;
  the label tap and the hotspot tap call the same presenter with their rect (no dependence on the mouse position, so
  accessibility presses and my background clicks work). Built from a pure `RemapMenuModel` (header, note, groups with
  tick and default tag, reset enabled, re-learn title). Notes: g2/g3/g4 "Mapped: Gn no longer changes the volume.";
  start "Holding Start still switches the controller off."; profile "Each press also switches the controller's own
  profile." (measured 2026-11-09). Selection outline on label and hotspot while the menu is open.
- **Clicks**: hotspots and labels take clicks only in Mapping mode (and labels in Edit layout as today). Live view:
  nothing. Tooltip and hint texts updated. "Re-learn…" calls the existing `startLearn(controlId:)`.
- **Tabs**: `ViewTab` all/front/back/sides → `columns`; `@AppStorage("controllerViewTab")`; a small segmented control
  above the drawing in every mode. Precedence (pure `visibleColumns`): Edit layout → All (picker disabled);
  a Developer step's focused view wins while it is focused; otherwise the tab.
- **Labels**: pure `RemapLabel` → "G1 → Y"; remapped = orange border and arrow, Nothing = grey arrow; in Mapping mode all
  labels get a dashed border. **Lighting**: pure `RemapLighting.levels(frame:mapping:layout:)` → pressed / linked, computed
  once per frame; linked = dim; pressed always wins; off while Developer mode is on (its purple overlay shows outputs).
- Accessibility identifiers for automation: `toolbar.mapping`, `toolbar.resetAllRemaps`, `viewTabs`, `remap.label.<id>`,
  `remap.hotspot.<id>`.
- No `@State` (the macro plugin is missing in this toolchain): state lives in the device, `@AppStorage`, or a
  `@StateObject` box, as the existing code does.

## Volume off for a mapped G2–G4 (R0 spike, R3 build)

Facts: the volume key is report 0x11 on **interface 4** of the receiver (Consumer Control 0x0C/0x01, sharing its HID device
with Corsair's control channel that GDHub uses for battery and the sleep timer). The driver's tap owns interface 3 only and
never sees it. Apple's event driver turns it into volume keys.

**Approach (no driver change, no seize):** set the per-service HID property `UserKeyMapping` on that one consumer service,
mapping only the mapped keys' usages to 0 — G2 → 0xC000000EA (volume down), G3 → 0xC000000E9 (up), G4 → 0xC000000E2 (mute).
Apple's keyboard filter drops an event whose destination is 0. Per key, so unmapped G keys keep their volume natively;
battery/sleep-timer keep working; the Mac keyboard's own volume keys are never touched (nothing global is written).

- `Sources/GDHub/HID/ConsumerKeyMute.swift` (no AppKit): `desired(for: mapping) -> Set<UInt64>`; `apply()` via
  `IOHIDEventSystemClientCreateSimpleClient` → services with VendorID 0x1B1C, ProductID 0x3A08, PrimaryUsagePage 0x0C →
  `IOHIDServiceClientSetProperty(s, "UserKeyMapping", pairs)` (SInt64 numbers); `clearAll()` sets `[]`.
- Re-applied: at engine start, on every mapping change, on every appearance of the service (IOKit first-match
  notification, retries at 0/100/300/1000 ms), on wake. A suppression is added only while buttons 13–15 are released.
- One writer: the engine in engine mode; the GUI only in in-app mode. `clearAll()` on SIGTERM/quit/uninstall. After a
  crash the property dies with the service at the next controller off/on, sleep or reboot.
- **R0 gate (one minute, owner's hands):** with the controller on, I set the mapping for G3 only with `hidutil`, the
  owner presses G3 ×3 then G2 ×3, I read the system volume before and after each, check the log for a permission
  refusal, and undo. Pass: G3 leaves the volume alone, G2 changes it. If macOS refuses (restricted property), the
  engine needs Input Monitoring — still no driver change. **Fallback** if the property has no effect: a second driver
  personality on interface 4 that filters the report, shipped with R6's driver update; step 1 then ships without the
  volume switch-off and the menu says so on G2–G4.

## Templates and checks (R4)

- `remap-g1-as-y` (`requires: {mapping: {g1: "y"}}`, App then Driver): press G1 twice → pad Y; press Y twice → pad Y;
  hold G1, add Y, release G1 → Y stays (a `held` step).
- `remap-swap-a-b` (`requires` a↔b): A → pad B, B → pad A.
- `gkeys-volume`: a digital step gains `expect.volume: "unchanged" | "changes"`; the GUI samples the default output
  device's volume and mute (CoreAudio, no permission) at window start and end and counts raw 0x11 reports in the window
  (none → the step is invalid, not a pass). Steps: G3 set to RB → pad RB, volume unchanged; G4 left alone → mute
  toggles (and back); G2 set to Nothing → pad nothing, volume unchanged.
- `scripts/receiver-check.sh` prints interface 4's driver and the consumer service's `UserKeyMapping`.

## Tests

`ControlMappingTests` (old file without `outputs`/`physicalBits` loads; round trip; empty omitted and `mappingHash` of the
default unchanged; unknown value tolerated; `apply()` leaves outputs alone; normalisation incl. the g2–g4 exception;
effective-output table) · `PassthroughPadMapperTests` (G1→Y OR; hold G1+Y release G1; swap; Nothing; start→Y leaves
Guide off; g5→Guide; button→LT = 1.0; LT→A; LT→RT) · `MapBlobEncoderTests` (2 sources validate; 3 sources and
button→LT unsupported with the reasons; factory blob and checked-in header unchanged) · the random-mapping parity,
sequence and golden tests extended with random outputs (≤ 2 sources) · `MappingWatcherTests` (outputs-only change
delivers; undecodable file delivers nothing) · `EngineCoreTests` (outputs-only change bumps the revision) ·
`DevExpectationTests`/`DevRunCoreTests` (requires by output; g1→Y links "y") · the learn guard · `RemapMenuTests`,
`RemapLabelTests`, `RemapLightingTests`, `ModeGateTests`, `ViewTab` in `LayoutTests`, focus-beats-tab in
`DeveloperViewsTests` · `ConsumerKeyMuteTests` (`desired(for:)`, pair encoding) · a source-text test that the live view
has no click-to-learn.

## Decisions taken while planning (say so if you want any changed)

1. G2–G4 show "Volume … (built in)" as their default; **Nothing is a real pick that silences the key**.
2. Triggers LT and RT are remappable as sources (the mockup lists them). A *button sending LT/RT*, and a pad button fed by
   three controls, work but run on the **App path** until the R6 driver update; the menu says so before you pick.
3. A hotspot click opens the menu at the hotspot; a label click at the label.
4. "Reset all remaps" asks no confirmation (as in the mockup); it never touches learned buttons.
5. Leaving Mapping does not cancel a running "Re-learn".
6. G5 → Guide lights the Start drawing as linked.
7. Until R6, remapping a D-pad direction (or A/B/X/Y) also changes what a paddle or SAX key ends up sending, because the
   controller reports those keys as that button. The paddles' and SAX keys' menus say "comes next".

## Not in step 1

Paddles and SAX as sources, hiding their echo, three-plus sources and button → trigger on the Driver path (R6, one driver
replacement); keyboard, mouse and macros (R7, with T11); per-game profiles.

## Done when

The owner maps G1 to Y from the menu and the three templates pass on App and on Driver; a mapped G3 leaves the volume
alone while G4 still mutes; old mapping files load unchanged; `swift test` and the Python tests are green; no driver
replacement was needed.
