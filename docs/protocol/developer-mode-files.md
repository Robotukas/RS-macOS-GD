# Developer mode: template and report files

Developer mode asks the owner to do a short, guided set of things on the controller (a **template**) and records what
the virtual pad sent for each (a **run report**). Both are plain JSON, schema 1. The model lives in
`Sources/GDHub/Developer/DevModel.swift`; the plan is `docs/plans/developer-mode-plan.md`.

Decoding is tolerant on both sides: a missing key takes its default, an unknown key is ignored. Only the `schema`
number decides whether a file is understood: **a file with a schema newer than 1 is refused** by the app and by the
compare tool (exit 2).

## Where files live

| What | Where |
|---|---|
| Built-in templates | the app bundle, flat, `dev-script-<id>.json` (source: `Sources/GDHub/Resources/`). Read from the bundle each time, so a shipped fix reaches every Mac. Shown as "built-in". |
| Local templates | `~/Library/Application Support/GDHub/dev-scripts/<id>.json`. Shown as "local"; one with a built-in's id overrides it ("local override"). "Reload" re-reads the folder. |
| Run reports | `~/Library/Application Support/GDHub/dev-runs/<yyyy-MM-ddTHH-mm-ss>_<path>_<templateId>.json`. `<path>` is the effective path (the requested one if none was observed), characters other than letters, digits and `-` become `-`. Written atomically (temp file, then rename). |
| In-flight marker | `dev-runs/.inflight`: `{pid, processStart, snapshot, writtenValue, startedAt}`. Exists only while a run has changed the input path; on the next launch it lets the app put the path back after a crash. Not a report; ignore it. |

`GDHUB_SUPPORT_DIR` moves the whole support directory (tests use it).

## Template format

```
{ schema, id, version, title, notes, paths?, recordReceiver?, steps: [ step ] }
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `schema` | int | 1 | Format version. Newer than 1 is refused. |
| `id` | string | required | `^[a-z0-9-]+$`. Also the file name part and the id reports carry. |
| `version` | int | 1 | Bump when the steps change in a way that matters for comparison. Must be 1 or more. |
| `title` | string | "" | Shown in the picker. |
| `notes` | string | "" | When to use this template. Every template devised for a test is committed with one. |
| `paths` | [string]? | absent | One pass per entry, in order, each of `engine`, `shadow`, `driver`. Absent = run once on the target chosen in the bar. See "paths" below. |
| `recordReceiver` | bool? | absent | `true` = every step stores the receiver's reports under `receiver` (see "Recording the receiver" below). Absent = only `record` steps do. Left out of the file when absent, so a template without it keeps its bytes. |
| `steps` | [step] | [] | At least one. |

### Step

| Field | Type | Default | Meaning |
|---|---|---|---|
| `id` | string | required | Unique in the template. Reports pair steps by this id, so keep it stable. |
| `kind` | string | required | `rest`, `stick`, `trigger`, `digital`, `held` (an item that must stay held for the whole window; see "held steps" below) or `record` (no verdict; see "Recording the receiver" below). A build that does not know a kind refuses the template visibly ("unknown kind"). |
| `controls` | [string] | [] | Ids from the control layout (`layout.controlsByOrder`). At least one, except for `rest`, which takes none. The control's layout kind must fit: `stick` needs a stick, `trigger` a trigger, `digital` a button (D-pad, paddles, SAX, G keys, Profile and Start count as buttons), `held` and `record` a button or a trigger. |
| `title` | string | "" | The instruction headline. |
| `detail` | string | "" | The line under it. |
| `seconds` | number | by kind | Length of the capture window. Range 1...120; outside is clamped with a warning. Defaults: rest 3, stick 5, trigger 3, digital 3, held 5, record 20. The ring shows it; a step may end earlier when its goal is reached. |
| `readySeconds` | number | 2 | Minimum "hands off" time before Go. Range 0...30. The hands-still gate can extend it. |
| `releaseSeconds` | number | 0.5 for stick, trigger and held, else 0 | Tail after the window where the owner lets go. Range 0...10. |
| `expect` | object? | by kind | Overrides of the judge. Flat; only keys that fit the step's kind apply, the rest are ignored. |
| `requires` | object? | absent | `{ "mapping": { "<control>": "<output>" } }`. If the control does not currently send that output (see "requires" below), the step is recorded as `skipped` with the reason, not failed. |
| `actions` | [object]? | absent | Held steps only. The one action is `{ "toggleInputPath": { "values": ["driver","engine"], "intervalMs": 3000, "count": 12 } }`; see "held steps" below. Without the background engine (in-app mode) the step is recorded `skipped` ("needs the background engine"). |

`expect` keys: stick `minReports` (100), `extent` (0.40), `deadZone` (0.12), `otherStickStill` (true),
`requireReturn` (true), `flicks` (absent) and `requireDirections` (true); trigger `peak` (0.90), `release` (0.05)
and `times` (1); digital `items` (`{buttons:[...], hat:"N"..."NW", guide:bool}`, replaces the simulated expectation;
empty means "nothing on the pad"), `times` (2) and `volume` (absent; `"unchanged"` or `"changes"`, see "Volume
checks" below); held `item` (`RT`, `LT`, a button name such as `A`, `D-pad left`,
or a hat direction `N`…`NW`; absent = derived from the control), `minLevel` (0.5, the trigger value that counts as
held) and `releases` (absent; a list of the step's own controls that must be let go while the item stays held, see "Held
steps" below); record `rises` (absent; how many presses in all the step asks for, see "Recording the receiver" below);
digital `builtInEcho` and digital, trigger and held `background` (see "Paddles, SAX keys and the hiding check" below).
`items` may also carry `lt` and `rt` (`true` = the pad's trigger that the step pulls all the way, the other one staying
still; left out of the file when false).

- `times` (digital) is how many times every expected item must go down and up ("Tap A 10 times" = 10). On a trigger
  step it is the number of **full pulls**: the pad's value reaches `peak` and is then released to `release` or less,
  that often (default 1). It must be 1 or more.
- `flicks` (stick) replaces the four-direction circle: the pad's stick must leave the dead zone from rest at least that
  many times (an *onset*: outside the `deadZone` after having been inside it for at least 60 ms, the same rule the
  latency uses), with the usual return to centre at the end. `minReports` then applies only if the step sets it.
  Must be 1 or more and only on a `stick` step.
- `requireDirections: false` drops the four-direction (extent) check of the stick rule; flick steps set it.

### `requires`

`requires.mapping` names what a control must send **at the moment the run starts**; it compares the control's effective
output (`ControlMapping.effectiveOutput`: what Mapping set, or the control's factory output when nothing was set) with a
value from a closed, lowercase vocabulary:

- a pad output: `a b x y lb rb lt rt view menu l3 r3 guide dpad_up dpad_right dpad_down dpad_left` (`"g1": "y"`);
- `nothing` (`"g2": "nothing"`: the control sends nothing, and for G2–G4 that also means the volume function is off);
- `built_in` (`"g4": "built_in"`: the control keeps its own function; valid for `g2`, `g3`, `g4` and the six paddle and SAX
  keys, where it is "Controller's profile": the button the controller's own profile gives the key).

The controls are the remappable ones (a b x y lb rb lt rt view menu l3 r3, the four D-pad directions, start, profile,
g1–g5). Learned bindings are not compared. A miss skips the step in the owner's words: `needs G1 → Y: set it in Mapping`,
`needs G2 → Nothing: set it in Mapping`, `needs G4 left at its built-in function: Reset it in Mapping`, `needs Paddle inner right on Controller's profile: Reset it in
Mapping` (`Reset it` when the wanted output is the control's factory one).

Start is blocked when **every** step of the selected template would be skipped for an unmet `requires.mapping`: the bar
says `Needs G1 → Y: set it in Mapping first (leave Developer mode, press Mapping, pick, Done)` (several needs are joined
with `; `, each in the owner's words: `G2 → Nothing`, `G4 at its built-in function`, `Paddle inner right on Controller's profile`). When only some steps are unmet the
run starts and those steps are recorded as skipped with their reason. The runner never sets a mapping itself.

Developer mode under remaps: a digital, trigger or held step expects what the virtual pad shows for the control **under the
current mapping** (G1 sent to Y expects Y; A and B swapped, A expects B; LT sent to RT: a pull of LT expects RT and the
pad's LT staying still; G1 sent to LT expects one full LT pull per press and RT still). Trigger remaps are judged: the
step skip of step 1 ("trigger remaps are checked after the next driver update") is gone. The window of an `lt` / `rt` step
opens on the physical pull of that trigger, not on the pad's trigger value. A trigger or held step also fails when a
button the step did not ask for changes on the pad ("unexpected change on B"). When the pad's trigger a control is mapped
to cannot be worked out (the expectation is empty), a trigger or held step on `lt` / `rt` judges that trigger itself, as
before.

When a Driver pass cannot be confirmed because the driver cannot express the current mapping (build 24 cannot hide a
paddle's own button or pull a trigger from a button), the question reads `Driver pass cannot be confirmed: <the engine's
mapping note>. Press Stop to keep the App result, or Reset that remap first.` Pressing Stop there ends the run with
the App pass as its result: the Driver pass is **stood down** (the chip row shows a grey "stood down", the report gets
the note `Driver pass not run: this driver version cannot take this mapping (<note>). The App pass is the result of this
run.`, and no report is written for the pass that did not run).

### Volume checks (`expect.volume`)

A **digital** step may say what the Mac's volume must do while its key is pressed: `"unchanged"` (the key is silenced
or sent to the pad: G2 → Nothing, G3 → RB) or `"changes"` (the key kept its built-in function: G4 mutes and unmutes).
Anything else, or a non-digital step, is a validation error. It is judged on **counted change events**, not on two
samples, between the step's Go and the end of its release tail (give such a step `releaseSeconds: 1`):

- CoreAudio property listeners on the default output device (software volume on the main element, else channels 1 and
  2; mute; and the default-output-device property itself). Observation only, no permission; nothing sets a volume.
  A notification counts only when the value really differs from the one before.
- Raw **0x11** reports from the receiver's Consumer Control interface (interface 4: `11 01` volume up, `11 02` down,
  `11 04` mute, `11 00` release). They arrive whether or not the Mac acts on the key, so a silenced key still proves it
  was pressed. They are read by the app's existing HID reader (a plain non-exclusive open, never a seize).

| Verdict | When |
|---|---|
| `pass`, `unchanged` | at least one key report (a 0x11 report with a key bit set) and no volume or mute change event |
| `pass`, `changes` | at least one key report and at least one volume or mute change event |
| `fail` | `unchanged` with a change event, or `changes` with none |
| `inconclusive` ("cannot judge", never a pass, never a fail) | no key report arrived; or the device has neither a software volume nor a mute (or there is no output device); or the volume was at its limit in the key's direction at Go (volume down at 0, volume up at 1.0; a mute key has no limit); or the default output device changed during the span |

The pad part of the step is judged as usual. Folded together: pad pass and volume pass is `pass`; pad pass and volume
`inconclusive` makes the step `inconclusive` (`cannot judge the volume: ...`); a failure on either side is `fail` and
a pad failure is never hidden by a volume that could not be judged.

### Held steps

The window opens on the first frame where the control is active (trigger above 5 %, button bit set). From then on the
pad item must stay held with no sample below: a trigger at or above `minLevel`, the button bit set, the hat at the
direction. Every held-to-released transition is a drop, and a report that puts everything at neutral is one. The item
must be held within 2 s of the window start (the pull is still on its way when the window opens). Pass = `held.drops`
0 and held at the end of the window. Only the window is judged; the release tail after it is where the owner lets go.
Metric values: `held.minLevel` (lowest trigger value once it had been all the way down), `held.drops`,
`held.padReports`, `held.ms`; with actions also `held.handOvers` and `held.handOversConfirmed`; with `expect.releases`
also `held.released`.

A held step may name several `controls` (for example `["g1","y"]`): the window opens on the first frame where **any** of
them is active, and `expect.item` names the one pad item that has to stay held.

`expect.releases` (held steps only) makes a hand-over part of the pass: every listed control (each must be one of the
step's `controls`) has to be seen **active and then released** while the item stays held. "Active" is
`ControlMapping.isActive(control, frame)` on the receiver frames (the physical key, whatever it is mapped to), so it is
independent of what the pad shows. The control counts as held at the moment the item first becomes held (or when it is
next seen active), and its release is the first receiver frame after that without it; a release before the item was held,
or after the window's end (in the release tail), does not count. The item must still stay held for the whole window as
for any held step, so a template can say "hold G1 (sent to Y), also hold Y, let go of G1, Y must still be down" and cannot
pass unless G1 really was let go. A listed control that was never let go fails the attempt with a plain reason (`G1 was
never let go while Y stayed held`; `G1 was never seen pressed while Y stayed held` when it was never active). Without any
receiver frames for the window the attempt is `inconclusive` (`cannot tell when G1 was let go: no receiver frames`), never
a pass. Once every listed control has been let go and the item stayed held for 0.5 s more, the owner letting go of everything before the window runs out ends the step and is not a drop; this is read from the receiver (no control of the step is down in the last frame before the pad dropped the item), so a pad that drops the item while a button is still down stays a failure.

Without `actions` the window runs the full `seconds` and never ends early. With `toggleInputPath` actions the window
ends 1.5 s after the last action has completed (`count` × `intervalMs`; `seconds` is not used then, and a warning says so
when it is shorter): one path write at the window start and then one per `intervalMs`, cycling through `values`. Several
actions run one after the other. A `pathEvents` entry with `wrote` records each write; the tap-status changes that follow
are recorded as usual, and the "armed changed during the step" invalidation is off for such a step. A hand-over counts as
confirmed when the engine is seen armed as the value asks (`inert` for engine, `live` for driver, `shadow`) before the
next write. When the hand-overs are over (and on Pause, Back or Skip) the path is written back to what the pass tests;
the run's final restore puts the original keys back as always.

### `paths` (multi-run)

With `paths`, the target control is read-only ("Runs on: Engine → Driver LIVE"). The app runs the whole step list once
per entry. Between passes it switches the input path, waits for it to be confirmed (up to 10 s), shows "Switching…
hands off", then continues. Back never crosses a pass boundary; Stop ends the run with no further passes. The result is
one report; each step's `effectivePath` tells which pass produced it. The In-app target refuses a `paths` template.

### Validation messages

Errors keep Start disabled; warnings let the run proceed with the value clamped. Messages are shown in the hint, in the
style `<id>.json step <n>: ...`:

- `id "X" may only use lowercase letters, digits and dashes` / `version must be 1 or more` / `has no steps`
- `paths is empty (leave it out to run on the chosen target)` / `paths value "X" is not engine, shadow or driver`
- `step n: has no id` / `duplicate step id "X" (also step m)` / `unknown kind "X"`
- `step n: a rest step takes no controls` / `needs at least one control` / `unknown control X`
- `step n: a stick step does not fit control X (a button)`
- `step n: unknown control X in requires`
- `step n: requires names unknown output "X" (use a pad output such as y or dpad_up, nothing, or built_in)` (values are
  lowercase and case-sensitive) / `requires built_in for X, but built_in is valid only for g2, g3, g4 and the paddle and SAX keys` /
  `requires names X, which has no output that can be remapped` (`built_in` is valid for g2, g3, g4 and the six paddle and SAX keys)
- `step n: expect names unknown button "X"` / `unknown hat direction "X"`
- `step n: expect times T must be 1 or more` / `expect flicks F must be 1 or more` / `expect flicks only applies to stick steps`
- `step n: expect volume "X" must be "unchanged" or "changes"` / `expect volume only applies to digital steps`
- `step n: expect builtInEcho only applies to digital steps` / `expect builtInEcho needs exactly one control, and it must be a paddle or SAX key`
- `step n: expect background only applies to digital, trigger and held steps` / `expect background names X, which is not one of the step's controls (the control that is held first has to be one of them, or the step never starts)`
- `step n: expect releases only applies to held steps` / `expect releases names X, which is not one of the step's controls`
- `step n: toggleInputPath value "X" is not engine, shadow or driver` / `toggleInputPath needs values, a count of 1 or more and an intervalMs of 1 or more`
- warnings: `seconds S is outside 1...120, using U`, `readySeconds ...`, `releaseSeconds ...`

### Example

```json
{
  "schema": 1,
  "id": "lb-lt-both-paths",
  "version": 1,
  "title": "LB and LT on Engine, then Driver LIVE",
  "notes": "Quick path comparison for the left shoulder. Run it, then compare two passes with dev-run-compare.py.",
  "paths": ["engine", "driver"],
  "steps": [
    {
      "id": "rest",
      "kind": "rest",
      "title": "Hands off everything",
      "detail": "Put the controller down. The pad has to stay completely still.",
      "seconds": 3
    },
    {
      "id": "lt",
      "kind": "trigger",
      "controls": ["lt"],
      "title": "Pull LT fully, then let go",
      "seconds": 3,
      "releaseSeconds": 0.5,
      "expect": { "peak": 0.9, "release": 0.05 }
    },
    {
      "id": "lb",
      "kind": "digital",
      "controls": ["lb"],
      "title": "Press LB twice",
      "detail": "Press it, let go, press it again, let go.",
      "expect": { "times": 2 }
    },
    {
      "id": "g1-as-y",
      "kind": "digital",
      "controls": ["g1"],
      "title": "Press G1",
      "requires": { "mapping": { "g1": "y" } },
      "expect": { "items": { "buttons": ["Y"] } }
    }
  ]
}
```

A complete real template is `Sources/GDHub/Resources/dev-script-full.json`.

### Recording the receiver (`record` steps, `recordReceiver`)

Added for the paddle and SAX survey (remap step 2). A **`record`** step has no verdict: it stores what the receiver sends
and its verdict is `recorded` (the table says "recorded", in grey, and the chip is a grey number). A step of any kind in a template with
`"recordReceiver": true` stores the same data and is judged as usual; a `record` step stores it whatever the template says.

- The window opens on the first receiver report where **any** listed control is active, with today's "no movement within
  5 s of Go" failure when none is. A paddle or SAX key counts as active by the **fixed table of extra bits** (outer right 1,
  inner right 2, inner left 4, outer left 8, SAX left 16, SAX right 32), not by what the mapping stores, so the survey
  that checks the table can still start when a stored bit is wrong. Every other control is read the way the mapping reads it.
- It ends early once **all** of these hold: every listed control has gone down and up during the window; the total of the
  controls' presses reaches `expect.rises` (absent = no count condition); and the receiver's non-stick bytes (9 to 15)
  have equalled the report at Go for 350 ms, so a late echo release is still seen. `seconds` stays the upper limit.
- `expect.rises` is for record steps only and must be 1 or more.
- No verdict means no pad judging either: the pad reader, the entry state and the pad's report count do not matter.

What is stored (per attempt, next to `raw`): `receiver` = `[{n, t, hex}]` and, when some did not fit, `receiverDropped`.
Both keys are absent for a step that does not record.

| Key | Meaning |
|---|---|
| `n` | Index of the report: every report 0x06 the app received since the run started, counted from 1. |
| `t` | Milliseconds from the step's window start (negative before it; from the step's start when the window never opened). |
| `hex` | The 16 bytes of the report, space-separated lowercase hex, report ID first (`06 00 00 ...`), sticks included. |

A report is stored when its non-stick bytes (9 to 15: triggers, hat, buttons, extra bits) differ from the report before,
and always for the first report of the step, which is the baseline. The reports in between are equal to the one before the
gap. At most **4000** are kept per step; `receiverDropped` counts the ones left out. The reports start at the step's start
(the ready phase included), so an echo that comes a report before its bit is still in the file. `scripts/tools/echo-survey.py`
reads these files.

### Paddles, SAX keys and the hiding check (remap step 2)

A remapped paddle or SAX key sends only its pick; the button the controller adds for it (its **echo**) is hidden by
`EchoFilter`. The runner steps that filter on **every receiver report of the run** (the run-long filter, with the
mapping the run started with), so the reference, the window of a step and the hiding check all see the report the pad is
meant to show: a step on D-pad right does not open on a hidden paddle's D-pad right, and the reference counts no echo edge.
`record` steps and the receiver recording keep the report as the controller sent it.

- **Expectations of the six keys.** A remapped one expects its pick whatever echo is stored (its press is its identity bit
  alone). One left on Controller's profile resolves to the `builtInEcho` rule in every template.
- `expect.builtInEcho` (digital, one control, one of the six): exactly one pad item (a button, a D-pad direction or a
  trigger pull) comes with each press, the same item every press, whichever the profile gives; the attempt's `echoItem`
  names it and the Seen column says `Saw D-pad down on each press (2 presses, one item per press)`. A step with no
  `expect.items` on one of the six left on Controller's profile takes the rule without saying so (rows 1 and 4). A key for
  which the controller sent no button reads `cannot judge: the controller sent no button for this key` (verdict
  `inconclusive`, label "Cannot judge"), never a failure.
- `expect.background` (control ids from the step's `controls`): controls pressed first and let go last while the others
  are pressed ("hold A, press SAX left"). What each sends to the pad (worked out from the mapping) is left out of
  "unexpected change", and per item B: it is not set at the window start and comes up exactly once, before the first rise of
  every expected item, or is set there with no rise; it does not fall before the last fall of every expected item. Fail
  messages: `A dropped while View was being pressed (fell 2 times before the last View release)`, `A came up after View`,
  `A went down 2 times (needs 1)`. Pressing the held control first is what the step's instruction says; the early end of the
  step counts only the presses of the other controls.
- **The hiding verdict**, for a step with a remapped key among its controls in a template with `recordReceiver`. It does not
  change the verdict (a leaked echo is already "unexpected change" on the pad); it says how much a pass proves. Per press the
  attempt keeps `hiding.presses[]` = `{control, press (receiver report index), item, found, result, reason}`: `item` is what
  the run's filter read for the key (`seen` when it came on with the press, `confirmed` when it was already on and the report
  agreed, `other` when the press showed another item than the stored one, `unconfirmed` when neither). `result`:
  - `cannot judge` when the press was `unconfirmed`: `the controller's button for this key was not seen at its press (it sent none or several)`;
  - `cannot judge` when the item is what the step expects, a background item, or the button pressed during the hold: `the controller's current profile sends A for this key`;
  - `not exercised` when the raw reports never set the item from the press report to the last report before the key was let
    go (a direction counts on its diagonals), for example because the controller cancelled it against a held opposite
    direction: `the controller sent no D-pad right during the hold`;
  - `hidden` otherwise: the item reached the receiver and never the pad.
  A key is conclusive with one `hidden` press; `hiding.conclusive` is true when every remapped key of the step is, and
  `hiding.line` is the sentence the table shows: `controller's own button hidden: pass (D-pad right seen on the receiver,
  never on the pad)` (with a recovered direction: `... (D-pad right was seen on the receiver before D-pad left; the pad
  showed D-pad left while the controller sent no direction)`), `... cannot judge: ...`, `... not exercised (...)`. The line is
  also appended to the step's `detail`. In the app a pass with a non-conclusive hiding verdict has an amber chip, and the
  line is the tooltip of the Result cell.
- **Echo counters** of the run's own filter, before and after each step (only when the mapping hides a key), in
  `metrics.values`: `echo.hiddenFramesBefore/After` (receiver reports the filter changed), `echo.recoveredFramesBefore/After`
  (a direction the pad shows and the report did not), `echo.otherBefore/After` (presses that showed another item than the
  stored one), `echo.unconfirmedBefore/After` (presses it could not read) and `echo.validBefore/After` (1 once it has seen a
  report). They are cumulative over the run. The Driver's own counters (`echoValid`, `echoHiddenFrames` ...) come with the
  driver update.

### Built-in templates

`full`, `sticks`, `gkeys` (generated from the layout), `paddles-sax-echo`, `remap-g1-as-y`, `remap-swap-a-b`,
`gkeys-volume`, `t7-rt-hold-toggle`, `t8-latency`, `echo-survey` (picker row 10), `remap-paddles` (row 11) and
`remap-triggers` (row 12), appended so rows 1 to 9 keep their numbers. The bundled files are the generator's output (`DevBuiltins.generate`); a unit test fails when they drift, and
`GDHUB_WRITE_DEV_TEMPLATES=1 swift test --filter DevTemplateTests/testWriteBundledTemplates` rewrites them.

**`echo-survey`** ("Paddles and SAX: what the controller adds (survey)", no `paths`, `recordReceiver: true`, no `requires`)
has `record` steps only, apart from a closing `rest` step (a rest step is judged against the pad's state, which is known
only after the pad has posted once): each of the six keys alone ten times (`alone-<id>`), D-pad up held with each paddle
once (`up-held-<id>`), a paddle held with D-pad up, D-pad left, the opposite-echo paddle and a cross-pair paddle pressed
twice (`outer-right-…`), A held with SAX left and SAX left held with A (`a-held-sax-left`, `sax-left-held-a`), pairs
together twice (`together-outer`, `together-inner`, `together-sax`), then three Profile blocks (`profile-block-N`: hold
paddle outer right, press Profile once) each followed by the six keys three times (`profile-N-<id>`). Read the run file with
`python3 scripts/tools/echo-survey.py <run.json>`.

**`remap-paddles`** ("Remap check: paddles and SAX (App, then Driver)", `paths: ["engine","driver"]`, `recordReceiver: true`,
picker row 11). The owner's picks, in Mapping: Paddle outer right → R3, Paddle outer left → L3, Paddle inner left →
Nothing, SAX left → View, SAX right → Menu; Paddle inner right stays on Controller's profile. Reset afterwards (`Mapping →
Reset all remaps`). Every step carries `requires.mapping` `{"paddle_outer_right":"r3","paddle_outer_left":"l3",
"paddle_inner_left":"nothing","sax_left":"view","sax_right":"menu","paddle_inner_right":"built_in"}` and a written-out
expectation. 14 steps: `rest`; `outer-right`, `outer-left`, `inner-left`, `sax-left`, `sax-right` (each key ten times,
30 s: R3, L3, nothing, View, Menu); `inner-right-profile` (`builtInEcho`); `outer-right-dpad-up`, `outer-right-dpad-left`
(hold Paddle outer right, press the D-pad twice: D-pad up / left, R3 `background`); `dpad-left-outer-right` (hold D-pad
left, press Paddle outer right twice: R3, D-pad left `background`); `a-held-sax-left` (View, A `background`);
`together-outer` (both outer paddles together twice: L3 and R3, nothing else); `dpad-right` and `a` (alone). The four
"hold" steps say "Press the held control first". With D-pad left held first the controller cancels the paddle's D-pad right
against it, so D-pad right never reaches the receiver: that step's hiding verdict is `not exercised` and it proves the
recovery (D-pad left never drops on the pad). With the paddle held first the controller sends no direction while D-pad left
is down; the pad must show D-pad left (the filter's RECOVERED case). The A-held step is `cannot judge` for SAX left by
design (its echo is the background item). On a driver build that cannot hide the controller's own button the Driver pass
stands down at the question described under "Developer mode under remaps".

**`remap-triggers`** ("Remap check: triggers and three sources (App, then Driver)", `paths: ["engine","driver"]`, picker
row 12). Picks: G1 → LT, LT → RT (RT still sends RT), X → A, G5 → A. Every step carries `requires.mapping`
`{"g1":"lt","lt":"rt","x":"a","g5":"a","a":"a","rt":"rt"}` (so a leftover remap of A or RT cannot change what "A twice" and
"RT twice" test). 9 steps: `rest`; `g1` (digital, `items {lt: true}`: one full LT pull per press, RT still); `lt` (trigger,
`items {rt: true}`: RT, LT still); `rt` (trigger, RT); `x`, `g5`, `a` (digital, A); `hold-x-then-g5` (held, `item` A,
`releases ["x"]`); `pull-lt-rt-let-go-lt` (held, `item` RT, `releases ["lt"]`).

**`remap-g1-as-y`** ("Remap check: G1 sent to Y (App, then Driver)", `paths: ["engine","driver"]`) and
**`remap-swap-a-b`** ("Remap check: A and B swapped (App, then Driver)", same `paths`) check remapping end to end. The
owner makes the picks by hand first (`Mapping → G1 → Y`; `Mapping → A → B` and `Mapping → B → A`) and resets afterwards
(`Mapping → Reset all remaps`; an A/B swap left on breaks games). **Every** step carries `requires.mapping` (`{"g1":"y"}`;
`{"a":"b","b":"a"}`), because `requires` is step-level only, and every expectation is written out in the template
(`expect.items`, `expect.item`), so the template never checks the mapper against itself. `remap-g1-as-y`: `rest`; `g1`
(digital, expects `Y`); `y` (digital, expects `Y`); `hold-g1-then-y` (held, controls `["g1","y"]`, 6 s, `expect.item`
`Y`, `expect.releases` `["g1"]`). `remap-swap-a-b`: `rest`; `a` (expects `B`); `b` (expects `A`).

**`gkeys-volume`** ("Volume keys under a remap: G2, G3, G4 (App, then Driver)", `paths: ["engine","driver"]`, picker
order after `remap-swap-a-b`) checks that a remapped or silenced G key leaves the Mac's volume alone and a G key left
at its built-in function still changes it. The owner makes the picks by hand first (`Mapping → G3 → RB`, G4 left at
Mute (built in), `Mapping → G2 → Nothing`), sets the Mac's output to about half volume and not muted, and resets
afterwards (`Mapping → Reset all remaps`). Every step carries `requires.mapping` `{"g3":"rb","g4":"built_in","g2":"nothing"}`
and an explicit expectation: `rest`; `g3-rb` (digital, pad `RB`, `times` 2, `expect.volume` `unchanged`); `g4-mute-on`
(pad nothing, `times` 1, `changes`); `g4-mute-off` (the same again, a separate step, `changes`); `g2-nothing` (pad
nothing, `times` 2, `unchanged`). Digital steps have a 1 s release tail. The runner never sets a mapping.

**`t8-latency`** ("Latency: controller to pad, per press (App, then Driver) — T8 gate", `paths: ["engine","driver"]`)
is the evidence for the receiver-takeover gate rows G4a (Driver digital p50 at most 0.5 ms) and G4b (Driver at least
0.2 ms lower than App on digital and on stick onset), `docs/plans/receiver-takeover-plan.md` 9.3. Both passes run back
to back in one session. Steps: `flick-left` (stick, `flicks` 10, `requireDirections` false, 12 s), `tap-a` and `tap-b`
(digital, `times` 10, 10 s), `pull-rt` (trigger, `times` 5, 10 s), `circle-left` (the standard stick circle, 5 s).
Each step must also pass as an ordinary check. Compare the two passes' reports with `dev-run-compare.py`.

## Run report format

```
{ schema, startedAt, endedAt?, t0Ns, complete, requestedPath, effectivePath?, pathEvents, header, steps, notes }
```

| Field | Meaning |
|---|---|
| `schema` | 1. |
| `startedAt`, `endedAt` | ISO-8601 with the local offset (`2026-11-09T14:03:22+01:00`). `endedAt` absent if the run never finished writing. |
| `t0Ns` | The run's time zero, ns on `CLOCK_UPTIME_RAW`. |
| `complete` | `false` when the run was stopped, the app quit or an error ended it. The table is partial then. |
| `requestedPath` | What the owner or template asked for: `engine`, `shadow`, `driver`, or `inApp`. |
| `effectivePath` | What the engine reported it was **armed** with (`inert` for Engine, `shadow`, `live`), never the request. Absent if it was never observed. |
| `pathEvents` | `[{tMs, armed, fallback?, latched?, liveUnavailable, mappingNote?, wrote?}]`: every change of the engine's tap status during the run, and an entry with `wrote` (the value) for each path write a held step's actions made. |
| `notes` | Free text lines (for example how the path was put back). |

### Header

`appBuild`, `engineBuild?`, `dextBuild?` (builds that produced the run), `guiMode`, `padIdentity` (the virtual pad that
was read), `readerMatched` (how many devices matched; anything but 1 auto-pauses), `vpadMaxRateHz`, `xlateCore` (which
translator ran), `mapping` (the control mapping in force), `mappingHash` (SHA-256 of that mapping as sorted-keys
JSON), `templateId`, `templateVersion`, `templateSha256` (SHA-256 of the template as compact sorted-keys JSON; formatting
does not matter, any step change does), `decodeTable` (report layouts and placements the raw bytes were read with, so a
report stays interpretable after the tables change).

### Steps, attempts, metrics

`steps[]` = `{index, stepId, kind, controls, expected, attempts}`. `expected` is the resolved expectation
(`{buttons, hat?, guide, lt?, rt?}`; empty = nothing on the pad; `lt` / `rt` = the pad trigger the step pulls, written only
when true). `attempts` holds every try at the step (Back and re-runs add
one). **The last attempt that is not `superseded` carries the result**; if all are superseded, the last.

An attempt: `startedNs`, `readyNs`, `windowStartNs`, `windowEndNs`, `superseded`, `pathUnconfirmed` ("Run anyway" after
a path confirmation timed out), `verdict`, `metrics`, `entryState` (pad state the judge started from; absent = no report
seen yet), `entryRaw` (last report of each ID before the step, hex), `effectivePath` (`{atReady, atStart, atEnd}`), `raw`,
and, only for a step with `expect.volume`, `volume`, and, only for a step that records the receiver, `receiver` and
`receiverDropped` (see "Recording the receiver"), and, only where they apply, `hiding` (`{conclusive, line, presses}`) and
`echoItem` (see "Paddles, SAX keys and the hiding check").

`volume`: `{expect, verdict, consumerReports, keyReports, volumeEvents, muteEvents, deviceEvents, startScalar?,
endScalar?, startMuted?, endMuted?, hasVolume, hasMute}`. `expect` is the step's word; `verdict` has the same shape as the
attempt's (`inconclusive` = cannot judge, with the reason); `consumerReports` is the number of 0x11 reports from Go to the
end of the release tail and `keyReports` how many of them were a key going down; the three `…Events` are the change events
by kind (volume, mute, output device) in that span; `startScalar` / `endScalar` (0...1) and `startMuted` / `endMuted` are the
output device's state at Go and at the end (absent when the device has no such control); `hasVolume` / `hasMute` say
whether it has them. A report whose steps have no `expect.volume` carries no `volume` key at all.

`verdict` is `{"verdict": "pass" | "fail" | "skipped" | "inconclusive" | "invalid" | "recorded", "reason": "..."}`
(`recorded`: a `record` step, nothing judged; the reason says how much was recorded, and the table shows the word "recorded"
in grey with `Expected` "—" and `Seen` "receiver frames kept: N"; `inconclusive` with a reason starting `cannot judge:` reads
"Cannot judge"); `pass` has no
reason. A verdict word from a newer build reads as `inconclusive` with the word in the reason.

`metrics`:

| Key | Meaning |
|---|---|
| `padReports` | Pad reports read during the window and release tail. |
| `padChanged` | How many of them changed the held state (exact, no tolerance). |
| `rawDropped` | Raw reports left out of `raw` by the cap. |
| `framesSeen` | Frames the GUI saw from the receiver ("frames seen by the GUI"). |
| `framesPerSecond`, `movingMs` | Frame rate over the window; time the control was moving. |
| `expectedChanges` | Pad changes the receiver frames should have produced, when a reference was available. |
| `lossRatio` | `padChanged / expectedChanges`, absent without a reference. 1 means everything arrived. |
| `onsetMs` | First pad change minus first reference change, ms. |
| `values` | Per-kind numbers (`ls.xMin`, `ls.onsets`, `lt.peak`, `rt.pulls`, `bit.rises`, `bit.falls`, `hat.visited`, ...) and, for every step but `rest` when the receiver frames were available, the per-event latency (below). |
| `detail` | Words from the judge. |

### Per-event latency (`lat.*`)

For every step except `rest`, from the receiver frames and the pad reports of the step's window and release tail (kernel
timestamps on both sides, as in `scuf-envision/tools/latency/padlat.swift`). Milliseconds.

| Value | Meaning |
|---|---|
| `lat.n` | Receiver edges the pad answered. |
| `lat.unmatched` | Receiver edges the pad never answered before the next edge of the same kind: the real "lost" ones. |
| `lat.p50Ms`, `lat.p95Ms`, `lat.p99Ms`, `lat.maxMs` | Over the answered edges; absent when `lat.n` is 0. Percentile = nearest rank on the sorted list, index `Int((n - 1) * p + 0.5)` (padlat's). |

*Receiver edges* come from the receiver frames after `PassthroughPadMapper` and the sink's dead band (what the pad is
supposed to show): **digital** each press and each release of each expected pad item (a button, a D-pad direction,
Guide); **trigger** each pull (value rises to 0.5 or more) and the release after it (value falls to 0.05 or less), a pull
being armed again only after a release; **stick** each *onset* (the stick leaves the 12 % dead zone after being inside
it; it counts as back inside only after 60 ms there, so a spring-back wobble is one edge; the step's first frame counts
as coming from rest). A held step watches its held item (trigger or buttons) the same way.

*Match*: an edge is answered by the first pad report at or after its timestamp that **changed** the pad into the edge's
state (item down / item up, trigger at or above 0.5 / at or below 0.05, stick outside the dead zone after being inside)
and arrived before the next receiver edge of the same kind (same item and direction). Its latency is the difference of
the two kernel timestamps. Pad reports are read past the end of the release tail for this, so an edge near the end finds
its report. `detail` ends with `latency p50 0.12 ms (n=20, p99 0.31, max 0.40)` (`, 2 unanswered` inside the brackets
when some were).

### Raw reports and the cap

`raw[]` = `{tMs, id, bytes, phase}`; `bytes` is space-separated hex with the report ID first (`01 00 80 ...`),
`phase` is `ready`, `window` or `release`. The judge sees the full stream, but a file keeps the **first 4000 and the last
2000** reports of each attempt; `metrics.rawDropped` counts the ones cut from the middle.

### Time bases

- All `*Ns` fields (`t0Ns`, `startedNs`, `readyNs`, `windowStartNs`, `windowEndNs`) are nanoseconds on `CLOCK_UPTIME_RAW`,
  the same base as the HID kernel timestamps.
- `raw[].tMs` is milliseconds relative to that attempt's **window start**. **Negative = the ready phase**, before Go.
- `pathEvents[].tMs` is milliseconds from the run start (`t0Ns`).

### Trimmed example

```json
{
  "schema": 1,
  "startedAt": "2026-11-09T14:10:05+01:00",
  "endedAt": "2026-11-09T14:10:40+01:00",
  "t0Ns": 1000000000,
  "complete": true,
  "requestedPath": "driver",
  "effectivePath": "live",
  "pathEvents": [{ "tMs": 0, "armed": "live", "liveUnavailable": false }],
  "header": {
    "appBuild": "41", "engineBuild": "41", "dextBuild": "7",
    "guiMode": "engine", "padIdentity": "xbox-bt16-02e0", "readerMatched": 1,
    "vpadMaxRateHz": 1000, "xlateCore": "c",
    "mappingHash": "5c5c...", "templateId": "sample", "templateVersion": 2, "templateSha256": "abab..."
  },
  "steps": [
    {
      "index": 1, "stepId": "rt", "kind": "trigger", "controls": ["rt"], "expected": { "buttons": [], "guide": false },
      "attempts": [
        {
          "superseded": false,
          "startedNs": 1000000000, "readyNs": 3000000000, "windowStartNs": 3500000000, "windowEndNs": 6500000000,
          "verdict": { "verdict": "fail", "reason": "trigger peak 0.62 (needs 0.90)" },
          "metrics": { "padReports": 250, "padChanged": 30, "expectedChanges": 40, "lossRatio": 0.75, "onsetMs": 4,
                       "framesSeen": 175, "framesPerSecond": 58.3, "movingMs": 1200, "rawDropped": 0,
                       "values": { "lt.peak": 0.62 }, "detail": "" },
          "effectivePath": { "atReady": "live", "atStart": "live", "atEnd": "live" },
          "raw": [
            { "tMs": -20.0, "id": 1, "bytes": "01 00 80", "phase": "ready" },
            { "tMs": 310.5, "id": 1, "bytes": "01 01 80", "phase": "window" }
          ]
        }
      ]
    }
  ],
  "notes": []
}
```

(The real files are pretty-printed with sorted keys and carry the full `mapping` and `decodeTable`; samples produced
by the Swift encoder are in `Tests/GDHubTests/Fixtures/dev-runs/`.)

## Comparing two reports

```
scripts/tools/dev-run-compare.py A.json [B.json]
        [--loss-threshold 0.10] [--onset-threshold 5] [--latency-threshold 0.1] [--json]
```

Python 3, standard library only. Typical use is the same template run on two paths: the Engine report as A, the
Driver LIVE report as B.

**One report** prints a header block (startedAt, requested/effective path, template id, version and short sha256,
short mappingHash, complete or not, app/engine/dext builds, pad identity, notes) and a table with one line per step:
`#`, `stepId`, `kind`, `controls`, `verdict`, `detail` (the verdict reason, else the judge's words), `padReports`,
`padChanged`, `lossRatio`, `onsetMs`, `framesSeen`, `effectivePath`, and, when any step carries latency, `lat.n`,
`lat.p50Ms`, `lat.p99Ms`, `lat.unmatched` before `effectivePath`, and, when any step carries a `volume` object, a
`volume` column (`unchanged: pass (keys 2, vol 0, mute 0, 50% unmuted -> 50% unmuted)`; an `inconclusive` volume verdict
reads `cannot judge`). The numbers come from the step's final attempt.
`—` means "not recorded".

**Two reports** print both of those, then:

1. `WARNING:` lines when the runs are not like for like: `templateSha256`, `mappingHash`, `effectivePath`,
   `padIdentity`, `xlateCore`, `vpadMaxRateHz` differ, and when a run is incomplete. A different `effectivePath` is
   expected when comparing paths; the others mean the numbers are not directly comparable.
2. A side-by-side table **paired by `stepId`** (not by position): `verdict A/B`, `lossRatio A | B | Δ`,
   `onsetMs A | B | Δ`, `padChanged A/B`, and, when either run has latency, `lat.p50Ms A | B | Δ` and
   `lat.p99Ms A | B | Δ`, and, when either run has a `volume` object, `volume A/B` (`pass`, `fail`, `cannot judge`). A step present in only one run shows `—` on the other side and is not a
   difference by itself (it is how an incomplete or shorter run looks). The `diff` column carries `*` and the reasons:
   `verdict` (the verdict word changed), `volume` (both runs have a volume check and its verdict differs), `lossRatio` (|Δ| above `--loss-threshold`, default 0.10), `onsetMs` (|Δ| above
   `--onset-threshold`, default 5 ms), `lat.p50Ms` (|Δ p50| above `--latency-threshold`, default 0.1 ms; p99 is shown, not
   marked). Δ is B minus A.
3. When both reports carry latency, a last line, for the gate rows G4a and G4b:
   `Latency gate: digital p50 A 0.400 ms / B 0.150 ms (Δ -0.250 ms), stick onset p50 A 0.500 ms / B 0.200 ms (Δ -0.300 ms)`.
   Each figure is the n-weighted median (by `lat.n`; a tie between two values is their mean) of the `lat.p50Ms` of the
   steps of that `kind` (`digital`, `stick`) present in both reports. `—` when a kind has no such step. Same line under
   `gate` in `--json`.

Exit codes: **0** nothing marked; **1** a paired verdict differs or a marked difference exists; **2** a file is
unreadable, is not a report, or has a schema newer than 1. `--json` prints the same comparison (pairs, marks, header
warnings, thresholds, `latencyThresholdMs`, `gate`, both row sets) as JSON. Note that a Driver run that is faster than the
App by more than 0.1 ms is a *marked* difference, so comparing App with Driver on `t8-latency` exits 1 by design.

Tests: `python3 -m unittest discover -s scripts/tools`. The fixtures are generated by the Swift encoder
(`GDHUB_WRITE_DEV_FIXTURES=1 swift test --filter DevRunReportFixtureTests`), so the tool and the app share one schema.
