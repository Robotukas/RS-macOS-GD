# Remap: a button sends what you pick (step 1 of the approved mockup)

Status: **plan v2 (2026-11-10)** — v1 plus the plan review of 2026-11-10 (seven reviewers against the code, every finding
challenged by a second agent: 98 confirmed, 1 refuted; 5 more from a completeness pass, marked ‡ below, not second-checked).
Approved for building: the owner answered "OK all" to the nine changes on 2026-11-10 (mockup v6).
Mockup: `docs/mockups/remap-buttons.html` v5, approved 2026-11-09 with decisions
**A** build order (step 1 ordinary buttons + G1–G5 + Start + Profile + volume off; step 2 paddles and SAX; step 3 keyboard,
mouse, macros), **B** linked buttons light up in the app, **C** a click in the live view no longer starts a learn.
Owner's rules that shape it: "Mapping should be very simple. When I press on Text label or button it should bring
menu"; "allow to map all buttons in controller not just extra"; "if mapped, it means it is mapped; you must disable the
volume"; "Of course light up any linked buttons"; every hands-on test is a Developer-mode template.

## Phases

| Phase | Title | Driver replacement? | Exit | Status |
|---|---|---|---|---|
| R0 | Volume-key spike, run as the template `volume-spike` (owner presses G3 and G2). Gate for R3 and for `gkeys-volume` only | No | Result (pass / which half failed) written here | waiting for the owner (controller on); template and scratch script ready |
| R0b | Mockup v6 (what changed since v5) and the owner's OK on "Changes from mockup v5" below | No | Answers recorded in this file | ✅ done 2026-11-10: "OK all" (mockup `remap-buttons-v6.html`) |
| R1 | Model and translators: `outputs` in the mapping, mapper OR, encoder limits, strict reload, learn guard, Developer mode under remaps | No | Listed tests green; factory blob, checked-in header, default JSON and `mappingHash` byte-identical; `swift test` + Python green | ✅ done 2026-11-10 (813 tests; independent review folded in) |
| R2 | UI: Mapping mode, click menu, view tabs, "G1 → Y" labels, linked lighting, no learn on click | No | R2 tests green; installed with `--same-build`; I open every menu through the accessibility ids | ▶ current |
| R3 | Volume off for a mapped G2–G4 (per key), re-applied at every link | No if R0 passes; owner decides if not | Engine-as-writer check passes (first step of R3) | pending — needs R0 pass |
| R4 | Templates `remap-g1-as-y`, `remap-swap-a-b`, `gkeys-volume`; owner runs them on App and Driver | No | Three reports pass on both paths; the owner's mapping file is what it was before R4 | pending (`gkeys-volume` needs R3) |
| R5 | Results, docs, HANDOFF (incl. the rollback note) | No | Committed and pushed | pending |
| R6 | Step 2: paddles and SAX by their physical bits, echo hidden; GDHM v2 (3+ sources, button → trigger, two triggers) | Yes | — | pending |
| R7 | Step 3: keyboard keys, mouse buttons, macros in the same menu (with takeover T11) | Yes | — | pending |

Needs the owner's hands: R0 (controller on, press keys, one press of a Mac volume key), R0b (answers), R4 (make the picks
in Mapping, run three templates, reset). Before any of them: Parallels VM not running, Shadow not forwarding the receiver.

## What step 1 delivers

- **Mapping** mode next to Edit layout and Developer (one mode at a time). While it is on, a click on a label or on a
  drawn button opens a native menu: `<Label> sends` · the pad buttons in groups (A B X Y · LB RB LT RT · View Menu L3 R3 ·
  D-pad up/down/left/right · Guide) · Nothing · Reset to default · Re-learn button…. A tick marks the current choice,
  "default" marks the factory one. Sticks: the note "Sticks are not remappable in this feature." and "Re-learn stick…".
  Paddles and SAX: the note "Remapping paddles and SAX comes next. Until then this key sends the button the controller's
  profile gives it, and follows that button's remap." and "Re-learn button…".
- Remappable in step 1 (23 controls, one constant `ControlMapping.remappableIDs`): a b x y lb rb lt rt view menu l3 r3,
  the four D-pad directions, start, profile, g1–g5.
- A remapped control does only what it is mapped to; its default function goes away. Two controls may send the same pad
  button (OR: "Y by Y or by G1"). A swap is two picks. Opposite D-pad directions cancel, as the translators already do ‡.
- The label shows it ("G1 → Y", orange; "View → Nothing", grey arrow); pressing G1 lights G1 (bright) and Y (dim).
- G2/G3/G4: the menu's default entry reads "Volume down / Volume up / Mute (built in)". Any other pick, **including
  Nothing**, switches that key's volume function off; the keys left alone keep it.
- Saved in the one mapping file and applied at once on both paths. View tabs All / Front / Back / Sides.
- A click in the live view starts no learn (decision C); the hint flashes "Switch Mapping on first (button on the left)."
  as in the mockup. Learning is "Learn all (guided)" or "Re-learn…" in the menu.

## Model (R1)

`ControlMapping` gains `outputs: [String: ControlOutput]`, keyed by control id; absent = default. Both new types live in
`Sources/GDHub/Mapping/ControlMapping.swift` (already in the engine isolation scan).

```
enum PadOutput: String, CaseIterable      // raw values = control ids; "guide" for Guide
  a b x y lb rb lt rt view menu l3 r3 guide dpad_up dpad_right dpad_down dpad_left
  padItem: PadItem?     // the existing GDX-numbered item (Developer/PadReportDecoder.swift); nil for lt, rt
  gdxItem, drawing control: derived from PadItem — no second hand-numbered table
enum ControlOutput: Hashable { case pad(PadOutput), nothing, builtIn }   // on disk: "y", "nothing", "built_in"
```

- **`builtIn` is new in v2** and removes v1's g2–g4 special case. It is valid only for g2, g3, g4 (the volume function).
  `defaultOutput`: the 16 pad-named controls send themselves; `start` → guide; g1, g5, profile → nothing;
  **g2, g3, g4 → builtIn**; paddles and SAX → nothing (they reach the pad through the controller's echo until R6).
- `effectiveOutput(id) = outputs[id] ?? defaultOutput(id)`; for any id outside `remappableIDs` (sticks, paddles, SAX,
  stray keys) it is always the default. `setOutput(_:for:)` removes the key when the value equals the default, with no
  exception, and ignores ids outside the list. `isRemapped(id)` = key present. "Reset all remaps" = `outputs = [:]`.
- One shared `sources(of: PadOutput) -> [String]` (default owner first, then `remappableIDs` order), used by the mapper,
  the encoder, the menu, the expectation and the lighting, so they cannot disagree.
- A digital pad item is held when **any** source is held (`isActive`, unchanged).
- **Triggers** (corrected): LT/RT value = max over its sources. The default owner contributes `triggerValue ?? 0` exactly
  as today (an un-remapped `lt` learned as a button still sends nothing). Only an explicit remap adds a source: analog
  when its learned binding is `.trigger`, otherwise 1.0 while held. Judged by the binding, not by the control id.
- **Codable, hand-written in an `extension`** (in the struct body it would remove the implicit `init()` that
  `ControlMapping.default`, `DevRunHeader` and tests use), explicit `CodingKeys`, `decodeIfPresent` for all four keys.
  `outputs` is decoded entry by entry: a non-string value, an unknown value, a key outside `remappableIDs`, or `built_in`
  on another control drops only that entry with a log line and never fails the file. `encode` omits `outputs` when empty.
- **Pin today's bytes first** (own commit, before `ControlMapping.swift` changes): fixtures of the JSON that
  `MappingStore.save` writes for `.default` and for `ControlMapping()`, and literals of `mappingHash` for both, in
  `DevRunReportTests` (today it compares the hash with itself).
- Learn (`apply(LearnAssignment)`) never touches `outputs`; a remap never touches `buttons`/`sticks`/`physicalBits`.
- **Learn guard** (the G1/Y incident; corrected — v1's wording would have refused re-learning A, B and the D-pad, whose
  bindings the paddles and SAX echo): pure `ControlMapping.learnConflict(_ a: LearnAssignment) -> String?`. In a
  single-control learn, an assignment with target `.whole`, a binding and no physical bits is refused when another
  control has the same binding **and no physical bits of its own**. Paddles and SAX never count as owners. Guided
  "Learn all" is never refused. Result line: "That is Y's button. To make G1 send Y use Mapping → Y."
- **Strict reload**: `MappingStore.loadStrict()` throws on an undecodable file. `MappingWatcher` uses it and keeps the
  last good mapping. GUI start uses it too: an unreadable file is moved aside
  (`envision-pro-mapping.unreadable-<stamp>.json`) with an event-log line before defaults are used, so no later save
  overwrites the owner's only copy. Engine start stays lenient but logs at error level and says so in the status line.
- `MappingStore.save` keeps a timestamped backup when a save adds or removes `outputs` (the layout's backup pattern,
  `ControlLayout.saveAsUserLayout`) ‡.
- **The GUI's copy of the mapping** ‡: today only the engine watches the file; the GUI reads it once and saves its own
  copy. R1 checks this first and then either gives the GUI the existing `MappingWatcher`, or documents "edits only
  through the running GUI". Either way a display-only GUI must not enter Mapping mode or learn (`ModeGate` gets the GUI mode).
- New log calls use one shared `GDHubID.subsystem` constant, so the planned RSUGD rename changes one place.

## Translators (R1)

No change to `Shared/GDHubXlate.{c,h}` or `Shared/GDHubDefaults.h` → **no driver replacement**. GDHM v1 takes 0, 1 or 2
OR-ed rules per pad **button**, any receiver button, hat and trigger-threshold sources — and exactly **one** field per
pad **trigger**.

- `PassthroughPadMapper.padState`: per pad item, OR over `sources(of:)`; triggers as above; `builtIn` and `nothing` feed
  nothing. It stays the oracle, the runtime fallback, and what Developer mode predicts with — **not** removed with the
  `xlateCore` key.
- `MapBlobEncoder`: one pure `remapLimit(_ mapping) -> String?` states what the driver cannot say: a pad button with
  three or more sources; a non-trigger source sending LT/RT; **a trigger with two sources** (v1 wrongly called LT→RT
  expressible: while RT still sends RT that is two sources. The LT↔RT swap, LT→A and LT→Nothing are fine). `table()`
  calls it first. It is never non-nil for a mapping with empty `outputs`, so un-remapped mappings stay byte-identical.
- The fallback for such mappings **already exists** (T5/T7: the offer returns `.unsupported`, `TapSupervisor` holds the
  driver inert, `VirtualPadSink` posts through the Swift mapper). New in R1: the engine checks a blob locally
  (`XlateCore(blob:spec:)`) before pushing it; an edit that stays unsupported makes no driver call; the status wording
  becomes "Driven by: App (mapping needs a driver update: …)" (`TapStatusReport.swift`, with the pinned strings in
  `InputPathMenuTests` and `LiveLifecycleTests`).
- The menu marks a pick by trying it: apply it to a copy, call `remapLimit`; marked only when the current mapping passes
  and the candidate does not. Wording in the owner's words: "(the App drives the controller until the next driver update)".
- Cost, corrected: going **into** such a mapping is one switch neutral (< 1 ms). Coming **back** is not immediate: the
  driver re-arms over about 2 s and 100 frames while the App keeps driving. The first pick of an LT↔RT swap passes
  through this.
- Applied like a learn edit: file → watcher (50 ms) → engine `setMapping` → blob push → the tap reloads.
- **Developer mode under remaps**: `requires.mapping` compares effective outputs by value from a closed, validated
  vocabulary (a pad output id, `nothing`, `built_in`); skip reasons in plain words ("needs G1 → Y: set it in Mapping").
  `DevExpectation` follows remaps for buttons and D-pad only. In step 1 a step whose control is a remapped `lt`/`rt`, or a
  button sent to LT/RT, is **skipped with that reason**; the step window opens on the physical pull
  (`triggerValue`), not on the pad's trigger. An un-remapped mapping resolves exactly as today.

### R1 result (2026-11-10)

Built in five slices plus one independent review; 813 Swift tests and 21 Python tests green; nothing under `Shared/`
changed, so the driver stays at build 24. Not installed yet (R2 installs). Differences from the text above:

- The learn guard refuses only a control that has no pad button of its own (G keys, Profile, a paddle or SAX key learned
  without its bits). Two ordinary buttons learned crosswise stay repairable one at a time.
- A mapping file without a `buttons` key is unreadable (moved aside), not an empty mapping.
- The GUI did read the mapping file only once; it now watches it and adopts outside edits without writing them back.
- `XlateCore` freed its map twice when a blob was rejected (a crash waiting in an existing fallback path); fixed.
- The Swift mapper's sources table is cached in the sink per set of remaps.
- An internal blob rejection has its own status wording. **Open:** the status line does not yet say when the engine
  started on defaults because the file was unreadable (logged at error level only).
- A trigger with two sources is refused even when the default owner would send nothing (could be allowed later).

## UI (R2)

- **Mode**: `EnvisionProDevice.isRemapping` (+ `remapMenuControl`), `beginRemapping()` / `endRemapping()`; a pure
  `ModeGate` with a written truth table that keeps today's behaviour: Mapping refused while editing or in Developer;
  Edit layout and Developer refused while Mapping; a running learn keeps going; display-only GUI refused ‡.
  Toolbar: [Edit layout] [Mapping → "Mapping ✓ Done"] [Developer] [Reset all remaps (only in Mapping)] + hint; while the
  mapping cannot run in the driver, the hint says who drives the controller.
- **Menu**: native `NSMenu` built from a pure `RemapMenuModel` (explicit group table in the mockup's order, not
  `allCases`). Mechanics that the review found necessary: the pop is deferred with `RunLoop.main.perform(inModes:)`
  (a menu opened inside a main-queue block would hold back frame and Developer work while open);
  `autoenablesItems = false`; the item target is kept alive until `popUp` returns; the anchor is an `NSView` that returns
  `nil` from `hitTest` so clicks still reach hotspots and labels. Notes: g2/g3/g4 "Mapped: Gn no longer changes the
  volume."; start "Holding Start still switches the controller off."; profile "Each press also switches the
  controller's own profile, which changes what the paddles and SAX keys send."
- **Clicks**: two existing gates (`CalloutLayer.allowsHitTesting` and the tap handlers) both go through
  `ModeGate.clickAction` → none / select label (Edit layout) / open menu (Mapping) / flash the hint (live view).
- **Tabs**: `ViewTab` all/front/back/sides, `@AppStorage`. Pure `visibleColumns`: Edit layout → All; a Developer run →
  its focused views, or All when the focus is empty (never the tab during a run); guided Learn all → All; otherwise the
  tab. The picker is disabled while overridden and the saved tab comes back.
- **Labels**: pure `RemapLabel`; mockup v5 styling (orange border and tinted fill when remapped, grey arrow for Nothing,
  dashed blue-grey border in Mapping mode so it does not look like Edit layout). In Edit layout the label is the plain
  one, so stored label geometry never depends on remaps; check the G-key row for overlap with the suffix.
- **Lighting**: pure `RemapLighting.levels` once per frame. Pressed = today. **Linked** = a control that is not pressed
  and whose effective output is an item the pad is actually sending this frame — computed from the mapper's output ‡, so
  cancelled D-pad directions and controls mapped away from an item are not lit. Start lights for G5→Guide only while
  Start still sends Guide. Developer mode keeps its own overlay.
- Accessibility: hotspots have no element today — add one (`accessibilityElement(children: .ignore)`, button trait,
  `remap.hotspot.<id>`, action); labels `remap.label.<id>`; `toolbar.mapping`, `toolbar.resetAllRemaps`, `viewTabs`.
- House rules: no `@State` (state in the device, `@AppStorage` or a `@StateObject RemapMenuPresenter`); write
  `SwiftUI.Binding` in full (GDHub has its own `Binding`).

## Volume off for a mapped G2–G4 (R0 spike, R3 build)

Facts: the volume key is report 0x11 on **interface 4** of the receiver (Consumer Control, sharing its HID device with the
control channel GDHub uses for battery and the sleep timer). The driver's tap owns interface 3 only.

**Approach (no driver change, no seize):** the per-service HID property `UserKeyMapping` on that one consumer service,
mapping only the mapped keys' usages to 0 — G2 → 0xC000000EA, G3 → 0xC000000E9, G4 → 0xC000000E2.
`desired(for: mapping)` = the keys whose effective output is not `builtIn`.

- **R0 gate — a template, not a chat session.** I write `volume-spike` (rest · "Press G3 three times" · "Press G2 once")
  to the local dev-scripts folder; the owner presses Reload and runs it from the picker. Before it: volume set to about
  50 %, unmuted, output device has a software volume, one press of a Mac volume key as a baseline. Volume and mute are
  sampled in the background. Two halves in one sitting:
  (a) `hidutil` sets the G3 mapping (the command in HANDOFF);
  (b) a scratch Swift script with **no entitlements** makes the same calls the engine will make
  (`IOHIDEventSystemClientCreateSimpleClient` → matching services → `IOHIDServiceClientSetProperty`). `hidutil` holds a
  private Apple entitlement, so (a) alone would not show that GDHub may do it.
  Also checked: GDHub's event log shows the `11 01` / `11 02` reports (R4 counts them).
  **Pass:** in both halves G3 leaves the volume alone and G2 changes it.
  Undo is always scoped: `hidutil property --matching '{…same…}' --set '{"UserKeyMapping":[]}'` — a bare `--set` writes
  to every keyboard on the Mac.
  R0 does not prove: the engine process as writer, mute and volume-down, re-apply after the service is re-created.
  R3 and R4 cover those.
- **If R0 fails: stop and ask the owner.** A mapped G2–G4 that still changes the volume is never shipped. Until the owner
  answers, G2–G4 are locked in step 1 (menu note "Remapping G2–G4 comes with the next driver update", 20 remappable
  controls). Options to offer: an interface-4 filter in the driver (one driver replacement; the battery / sleep-timer
  channel must be shown still working), or leaving G2–G4 for R6.
- **R3 build**: `Sources/GDHub/HID/ConsumerKeyMute.swift` (no AppKit; added to `EngineIsolationTests` together with
  `MapBlobEncoder.swift`).
  - Own serial queue; nothing on the frame queue (`vhidQueue`) touches IOKit. A `ConsumerServiceWatcher` (the
    `SyntheticPadWatcher` pattern) re-applies when the service appears (retries 0/100/300/1000 ms); also at start, on
    every mapping change (from the watcher callback) and on wake.
  - No "only while released" gate: Apple's filter releases held keys itself when the map changes.
  - One writer: the engine in engine mode; the GUI in in-app mode, including a mid-session fall-back to in-app. A process
    that is not the writer neither sets nor clears. Cleared on SIGTERM / quit.
  - First step of R3: G3 only, installed with `--same-build`, engine as the writer, checked with the template and the
    log. If the engine is refused, the owner is asked before anything is granted.
- `scripts/receiver-check.sh` adds the filter's live map (`hidutil … --get FilterDebug`); the plain property read-back is
  labelled "as last set (not proof)".

## Templates and checks (R4)

All three are built-ins from `DevBuiltins.generate` (in picker order), `paths` App then Driver, with **explicit**
expectations (they must not check the mapper against itself). `requires` is step-level only, so every step carries it.

- `remap-g1-as-y` (`g1: "y"`): press G1 twice → pad Y; press Y twice → pad Y; hold G1, add Y, release G1 → Y stays — a
  `held` step with a new `expect.releases: ["g1"]`, so it cannot pass without the hand-over happening.
- `remap-swap-a-b` (`a: "b"`, `b: "a"`): A → pad B, B → pad A.
- `gkeys-volume` (`g3: "rb"`, `g4: "built_in"`, `g2: "nothing"`): a digital step gains
  `expect.volume: "unchanged" | "changes"`. Judged by **counted change events**, not two samples: CoreAudio listeners on
  the default output device (volume, mute, device change; no permission) and raw 0x11 reports (a new `consumerTap` next
  to `frameTap`), from the step's Go to the end of a 1 s release tail. G4 is two steps (mute on, mute off). "Cannot
  judge" (inconclusive, never a pass) when: no 0x11 report, no software volume or mute, volume at its limit in the key's
  direction, or the output device changed.
- **The owner makes the picks by hand in Mapping** (that is also the UI check). The runner never sets a mapping: Start is
  blocked with "Needs G1 → Y: set it in Mapping first" when every step would skip; notes list the picks and end with
  "Afterwards: Mapping → Reset all remaps". I copy the mapping file before R4 and compare it after ‡.
- The Driver pass needs a mapping the driver can express; the runner names the mapping note in its prompt ‡.
- `dev-run-compare.py` and `docs/protocol/developer-mode-files.md` gain the `requires` vocabulary, `expect.volume`,
  `expect.releases` and the volume values in the report.

## Tests

`ControlMappingTests` (old files load; round trip; pinned default JSON; stray key and unknown value tolerated and equal
in hash to the clean file; `built_in` only on g2–g4; `setOutput` normalisation; effective-output table; `learnConflict`:
re-learn A and D-pad up applied despite SAX/paddle echoes, G1 → `.button(4)` refused naming Y, a paddle learned without
its bits refused, guided learn never refused) · `PassthroughPadMapperTests` (G1→Y OR; hold G1+Y release G1; swap;
Nothing; start→Y leaves Guide off; g5→Guide; button→LT = 1.0; LT→A; LT→RT alone = max; LT↔RT swap; `lt` learned as a
button and un-remapped → LT 0; G5→D-pad down while up is held → no direction) · `MapBlobEncoderTests` (2 sources
validate; 3 sources, button→LT and LT→RT alone unsupported with reasons; LT↔RT encodes; `remapLimit == nil` exactly when
`table()` succeeds; factory blob and checked-in header unchanged) · random outputs from **their own seed** (existing
seeded mappings stay byte-identical), expressible ones only in parity/sequence; remapped golden vectors in a new
Swift-only `GDHubXlateRemapGoldenTests` — `Shared/GDHubDefaults.h` is not touched · `MappingWatcherTests`,
`EngineCoreTests`, `TapSupervisor` (unsupported → unsupported makes no driver call; local blob check) ·
`DevRunCoreTests`/`DevExpectationTests`/`DevTemplateTests` (requires vocabulary and validation; trigger-remap skips; no
new skips un-remapped; one test per R4 template; `expect.volume` and `expect.releases` decode and validate; each
"cannot judge" reason; two mute toggles) · `RemapMenuTests`, `RemapLabelTests` (plain in Edit layout),
`RemapLightingTests`, `ModeGateTests` (truth table, display-only refused), `visibleColumns` cases ·
`ConsumerKeyMuteTests` · `EngineIsolationTests` (new files listed) · `DevRunReportTests` (pinned hashes).

## Changes from mockup v5 (owner: "OK all", 2026-11-10)

Mockup v6 (`docs/mockups/remap-buttons-v6.html`) shows each of these in a "changed since v5" box.

1. G2–G4 show "Volume … (built in)" as their default; **Nothing is a real pick that silences the key** (v5: Nothing was
   the default).
2. LT and RT are remappable. A button sending LT/RT, a pad button fed by three controls, and a trigger fed by two (LT→RT
   while RT still sends RT) work, but **the App drives the whole controller** until the R6 driver update; the menu says
   so before the pick, and Developer runs on the Driver cannot be confirmed while such a pick is in force.
3. A hotspot click opens the menu at the hotspot; a label click at the label.
4. "Reset all remaps" asks no confirmation; it never touches learned buttons.
5. Leaving Mapping does not cancel a running "Re-learn".
6. G5 → Guide lights the Start drawing as linked (only while Start still sends Guide).
7. Until R6, a paddle or SAX key is seen only as the pad button the controller's profile turns it into, so remapping that
   button also changes what the paddle or SAX key sends (A↔B swapped: SAX left sends B). Their menus say so.
8. Profile stays remappable, but the Mac cannot stop the controller's own profile switch: each press also changes what
   the paddles and SAX keys send. The menu says so.
9. Edit layout forces the All tab; the status line says "needs a driver update" instead of "needs GDHM v2".

## Not in step 1

Paddles and SAX as sources, hiding their echo, three-plus sources, button → trigger and two-trigger targets on the
Driver path (R6, one driver replacement); checking trigger remaps in Developer mode (R6); keyboard, mouse and macros
(R7, with T11); per-game profiles.

## Done when

The owner maps G1 to Y from the menu and the three templates pass on App and on Driver; a mapped G3 leaves the volume
alone while G4 still mutes (or, if R0 failed, the owner's recorded choice is in force); old mapping files load
unchanged; after R4 the owner's mapping is what it was before; `swift test` and the Python tests are green; no driver
replacement was needed.
