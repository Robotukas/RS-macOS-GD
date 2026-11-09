# Developer mode: guided, recorded test runs

Status: plan v2 (2026-11-09), after a three-lens review of v1 against the code (findings folded in below).
Mockup: `docs/mockups/developer-mode.html` (v1; the differences listed under "Mockup corrections" apply).
Decisions taken with the owner's "continue": **A** a third toolbar button next to "Edit layout"; **B** sound last,
off by default; **C** build order below. Owner's rules for this feature, verbatim: "it would highlight what to press
so you can record driver or engine or app"; "give max 5 sec, pause in case I have a call, do step back in case is
needed"; "prepare as templates so it can be re-run"; "always add as template so you can choose testing template to
start".

## Why

During the T7 live checks the owner and I could not get a consistent recording: I asked for a movement, the capture
window started before or after the hands moved, and twice the result looked like a driver fault when it was a timing
miss. The feature removes the stopwatch: the app says what to move, waits for the hands to be still, starts the window
on the first movement, records what the virtual pad sent on a confirmed input path, judges it, and saves a report that
can be compared with the same template run on another path.

## What it is

A third GUI mode, exclusive with Edit layout and the guided learn: **Developer**. Switching it on shows a bar
(Record on · Template · Start) above the drawing and opens the virtual-pad reader. A run walks a *template* of
*steps*. Each step: the control is highlighted (purple pulse; its linked output control, when different, lit a dimmer
purple), "Let go of everything" until the receiver frame has been neutral for 300 ms, then "Go": the window (at most
5 s, template-set) starts on the first movement of the wanted control and ends early once the pass condition is met and
the control has been back at rest for 300 ms; sticks and triggers get a 0.5 s "Let go" tail. Then an automatic verdict:
✓/✗ on the drawing and in a chip strip. Pause, Back, Skip and Stop. The run ends with a result table under the drawing
and a JSON report on disk. The mode changes nothing but the input path, only for the run, and puts back exactly what
was there (including a tripped breaker).

## Where it lives in the code

| Concern | Today | Developer mode |
|---|---|---|
| Mode flags | `device.editor.isEditing`, `device.learn != nil`; nothing enforces exclusivity | `device.dev: DevSession?` (nil = mode off). Turning Developer on calls `cancelLearn()` and is disabled while `editor.isEditing`; while `dev != nil` the `LearnToolbar` is hidden, "Edit layout" (button and ⇧⌘E menu item, App.swift ≈198) is disabled, the status strip is hidden, tap-to-learn and hit testing are off. "Developer ✓ Done" during a run = Stop then off. Driver ▸ Input path menu is disabled while `dev?.isRunning` |
| Toolbar | `LayoutToolbar` (ControllerView.swift ≈957–1018), `Button("Edit layout")` ≈1005 | second button `Developer` beside it |
| Drawing | `HotspotView` (≈203–256): orange from the receiver frame; `MagnifierView` (≈155–201) used by the learn flow | overlay states `wanted` (purple ring + pulse; steady ring with ❚❚ while paused), `linked` (dim purple), `passed` (green), `failed` (red), `skipped` (grey slash), `inconclusive` (amber). While recording, the **decoded pad state** is drawn in purple on the wanted control (second stick dot / trigger fill / button fill) next to today's orange receiver state, so "receiver moved, pad didn't" is visible. `MagnifierView` follows the wanted control. Rest steps outline every hotspot faintly. `finish` keeps ✓/✗ until the next Start or Done |
| Receiver frames | `HIDMonitor` → `EnvisionProDevice.handleGamepadReport` → `ingest` (every path: the engine saw 964 Hz in LIVE on 2026-11-09) | `EnvisionProDevice.frameTap: ((GamepadFrame, UInt64 tK) -> Void)?` called per raw report (before the 125 Hz publish cap), main thread. Used for: the "hands still" gate, the window start, the frame count, and the **reference** (below) |
| Virtual pad reports | nothing in the app; `padlat.swift:41–49` is the template | `VirtualPadReader` (Sources/GDHub/Output/VirtualPad/VirtualPadReader.swift): IOHIDManager matching the **active identity** (`PadIdentity.named(defaults "vhid.pad.identity") ?? .default` → VID/PID) **and** `kIOHIDSerialNumberKey == PadIdentity.serial` ("GDHub-1"); lifecycle exactly as `GamepadHIDReader.swift:40–66` (SetDispatchQueue, Activate, cancel handler releasing the retained context); `IOHIDManagerRegisterInputReportWithTimeStampCallback`; non-exclusive. Opened when the mode is switched on. Publishes `matchedCount`; exactly 1 is required for a step to be judged |
| Pad report layout | `MapBlobEncoder.xboxBT16Reports` / `xboxBT16Placements` (117–139) is what the C core and the dext build from; `PadReportBuilders.xboxBT16` is an independent Swift builder | `PadReportDecoder(reports:placements:)` built from the encoder's tables: report 0x01 (16 B: LX LY RX RY u16 centre 0x8000, Y negated; LT RT 0…1023 in u16; byte 13 hat 0 none/1 N…8 NW; byte 14 A B X Y LB RB View Menu; byte 15 bits 0–1 LS RS) and report 0x02 (2 B, Guide bit 0). HAT8 special-cased to four D-pad items. Keeps a merged held state across both reports |
| Expected output per control | `ControlMapping.isMapped` is true for G keys although the mapper drops them; paddles/SAX reach the pad only as their echo | **by simulation**: build a `GamepadFrame` with the control's binding active (`buttons[cid]` + `physicalBits[cid]`), run `PassthroughPadMapper.padState(frame, mapping)`, diff against `.neutral` → `expected: {buttons:[…], hat:…, guide:Bool}`; empty = "nothing on the pad". One `digital` rule then covers button, paddle, SAX, D-pad direction, G key, Profile and Start→Guide |
| Input path | `DriverManager.writeInputPath` (595–603) bumps `inputPathChoice` and, for arming values, deletes the breaker keys; `inputPathStored` refreshes every 5 s; `TapStatusReport.path` echoes the request, `armed` says what drives the pad | see "Input path: confirm and restore" |
| App support paths | `MappingStore.defaultURL(fileName:)` honours `GDHUB_SUPPORT_DIR` | reports `dev-runs/<yyyy-MM-ddTHH-mm-ss>_<path>_<templateId>.json`; marker `dev-runs/.inflight`; templates `dev-scripts/<id>.json` |
| Tests | `Tests/GDHubTests/` flat, XCTest; `LearnSession.feed(_:now:)`/`tick(now:)` is the testable pattern | `DevRunCoreTests`, `DevJudgeTests`, `PadReportDecoderTests`, `DevExpectationTests`, `DevTemplateTests`, `DevRunReportTests`, `InputPathSnapshotTests`; Python `unittest` for the compare tool |

## Targets ("Record on")

Labelled by who drives the pad, from `driver.mode`:

| `driver.mode` | Targets | Notes |
|---|---|---|
| `.engine`, engine running | **Engine (App path)** · **Driver (shadow: engine posts, parity checked)** · **Driver LIVE** | the only mode in which the path is switched |
| `.engine`, engine not running | none; Start disabled, "Engine not running", a **Restart engine** button (`restartEngine` exists) | |
| `.inApp` | **In-app** (fixed) | record only: no path writes, no marker; a template with `paths` is refused with a hint |
| `.displayOnly` | Start disabled, "display-only copy" | |

A shadow run records the engine's output under shadow load; its driver evidence is parity, so shadow runs record
`parityOkBucket`/`parityMismatches` before and after each step and show them in the table. If `runningEnginePid`
changes or becomes nil during a run, or the mode flips engine → in-app (E1), the run auto-pauses (pid change) or ends
with `complete=false` and a note (mode flip).

Open question for the owner (not blocking): "driver or engine or app" — if "app" meant the old in-app mode (the GUI
driving the pad itself), that needs the engine stopped and is a separate target; today it appears only when the app
runs in in-app mode.

## Input path: confirm and restore

**Snapshot at Start** (raw `UserDefaults`, not `inputPathStored`): `inputPath`, `inputPathChoice`,
`tapBreakerTrippedAt`, `tapBreakerReason`, plus `tapStatus.latched`/`fallback`. Written to `dev-runs/.inflight` as
`{pid, processStart, snapshot, writtenValue, startedAt}`.

**Switch**: if the requested path equals the effective one and nothing is latched → write nothing. If the breaker is
latched or a final fallback is set and the run wants shadow or driver → a prompt: "Driver path was stopped by the
breaker: <reason>. Re-arm it for this run?"; the answer goes into the report. Otherwise `writeInputPath`.

**Confirm** (replaces v1's "wait for `path`", which only echoes the request): the status is good when
`report.pid == runningEnginePid`, `fallback == nil`, `latched == nil`, `mappingNote == nil`, and `armed` equals the
expected value — `inert` for Engine, `shadow` for shadow, `live` for Driver LIVE (and `!liveUnavailable`). LIVE needs
≥2 s of SHADOW and 100 translated frames after the 1 Hz poll, so the wait is up to **10 s**, shown in the instruction
box ("Switching to Driver LIVE… shadow 1.4 s, waiting for LIVE — keep the controller awake"), with Stop available. On
timeout: the `InputPathMenu.status` text with **Run anyway** / **Cancel**; "Run anyway" stamps every step
`pathUnconfirmed`. `effectivePath` is the observed `armed`, never the request. The same confirmation runs between the
passes of a `paths` template (no fixed rest).

**During the run**: `driver.$tapStatus` is observed; every change is appended to `pathEvents[{tMs, armed, fallback,
latched, liveUnavailable, mappingNote}]`; each step stores `effectivePath` at ready, window start and window end. A
step whose `armed` differs from the expected value at any point gets verdict `invalid(path changed)`, and a fallback
mid-run auto-pauses with the status text.

**Restore** (on finish, Stop, error, "Developer ✓ Done", and app termination): put the raw keys back exactly —
`set` or `removeObject` per key as in the snapshot — **without** `writeInputPath` (so no choice bump, no breaker
clearing); if a latch existed it is written back after the path so the engine latches again on its next poll. The end
text names what was restored ("Path put back to Driver (stopped by breaker, as before)"). A `willTerminate` observer
(all modes, App.swift) runs `finish(complete:false)` synchronously: defaults first, then the atomic report write. On
launch, if `.inflight` exists: restore only when the GUI is in engine mode, the marker's pid is dead, and the stored
`inputPath` still equals `writtenValue`; otherwise remove the marker and log a note.

## Model

```
DevTemplate  { schema:1, id:/^[a-z0-9-]+$/, version:Int, title, notes, paths?:[engine|shadow|driver],
               steps:[DevStep] }
DevStep      { id, kind, controls:[String] (layout ids; ≥1 except rest), title, detail,
               seconds: 1…5 (default by kind; a template may raise it up to maxSeconds:120 — the ring shows it),
               readySeconds?: default 2 (min; the hands-still gate can extend it), releaseSeconds?: 0.5 stick/trigger else 0,
               expect?: DevExpect, requires?: { mapping?: {control: bindingName} }, actions?: [DevAction] }
DevKind      rest | stick | trigger | digital | held          (digital covers button, paddle, SAX, D-pad, G key, Profile, Start)
DevExpect    stick   { minReports:100, extent:0.40, deadZone:0.12, otherStickStill:true, requireReturn:true }
             trigger { peak:0.90, release:0.05 }
             digital { items?: override of the simulated expectation; times:2 }
             held    { item, seconds }  (state stays set; no neutral or glitch — step 2)
DevAction    { toggleInputPath: { values:[…], intervalMs, count } }      (step 2; step 1 marks the step skipped(precondition))
DevVerdict   pass | fail(reason) | skipped(reason) | inconclusive(reason) | invalid(reason)   — custom Codable {"verdict":…,"reason":…}
DevAttempt   { startedNs, readyNs, windowStartNs, windowEndNs, superseded:Bool, verdict, metrics, entryState, entryRaw,
               effectivePath:{atReady, atStart, atEnd}, raw:[DevRawReport] }
DevRawReport { tMs: Double (from window start; negative = ready phase), id, bytes: hex, phase: ready|window|release }
DevMetrics   { padReports, padChanged, rawDropped, framesSeen, framesPerSecond, movingMs, expectedChanges, lossRatio,
               onsetMs, values:[String: Double] (fixed keys per kind: ls.reportsOutside ls.xMin ls.xMax ls.yMin ls.yMax
               lt.peak bit.rises bit.falls hat.visited neutrals …), detail: String }
DevStepResult{ index, stepId, kind, controls, expected (resolved), attempts:[DevAttempt] }   — the last attempt is the verdict
DevRunReport { schema:1, startedAt (ISO-8601 with offset), endedAt, t0Ns, complete, requestedPath, effectivePath,
               pathEvents, header:{ appBuild, engineBuild, dextBuild, guiMode, padIdentity, readerMatched, vpadMaxRateHz,
               xlateCore, mapping, mappingHash (SHA-256 of sorted-keys JSON), templateId, templateVersion, templateSha256,
               decodeTable (reports+placements) }, steps:[DevStepResult], notes:[String] }
```

All timestamps inside a run are ns on `LatencyMeter.nowNs()` (CLOCK_UPTIME_RAW = the HID kernel timestamp base);
raw reports are windowed by `LatencyMeter.nanos(fromMach:)` of their kernel timestamp. `DevRunReport` and `DevTemplate`
decode tolerantly (`init(from:)` with `decodeIfPresent` defaults and a schema gate, as `TapStatusReport` does).
Raw per attempt: judged on the full stream, serialised as head 4000 + tail 2000 with `rawDropped`.

## Judging (`DevJudge`, pure; all thresholds in `DevJudge.Rules`)

The judge works on the **merged held state** (zero-order hold: the state at time t is the last report at or before t,
across reports 0x01 and 0x02), seeded with the last report seen before the step (`entryState`). If the reader has seen
no report since it opened, the verdict is `inconclusive("pad state unknown")`, never pass. If `matchedCount != 1` at
window start → `inconclusive("reader matched N pads")`. Tolerances everywhere: buttons/hat/guide exact, sticks inside
the 12 % dead zone, triggers below 5 % (the sink's own dead band is 0.2 %, so jitter alone must not fail a step; the
exact change count is kept as `padChanged`).

| kind | pass when |
|---|---|
| rest | `entryState` known and neutral within tolerance, and the held state never left tolerance during the window |
| stick | ≥ `minReports` reports with that stick outside the dead zone; the axis reached ≥ +extent and ≤ −extent on both X and Y (four directions); the *other* stick stayed inside the dead zone; the held state at window end (after the release tail) is inside the dead zone and has been for ≥300 ms |
| trigger | the held trigger exceeded `peak`; held state at end below `release` for ≥300 ms |
| digital | every expected item rose and fell `times` times (hat: reached the expected direction and returned to none `times` times; guide via report 0x02); no *unexpected* button/hat/guide change (the control's own echo is part of the expectation, so it is not "unexpected"); if the expected set is empty: nothing changed within tolerance. `detail` says "bit already set at step start" when `entryState` had it |
| held | step 2 |

Every verdict has `detail` in words and `values` in numbers. **Reference** (so two runs compare on what the path
lost, not on how long the hands moved): the GUI's own receiver frames from `frameTap` go through
`PassthroughPadMapper.padState` and the sink's static `snapped`/`unchanged` (dead band 0.002) to count
`expectedChanges` and the first changed frame's tK; `lossRatio = padChanged / expectedChanges`, `onsetMs = first pad
change − first frame change`. `framesSeen` is labelled "frames seen by the GUI".

## Runner

`DevRunCore` is a pure state machine driven by events and returning actions, so it is unit-tested with a fake clock
and no IOKit; `DevSession` (`@MainActor ObservableObject`) is the thin shell that owns the Task, the reader, the path
control and the report writer.

```
events : start(target, template) | tick(nowNs) | frame(GamepadFrame, tK) | reports([DevRawReport]) | status(TapStatusReport)
         | enginePid(Int?) | controllerStatus | pause | resume | back | skip | stop | terminate
actions: setCapture(on, windowStartNs) | writePath(value) | confirmPathStarted | writeReport(report) | restorePath
         | setHighlights([id: state]) | setInstruction(text, sub) | playTick (step 3)

idle ─Start─▶ snapshot ─▶ switching(≤10 s, confirm) ─▶ step k: ready ─▶ window(≤seconds) ─▶ release(tail) ─▶ judge ─▶ k+1 … ─▶ finished
                                                           ▲   waits: controller .active, frames flowing, receiver neutral 300 ms,
                                                           │   path still confirmed; starts the window on the first movement of a
                                                           │   wanted control; ready timeout 5 s ⇒ attempt "no movement"
  Pause  : any step phase → paused (steady ring, nothing recorded, path untouched); Resume → ready of the same step (re-confirms path)
  Back   : during window/release → restart this step (attempt superseded); during ready (or <1 s into the window) → previous step,
           its result superseded; at step 0 the button reads "Restart step"; never crosses a `paths` boundary
  Skip   : verdict skipped("by user"); chip grey with a slash
  Stop   : any state (incl. switching, paused, between passes) → finished(complete=false), partial table shown, path restored
  auto-pause: controller leaves .active, matchedCount != 1, engine pid change, fallback/latch appears
  after finished: clicking a red/amber chip or control re-runs that step only; "Re-run failed (n)" runs them all
```

- Phase timers: one `Task` per phase with a generation token checked after every `await`; `Task.sleep` on the
  continuous clock is used only to wake up, all stamps come from `LatencyMeter.nowNs()`.
- The reader captures continuously while the mode is on (ring buffer); the core windows reports by kernel timestamp,
  so Pause/Back at phase edges lose nothing and the ready phase is kept (negative `tMs`).
- `finish(complete:)` is the single exit: stop capture, judge the open attempt as `invalid("stopped")`, write the report
  atomically (kept in memory and shown in the hint if the write fails), restore the path, remove `.inflight`, clear
  `wanted`/`linked` states (keep verdict colours).
- Keyboard: Space Pause/Resume, ← Back, → Skip, Esc Stop (tooltips on the buttons).

## Templates

- **Location and format**: bundled flat as `Sources/GDHub/Resources/dev-script-<id>.json` (both SwiftPM `.process` and
  the Xcode wrapper flatten resource folders), listed with `urls(forResourcesWithExtension:"json", subdirectory:nil)`
  filtered by the `dev-script-` prefix; on-disk copies in `~/Library/Application Support/GDHub/dev-scripts/<id>.json`.
  The picker lists bundled templates (read-only, marked "built-in") and the folder's files (marked "local"); a local
  file with a built-in's id overrides it and is marked "local override". **Shipped fixes reach every Mac**: nothing is
  copied; built-ins are read from the bundle each time. Local = the owner's or my additions. "Reload" re-reads the
  folder.
- **Validation** (`DevTemplate.validate(layout:) -> [String]`): unknown control id, kind not fitting the control's
  layout kind, duplicate step ids, `paths` values outside engine/shadow/driver, `seconds` out of range (clamped with a
  warning), bad `id`. Messages like "full.json step 7: unknown control g6" go to the hint; Start is disabled while any
  error stands. A unit test validates every bundled template against the bundled layout. `kind` is decoded as a
  String and checked.
- **Remembered**: last template and target in `AppStorage` (step 1), so Start alone re-runs.
- **Built-ins (step 1)**: `full` is **generated** from `layout.controlsByOrder` (all 31 controls) so it cannot drift —
  one rest, both sticks, both triggers, every digital control (D-pad as four steps, each lighting the pressed
  direction), G1–G5 and Profile (expected "nothing on the pad" unless mapped), Start (Guide via 0x02), paddles and
  SAX via their echo; `sticks` (rest + two sticks); `gkeys` (G1–G5, Profile, Start). Durations by kind: rest 3 s,
  stick 5 s + 0.5 tail, trigger 3 s + 0.5 tail, digital 3 s; ready ≥2 s. Full ≈ 31 steps × ~5 s ≈ 2.5–3 min with
  early finish.
- **Rule (owner, 2026-11-09): every test I devise is added as a template**, committed as a bundled file with `notes`
  saying when to use it. First batch after step 1: `t7-sleep-neutral` (seconds raised to 120 for one rest step after
  the controller sleeps), `remap-g1-as-y` (`requires: {mapping: {g1: "y"}}` → skipped when absent), `paddles-sax-echo`;
  `t7-rt-hold-toggle` once `actions` and `held` exist (step 2).
- `paths`: the segmented control becomes read-only "Runs on: Engine → Driver LIVE"; one chip row per pass; between
  passes the box reads "Switching to Driver LIVE… hands off" with highlights cleared; Pause and Stop work there.

## UI pieces (SwiftUI; `Sources/GDHub/UI/DeveloperBar.swift`, `DeveloperRun.swift`, edits in ControllerView.swift)

`DeveloperBar` (targets, template picker with source tags and Reload, Start/Stop, path note) · `DevInstructionBox`
(ring with the step's real length, title, detail, Back/Skip/Pause) · `DevLiveStrip` (target, armed state, frames seen
/s, pad reports, changed, neutrals, parity for shadow, battery %) at 4 Hz · `DevChips` (per pass) · `DevResultTable`
(`Table`: #, Step, Expected, Seen, Loss, Onset, Frames, Result; buttons: Save report, Re-run failed (n), Run again on…
(step 2), Copy summary (step 2)).

## Tools for me (repo, not the app)

- `scripts/tools/dev-run-compare.py A.json [B.json]`: one table per report; with two reports pairs steps by `stepId`,
  checks `templateSha256`, `mappingHash`, `effectivePath` and warns on mismatch; marks differences by numeric
  thresholds (lossRatio Δ > 10 %, onset Δ > 5 ms, verdict change); "—" for steps missing in an incomplete run; refuses a
  newer schema; exit 1 when verdicts differ. Tests: `python3 -m unittest discover -s scripts/tools`, fixtures under
  `Tests/GDHubTests/Fixtures/dev-runs/` (declared `.copy("Fixtures")`, **generated by a Swift golden test** from the
  encoder so both languages share one schema, and decoded back in Swift).
- `docs/protocol/developer-mode-files.md`: the template and report formats with an example of each.

## Build order (C)

1. **Step 1 (now):** model + tolerant Codable; `PadReportDecoder`; expectation by simulation; `DevJudge`
   (rest/stick/trigger/digital); `DevRunCore` + `DevSession`; `VirtualPadReader`; input-path snapshot/confirm/restore
   + `.inflight` + `willTerminate`; report writer; templates (bundle listing, folder, validation, remembered choice,
   `paths`); generated `full`, `sticks`, `gkeys`; UI pieces incl. pad-state overlay, linked lighting, magnifier, Skip,
   keyboard; compare tool + docs; unit tests. Install; run `full` on Engine, then Driver LIVE; compare.
2. **Step 2:** `held` kind and `actions` (then `t7-rt-hold-toggle`), volume consumer-report check for G2–G4, "Run again
   on…", "Copy summary", a two-report comparison view in the app.
3. **Step 3:** sound (tick at Go and Done, off by default).

## Tests that give confidence

- `DevRunCoreTests` (fake clock, scripted events): Pause in ready / window / release; Resume re-confirms; Back at
  step 0, during window, during ready; Skip; Stop in switching, paused and between passes (no further passes); finish
  writes exactly once; restore on every exit; confirm timeout → Run anyway path stamps; fallback mid-step → invalid.
- `DevJudgeTests`: synthetic held-state sequences per kind incl. "no report in the last 300 ms" (pass by hold),
  "bit already set at entry", jitter inside tolerance, cross-talk stick, hat round trip, guide via 0x02, empty
  expectation with and without noise, inconclusive cases.
- `PadReportDecoderTests`: decode `PadReportBuilders.xboxBT16(state)` for random states within quantisation; golden
  hex lines from a padlat capture; Y sign; trigger mask; hat 0–8; lone 0x02 merged.
- `DevExpectationTests`: every layout control's simulated expectation against a table (a→A, paddle_outer_left→hat W,
  g1→nothing, start→guide, dpad_up→hat N, sax_left→A).
- `DevTemplateTests`: every bundled template validates; bad files produce the right messages; clamping warns.
- `InputPathSnapshotTests` (`UserDefaults(suiteName:)`, temp support dir): nil → driver → restored to absent; latched
  breaker survives a run; marker restored on launch under the conditions and removed otherwise.
- `DevRunReportTests`: encode → decode round trip, tolerant decode of an older file, golden fixture generation.

## Mockup corrections (v1 → what is built)

Remove the All/Front/Back/Sides tabs and the "Mapping" button (they arrive with the remap feature). Targets renamed as
above. Stick text: "Roll one or two slow circles, then let go". Steps end early; Back = media-player rules; Skip added;
Stop shows the partial table; paused = steady ring; ring starts at the step's real length; `full` is all 31 controls;
templates come from the bundle and `dev-scripts/`; "Full check" ≈ 2.5–3 min.

## Not in this feature

Tabs, changing mappings or layouts, anything that writes to the controller, switching between engine and in-app mode.

## Done when

`full` runs end to end on Engine (App path) with every step passing when the owner does what the highlight says; the
same template on Driver LIVE produces a report the compare tool pairs step by step with loss ratio and onset; Pause,
Back, Skip and Stop behave as specified; the input path and breaker keys are back to the snapshot after every exit,
including Cmd-Q mid-run; `swift test` and `python3 -m unittest discover -s scripts/tools` green.
