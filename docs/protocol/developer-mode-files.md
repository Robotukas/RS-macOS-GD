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
{ schema, id, version, title, notes, paths?, steps: [ step ] }
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `schema` | int | 1 | Format version. Newer than 1 is refused. |
| `id` | string | required | `^[a-z0-9-]+$`. Also the file name part and the id reports carry. |
| `version` | int | 1 | Bump when the steps change in a way that matters for comparison. Must be 1 or more. |
| `title` | string | "" | Shown in the picker. |
| `notes` | string | "" | When to use this template. Every template devised for a test is committed with one. |
| `paths` | [string]? | absent | One pass per entry, in order, each of `engine`, `shadow`, `driver`. Absent = run once on the target chosen in the bar. See "paths" below. |
| `steps` | [step] | [] | At least one. |

### Step

| Field | Type | Default | Meaning |
|---|---|---|---|
| `id` | string | required | Unique in the template. Reports pair steps by this id, so keep it stable. |
| `kind` | string | required | `rest`, `stick`, `trigger`, `digital` or `held` (an item that must stay held for the whole window; see "held steps" below). |
| `controls` | [string] | [] | Ids from the control layout (`layout.controlsByOrder`). At least one, except for `rest`, which takes none. The control's layout kind must fit: `stick` needs a stick, `trigger` a trigger, `digital` a button (D-pad, paddles, SAX, G keys, Profile and Start count as buttons), `held` a button or a trigger. |
| `title` | string | "" | The instruction headline. |
| `detail` | string | "" | The line under it. |
| `seconds` | number | by kind | Length of the capture window. Range 1...120; outside is clamped with a warning. Defaults: rest 3, stick 5, trigger 3, digital 3, held 5. The ring shows it; a step may end earlier when its goal is reached. |
| `readySeconds` | number | 2 | Minimum "hands off" time before Go. Range 0...30. The hands-still gate can extend it. |
| `releaseSeconds` | number | 0.5 for stick, trigger and held, else 0 | Tail after the window where the owner lets go. Range 0...10. |
| `expect` | object? | by kind | Overrides of the judge. Flat; only keys that fit the step's kind apply, the rest are ignored. |
| `requires` | object? | absent | `{ "mapping": { "<control>": "<binding name>" } }`. If the current mapping does not route that control to that output, the step is recorded as `skipped` with the reason, not failed. |
| `actions` | [object]? | absent | Held steps only. The one action is `{ "toggleInputPath": { "values": ["driver","engine"], "intervalMs": 3000, "count": 12 } }`; see "held steps" below. Without the background engine (in-app mode) the step is recorded `skipped` ("needs the background engine"). |

`expect` keys: stick `minReports` (100), `extent` (0.40), `deadZone` (0.12), `otherStickStill` (true),
`requireReturn` (true); trigger `peak` (0.90), `release` (0.05); digital `items` (`{buttons:[...], hat:"N"..."NW",
guide:bool}`, replaces the simulated expectation; empty means "nothing on the pad") and `times` (2); held `item`
(`RT`, `LT`, a button name such as `A`, `D-pad left`, or a hat direction `N`…`NW`; absent = derived from the control)
and `minLevel` (0.5, the trigger value that counts as held).

### Held steps

The window opens on the first frame where the control is active (trigger above 5 %, button bit set). From then on the
pad item must stay held with no sample below: a trigger at or above `minLevel`, the button bit set, the hat at the
direction. Every held-to-released transition is a drop, and a report that puts everything at neutral is one. The item
must be held within 2 s of the window start (the pull is still on its way when the window opens). Pass = `held.drops`
0 and held at the end of the window. Only the window is judged; the release tail after it is where the owner lets go.
Metric values: `held.minLevel` (lowest trigger value once it had been all the way down), `held.drops`,
`held.padReports`, `held.ms`; with actions also `held.handOvers` and `held.handOversConfirmed`.

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
- `step n: expect names unknown button "X"` / `unknown hat direction "X"`
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
(`{buttons, hat?, guide}`; empty = nothing on the pad). `attempts` holds every try at the step (Back and re-runs add
one). **The last attempt that is not `superseded` carries the result**; if all are superseded, the last.

An attempt: `startedNs`, `readyNs`, `windowStartNs`, `windowEndNs`, `superseded`, `pathUnconfirmed` ("Run anyway" after
a path confirmation timed out), `verdict`, `metrics`, `entryState` (pad state the judge started from; absent = no report
seen yet), `entryRaw` (last report of each ID before the step, hex), `effectivePath` (`{atReady, atStart, atEnd}`), `raw`.

`verdict` is `{"verdict": "pass" | "fail" | "skipped" | "inconclusive" | "invalid", "reason": "..."}`; `pass` has no
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
| `values` | Per-kind numbers (`ls.xMin`, `lt.peak`, `bit.rises`, `bit.falls`, `hat.visited`, ...). |
| `detail` | Words from the judge. |

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
        [--loss-threshold 0.10] [--onset-threshold 5] [--json]
```

Python 3, standard library only. Typical use is the same template run on two paths: the Engine report as A, the
Driver LIVE report as B.

**One report** prints a header block (startedAt, requested/effective path, template id, version and short sha256,
short mappingHash, complete or not, app/engine/dext builds, pad identity, notes) and a table with one line per step:
`#`, `stepId`, `kind`, `controls`, `verdict`, `detail` (the verdict reason, else the judge's words), `padReports`,
`padChanged`, `lossRatio`, `onsetMs`, `framesSeen`, `effectivePath`. The numbers come from the step's final attempt.
`—` means "not recorded".

**Two reports** print both of those, then:

1. `WARNING:` lines when the runs are not like for like: `templateSha256`, `mappingHash`, `effectivePath`,
   `padIdentity`, `xlateCore`, `vpadMaxRateHz` differ, and when a run is incomplete. A different `effectivePath` is
   expected when comparing paths; the others mean the numbers are not directly comparable.
2. A side-by-side table **paired by `stepId`** (not by position): `verdict A/B`, `lossRatio A | B | Δ`,
   `onsetMs A | B | Δ`, `padChanged A/B`. A step present in only one run shows `—` on the other side and is not a
   difference by itself (it is how an incomplete or shorter run looks). The `diff` column carries `*` and the reasons:
   `verdict` (the verdict word changed), `lossRatio` (|Δ| above `--loss-threshold`, default 0.10), `onsetMs` (|Δ| above
   `--onset-threshold`, default 5 ms). Δ is B minus A.

Exit codes: **0** nothing marked; **1** a paired verdict differs or a marked difference exists; **2** a file is
unreadable, is not a report, or has a schema newer than 1. `--json` prints the same comparison (pairs, marks, header
warnings, thresholds, both row sets) as JSON.

Tests: `python3 -m unittest discover -s scripts/tools`. The fixtures are generated by the Swift encoder
(`GDHUB_WRITE_DEV_FIXTURES=1 swift test --filter DevRunReportFixtureTests`), so the tool and the app share one schema.
