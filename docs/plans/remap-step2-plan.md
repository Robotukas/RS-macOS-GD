# Remap step 2: paddles and SAX by their own signal, GDHM v2 (R6 of the remap plan)

Status: **plan v3 (2026-11-11): a new rule for hiding the controller's own button, after the survey (S2), reviewed.**
Plan v2 was made from a read-only survey of the code and docs and three independent designs (smallest driver change,
risk first, owner first), reviewed against the code, and answered by the owner in S0 ("OK all"). The survey failed the
v2 gate on one real point: the controller cancels opposite D-pad directions, which the reviewed rule cannot handle. The
owner chose "Rework the rule". Plan v3 replaces the hiding rule and everything that depends on it. It was made from three
independent designs of a new rule (a fixed table with no state; a learned and saved table; a small state), replayed over
the survey recording, then reviewed against the code and the recording (S2b: 33 findings, all confirmed, folded in
below). The choices are under "Design choices". Before S3 code: the owner answers "Questions for the owner (v3)".
Scope (remap plan, R6 row and "Not in step 1"): paddles and SAX as sources by their physical bits with the controller's
own button hidden; GDHM v2 for three-plus sources on a button, a button sending a trigger and two sources on a trigger;
trigger remaps checked in Developer mode; **one** driver replacement.
Mockup: v6 (`docs/mockups/remap-buttons-v6.html`) is approved; v7 was approved during S2 (2026-11-10 21:56, "v7 OK",
after S1 was closed); v7b (v7 with only the changes listed under "UI": v3's wordings, the placeholders v7 left for after
the survey, row 11's two new steps and the demo's press order) is approved before S3's UI code and before S4 builds rows
11 and 12.
Owner's rules that shape it: mockup first, from the real layout; a click on a label or button opens a plain menu; plain
words; hidden, not greyed; cover every button; every hands-on test is a saved Developer-mode template, named by picker
number and title.

## Plan v3: what the survey changed (2026-11-10)

1. The hiding rule is new: a remapped key's extra button (the "echo") is removed in the same report as the key's own
   bit, and a D-pad direction the controller cancelled against a remapped paddle is worked out per axis (D-pad up held
   while the paddle that adds D-pad down is pressed: the pad keeps D-pad up).
2. No window W, no grace G, no latch set S: S2 measured no lag and no lead at all.
3. Each remapped key's stored item (its binding; the factory item D-pad right, down, up, left, A or B when the binding
   names no single hideable item) is always covered while the key is held. The press itself is read only when that
   item was not already on and the press is the only change among the six keys: it either shows the stored item
   ("seen"), or one other item, which is then covered too ("other": a Profile press changed the key's button).
   Otherwise the report is checked against the stored item ("confirmed" or "unconfirmed").
4. A small state (16 bytes) matters only while a remapped key is held: the value each covered button or direction had
   before the cover, and which keys' stored item was seen or confirmed at their press. With no remapped key held the
   report passes unchanged.
5. No ghost presses with the echoes S2 measured: an opposite direction is worked out only from a key's stored item, and
   only when its press showed it or the report agreed with it (seen or confirmed); an item read as "other" is hidden,
   never used to work out a direction. The listed limits can drop or hold an item; none shows one nobody pressed. The
   exceptions are a profile change (Q11) and onboard bindings cleared (not planned).
6. Triggers, sticks, Start, the G keys and Profile are never touched (v2 zeroed LT and RT inside a window).
7. Smaller driver change: `gdx_reset` stays the only reset function and its body does not change; no
   `gdx_reset_delivery`, no echo-entry compare in `loadMap`, no keep rules in LiveWatch or the App. The frame path's LIVE
   gate reset (`GDHubReceiverTap.cpp:564`) keeps the echo state around it, three lines in `shadowFrame`. After any other
   reset during a hold the stored item is covered from the first report on.
8. The GDHM v2 echo entry is the hide mask plus one stored item per key (8 bytes), instead of hide mask, W, G and S.
9. Parity carries the echo word (the cleaned buttons and hat) instead of a mask; the engine's own check compares words
   only when both sides are armed and have stepped the same number of reports since the last report with no remapped
   key held.
10. Limits: "at the same moment as the key", the LT/RT zeroing, the Profile window and the release flash are gone;
    "everything held is hidden after a reset" is narrowed to the key's own item; the opposite-direction cancel is
    recovered; new: both paddles of a pair remapped and held together freeze that D-pad axis (Q10), and what a profile
    change can still upset (Q11).
11. Echo cases E1–E29 become V1–V27; a replay test runs the rule over a trimmed fixture of the survey recording under all
    64 hide masks; the random walk drops lags and adds echo changes between holds and two changes in one report; an
    exhaustive search of short sequences with up to two changes per report pins "no ghost".
12. Row 11 gains the recovered case in both orders (D-pad left held through paddle outer right, and the reverse); its
    picks stay; row 12 is unchanged.
13. `echo-survey.py`: an item change belongs to a key only in that key's own report, never across two keys; the gate
    checks same-report timing, the per-axis hat and a replay of the rule; W and G go.
14. Facts: whether S2's Profile presses (all made while a paddle was held) switched the profile is unproven; on
    2026-11-09 plain Profile presses did change the echoes. The new rule depends on neither.
15. Review of v3 (S2b, 2026-11-11): **33 findings raised, 33 confirmed** by independent verifiers, none a blocker, in five
    dimensions (rule against the recording 3, rule on sequences 4, blob and C 5, tests and templates 7, slicing and
    consistency 14). The ones that matter most: a real change in the same report as a key whose own item was already on
    was read as the key's button (the real press hidden, ghost directions); the replay's truth model, "wrong" and "ghost"
    were not defined; the remapped-key note and row 11's new steps were not in an approved mockup before their code;
    "a repeated report gives the same word" and "the state depends on that report alone" were not true as written; the
    engine's word check failed on a missed frame. All are folded into the sections below; conflicts are decided under
    "Design choices".

## Plan v2: what the review changed (2026-11-10)

Items 1–3 and the echo parts of items 6 and 9 are replaced by plan v3; the rest stands.

55 findings confirmed against the code (2 rejected), in 7 dimensions: echo correctness, blob and C core, driver
upgrade, model and compatibility, tests and templates, UI and owner, slicing. None was a blocker. The ones that matter
most:

1. The App path steps its echo filter on every receiver report at the sink's mailbox, also while the driver drives;
   before, W and G counted only deduplicated, coalesced frames.
2. The echo rule is hardened: a per-hold echo set re-hides an echo the hat dropped and brought back; a release opens a
   window of max(W, G); a one-report lead is caught on a press edge; a Profile edge during a hold reopens the window;
   LT and RT are always in the latch set; W and G get a floor of 1 and a one-report margin.
3. `gdx_reset` stays the full reset; a new `gdx_reset_delivery` keeps the echo state; a new map keeps the echo state
   only when its echo entry is unchanged; tap Start, Stop and SetPowerState get no new code.
4. Paddle and SAX identity comes only from the fixed bit table. Stray learned bits on other controls are listed in S1
   and shown as a "re-learn" note, never as "needs a driver update".
5. The encoder's `maxVersion` defaults to 1 and TapSupervisor passes the running driver's level. The GUI level is
   "unknown" (no driver-update text) until a report or hello says otherwise, and the hint refreshes on a level change.
6. S7 has explicit SHADOW soaks: 10 min on the factory blob, then 5 min with the row 11 and 12 picks, so the new echo
   code runs in the driver before it posts; an independent echo-mask check; a judged App-path check before the soak.
7. A compile-only `build-xcode.sh --check`, a seeded build-24 source hash, and a build number written only after a
   successful build: the driver code compiles before S7, and a failed U3 still gives 25.
8. Rollback fixes in takeover §7.2 (RB4 without the terminate flag when build 25 is not running, RB5 judged by
   `systemextensionsctl`, a latch check, the rolled-back 24 self-test checked) and written stop rules for a failed S7,
   a rollback and any second replacement.
9. Developer mode: untouched paddles and SAX keys are judged by `builtInEcho` in every template, so Profile presses no
   longer turn rows 1 and 4 red; "cannot judge" when the profile hides the evidence; a precise `background`; row 12
   split per source; row 11 remaps five keys, with picks outside every echo seen and ten taps per key.
10. Mockup v7 keeps every tab and the toolbar, adds a Developer-mode part, and is approved in S1 before any UI code.
11. Owner questions: "the limits" listed in full; the gate-failure and stray-signal choices asked now; the two that
    restated the owner's own rules turned into statements.
12. The mapping backup now also saves the new file when it holds remaps a step-1 app would drop.

## Phases

During R6 the progress line counts this S0–S9 ledger (Phase n/10); S2b shows as 2b.

| Phase | Title | Driver replacement? | Exit | Status |
|---|---|---|---|---|
| S0 | Plan review and the owner's answers to "Questions for the owner" | No | Review folded in (plan v2, 2026-11-10): done. Outstanding: the owner's answers to Q1–Q9, quoted in "S0 answers"; then plan v2 committed, the remap-plan R6 row and HANDOFF point here | ✅ done 2026-11-10: "OK all" (see "S0 answers") |
| S1 | Safety net, build guard, receiver recorder, survey template, mockup v7 (app-only install) | No | Pins committed; build-24 source hash seeded; `--check` works; v7 approved (quoted) before the `record` display was coded; `swift test` + Python green; installed with `--same-build`; layout and mapping equal to their copies | ✅ done 2026-11-10 21:05 (see "S1 notes"). Deviation: `fb83ebd` (21:01) coded an interim, neutral "recorded" display before the v7 OK (21:56, during S2); S4(a) aligns it with v7 |
| S2 | Owner sitting 1: run row 10 (survey) | No | "S2 result" written: echoes per key and state, each key's bit, timing, hat behaviour, Profile during a hold; row 11's probe and picks checked; gate passed, or the owner's decision recorded (S2b opened when needed) | ✅ done 2026-11-10 23:29: survey run 23:14; **gate failed on the opposite-direction cancel**; the owner chose "Rework the rule"; mockup v7 approved 21:56 ("v7 OK"); row 11's probe (D-pad up) and picks (R3, L3, Nothing, View, Menu) are outside every echo seen (`echo-survey.py`) (see "S2 result") |
| S2b | Plan v3: new hiding rule, reviewed | No | Plan v3 written; an independent read-only review against the code and the recording folded in (choices under "Design choices") | ✅ done 2026-11-11: 33 findings raised, 33 confirmed, all folded in, none a blocker |
| S3 | Model, Swift echo filter, menus, labels, lighting (App path only) | No | Before any S3 code: the owner's answers to "Questions for the owner (v3)" quoted in "S2b answers" and plan v3 committed. Tests green; S1 pins byte-identical; echo cases V1–V27 pass in Swift (their Swift halves); V22, V23, V25 and the survey replay pass in Python (`echo_rule.py`); the survey replay passes in Swift; `echo-survey.py` fixed; v7b approved (quoted) before the UI code of S3(c), which includes the remapped-key note | ✅ done 2026-11-11 10:00: (a) `cf357e3`, (b) `109b613`, (c) `3e8f223`; 1101 Swift and 115 Python tests green; nothing installed yet, so nothing seen on screen |
| S4 | Developer mode judges triggers, `builtInEcho`, "cannot judge"; rows 11 and 12; app-only install; owner runs them on App | No | Rows 11 and 12 pass on App with a conclusive hiding verdict per remapped key; row 11's receiver reports read for the paddle-first cancel; their Driver pass stands down quietly on build 24; rows 4, 1 and 7 pass on App and Driver; layout and mapping equal to their copies; no before-edit file | ▶ current |
| S5 | GDHM v2 in the shared C translator and the encoder | No (shared C; reaches the driver in S7) | Tests green; v1 bytes, golden vectors and existing `GDHubDefaults.h` arrays unchanged; C equals Swift on V1–V27 (`GDHubXlateEchoTests`), on random sequences and on the survey replay; `swift build` of `GDHubDextCore` with the sequence runner; `build-xcode.sh --check` passes | pending |
| S6 | Driver code, capability bit, §7.1/§7.2 text fixes, independent pre-install review | Prepares it | Tests green; `--check` passes before and after the review; Start, Stop, SetPowerState and `syncMode` source unchanged; review findings fixed | pending |
| S7 | The driver replacement, build 24 → 25 (takeover plan §7.1), with two SHADOW soaks | **Yes (the only one)** | Build 25 activated enabled, one driver process, `tapPid == rootPid`, self-test passes; row 1 passes on App; 10 min v1 and 5 min v2 SHADOW soaks with 0 parity mismatches, 0 echo-word differences on aligned words and no fallback; `inputPath` absent and the engine LIVE; no latch; layout and mapping equal to their copies | pending |
| S8 | Owner sitting 3: rows 11 and 12 on App and Driver; regression rows 4, 5, 6, 1 | No | Every step passes on both paths; each remapped key had a conclusive hiding verdict on both; row 11's Driver pass shows echo parity checked (the echo counters and `parityEchoOk` rose); no fallback, limiter or breaker line and no latch; mapping and layout equal to their copies after "Reset all remaps" | pending |
| S9 | Results, docs, HANDOFF | No | Committed; pushed on the owner's word; remap-plan R6 row ticked; compatibility table in takeover §5.7 | pending |

Needs the owner's hands: S0 (answers only), S1 (look at mockup v7 on the phone and say OK; given during S2), S2
(controller on, run row 10), S3 (first the answers to Q10 and Q11; then look at mockup v7b on the phone and say OK), S4
(picks in Mapping, runs, Profile back to the noted colour, resets), S7 (power-cycle the controller at U6; a reboot only
if U5 does not match within 2 min; any System Settings prompt; row 1 on App; use the controller for 10 min, then 5 min
with the row 11 and 12 picks), S8 (picks, runs, resets). S7 and S8 are one sitting.
Before any sitting: Parallels VM not running, Shadow not forwarding the receiver; for row 7 (S4), the Mac's own
speakers as the sound output. Profile is pressed only where a step says so. Before the first run of S4, S7 and S8 the
owner notes the controller's light colour, and after every row-1 run presses Profile until that colour is back.

## What step 2 delivers

- A paddle or SAX key opens the same menu as A or G2: `<Label> sends` · ✓ **Controller's profile (built in)** (the
  default) · A B X Y · LB RB LT RT · View Menu L3 R3 · D-pad up/down/left/right · Guide · Nothing · Reset to default
  (only when remapped) · Re-learn button…. (Default and wording are Q1.)
- **Controller's profile** is exactly today: the key sends the button the controller's onboard profile gives it, and
  follows that button's remap. Nothing changes on the day of the update for keys the owner has not touched.
- **Any other pick** (a pad button or Nothing) makes the key send only that pick, recognised by its own signal, and
  GDHub hides the button the controller adds for it, in the same report. GDHub hides the key's stored button (its
  binding, the factory button by default) and also reads the press itself: when a Profile press has changed the key's
  button, a clean press shows the new one, and that is hidden too. A D-pad direction the controller cancels against a
  remapped paddle still reaches the pad (D-pad up held while pressing the paddle that adds D-pad down: the pad keeps
  D-pad up).
- **The limits** (Q3 as changed in v3, see "The limits in v3 against Q3"), because the controller sends its own button
  on the same line as the real button: while a remapped key is held, a press of the button it adds is not visible until
  the key is let go (lost if let go first), and that button held from before stays held until the key is let go; with
  both paddles of a pair remapped and held together, the D-pad axis between them stays as it was (Q10); a profile
  change can still upset a few presses (Q11). Other buttons pressed at the same moment as the key pass. A few rarer
  cases are listed under "What cannot be told apart".
- Three or more controls on one pad button, a button sending LT or RT, and two controls on one trigger run in the driver
  after the update. The "App drives *" tag and the "needs a driver update" lines disappear after the update, come back
  by themselves if the driver is rolled back to build 24, and never show while the driver's level is unknown.
- Developer mode judges trigger remaps (step 1 skipped them), and judges untouched paddles and SAX keys in any profile.

## Facts this plan rests on

- Each paddle and SAX key has its own bit in report 0x06: the 13 "extra" bits are bits 19–31 of bytes 12–15; extra
  bit 0 paddle outer right, 1 inner right, 2 inner left, 3 outer left, 4 SAX left, 5 SAX right
  (`docs/protocol/envision-pro-receiver.md:74-82`; `ControlMapping.swift:173-174`). Real D-pad, A and B presses carry
  no extra bit.
- The standard fields also carry the onboard profile's button for that key (the "echo", the owner's "extra button").
  The Mac cannot see the active profile: a Profile press sends only button 17 (`envision-pro-receiver.md:113-126`).
  Echoes seen on this unit: the four D-pad directions, A, B, X, Y, LB and RB (protocol notes; takeover plan T7 runs).
- Measured in S2 (2026-11-10, wireless, App path, one session; "S2 result"): in the starting state and after each of
  three Profile presses the echo was paddle outer right → D-pad right, inner right → down, inner left → up, outer left
  → left, SAX left → A, SAX right → B. That equals the factory bindings (`ControlMapping.swift:167-172`) and the stored
  bindings in the owner's S1-pre mapping copy. Of 654 key edges where only one of the six keys changed (all 54
  attempts, superseded ones included), 634 changed exactly that echo in the same report (a cancel counted as the
  opposite direction) and 20 changed nothing because the echo item was already on. None lagged or led. In
  `scuf-envision/captures/02-button-walk.txt` 16 of 16 edges did the same.
- Whether those Profile presses switched the profile is unproven: all three were made while paddle outer right was
  held, and no light colour was recorded. On 2026-11-09 plain Profile presses did change the echoes (paddles A, X, Y,
  B and SAX RB; `receiver-takeover-plan.md:1716-1717`), and SAX left has shown A, LB and X
  (`envision-pro-receiver.md:124-126`). The v3 rule reads the echo from each press, so it depends on neither reading.
- How the report combines them (S2): buttons are ORed with the real button. The D-pad is a hat the controller combines
  per axis: a direction is reported when the real D-pad or any held key adds it, and none when both directions of that
  axis are added. Neighbours give the diagonal, the same direction changes nothing, opposite directions cancel. Profile
  pressed during a hold changes nothing until the key is let go.
- So while a key is held, the item it adds says nothing about the real control. Everything else can be worked out,
  including a real direction opposite to a paddle's (the axis reads none). Not measured: three inputs on one axis, a
  real diagonal with a paddle, a real B with SAX right, wired mode, other firmware; a real button or direction pressed
  or let go while one of the six is held (none of the 789 reports shows one; a press of the key's own item would not
  show anyway); any opposite cancel with the paddle, or the down/right input, first (in S2 the real or up/left input
  always came first). S2 rules out a fixed priority on either axis, and "first press wins" when the real input came
  first, so the combination is expected not to depend on order. That is an expectation, not a measurement: row 11
  reads it in S4.
- Order of pressing in S2 (a correction to "S2 result", which says two steps): three steps were done the other way
  round, 11 `outer-right-dpad-up` (D-pad up held, then paddle outer right), 12 `outer-right-dpad-left` (D-pad left
  held, then the paddle) and 13 `outer-right-outer-left` (its second attempt, the one read: outer left held, then outer
  right); step 16 `sax-left-held-a` began with A pressed and let go alone, then SAX left with its own A, and nothing in
  the reports shows A pressed during a SAX left hold.
- GDHM v1 already has a per-rule `physMask` that overrides the rule kind (`Shared/GDHubXlate.c:376`), and the encoder
  fills it (`MapBlobEncoder.swift:249`). What v1 lacks: hiding the echo (`nEcho` must be 0, `GDHubXlate.c:181`), more than
  two rules per pad button (`:219`, a 15-entry counter declared at `:158`), a button rule on LT/RT, two entries per
  trigger (`:261-272`).
- Build 24 accepts only version 1 (`GDHubXlate.c:165`), and there is no capability bit for blob versions. The encoder
  stamps the compiled `GDX_BLOB_VERSION` into every blob (`MapBlobEncoder.swift:49-50`). The driver's blob is encoded in
  the `mappingOffer` closure in `EngineService.swift:93-100` with default arguments; TapSupervisor only calls it with a
  revision (`TapSupervisor.swift:445, 761`). A driver refusal counts toward the persisted 3-in-10-min limiter
  (`TapSupervisor.swift:795-802`); a mapping the encoder cannot express stands down quietly (`:440-463`).
- `gdx_reset` is documented and used as the full reset of a fresh state (`GDHubXlate.h:189-190`; the self-test's
  uninitialised stack state, `GDHubXlateGlue.cpp:32-33`; `LiveWatch.swift:18-21`).
- The App sink drops a frame equal to the last one, keeps only the newest frame while a drain is pending, and drops
  everything while the driver drives (`VirtualPadSink.swift:516-527`). Developer mode caches its per-frame summary by
  frame (`DevRunCore.swift:1028`).
- Row 1 (Full check) has no `paths`, so "App and Driver" is two runs, and it presses Profile at its end. Rows 1 and 4
  judge paddles and SAX keys against the stored, learned echo today (`DevExpectation.swift:10-38`).
- SwiftPM never compiles the driver C++ (`Package.swift`); the first DriverKit compile of new driver code would be U3.
  `scripts/build-xcode.sh:31` writes the new build number before it builds.
- With no `inputPath` stored the path is `driver`, which goes SHADOW for 2 s and then LIVE (`InputPath.swift:30`;
  `TapSupervisor.swift:919-938`). The breaker and limiter latch is stored in defaults and survives restarts and rollbacks
  (`TapSupervisor.swift:717-724`, `:871-880`).
- Driver log lines are live-only (takeover T0); DriverManager's `replacing dext` line is info level, which `log show`
  does not keep (`DriverManager.swift:503-504`).
- The installed step-1 app has no rollback archive yet. A step-1 app drops `outputs` entries for paddle and SAX ids
  (`ControlMapping.swift:408`). The mapping backup fires only when the `outputs` key appears or disappears, and it saves
  the file from before the change (`MappingStore.swift:94-99, 108-128`).

## Model (S3)

All in `Sources/GDHub/Mapping/ControlMapping.swift` unless named.

- `remappableIDs` (`:285-288`): append `paddle_outer_right`, `paddle_inner_right`, `paddle_inner_left`,
  `paddle_outer_left`, `sax_left`, `sax_right` **at the end** (29 ids). At the end, so the source order and rule order of
  every existing remap do not move.
- `builtInIDs` (`:293`) gains the six; `defaultOutput` returns `.builtIn` for them. On a paddle or SAX key `.builtIn`
  means "what the controller's profile sends"; on G2–G4 it stays the volume function. `ConsumerKeyMute` keeps handling
  g2–g4 only (a test pins it). Consequences: the factory mapping keeps empty `outputs`, so its blob, `default.json` and
  `mappingHash` stay byte-identical; `defaultSources` is unchanged (the six never become default owners); Nothing
  becomes a storable pick (`setOutput` no longer normalises it away).
- New `identityBits(id)`: for the six only, always the fixed table outer right 1, inner right 2, inner left 4, outer
  left 8, SAX left 16, SAX right 32 (hardware positions, measured; protocol doc and prior art agree). For every other id
  it returns 0. The six's stored `physicalBits` are never used for identity: a stored value that differs from the table
  is a mis-learn, listed in S1 and never used. Users: `isActive` for the six, the source rule, the hide mask,
  `triggerFeed`, `DevExpectation.pressedFrame` (S4) and `learnConflict`.
- Sources: one of the six is a source of pad item X only when its effective output is `.pad(X)`, and only by its
  identity bits; the encoder writes those bits as the rule's `physMask` (not the stored `physicalBits`,
  `MapBlobEncoder.swift:249`). `.builtIn` and Nothing feed nothing.
- `triggerFeed` (`:349-365`): one of the six with an effective `.pad(lt)` or `.pad(rt)` output feeds full scale by its
  identity bits, before its stored binding is looked at. Every other source keeps today's order: a `.trigger` binding
  gives `.analog`, the default owner gives `.nothing`, anything else gives `.fullScale`. So a stray learned bit on
  `lt` or `rt` never turns the analog trigger digital.
- New `echoHideMask`: OR of `identityBits` over the six whose effective output is not `.builtIn` (Nothing included).
- New `echoItem(id)`: the stored echo of one of the six, read from its binding `buttons[id]`: `.button(1...10)` → that
  receiver button, `.hat(0)`, `.hat(2)`, `.hat(4)`, `.hat(6)` → D-pad up, right, down, left; anything else (missing, a
  diagonal, a trigger, an axis, buttons 11–19) → that key's factory item (paddle outer right D-pad right, inner right
  down, inner left up, outer left left, SAX left A, SAX right B), never none. The default bindings (`:167-172`) are the
  factory echoes. For every other id it returns none. New `echoParams`: `echoHideMask` plus `echoItem` of the six, the
  only input of every echo filter and of the encoder's echo entry; it returns the plain `EchoParams` value of S3(a).
  A key in the hide mask therefore always has a stored item, so a press the rule cannot read still covers one.
- New `signalConflict()`, the same on every driver build: a remapped key of the six whose table bit is also stored in
  the `physicalBits` of a control outside the six (an old learn). It gives "<Other> was learned with <Paddle>'s signal:
  re-learn <Other>." It is shown as a note and a hint line (UI item 9), never through `remapLimit`, and the encoder
  does not refuse it (App and driver do the same thing with it). What to do with such controls is Q9.
- `LearnSession` (`:191-195`): attach extra bits only when learning one of the six. A learn of one of the six whose
  rising bit is not its table bit is refused: "That was <Other>'s signal: press <Label> itself." "Re-learn button…" on
  one of the six stores the rising standard item as its binding (as today), which is also its stored echo; for a D-pad
  echo it stores the one direction that changed against the baseline hat (`LearnSession.swift:217-224`), not the most
  frequent hat value, so a paddle re-learned while D-pad up is held is stored as `.hat(2)`, not the diagonal `.hat(1)`.
- `learnConflict` (`:368-378`): the six are never owners of a binding (they never feed the pad through it); its doc
  comment says so.
- Codable: no change. The decoder now keeps paddle and SAX keys because they are in the list; unknown words are still
  dropped entry by entry.
- `MappingStore.save` (`MappingStore.swift:92-128`): keep today's backup of the old file on today's trigger, so undo
  still works. In addition, when the new mapping has `outputs` ids a step-1 app does not know (the six) and its
  `outputs` differ from the file on disk in ids or in values, also write the **new** bytes as `mapping <stamp> new.json`.
  Pruning to `backupsKept` never deletes the newest "new" backup. This covers every entry a step-1 app could drop,
  including a changed pick on a key that was already remapped.
- `VirtualPadSink`'s Swift sources cache stays keyed on `outputs` (identity bits are fixed).
- Requires vocabulary: the six become valid `requires.mapping` ids; `built_in` is valid on them. The validation message
  (`DevModel.swift:421-422`) says `built_in` is valid for G2–G4 and the paddles and SAX keys, and does not call a
  paddle's state a "built-in function".

## Translators: hiding the echo

### The rule (the same in Swift `EchoFilter.step` and in C `gdx_echo_next`)

In words: while a remapped key is held, its stored item is covered (a button A–R3 or one D-pad direction; every key in
the hide mask has one). A covered button or direction keeps the value it had in the report before the cover began. On
an axis where exactly one direction is covered, a reading of "no direction" means the real opposite direction is held,
and the pad shows it, but only when the key covering that direction had its stored item seen or confirmed at its press.
At a press the press itself is read only when the key's stored item was not already on in the report before and the
press is the only change among the six keys in that report: if it changed exactly the stored item, the item is "seen";
if it changed exactly one other item (a Profile press changed the key's button), that item is covered too, and neither
is used to work out a direction ("other"). In every other case the stored item stands: "confirmed" when the report
agrees with it (it shows the item, or the axis reads what the held keys add), else "unconfirmed" (covered, never used to
work out a direction). With no remapped key held the report passes unchanged.

Items, a 14-bit word: bits 0..9 = receiver buttons 1..10 (A B X Y LB RB View Menu L3 R3), bits 10..13 = D-pad up,
right, down, left. An item code c in 1..14 names bit c − 1; 0 = none. `HAT_ITEMS[16]` turns the receiver hat into
direction bits (hat 0 up, 1 up+right, 2 right, 3 right+down, 4 down, 5 down+left, 6 left, 7 left+up, 8..15 none);
`ITEMS_HAT[16]` = {8,0,2,1,4,8,3,2,6,7,8,0,5,6,4,8} turns direction bits back into a hat value, opposite directions
cancelling as the controller does. `axis(s)` on {p, n} is 1 when `s` has p and not n, −1 for n and not p, else 0.

Parameters (`EchoParams`; the blob's echo entry): `H`, the hide mask (bit k = extra bit k is remapped: 0 paddle outer
right, 1 inner right, 2 inner left, 3 outer left, 4 SAX left, 5 SAX right), and `S[0..5]`, the stored item of each key
in H (from `echoItem`; never none for a key in H, 0 for a key outside it).

State `gdx_echo` / `EchoState`, 16 bytes, all zero = fresh: `u16 est` (the cleaned items of the last report; both
directions of an axis may be set), `u16 prev` (the raw items of the last report), `u8 held` (remapped keys down in the
last report), `u8 six` (all six key bits of the last report), `u8 known` (held keys whose stored item was seen or
confirmed at their press), `u8 flags` (bit 0 VALID: `prev` and `six` hold a report; bit 1 ARMED: a report with no
remapped key held was seen since the reset), `u8 cur[6]` (the item code read for each held key: its stored item, or the
other item its press showed; all 0 while no remapped key is held), `u8 pad[2]` = 0.

`changed(prev, obs)`, what one press changed: the buttons 1..10 that came on, plus per axis {p, n} the direction p when
the axis went from 0 to p, from n to 0 or straight from n to p, and n when it went from 0 to n, from p to 0 or straight
from p to n. (For a release, `echo-survey.py` reads it backwards, `changed(obs, prev)`: what the release took away.)
`on(s, items)`: item s is on in a raw report, a button by its bit, a direction when the axis reads s's direction.

Per report (C-like; the Python oracle `scripts/tools/echo_rule.py`, written in S3(a), is the reference):

```
obs  = (buttons & 0x3FF) | HAT_ITEMS[hat] << 10
six  = extra & 0x3F;   held = six & H
if (!held) {                                                                                    // unchanged
    if (st.held) cur[0..5] = 0                                                                  // a hold ended
    est = prev = obs; st.six = six; st.held = known = 0; flags = VALID | ARMED; return 0;
}
pressed = held & ~st.held
if (pressed) {
    mp = OR S[j] over j in (held & ~pressed & known) | pressed                 // what the keys add, as stored
    c  = (flags & VALID) && exactly one bit in (six ^ st.six) ? changed(prev, obs) : 0
    for each k in pressed:
        if (!on(S[k], prev) && c is exactly one item) {                        // the press shows one item
            cur[k] = code(c);
            if (c == S[k]) known |= 1 << k;                                   // seen
            else word |= OTHER;                                               // covered with S[k]; never worked out from
        } else {                                                              // the stored item stands
            cur[k] = code(S[k]);
            ok = (obs & S[k]) != 0 || (S[k] is a direction && axis(obs) == axis(est | mp) on S[k]'s axis)
            if (ok) known |= 1 << k; else word |= UNCONFIRMED;                // confirmed, or covered only
        }
}
known &= held
M  = OR (S[k] | item(cur[k])) over k in held;   MI = OR S[k] over k in held & known
out = (obs & 0x3FF & ~M) | (est & 0x3FF & M)                          // a covered button keeps its value
for each axis {p, n} of {up, down} and {right, left}:
    if neither p nor n is in M:  out |= obs & (p | n)                 // nothing covered: as reported
    else if both are in M:       out |= est & (p | n)                 // the axis is frozen
    else {                       // a = the covered direction, b = the other one
        out |= est & a;                                               // a keeps its value
        if ((obs & b) || (!(obs & a) && (MI & a))) {                  // "none" under a seen or confirmed a: b is held
            out |= b; if (!(obs & b)) word |= RECOVERED; }
    }
est = out; prev = obs; st.held = held; st.six = six; flags |= VALID
return word | APPLIED | (flags & ARMED ? W_ARMED : 0) | held << 16 | ITEMS_HAT[(out >> 10) & 15] << 10 | (out & 0x3FF)
```

The word (u32): bits 0..9 the cleaned receiver buttons 1..10; bits 10..13 the cleaned hat (0..8); bits 16..21 the
remapped keys held; bit 24 RECOVERED (the pad shows a direction the report does not); bit 25 OTHER (a press showed
another item than the stored one; both are covered); bit 26 UNCONFIRMED (a press whose stored item was neither seen nor
agreed with by the report); bit 27 ARMED; bit 31 APPLIED. Bits 25 and 26 mark the press report only. A word of 0 means
the report passes unchanged (no echo entry, a bad frame, or no remapped key held).

Applying the word (`gdx_echo_apply(word, in[16], out[16])` / `EchoFilter.apply`, pure): with bit 31 set, receiver
buttons 1..10 (byte 12 and bits 0–1 of byte 13) := word bits 0..9 and the hat nibble (the high nibble of byte 11) :=
word bits 10..13; nothing else changes. The extra bits stay, so the remapped key's own rule still fires
(`GDHubXlate.c:376`); triggers, sticks, Start, G1–G5, Profile and buttons 18–19 are never touched. A word of 0 gives
the input bytes unchanged.

What the code guarantees (tests pin each):
- With no remapped key held, the output equals the input, and the state is byte for byte the state a fresh one gets
  from that report (`cur` is cleared on the report a hold ends).
- A repeated report gives the same state and the same word except bits 25–26, which mark only the press report.
  `gdx_echo_apply` reads only bits 0–13 and 31, so dropping duplicates and coalescing change no cleaned byte.
- A direction the report does not show appears only for a key whose stored item was seen or confirmed at its press, and
  only as the opposite of that item. An item read as "other" is only ever hidden.
- Only items covered by a held key and, on an axis with one covered direction, the other direction can differ from
  the report; every other button and direction passes as reported.
- Integer work on six keys and two axes: no allocation, no division, no floating point, no libm. With no remapped key
  held about ten operations (six byte stores more on the report a hold ends); with one held one loop over six keys and
  two axis cases; the press part runs only on a press report.

Truth model (the yardstick of the replay, the row 10 gate, the S3 exit and the Python tests; `echo_rule.py` implements
exactly this):
1. Real items per report, with E = the echoes of every held key among the six (hidden or not) as measured for that
   state (the table for the fixture): buttons = the report's buttons minus E's buttons, which become unknown. Per axis:
   no echoed direction, the axis as reported; exactly one echoed direction a, a is unknown and a reading of "none"
   means the opposite b is really held; both directions echoed, both unknown.
2. Each maximal run of an unknown item within one attempt takes the value of the report before the run (off when the
   run starts the attempt) when the report after it agrees or the run reaches the end of the attempt; otherwise the
   item is ambiguous for the whole run and not compared.
3. Target = the real items plus the echoes of held keys outside H. A report is wrong when a button that is not
   ambiguous differs, or when, on an axis with no ambiguous direction, the combined value (+1, 0, −1) differs.
4. Ghost: from the report before a hold of a key in H begins, through every report of the hold, collect the target
   items (before the axis combination); a pad item outside that set is a ghost.
5. The random walk and the exhaustive search use the same ghost definition with the simulator's known real input. The
   replay and the gate also print the number of ambiguous items (S2 copy: 0), so a later run that is mostly ambiguous
   cannot pass unseen.

### What the owner gets (factory echoes and row 11's picks as the example)

- Paddle outer right → R3, pressed alone: R3; D-pad right never reaches the pad, on press, hold and release.
- D-pad right alone, with no remapped key held: D-pad right at once.
- D-pad up held, then the paddle (the controller sends up+right): the pad shows D-pad up and R3.
- D-pad left held, then the paddle (the controller sends no direction): the pad keeps D-pad left and shows R3. The
  other order is expected to work the same (paddle held, D-pad left pressed twice → D-pad left twice): S2 measured the
  cancel only with D-pad left first, and row 11 reads the other order in S4.
- D-pad up held, then paddle inner right remapped (it adds down; the controller sends no direction): the pad keeps
  D-pad up.
- Paddles outer right and inner right both remapped and held: no D-pad from them; a real D-pad up or left during the
  hold passes.
- Both outer paddles remapped and held: no D-pad from them; up and down pass; left and right stay as they were before
  the pair went down (Q10).
- A held, then SAX left (adds A) remapped and tapped: A stays held on the pad without a break.
- Other buttons and directions pass at once during the hold, also when pressed or let go in the same report as the key
  (one other change; the key's own item and the opposite of a paddle's direction are the exceptions listed below).
- A key left on Controller's profile is not hidden: its button passes as today, also next to a remapped key (paddle
  outer right remapped and outer left untouched, pressed one after the other and held: the pad shows outer left's D-pad
  left).
- If a Profile press changes what a key adds (seen on 2026-11-09), the next clean press of that key shows the new
  button, and GDHub hides it together with the stored one for that hold, with no setting to change. The engine log
  names the change. Q11 lists the presses where the new button can show instead.
- If the onboard bindings were ever cleared (not planned, "Not in step 2"), a press changes nothing and the stored item
  is still hidden while the key is held. Then a D-pad direction on a remapped paddle's axis that is held, pressed or let
  go around the paddle's press can show as its opposite, or stay shown after it is let go, until the paddle is let go
  (for example D-pad left held, paddle outer right pressed in the very report D-pad left is let go: left stays shown),
  and a button or direction pressed in the very report of the press is hidden for that hold. Turning the hiding off for
  such keys is the follow-up named there.

### What cannot be told apart (the report ORs the echo with the real control)

These are the limits of v3; "The limits in v3 against Q3" says which ones are new.
- While a remapped key is held, its own item (A for SAX left, D-pad down for paddle inner right, and so on): a press
  of it that starts during the hold shows only at the key's release (lost if let go first); held from before, it stays
  held until the key is let go, also if let go earlier. Rocking the D-pad from that direction to the opposite during
  the hold shows nothing until the opposite is let go, then the old direction again until the key is let go.
- Both paddles of a pair (outer left and outer right, or inner left and inner right) remapped and held together: the
  controller reports no direction on that axis whatever the D-pad does. The pad keeps that axis as it was before the
  pair went down, until one of them is let go; the other axis passes.
- A direction opposite to a remapped paddle's that comes on in the very same report as the paddle (about 1 ms), from
  the D-pad or from an untouched paddle pressed in that report, or that is already held when the echo state starts with
  the paddle down (tap open, a new mapping, LIVE turned on, pause end, wake, a reconnect, the controller going quiet):
  it shows only when the paddle is let go. After such a start, a covered item held from before drops until the key is
  let go. The stored item stays covered from the first report on. (The LIVE gate reopening keeps the echo state, "Where
  it runs".)
- A direction of the key's own item let go in the very report of its press counts as held from before: it stays until
  the key is let go (D-pad right let go as paddle outer right goes down).
- After a Profile press that changed what a remapped key adds, the new button shows next to the pick for that hold, and
  the stored item is hidden instead, when the press cannot be read cleanly (Q11): two of the six keys pressed in the
  same report; the new button, or the key's old button, already on when the key is pressed (held by the owner or added
  by another held key); another item changing in the very report of the press; a reset during the hold (tap open, a
  new mapping, LIVE turned on, pause end, wake, a reconnect, the controller going quiet). A button held from before
  then stays held until the key is let go. When the press is read cleanly ("other"), the stored item is hidden together
  with the new button for that hold, and a real opposite of a new D-pad direction is not shown while the key is held.
- Rare, three inputs on one axis (a real direction, a remapped paddle of the same direction and an untouched paddle of
  the opposite one, in any order): the axis can show nothing, or the untouched paddle's direction, until the remapped
  paddle is let go, and a button or direction pressed in the very report of that paddle's press is hidden for that hold.
  An untouched key that adds the same item as a held remapped key (only after a profile change): hidden while both are
  held.
- Rare, several changes in the very report of a press (about 1 ms), such as the D-pad rolled straight from up to left
  as paddle outer right goes down: the rule can take one of them for a changed button and hide it for that hold. It
  never shows an item nobody pressed: the exhaustive search under "Tests" finds no ghost with the echoes S2 measured.
- Timing: the rule needs each echo in the same report as its key's bit (S2: no exception in 654 edges). If wired mode
  or another firmware were one report off, a remapped paddle could show its opposite direction for one report when its
  echo goes early, or its own direction for one report when it goes late; an echo one report early on a press would
  show for the whole hold. Row 10's gate finds this before such a setup is used.
- An echo onto a stick, a trigger, Start, a G key or Profile is never hidden (none seen).
- Only removing the echo at the controller removes these limits ("Not in step 2").

### The limits in v3 against Q3

What the owner accepted in Q3 on 2026-11-10, item by item:
- Pressing the key's own button during the hold shows only at release; held from before, it stays until release:
  **stays**, unchanged.
- A button or D-pad direction pressed at the same moment as the key (about 1–4 ms) counts as the controller's:
  **gone**. With the echoes S2 measured only the key's own item is hidden, apart from rare coincidences of several
  changes in one report ("What cannot be told apart"); an opposite direction pressed in the very same report shows at
  release.
- The same just after letting go of one of two held remapped keys: **gone**.
- LT or RT pulled at that moment stays at zero: **gone**; triggers are never touched.
- Profile pressed while holding a remapped key: **gone** as a limit; S2 saw nothing change during a hold, and a
  changed button is read at the next press.
- Holding a remapped key while GDHub starts, reconnects, wakes or the mapping changes hides every such button already
  held: **narrowed** to the key's own item; an opposite direction held then shows at release.
- A D-pad direction can flash once when letting go of one of two remapped keys: **gone**.
- A real D-pad press the controller drops while a paddle is held cannot be shown: **mostly gone**, the opposite cancel
  is now worked out. What is left is new: both paddles of a pair remapped and held together (**Q10**).
- **New**: after a profile change that altered a remapped key's button, the new button can show next to the pick for a
  hold: two remapped keys pressed in the same millisecond; the key pressed while its new or old button is already held
  (an ordinary move, no exact timing); another button or direction changing in the same millisecond; a restart of the
  reading during the hold. A cleanly read press hides both buttons for that hold (**Q11**).

### Where it runs

- **Driver path**: `gdx_step` runs `gdx_echo_next` **only when the map has an echo entry** and, when the word is not 0,
  `gdx_echo_apply` into a 16-byte stack copy; then it evaluates the copy as today. `gdx_state` gains `gdx_echo echo`
  and `u32 lastEchoWord` (the word of the last frame). A v1 map pays one branch.
- **Resets**: `gdx_reset` stays the only reset function and its body does not change (it zeroes the echo state and
  `lastEchoWord` with the rest, `GDHubXlate.c:544-551`). One call site changes around it: the LIVE gate's `needReset`
  in the frame path (`GDHubReceiverTap.cpp:564`) becomes `gdx_echo keep = iv->xstate.echo; gdx_reset(&iv->xstate);
  iv->xstate.echo = keep;`. `gdx_step` runs on every frame there, also while submit is false (`:569`), so the echo
  state has seen the stream all along; a pool miss (`:666`) skips one full-state frame, which the rule reads as the next
  report. Every other call site stays exactly as it is and does the full reset: a map load (`:211`, a new map may
  change H and S), `tapNeutral` (`:291`), power on (`:372`), a SHADOW change (`:426`), LIVE turned on (`:434`), tap
  open (`:491`) and pause end (`:644`, a whole pause of frames is missing). After a full reset during a hold the stored
  item is covered from the first report on; what it can cost is listed under "What cannot be told apart" (the opposite
  direction at release, a covered item held from before dropping, and after a profile change the new button showing).
  Tap Start, Stop, SetPowerState, `syncMode` and the timer reach no new code.
- **Loading a map**: `loadMap` (`:203-223`) gains only the count checks (nTriggers ≤ 4, nEcho ≤ 1); no compare and no
  keep rule.
- **Parity (F5)**: the tap builds the parity record from `gdx_eval` + `gdx_build` of the frame with `lastEchoWord`
  applied, the word `gdx_step` just made for that frame (`GDHubReceiverTap.cpp:569-575`). It stores the word in the
  record's spare bytes: `rec.pad[0..3]` little-endian, `rec.pad[4]` = 1 when the map has an echo entry, `rec.pad[5]` =
  `echoRun` (`GDHubDextCore.h:414`). `echoRun` is a u8 the tap keeps next to the state, outside the rule: after each
  `gdx_step`, 0 when the word is 0, else the last value + 1 (mod 256): the number of frames stepped since the last one
  with no remapped key held. The engine's `ParitySampler` applies that word with the same pure `gdx_echo_apply` and
  compares bytes exactly as today. A record with `rec.pad[4]` = 0 while the pushed blob has an echo entry is skipped
  (counted in `skipped`), never a mismatch. `gdx_eval` itself stays stateless and keeps its signature. Parity checks
  the driver's eval and build under the driver's own word; it cannot see a wrong word, nor a fault in the shared C
  (both sides run it).
- **Independent word check**: the engine's `FrameRing` (`ParitySampler.swift:10-52`) steps its own Swift `EchoFilter`
  on every frame it records and keeps the word and its own `echoRun` (counted the same way) next to the bytes; its
  state resets when the ring is enabled or reset, on a revision change and on a new tap instance. `ParitySampler`
  compares that word with the record's, bits 25–26 masked out, only when both are 0, or both carry the ARMED bit and
  the two `echoRun` values are equal. The states are then equal when both sides stepped the same reports since the last
  report with no remapped key held (after such a report the state is that report's alone), which the equal count
  checks; only misses on both sides that exactly make up for each other inside one hold would pass unseen. Differences
  count in `echoWordDiffs`; a word without ARMED on either side counts in `echoUnarmed`, armed words with different
  counts in `echoUnaligned` (recorded, not judged: the engine's reader or the tap missed a frame,
  `ParitySampler.swift:57-61`, `GDHR_CTR_FRAMES_UNMAPPED`). The masking keeps a press flag seen on one side only from
  counting as a difference. Matches whose record word has bit 31 count in `parityEchoOk`. It is a gate in S7 and S8,
  not a fallback trigger.
- **App path**: `VirtualPadSink.submit(frame:)` steps one Swift `EchoState` under the mailbox lock on **every** call,
  right after `received += 1` and before the `gateClosed` return and the duplicate drop (`VirtualPadSink.swift:516-527`),
  so App and Driver words agree report by report when both stepped the same reports since a report with no remapped
  key held. `EchoParams` come from the mapping's `echoParams`, cached in the
  mailbox per `revision`; the state is reset only when the params change (never by `setDriverDrives`,
  `resetDeliveryState` or a rebuild of `xlateCache`). The slot carries `(frame, word)`; the duplicate drop stays on
  `(frame, revision)`: a repeated report applies the same bits 0–13 and 31. `handle` applies the word and never steps a
  second state: the Swift path runs `EchoFilter.apply`, then `PassthroughPadMapper.padState` (pure, unchanged); from S5
  the C path calls `XlateCore.eval(frame, word:)`, which runs `gdx_echo_apply` into a 16-byte copy and then the
  stateless `gdx_eval`.
- **LiveWatch (F6)**: its C core steps the echo inside `gdx_step`; `configure(core:)` keeps today's full `gdx_reset`.
- **GUI**: `EnvisionProDevice.ingest` (`EnvisionProDevice.swift:225-237`) steps its own filter on every frame (not at
  the publish rate) and gives `RemapLighting.levels` the cleaned frame. `LearnSession` keeps reading raw frames.
- **Developer mode** (S4(a)): one `EchoState` per run, from the setup mapping's `echoParams`, reset at run start and
  when the params change. `DevRunCore.onFrame` steps it once on every frame, before and outside the frame-keyed cache
  of `summary(for:)` (`DevRunCore.swift:1028`), which is keyed on `(frame, word)`. The cleaned frame feeds the summary
  (reference pad, neutral check) and `wantedActive`/`isActive`; extra bits are never touched, so paddle activity still
  reads right. Each press's covered items and how they were found (seen, confirmed, other, unconfirmed) go into the
  step's report. `recordReceiver` keeps the raw frame.
- **Engine log**: when the ring's filter flags OTHER, one line "echo: <Label> now adds <item> (stored: <item>)" from
  its state's `cur`, and one line when that key adds its stored item again; when a press where only that key changed
  is UNCONFIRMED, one line "echo: <Label> not seen at its press (stored: <item>)"; nothing more per key until it
  changes.

### Other v2 semantics (the Swift oracle already has them)

- A pad button is held when any of its sources is active, with no count limit.
- LT/RT = maximum over its sources: an analog source gives clamp(raw/1023); a button source gives 1.0 while active.
  In C, the trigger loop's assignment becomes `if (x > v) v = x`, which is bit-identical for one entry starting at +0.0;
  then full scale from item 20/21 rules; then today's deadband snap.

## Blob format GDHM v2 (S5)

Same 64-byte header and entry sizes as v1, little-endian, read with memcpy, at most 1024 bytes. No reserved field gains
a meaning: `outSlot` stays reserved for R7, the trigger entry's reserved u16 and the header `flags` stay 0.

Header changes only:

| Offset | Field | v1 | v2 |
|---|---|---|---|
| 4 | u16 version | 1 | 2 (0 and 3+ → `GDX_E_VERSION`) |
| 25 | u8 nTriggers | ≤ 2 | ≤ 4 |
| 27 | u8 nEcho | must be 0 | 0 or 1 |

Sections, each starting on an 8-byte boundary, the last ending exactly at `length`, zero padding enforced:
reports (4 B) · buttons (8 B) · axes (16 B) · triggers (4 B) · placements (8 B) · **echo (8 B, v2 only)**.

Button entry, layout unchanged: `{u8 item, u8 kind, u8 arg, i8 sign, u16 physMask, u8 stickRef, u8 outSlot = 0}`.
- v2 allows item **20 (LT) / 21 (RT)**: "this trigger = 1.0 while the rule is active". It never sets a bit in
  `gdx_pad.buttons`, so `XlateCore.padButtons` and `gdx_unchanged` see only bits 0..15 as today.
- v2 has **no per-item cap**; the total stays ≤ 32 (29 sources at most).

Trigger entry, layout unchanged: `{u8 item 20|21, u8 field 0 lt | 1 rt | 0xFF none, u16 0}`.
- v2: up to two entries per item, only with distinct fields 0 and 1; 0xFF only as an item's single entry.

Echo entry (new, 8 bytes); it has no reserved or padding bytes:

| Offset | Field | Valid |
|---|---|---|
| +0 | u16 hideMask | 0x0001..0x003F: bit k = extra bit k is remapped (0 paddle outer right, 1 inner right, 2 inner left, 3 outer left, 4 SAX left, 5 SAX right); bits 6..15 zero |
| +2 | u8 item[6] | the stored item of key k, in that order: 1..10 receiver buttons 1..10 (A B X Y LB RB View Menu L3 R3), 11 D-pad up, 12 right, 13 down, 14 left for a key in hideMask (never 0); always 0 for a key outside hideMask |

With all six remapped on their factory bindings the entry is `3f 00 0c 0d 0b 0e 01 02`; the factory mapping itself has
no echo entry (its mask is 0) and stays a v1 blob. Start, G1–G5, Profile, buttons 18–19, the triggers and the sticks
have no code, so they can never be hidden.

Validation: version 1 runs **exactly today's checks** (every existing blob test keeps its reason code). Version 2:
the button item check is `item < GDX_BUTTON_ITEMS || item == GDX_ITEM_LT || item == GDX_ITEM_RT`, else `GDX_E_ITEM`;
the per-item counter `itemRules` (`GDHubXlate.c:158, 219`) runs **only for version 1** and is neither read nor written
in version 2; the range check comes strictly before any array access in both versions. A third trigger entry, a
repeated field or 0xFF next to another entry → `GDX_E_TRIGGER`; nEcho > 1 or nTriggers > 4 → `GDX_E_COUNTS`; a
hideMask of 0 or above 0x3F, an item code above 14, code 0 for a key inside hideMask, or a non-zero code for a key
outside hideMask → new **`GDX_E_ECHO` = 22** (driver reasons stay below 100).

Sizes: largest v2 blob 64 + 16 + 256 + 64 + 16 + 256 + 8 = 680 B (v1: 664). Factory blob 408 B, unchanged. Native
`gdx_map` gains `version`, `nEcho`, `echoHide` (u8) and `echoItem[6]` (u16 item masks, decoded once by `gdx_validate`),
and `triggers[4]`; it stays far below `GDH_MAP_MAX` 1024 (the static asserts in `GDHubReceiverTap.cpp:21` and
`GDHubXlateGlue.cpp:8-9` hold; `--check` compiles them before S7).

Defines: `GDX_BLOB_VERSION` stays 1; new `GDX_BLOB_VERSION_MAX` 2, `GDX_MAX_ECHO` 1; `GDX_MAX_TRIGGERS` 4 (v1's limit of 2
is checked by version). C API, two functions: `uint32_t gdx_echo_next(const gdx_map *, gdx_echo *, const uint8_t *in,
size_t len)` returns the word (0 when the map has no echo entry, the frame is bad, or no remapped key is held), and
`void gdx_echo_apply(uint32_t word, const uint8_t in[16], uint8_t out[16])`. The `gdx_echo` type and the two
`gdx_state` fields go into `GDHubXlate.h`. No delivery reset and no compare helper. All in `GDHubXlate.c` (the only
`Shared` file the dext compiles, `project.yml:39-41`). Integer only, no allocation, no libm, compiled with
`-ffp-contract=off` as today.

Encoder (`MapBlobEncoder.swift`):
- `GDHMTable` gains `version` and `echo`; `serialize` writes `version` (not the compiled define) and byte 27, and appends
  the echo section.
- `encode(_:identity:spec:revision:axisDeadband:triggerDeadband:maxVersion:)` with **`maxVersion: Int = 1`**: version 1
  whenever v1 can say the mapping (today's `table()`, byte-identical); else version 2 when `maxVersion ≥ 2`; else
  `.unsupported` with the level-1 reason. The default of 1 means build 24 can never get v2 by accident, and today's call
  sites stay as they are.
- `remapLimit(_:level:)`, level default 1, returns **only driver limits**: at level 1 today's three messages plus
  "<Label> sends <X>: this driver version cannot hide the controller's own press"; at level 2 always nil.
- Words: one private, fixed id → words table next to `label(_ PadOutput)`: "Paddle outer right", "Paddle inner right",
  "Paddle inner left", "Paddle outer left", "SAX left", "SAX right" (the layout labels). Used only in the new message;
  step-1 messages stay byte-identical. A test checks the table against `envision-pro-layout.json`.
  **Changed after the pre-install review (finding 5):** v7b change 6 wants every driver-limit message in words, which
  contradicts the line above. Both are kept: `remapLimit` keeps the step-1 text byte for byte (`GDHMv1PinTests` pins it),
  and `remapLimitInWords` says the same limits with the layout labels for controls and the menu's names for items
  ("three buttons send A: A, X, G5", "SAX left sends View: …"). The engine reports the worded text as its reason, and the
  Mapping hint, the menu marks, the Driver menu status and the Developer prompt show it. The table now covers every
  remappable control.
- v2 order: items 0..14 as today (default owner first, then `remappableIDs` order, so paddles come last), then item 20
  rules, then item 21; trigger entries LT then RT, distinct analog fields in source order or one 0xFF entry; then echo.
- Echo entry from `echoParams`: written whenever `echoHideMask` is not 0; the item codes of the keys in the mask from
  `echoItem` (a button n → n; up, right, down, left → 11, 12, 13, 14; never none for a key in the mask), 0 for every
  other key.

## Driver and engine (S6), and the replacement (S7)

Driver changes, only these:
- `GDHUB_CAP_GDHM2` = `1u << 12` in hello `out[2]`, set together with `XLATE` (build 25 reports 0x1F01 = 7937; a
  `GDHUB_TAP_DECLINE` build does not set it). No protocol bump, no new selector.
- `loadMap` (`GDHubReceiverTap.cpp:203-223`): count checks gain nTriggers ≤ 4 and nEcho ≤ 1. Nothing else: no
  compare, no new reset site (see "Where it runs").
- Frame path (`shadowFrame`): the LIVE gate's reset at `:564` keeps the echo state (three lines, "Where it runs"), and
  the tap keeps `echoRun` after each `gdx_step` and writes it to `rec.pad[5]`.
- Parity record: the echo word as above. status2 appended (version stays 1, size 676 → 720): 676 u32
  `PARITY_ECHO_WORD`, 680 u8 `PARITY_ECHO_VALID`, 681–687 zero, then u64 counters of frames whose word has a bit set:
  688 `ECHO_HIDDEN_FRAMES` (bit 31), 696 `ECHO_RECOVERED_FRAMES` (bit 24), 704 `ECHO_OTHER` (bit 25), 712
  `ECHO_UNCONFIRMED` (bit 26). The tap counts them from `lastEchoWord` after each `gdx_step`; bits 25 and 26 mark the
  press report only, so those two count presses. `PARITY_ECHO_WORD` is the last frame's word, for diagnosis only.
- Self-test (`GDHubXlateGlue.cpp:17-66`): also runs the v2 golden blob and its sequence through `gdx_step`, starting
  from `memset(&st, 0, sizeof st)`, with the `gdx_reset` the sequence marks. The runner is a new
  `Dext/GDHubVirtualHID/Core/GDHubSeqCore.c` that includes only `GDHubXlate.h` (never `GDHubDefaults.h`) and takes the
  blob, spec, frame sequence, expected bytes and reset marks as pointer and length parameters, declared in its own Core
  header with `uint8_t`/`uint32_t`/`size_t` parameters only; `GDHubXlateGlue.cpp` passes the `GDHubDefaults.h` arrays,
  and `GDHubXlateGoldenTests` passes the same arrays through the `GDHubXlate` module, so both run identical code.
  Package.swift gets `dependencies: ["GDHubXlate"]` on the `GDHubDextCore` target (`Package.swift:18-22`); no
  project.yml change (the dext compiles everything under `Dext/GDHubVirtualHID` with `Shared` on its header path). Still
  all-or-nothing.
- **Do not touch**: the bodies of tap Start, Stop, free/init, SetPowerState and `syncMode`, the timer setup in Start
  and every existing `gdx_reset` call except the three-line keep at `:564` (an empty `git diff` of those functions
  against build 24, recorded in the S6 notes); in the tap, new code is reachable only from `loadMap`'s count checks and
  the frame path (`shadowFrame`/`gdx_step`: the `:564` keep, `echoRun`, the parity word and the four echo counters);
  outside the tap, only the hello caps, the status2 writer and the self-test; registry sizes (`GDH_MAP_MAX`);
  `GDHUB_PROTOCOL_VERSION`; the −1 quirk (takeover open question 9). New frame code then runs only after SHADOW is
  asked for and the self-test passes.

Engine and GUI:
- `DextClient.acceptsGDHM2`. `TapSupervisor.mappingOffer` becomes `(revision, maxVersion) -> MappingOffer`.
  TapSupervisor already holds the hello caps and the instance nonce; it passes 2 only when the **running** driver's
  hello has `GDHUB_CAP_GDHM2`, else 1, and uses the same value at the stand-down check (`:445`) and the push (`:761`). It
  re-evaluates the offer when the caps or the nonce change. `EngineService.swift:93-100` forwards `maxVersion` to
  `encode`. `VirtualPadSink.swift:571` passes `maxVersion: 2` explicitly; its fallback note (`:574`) says "not
  expressible in GDHM" without a version.
- A mapping that needs v2 on build 24 is `.unsupported`: quiet stand-down, the App drives, no limiter count, never
  pushed, so `GDX_E_VERSION` cannot happen.
- `TapStatusReport`: `gdhmMax` (an integer; a missing key decodes to 1); `echoValid`, `echoWord`, `echoHiddenFrames`,
  `echoRecoveredFrames`, `echoOther`, `echoUnconfirmed`, `echoWordDiffs`, `echoUnarmed`, `echoUnaligned` and
  `parityEchoOk` (missing keys decode to 0); one engine log line with them. The counters are cumulative; they go into
  the report rounded down to hundreds, like `parityOkBucket` (`TapSupervisor.swift:1028`), so the file is rewritten
  when one crosses a bucket and never per frame (`TapStatusReport.swift:7-10`); parity is sampled on the 100 ms tick.
  Developer-mode run reports record them, with `echoValid` and the sampler's `skipped` count, before and after each
  step, next to the parity numbers.
- GUI level: `EnvisionProDevice` gets `@Published var gdhmLevel: Int?`. `DriverManager` sets it from the live report's
  `gdhmMax` only when `report.pid` is the running engine's pid; in in-app mode from `DextClient`'s hello caps (2 with
  `GDHUB_CAP_GDHM2`, else 1) once a hello was read; nil in every other case (engine not running, waiting for the engine,
  no hello yet). It is updated on every report poll, engine pid change, caps change and instance-nonce change.
  `refreshRemapCaches()` runs on a mapping change **and** on a level change; `remapLimit = RemapHint.limit(of: mapping,
  level: gdhmLevel)`, nil while the level is nil. `RemapMenuModel`, the footnote, the toolbar hint, the Driver-menu
  status and the Developer prompt all read this one level.

Compatibility (to add to the takeover plan §5.7 in S9):

| App | Driver | Result |
|---|---|---|
| S5 and later | 25 | Everything in the driver |
| S5 and later | 25, self-test FAIL | Everything on the App, v1 mappings included; the Driver menu shows the self-test failure |
| S5 and later | 24 | v1 mappings in the driver; mappings that need v2: the App drives, quietly, "App drives *" shown |
| S4 app (Swift only) | 24 or 25 | v1 blobs only; paddle remaps and the other v2 cases run on the App, no data lost |
| step-1 app | 25 | v1 works; paddle and SAX remaps are dropped from the file at its next save (restore from the newest `mapping … new.json` in `mapping-backups`, or the copy) |

### The replacement (S7)

S7 follows the takeover plan **§7.1 U1–U7** and, if needed, **§7.2 RB1–RB8**, exactly as written after S6(d) corrects
them; they are not restated here. These step-2 steps come around them:

Before U1:

1. `scripts/build-xcode.sh --check` passes on the current tree.
2. Archive the installed app (the S4 build, which knows paddle remaps) to `~/GDHub-rollback/S7-pre/GDHub.app`. Check
   that the archived dext's `CFBundleVersion` is 24 and the archived app's `GDHubDextSourceHash` (in the app's own Info.plist: `plutil -extract GDHubDextSourceHash raw …/Contents/Info.plist`; S1 put it there so nothing under `Dext/` had to change) equals the seeded build-24 hash: a
   rollback would install unchanged build-24 sources.
3. Copy the layout and mapping files; check that no `envision-pro-layout.before-edit.json` exists; Parallels off,
   Shadow not forwarding.
4. `defaults read com.interlinked.gdhub tapBreakerTrippedAt` and `… tapBreakerReason` both report a missing key, and
   the Driver menu shows the Driver path armed. A latch left from S4 is recorded, never blamed on build 25.
5. Start a `scripts/dext-log.sh` capture (U5 and RB5 read it).

U1–U3. U3 is expected to give build 25: the script takes the highest of the last and the listed builds, plus 1, and
from S1 it writes `Xcode/build-number` only after a successful build. U5 uses the N that U3 printed ("built build N").
If U3 stops before it prints "installed /Applications/GDHub.app", the old app and driver 24 are untouched: run
`scripts/engine-agent.sh install && open /Applications/GDHub.app` to get the engine, the pad and the GUI back, then stop
and report the last lines of U3 (or `.xcodebuild/last-build.log`). A retry starts again at U1. If `/Applications/GDHub.app`
is missing (a failed copy after the old app was removed), first restore it from `~/GDHub-rollback/S7-pre/`.

U4–U6, then before U7 (the engine is still uninstalled, so nothing drives in between):

6. `defaults write com.interlinked.gdhub inputPath -string shadow`.

After U7:

7. The engine log or the Driver menu shows armed = shadow, self-test pass, a map and the pushed revision accepted.
8. App-path check: row 1 (Full check) on App only, on the factory mapping and the C core. (Row 4 is not used here: it
   has a Driver pass, which would go LIVE on the new driver before the soak; row 1 holds row 4's six steps.) Then the
   owner presses Profile until the noted colour is back, and SHADOW is armed again (Developer mode puts `shadow` back).
   If row 1 fails, run it again with `xlateCore` set to swift (below). Passing on Swift and failing on C points at the
   shared C: stop S7, leave the owner on the Swift App path, go back to S5/S6 fixes.
9. v1 soak: 10 min in SHADOW with the controller in use (a game is fine: the App drives the pad). Pass: parity ok count
   rising, 0 parity mismatches, no fallback or limiter entry.
10. v2 soak, still in SHADOW: the owner makes the row 11 and row 12 picks together (paddle outer right → R3, paddle
    outer left → L3, paddle inner left → Nothing, SAX left → View, SAX right → Menu, G1 → LT, LT → RT, X → A, G5 → A;
    they do not overlap). That one v2 blob has an echo entry, an item 20 rule, two sources on RT and three on A. The
    owner presses the remapped keys, paddle inner right, the D-pad, A, X, G1, G5, LT and RT for 5 minutes, with holds
    and combinations, and a few times holds D-pad left while pressing paddle outer right. Pass: the "mapping revision
    accepted" line shows a blob size other than 408; `ECHO_HIDDEN_FRAMES` and `ECHO_RECOVERED_FRAMES` rise;
    `PARITY_ECHO_VALID` = 1 on the samples; 0 parity mismatches; `echoWordDiffs` = 0 over aligned armed words, with at
    least one aligned armed word compared while a remapped key was held (`parityEchoOk` rose); no `driverRefused` or
    fallback; the self-test still passes. `ECHO_OTHER`, `ECHO_UNCONFIRMED` and `echoUnaligned` are recorded, not judged
    (a profile change, a two-key press or a missed frame is not a fault).
11. Mapping → Reset all remaps; compare the mapping and layout with the copies.
12. `defaults delete com.interlinked.gdhub inputPath` (delete, not `driver`, so the Mac is back in the HANDOFF "no
    inputPath stored" state). Within seconds the engine logs `inputPath: shadow -> driver` and reaches LIVE (armed =
    live, pad source TAP). The key is absent before S8 starts: Developer mode snapshots the path keys at each run.

Build 25 is proven by: `systemextensionsctl list` showing `0.1.0/25` `activated enabled` with no build-24 entry left
"terminating"; `pgrep -lf 'com.interlinked.gdhub.VirtualHID$'` printing exactly one line; the engine's notice-level
`connection: connected(dextBuild: 25 …)`; status2 `build == 25`, `tapPresent == 1` and `tapPid == rootPid`. This stands in
for U5's "root start" line after a reboot (the line is printed at boot, before any stream) or whenever the stream
missed it; before U7, the app's `connected(dextBuild: 25` line can be read with `log show --last boot --info`.
One reboot is budgeted, only on the common-rule conditions. A tap crash loop: the owner switches the controller off
before RB1 and keeps it off until RB6.

First escape for an App-path problem in S7 or S8 (cheaper than a driver rollback): `defaults write
com.interlinked.gdhub xlateCore -string swift`, then restart the engine (`scripts/engine-agent.sh uninstall` and
`install`; in the in-app mode of U4–U7, quit and open the app), and check that the run report header shows
`xlateCore: swift`. The key is read only when the sink is built. Undo with `defaults delete … xlateCore` and the same
restart. For a shared-C fault seen on both paths: `inputPath -string engine` plus `xlateCore` swift. §7.2 stays for a
driver fault.

**If the S7 exit fails** (the same rule applies to a Driver-pass failure in S8). Failure is any of: U5 not matching
within 2 min even after the budgeted reboot; "selftest FAIL" or `driverRefused` in the engine log; a parity fallback or
any parity mismatch or echo-word difference on an aligned word in a soak; the layout or mapping differing from its
copy. First, with no
owner decision needed: leave the automatic App fallback in place (F4/F5) and make sure `inputPath` = engine so the
controller keeps working; do not install, rebuild or reboot again. A tap crash loop is the one exception: controller
off and roll back per §7.2 at once (takeover R9). Then stop: "apprall" does not cover this. Report what failed
(self-test vector, parity counters, log lines) and offer the owner: (a) stay on build 25 with the App driving, no
further replacement for now; (b) roll back 25 → 24 per §7.2 to `~/GDHub-rollback/S7-pre`; (c) fix forward with build
26. Both (b) and (c) are further driver replacements, each with its own reboot budget and the owner's explicit word. A
build 26 also needs a new read-only pre-install review of the diff since 25 (Opus high), a fresh S7-pre archive, and
copies of layout and mapping compared after; the "only one replacement" lines (ledger, Q7, "Done when") are then
updated to record it.

**After a rollback (RB1–RB8 ran)**: the active driver is build 24 and the app is the S4 build from S7-pre. Record what
failed, the U5/RB5 output and `systemextensionsctl list` in the ledger; mark S7 "rolled back"; copy and compare the
layout and mapping; stop for the owner. Until a retry the build guard refuses every `--same-build` (the number says
25, the active driver is 24), so a later app-only install cannot quietly embed driver 25. If one is needed before a
retry, it is built from the S7-pre commit (the current tree holds build-25 driver code) after `Xcode/build-number` and
`Xcode/dext-source.hash` are set back to 24 with the S1 seeding check, which proves the sources are build 24's. A
retry needs a fix, a new S6 independent review and the owner's consent in chat; it uses a new number (U3 gives 26) and
never rebuilds 25 from different code.

## UI (mockup v7 first, approved during S2; v7b before the UI code of S3(c) and rows 11 and 12; code in S3 and S4)

Mockup `docs/mockups/remap-buttons-v7.html` is drawn from the layout copy taken at the start of S1 into
`~/GDHub-rollback/S1-pre/` (the owner's rule: from the real layout; the drawing never opens the data folder; the copy is
checked equal to the live file first). A copy stays in `docs/mockups` and it is sent in chat for review on the phone.
It keeps v6's live All / Front / Back / Sides tabs and its toolbar, with a "Changes from mockup v6" box, and these live
demos: a "press" toggle for paddle outer right → Y (Front and All light the paddle and Y as linked, not D-pad right); a
toggle for a paddle left on Controller's profile (it still lights D-pad right); the Profile menu with its new note; a
switch "driver build 24 / after the update / level unknown" that shows and hides the driver-update texts on a step-1
control's menu and the status line; the toolbar and a Front menu with nothing remapped (Reset items hidden); A's menu
showing that remapping A leaves a remapped SAX key alone; a signal-conflict note and hint line. A Developer-mode part
shows a `record` step, a judged trigger step, a `builtInEcho` step naming the button it saw, a "cannot judge" verdict,
the `built_in` wording for a paddle and the trigger-remap skip gone. The owner's OK was to come before any UI code,
including S1's `record` display; it came during S2 ("v7 OK", 2026-11-10 21:56), after `fb83ebd` had coded an interim,
neutral display (the S1 deviation in the ledger; S4(a) aligns it with v7).

Mockup v7b (`docs/mockups/remap-buttons-v7b.html`, copy kept in `docs/mockups`, sent in chat for the phone) is v7 with
only these changes, listed in a "Changes from mockup v7" box; every text in v7 that describes a placeholder is updated
with it:
1. The remapped-key note without "or any button at the same moment as the key" (item 2; v7 `NOTE_RM`, `:254`).
2. The Profile note's placeholder sentence filled (item 5; v7 `PH_PROFILE`, `:255`), and the texts that describe it:
   change 5 of the "Changes from mockup v6" box (`:147`) describes the final sentence, "remapped ones keep sending only
   your pick", instead of a sentence written after the survey; the Profile menu "Try" caption (`:450`) reads "The new
   note."
3. The limits paragraph of part 3, "What a remapped paddle does, and its limits" (`:196`), rewritten to v3 ("The limits
   in v3 against Q3", the owner's view), its milliseconds placeholder removed (v3 has no window); the table above it
   (`:190-193`) gains the row "Hold the paddle, press D-pad right → Y only; D-pad right shows when you let go of the
   paddle".
4. The "Hold" demo models press order (`lights()`, `:295-301`, and "The game gets" `:352`): a remapped key's own
   button pressed after the key is not sent and is drawn as waiting ("shows when you let go of <key>") until the key is
   let go, and lost if let go first; held before the key and let go during the hold, it stays lit and sent until the
   key is let go. One line under "The game gets": "Pressing a remapped key's own button while you hold the key shows
   only when you let go of the key." With an untouched paddle and the opposite real direction held, the demo leaves
   that direction out, as the controller's cancel does.
5. Developer mode: the hiding-check wordings of UI item 11, each with the condition it applies to, replace `:225`; the
   "cannot judge" tooltip placeholder (`:226`) is filled ("the controller sent no button for this key").
6. Row 11 as built in S4 (`ROW11`, `:482-494`; `NOTES[11]`, `:526`): the two new steps after the D-pad up step, "Hold
   Paddle outer right, press D-pad left twice" (D-pad left ×2, R3 held in the background) and "Hold D-pad left, press
   Paddle outer right twice" (R3 ×2, D-pad left held in the background and never dropping), each with an instruction
   line saying to press the held control first; the first step's hiding verdict says D-pad right was seen on the
   receiver before D-pad left and that the pad showed D-pad left while the controller sent no direction; the second's
   reads "not exercised (the controller sent no D-pad right during the hold)", and it proves the recovery (D-pad left
   never dropped); `NOTES[11]` gains "Press the held control first, as the step says".
7. Row 10's survey table (`SURVEY()`, `:474-480`) follows the built template: the six keys first, four "Hold D-pad up,
   press <paddle> once" steps, rest last, 41 rows.
8. "What I need from you" (`:236`) names the one placeholder left, the Driver-pass stand-down (`:557`), which is worded
   in S4.
Drawn from the same S1-pre layout copy. The owner's OK is quoted before the UI code of S3(c) (the remapped-key note
included) and before S4(b) codes rows 11 and 12.

What changes on screen:

1. Paddle and SAX menus become full menus with ✓ "Controller's profile (built in)" as the default; `deferredNote` and
   the `.deferred` kind go (`RemapMenuModel.swift:41-48,76,122-130`).
2. Their note: on Controller's profile, "Sends the button the controller's profile gives it, and follows that button's
   remap."; remapped, "Sends only your pick. The controller's own button for this key is hidden while you hold it, so
   pressing that same button yourself shows only when you let go." (final words in v7b).
3. Labels: "Paddle outer right → Y", "SAX left → Nothing" (grey). Check the leading and trailing labels on Back and
   Sides for overlap: they grow sideways (only centred labels keep their place).
4. Lighting: a remapped paddle lights itself and Y (linked) on Front and All, not D-pad right; a paddle on Controller's
   profile still lights D-pad right as today.
5. Profile note: "Each press also switches the controller's own profile. Paddles and SAX keys left on Controller's
   profile change with it; remapped ones keep sending only your pick." (the sentence v7 left as a placeholder; final
   words in v7b).
6. "App drives *", the footnote and "Driven by: App (mapping needs a driver update: …)" appear only while the running
   driver cannot take the mapping (build 24). After the update they are gone, and they never show while the driver's
   level is unknown. They name keys in words ("Paddle outer right sends Y: this driver version cannot hide the
   controller's own press"), never as raw ids.
7. Hidden instead of greyed (owner's rule): "Reset to default" in a menu when the key is not remapped
   (`RemapMenuModel.swift:152` leaves the item out), and "Reset all remaps" in the toolbar when nothing is remapped
   (`ControllerView.swift:1346-1347` shows the button only when `outputs` is not empty).
8. v6 changes 7 and 8 are reversed for remapped keys (remapping A no longer moves a remapped SAX key).
9. Signal conflict (rare, from an old learn): a note in the remapped key's menu, "<Other> was learned with <Paddle>'s
   signal: re-learn <Other>.", and a toolbar hint line in the warning colour with the same text and no "Driven by"
   prefix. Never "App drives" or "needs a driver update".
10. Re-learn of a paddle or SAX key refused when the signal is another key's: "That was <Other>'s signal: press
    <Label> itself."
11. Developer mode: the skip "trigger remaps are checked after the next driver update" disappears and trigger steps are
    judged; `record` steps read "recorded" with no verdict; a `builtInEcho` step names the button it saw; a hiding
    claim reads "cannot judge: the controller's current profile sends <X> for this key" when the covered item equals
    the pick, a background item or the button pressed during the hold; "cannot judge: the controller's button for this
    key was not seen at its press (it sent none or several)" when the press was unconfirmed; "not exercised (the
    controller sent no <X> during the hold)" when the covered item never reached the receiver during the hold (for
    example cancelled against a held opposite direction); a `built_in` requirement on one of the six reads "needs Paddle
    inner right on Controller's profile: Reset it in Mapping" (G2–G4 keep "at its built-in function"); `background` fail
    messages such as "A dropped while View was being pressed"; the Developer prompt names keys in words; rows 10, 11
    and 12 appear in the picker.
12. No new line in the Driver menu; the echo counters and the "now adds" line go to the engine log and the run report.

## Templates and checks

Rows 1–9 stay as they are: 1 Full check · 2 Sticks check · 3 G keys, Profile and Start · 4 Paddles and SAX echo (App,
then Driver) · 5 Remap check: G1 sent to Y (App, then Driver) · 6 Remap check: A and B swapped (App, then Driver) ·
7 Volume keys under a remap: G2, G3, G4 (App, then Driver) · 8 Hold RT while the app switches App ↔ Driver (T7) ·
9 Latency: controller to pad, per press (App, then Driver) — T8 gate. Their steps do not change. Untouched paddles and
SAX keys in rows 1 and 4 are judged by `builtInEcho` (below), because row 1 presses Profile and the Mac cannot see the
profile. Row 4 now checks one echo per press and the same echo on both paths (`dev-run-compare.py`), not the stored
echo; only its notes are reworded to say so. New built-ins are **appended** to `DevTemplates.builtInOrder`; local
templates move down by three, so the picker is re-read before a row number is quoted.

Developer-mode additions:
- S1: template option `recordReceiver: true` stores every receiver frame whose non-stick bytes changed, as
  `{n: receiver report index, t: ms, hex: 16 bytes}`, capped at 4000 per step, under a new run-report key `receiver`.
  New step kind `record`: no verdict, shown as "recorded" (an older build refuses the kind visibly). Its window opens on
  the first frame where any listed control is active (`wantedActive` learns the kind), with today's "no movement within
  5 s of Go". It ends early once every listed control has gone down and up, the total rises reach the step's `rises`
  count (written in the template), and the receiver's non-stick bytes have equalled the frame at Go for 350 ms (so a
  late echo release is still seen); `seconds` stays the upper limit. `scripts/tools/echo-survey.py` (with Python tests)
  prints per key and per Profile block: the extra bit seen next to the table entry, the echo, the lag on press and
  release, any lead, the re-emergence lag of the other key's direction in two-key blocks, the hat value in each
  combination, the echo change after a Profile edge during a hold, and any analog field moving. S3(a) fixes how it
  attributes changes when two keys are pressed together and replaces its gate (row 10 below).
- S4: `DevExpectedItems` gains `lt` and `rt` (one full pull per press, the other trigger still); the trigger rule judges
  the pad trigger the control is **mapped to**, and fails unexpected button changes; trigger and held steps get the
  unexpected-change rule; the latency watch follows the expected output; `DevExpectation` keeps LT/RT.
  `DevExpectation.pressedFrame`: for the six whose effective output is not `.builtIn`, only `identityBits(id)` is set,
  never the stored binding, so a remapped key expects its pick whatever echo is stored (`linkedOutputControls` follows).
  `DevExpectation.resolve` sends one of the six whose effective output is `.builtIn` to the `builtInEcho` rule, in every
  template. New expect keys:
  - `builtInEcho`: exactly one pad item (a button, a D-pad direction or a trigger pull) per press, whichever the profile
    gives; the report names it.
  - `background`: pad items whose control is pressed first and let go last; the control must be in the step's
    `controls` (a template check), or the ready gate never passes. Per background item B: B is not set at the window
    start, or set there with no rise; at most one rise, before the first rise of every expected item; no fall before
    the last fall of every expected item; at most one fall (none is allowed: the window may end first). Only then is B
    left out of "unexpected change". Fail messages: "A dropped while View was being pressed (fell N times before the
    last View release)", "A came up after View", "A went down N times (needs 1)".
  - "cannot judge", for steps with `recordReceiver`: per press the judge takes the item the run's echo filter read for
    the key (`cur`: seen, confirmed or other; the stored one when unconfirmed) and how it was found, named in the
    report. The verdict is split: the pick arriving passes or fails as usual; the claim that the echo was hidden is
    "cannot judge" when that item equals the pick, a `background` item or the item pressed during the hold (reason
    "same item" or "background"), or when the press was unconfirmed (reason "not seen at its press"); it is "not
    exercised" when that item is never set in the raw reports from the press report to the last report before the
    release (for a direction, its diagonals count), as when the controller cancels it against a held opposite. Each
    verdict names its reason with the wording of UI item 11. A step with no hold that exercises the item gets no
    conclusive verdict. A `builtInEcho` step with no echo is "cannot judge", not a fail.
  - Rule for templates: a step with several sources on one pad item is split into one step per source (the judge counts
    rises of the item, not which control caused them).
  `triggerRemapSkip` and its wording go (`DevRunCore.swift:172-191`). The `built_in` wording for the six
  (`DevRunCore.swift:135, 167`; `DevRequirementCheck.swift:39`) comes from one helper next to the menu's own label.
  `dev-run-compare.py` and `docs/protocol/developer-mode-files.md` learn every new key; the compare names the echo per key
  on both paths and fails on a difference.

**10. "Paddles and SAX: what the controller adds (survey)"** (`echo-survey`, S1; steps of kind `record`, no `requires`;
41 steps, as built in `Sources/GDHub/Resources/dev-script-echo-survey.json`, which is the source of truth): each of the
six keys alone, ten times · hold D-pad up, press one paddle once, as four steps in the order inner left (same
direction), outer right (next), inner right (opposite), outer left (next) · hold paddle outer right, press D-pad up
twice (shows "last press wins") · hold paddle outer right, press D-pad left twice · hold paddle outer right, press
paddle outer left twice (an untouched key with the opposite echo) · hold paddle outer right, press paddle inner right
twice (a cross pair: right and down) · hold A, press SAX left twice · hold SAX left, press A twice · both outer paddles
together twice · both inner paddles together twice · SAX left and right together twice · only if Q4 is yes (it was):
three blocks, each "hold paddle outer right, press Profile once, let go of both, note the light colour", then the six
keys three times each · rest, last (a first rest step cannot know the pad's state).
Notes: "Do not press Profile except where a step says so." and "After the last block, press Profile until your
starting colour is back."
**Gate (S2), as run**: for each key pressed alone exactly one extra bit, the table entry; echo timing within 1 report
before and 3 after on press, 7 on release; the remaining key's direction back within 7 reports; the hat never drops a
real direction while a paddle is held; no echo on a stick; Profile during a hold; W and G derived from the worst lags.
It failed on one real point, the opposite-direction cancel; its other failed lines came from the reader's attribution
and from the order of pressing ("S2 result"). W, G and S are no longer used.
**Gate from v3 on** (any later run of row 10, for example wired mode, another firmware or after an iCUE change; read by
the fixed `echo-survey.py`), in every state seen. Every gate line reads every attempt, superseded ones included, as
the S2 numbers were counted; each attempt starts from a fresh state, and a failure names its step and attempt index:
- each key's presses raise its table bit; any other bit seen in an attempt of an "alone" step is another of the six's
  table bits (a touched neighbour: reported as "touched <key> N times (attempt i)", and its presses left out of that
  step), so an owner's slip in a redone attempt never fails the gate, while a timing fault or a clean unconfirmed press
  in it still does;
- each key's echo is one receiver button 1–10 or one D-pad direction, the same in every press of that state (never a
  stick, a trigger, Start, a G key or Profile);
- every key edge where only that key changes either changes exactly its echo in its own report (the oracle's
  `changed`: a cancel counts as the opposite direction; a release is read backwards, `changed(report, report before)`,
  what it took away), or changes nothing because the echo item was already on for at least 8 reports before a press
  (or stays on for at least 8 reports after a release); anything else is a lag or a lead and fails (S2 copy: 654 such
  edges, 634 exactly the echo, 20 already on, 0 other);
- the replay of the v3 rule (`scripts/tools/echo_rule.py`) over every attempt under all 64 hide masks, with the echoes
  just measured as the stored items: 0 wrong and 0 ghosts against the truth model under "The rule", the number of
  ambiguous items printed; an unconfirmed press fails only when it is clean (that key is the only one of the six that
  changed in its report, and nothing else on the pad changed there besides its own echo);
- no step lost reports to the cap.
Reported, not judged: Profile during a hold, the hat in each combination, the echo per key and state, the re-emergence
and Profile-edge lags, unconfirmed presses that are not clean, with their cause ("shared with <key>": two of the six in
one report; "with <item>": another input in the same report), and row 11's probe direction and picks checked against
every echo seen. **If this gate fails**: stop for the owner; the facts the rule rests on do not hold for that setup.
**Q8 = (b), written out** (not applied: the owner chose "Rework the rule"; it stays the other choice of Q10 and Q11):
paddles and SAX keep the `.deferred` kind and its note, reworded to "Remapping paddles and SAX is not available yet:
the controller's own button for these keys could not be hidden reliably. This key sends the button the controller's
profile gives it, and follows that button's remap." The six stay out of `remappableIDs`; UI items 1–5, 8, 9 and 10 are
dropped, and row 11. S3's echo filter, S5's echo entry and `gdx_echo_*`, the parity word and the echo counters are
dropped; the GDHM v2 version byte and the other three v2 items stay. "Done when" loses its paddle clause. A short v7b
is approved before S3.

**11. "Remap check: paddles and SAX (App, then Driver)"** (`remap-paddles`, S4; `recordReceiver: true`). Picks, outside
every echo seen so far: paddle outer right → R3, paddle outer left → L3, paddle inner left → Nothing, SAX left → View,
SAX right → Menu; paddle inner right stays on Controller's profile. `requires` on every step: the five picks and
`built_in` for paddle inner right. Steps, all with written-out expectations: rest · paddle outer right ten times → R3 ·
paddle outer left ten times → L3 · paddle inner left ten times → nothing · SAX left ten times → View · SAX right ten
times → Menu · paddle inner right twice → `builtInEcho` · hold paddle outer right, press D-pad up (the S2 probe) twice →
D-pad up twice, `background` R3 (controls paddle_outer_right, dpad_up) · hold paddle outer right, press D-pad left
twice → D-pad left twice, `background` R3 (controls paddle_outer_right, dpad_left; expected: the controller sends no
direction while D-pad left is down, as measured with D-pad left first; the pad must show left) · hold D-pad left, press
paddle outer right twice → R3 twice, `background` D-pad left (controls dpad_left, paddle_outer_right; D-pad left must
not drop) · hold A, press SAX left twice → View twice, `background` A (controls a, sax_left) · both outer paddles
together twice → R3 and L3, no D-pad · D-pad right twice alone → D-pad right · A twice alone → A. Notes list the picks,
"Do not press Profile", "Press the held control first, as the step says", and end with "Afterwards: Mapping → Reset
all remaps". The probe (D-pad up) and the picks are outside every echo S2 saw. Each remapped key gets a conclusive
hiding verdict from its ten-press step. Paddle outer right's echo (D-pad right) is also conclusive in the two steps
where the paddle is held first (D-pad up and D-pad left). In "hold D-pad left, press paddle outer right" the controller
cancels right against left, so D-pad right never reaches the receiver: that step's hiding verdict is "not exercised",
and it proves the recovery (background D-pad left), not the hiding. In "both outer paddles together" the verdict follows
the order: an echo the controller cancelled through the whole hold is "not exercised". The A-held step is "cannot
judge" for SAX left by design (its echo is the background item). In S4, before the "hold paddle outer right, press
D-pad left twice" step is judged, its receiver reports are read for the paddle-first order: hat neutral or left, the
rule stands; hat right (the paddle's direction, so the first press wins), stop for the owner, write it up as a new limit
under "What cannot be told apart" (a real direction opposite a held paddle is invisible when the paddle came first) and
pin it with a V test.

**12. "Remap check: triggers and three sources (App, then Driver)"** (`remap-triggers`, S4). Picks: G1 → LT, LT → RT
(RT still sends RT), X → A, G5 → A. `requires` on every step: `{g1: lt, lt: rt, x: a, g5: a, a: a, rt: rt}`, so a
leftover remap of A or RT cannot change what "A twice" and "RT twice" test. Steps: rest · G1 twice → LT, RT still ·
LT twice → RT, LT still · RT twice → RT · X twice → A · G5 twice → A · A twice → A · hold X until A shows, then add G5,
then let go of X → A held (`releases: ["x"]`) · pull LT and RT together, let go of LT → RT held (`releases: ["lt"]`).
Same notes.

Sitting order. S4: row 4 (App, then Driver, no Profile in between) · row 1 on App · Profile back to the noted colour ·
row 1 on Driver (the build-24 baseline for the new trigger judge) · Profile back · row 7 on App and Driver (the first
live check of the S3 model change) · row 11 · reset · row 12 · reset. S8: rows 11 and 12 on App and Driver (reset after
each) · row 4 · rows 5 and 6 · row 1 on App · Profile back · row 1 on Driver · Profile back; row 9 if the owner has
time. Row 7 is not in S8: its volume side runs on interface 4, which the driver does not touch, and row 5 checks the
same pad-side case through the new driver. The judge's unexpected-change rule sees every pad report, so a one-report
ghost fails a step.

## Implementation slices

One implementer at a time, each slice its own commit with `swift test` and the Python tests green. Models set
explicitly: Sonnet medium for Swift and scripts; Sonnet high for shared C and driver C++; Haiku low for mechanical
steps and test runs; Opus high only for a driver bug Sonnet cannot fix; no fan-out. The pre-install review is read-only
(Opus high). Order: implement → tests → install → live checks → commit → S ledger and HANDOFF. Commit bodies hold the
results, the test count, "Not yet verified:" and the Co-Authored-By line. HANDOFF's "State of the Mac" is updated when a
phase changes it: S1 (installed build, the S1-pre archive, the build guard), S5 (the app-only install recipe no longer
works), S7 (driver 25, the rollback path, the archive), and the test counts at every slice.

- **S0** After the answers: commit plan v2 (push per Q6); set the R6 row of `docs/plans/remap-plan.md` to "▶ in
  progress: plan and ledger in `docs/plans/remap-step2-plan.md` (S0–S9)" with Exit "S9 of remap-step2-plan.md done";
  in `docs/HANDOFF.md`, "Start here" item 2 names this plan as the work in progress (remap-plan.md as its parent), the
  "Next: R6" bullet becomes "R6 in progress, phase S<n>; see remap-step2-plan.md", and the progress-line rule says that
  during R6 it counts this ledger.
- **S1** (a) Copy the layout and mapping into `~/GDHub-rollback/S1-pre/` (read-only on the data folder). From the copy,
  list every control outside the six with non-zero `physicalBits` and any of the six whose stored bits differ from the
  table; the list goes into "S1 notes" and decides whether Q9 applies. (b) Pin today's bytes first, own commit:
  fixtures of today's encoder output for the factory mapping, learned sets A and B and 200 seeded v1-expressible
  remapped mappings (`Tests/GDHubTests/Fixtures/gdhm-v1-pins.json`), the step-1 `remapLimit` messages, and a default
  mapping with `physicalBits` on `lt` (1) and `rt` (0x20) encoding byte-identical to the default blob; existing
  `randomOutputs` seeds keep a frozen 23-id draw; random mappings sometimes put `physicalBits` on `lt` and `rt`.
  (c) Build guard in `scripts/build-xcode.sh`, with a Python test on a temporary folder:
  - Seed `Xcode/dext-source.hash` = `24 <sha256>` once, only after `git diff --quiet 1fabee0 -- Dext Shared project.yml`
    succeeds (1fabee0 is the T7 commit build 24 was built from) and `git status --porcelain -- Dext Shared` is empty;
    otherwise stop and ask. The hash covers the tracked files under `Dext/` and `Shared/` and the `GDHubVirtualHID`
    target block of `project.yml`, sorted paths and contents; untracked files there make it refuse. The file is ignored
    by git, next to `Xcode/build-number`. Every bump rewrites it.
  - `--same-build` refuses when the hash file is missing (the message names the seeding step), when its number differs
    from the reused number, when the hash differs, or when the build would differ from the `activated enabled` build in
    `systemextensionsctl list` (the enabled entry, not the highest listed). Otherwise it passes.
  - New `--check`: allowed by the guard and by the engine-agent check, installs nothing, never writes
    `Xcode/build-number`; xcodegen and xcodebuild of the Release configuration into a scratch `.xcodebuild-check`,
    with the current number; the existing signature, entitlement, plist and `-ffp-contract` checks; the built app is
    deleted afterwards.
  - The build number is written only after xcodebuild and the checks succeed, so a failed build leaves it as it was.
  - The build writes the hash into the app's Info.plist as `GDHubDextSourceHash` (as built in S1: a key in the dext's own
    plist would have changed `Dext/` and the seeded hash).
  (d) Mockup v7 (with its Developer-mode part) from the S1-pre layout copy, sent in chat, copy in `docs/mockups`. Stop
  for the owner's OK; (a)–(c) do not wait for it. (e) Recorder, `record` kind, row 10, `echo-survey.py`; the "recorded"
  display only after the v7 OK. Install: archive the installed step-1 app to `~/GDHub-rollback/S1-pre/GDHub.app` (none
  exists yet); compare the live files with the S1-pre copy (copy again if they changed); `--same-build`; compare after
  the relaunch.
- **S2** The owner runs row 10 (and the Profile blocks if Q4 is yes); I write "S2 result" with `echo-survey.py`.
- **S2b** Plan v3 (this file). An independent read-only review against the code and the recording: the rule against
  the oracle and the survey replay, the rule on sequences, the C sketch, the blob and validator, the reset sites, parity
  and the word check, the App path, the tests, the templates and the slices. Done 2026-11-11: 33 findings, all
  confirmed, folded in; choices under "Design choices".
- **S3** First, before any code: the owner answers Q10 and Q11, quoted in a new "S2b answers" section at the end;
  commit plan v3 (push per Q6); HANDOFF's phase line says S2b done and S3 current.
  (a) The echo rule on the Swift side, own commit, no UI:
  - `scripts/tools/echo_rule.py` (standard library): the rule exactly as written above, the truth model under "The
    rule", a replay over a run report or the fixture, the ghost check and the exhaustive search (V25). It is the
    reference for Swift and C.
  - `scripts/tools/echo-fixture.py RUN.json`: writes `Tests/GDHubTests/Fixtures/echo-survey-s2.json` (see "Tests") from
    the S1-pre copy of the S2 run report. Run once; the output is committed.
  - `scripts/tools/echo-survey.py`, fixed: `load_run` keeps every attempt with its `superseded` flag and index (in
    place of the rule at `echo-survey.py:96-97`); an item change belongs to a key only in that key's own edge report,
    and only when no other of the six changed in that report; a direction a cancel took away counts as the opposite
    (the oracle's `changed`, read backwards for a release); a change in another report near an edge is listed as "other
    change, N reports from <key>", never as its echo, and a change in a report where two of the six changed is
    "shared". So together-sax's A at +5 becomes SAX left's own echo at 0, and together-outer's "lead 1" becomes outer
    left's. A neighbour bit in an "alone" step is "touched <key> N times (attempt i)" and its presses leave that step's
    table. The gate becomes "Gate from v3 on" (row 10): kept lines are the table bit, one echo item per key and state,
    no echo on a stick, no lost reports; changed are the timing line (same report, or "already on" for 8 reports) and
    the hat line (the replay). Dropped: the lag limits (`echo-survey.py:49-50`, `W_MAX`/`G_MAX`), the `realDirection`
    call (`:215`), `REAL` and `real_direction` (`:264-291`), the worst-lag accumulators that feed W and G (`:324-325`,
    `:332-333`) and `w`, `g` (`:338-339`), and the old gate lines in `check_gate` (`:360-377`). Kept as reported output,
    not judged: `reemergence()` and `profile_edges()` (`:219-261`) and their calls (`:213-214`). The "Chosen: W = …"
    line (`:451`) becomes "Replay of the v3 rule: N reports × 64 masks: wrong 0, ghosts 0, ambiguous 0, unconfirmed
    clean 0 (shared S, with-item I)", over all attempts.
  - `Sources/GDHub/Mapping/EchoFilter.swift` (pure, no AppKit, listed in `EngineIsolationTests`): `EchoParams` (a
    plain value: hide mask H and stored items S[0..5], with a `factory` item table for tests), `EchoState`, `step`,
    `apply`. It does not depend on `ControlMapping`; tests build `EchoParams` directly. Tests: V1–V27 in Swift (their
    Swift halves: V14 with a fresh state, V18 with H = 0, V23 against the written table and the Python oracle), the
    fixture replay in Swift and Python, the Python tests of the three scripts (with the changes to
    `test_echo_survey.py` under "Tests").
  (b) The model changes above (`identityBits`, `echoHideMask`, `echoItem` and `echoParams`, which returns the
  `EchoParams` of (a), with their `ControlMappingTests`); the menu-model part of UI items 1 and 2 (in `RemapMenuModel`,
  the `.deferred` kind and `deferredNote` go, `builtInTitles` gains "Controller's profile (built in)" for the six, the
  notes plumbing and the Controller's-profile note, whose words v7 approved, join `notes`; the remapped-key note stays
  empty or a marked placeholder until (c)) with the rewrites of `RemapMenuTests:111-121` and `RemapMenuItemsTests:71-74`
  for kind, groups, reset, re-learn and that note only; the `remapLimit` level-1 message with the words table;
  `signalConflict`; the learn refusal, the single-direction D-pad learn and `learnConflict`; the requires vocabulary and
  its validation message; the sink stepping in `submit` on the Swift path; the backup rule; DriverManager's
  `replacing dext` and `request finished` lines (`DriverManager.swift:504, 514`) raised from `.info` to `.notice`, so
  the S4 build (the future S7-pre) logs them at a kept level. No install happens before S4, so the empty note is never
  seen. Before each S3 commit, `grep -rn "deferred\|remappableIDs" Sources Tests` finds no stale use. (c) Mockup v7b
  first (sent in chat, copy in `docs/mockups`; (a) and (b) do not wait for it, except the remapped-key note, which
  lands here); after the owner's OK: the remapped-key note's string and its exact-text assertion, native menu look,
  labels, lighting through the cleaned frame, the Profile note, the hidden Reset items, the conflict hint line, per v7
  and v7b.
- **S4** (a) Judge changes, `builtInEcho` for untouched keys everywhere, `background`, "cannot judge" with its three
  wordings and "not exercised" by the raw reports, the Developer-mode run-long filter, `DevExpectation` for the six, the
  `built_in` wording, the template checks, `dev-run-compare.py`, the echo counters before and after each step in the run
  report; the `record` display per v7 (Expected "—", Seen "receiver frames kept: N", the word "recorded" in grey),
  replacing `fb83ebd`'s interim "recording only" (`DevSession.swift:604`) and the "○" chip
  (`DeveloperRun.swift:50`, `ControllerView.swift:707`), or keeping the chip if v7b says so.
  (b) After the v7b OK: rows 11 and 12 from `DevBuiltins`, row 11 as in v7b; row 4's notes reworded. (c) App-only
  install (copy, `--same-build`, compare).
  I open every paddle and SAX menu through the accessibility ids on Back and Sides, again after cycling Developer →
  Mapping → Edit layout → Mapping on every tab (the anchor-loss regression). Edit layout is left only with Cancel,
  never with "Done (lock layout)" and never by quitting or relaunching; no label is clicked, dragged or selected while
  editing; the app is not quit until the checks pass. Right after the cycle: no `envision-pro-layout.before-edit.json`;
  layout and mapping byte-equal to the S4 copies; no `layout-backups` file newer than the install. If a check fails,
  stop, leave the app running and ask the owner; never restore over the data folder without the owner's word.
  (d) The owner's sitting, in the order under "Templates and checks". Rows 11 and 12: the App pass must pass, with a
  conclusive hiding verdict for each remapped key (all "cannot judge": press Profile and run again, or ask), and row
  11's receiver reports of "hold paddle outer right, press D-pad left twice" are read for the paddle-first cancel as
  row 11 says, before the step is judged; at the Driver pass the prompt "Driver pass cannot be confirmed: …" is
  expected — press Stop, not Run anyway (that prompt is the check that the new app stands down on build 24). Afterwards I compare the mapping and layout with the copies,
  check for no before-edit file, and check the engine log for no `driverRefused`, no `fallback:`, no `limiter: tripped`
  and no `breaker: tripped`, and that `tapBreakerTrippedAt` is absent.
- **S5** (a) Version-gated validator and the echo entry. (b) `gdx_eval` item 20/21 and trigger max, `gdx_echo_next`,
  `gdx_echo_apply`, the echo step inside `gdx_step` and `lastEchoWord`; `gdx_reset` unchanged. (c) Encoder versions
  with `maxVersion: Int = 1` and the echo entry from `echoParams`, `remapLimit(_:level:)`, the sink's C core at version
  2 through `XlateCore.eval(frame, word:)` (the Swift filter in `submit` still does the stepping),
  `EnvisionProDevice.gdhmLevel` and the menu model's level (wired to real values in S6). (d) The `GDHubDefaults.h`
  generator **appends** a v2 blob (row 11's and row 12's picks plus paddle inner right → Y, so its hide mask is 0x3F
  and every key is hidden; Y is outside every echo seen and not used by row 12; this golden blob is not row 11's
  mapping) and a sequence of at least 128 frames (expected bytes from the Swift oracle: V1, V3, V4, V5, V6, V8, V11,
  V13, V14 with its marked `gdx_reset`, V16, in that order), and the plain-C sequence runner
  `Dext/GDHubVirtualHID/Core/GDHubSeqCore.c` that starts from a zeroed state (see S6's self-test), with
  `dependencies: ["GDHubXlate"]` on `GDHubDextCore` in Package.swift. `GDHubXlateEchoTests`: V1–V27 in C on the same
  scripted sequences as `EchoFilterTests`, including V14 with `gdx_reset`, V18 with a v2 nEcho-0 map byte-identical to
  the v1 map, and V23 Swift = C = the Python oracle. The fixture replay runs against C too, and `VirtualPadSinkTests`'
  C-path half. Exit includes `swift build` of `GDHubDextCore`, `DextSourceRulesTests` and `build-xcode.sh --check`.
  From here the seeded hash makes the guard refuse `--same-build`: the next install is S7.
- **S6** (a) Cap bit and status2 offsets in `GDHubProtocol.h`, the `DextProtocol.swift` mirror, the status2 writer.
  (b) Driver C++: hello caps, `loadMap` count checks, the `:564` echo keep, `echoRun`, the parity word and the four echo
  counters, self-test; no change in Start, Stop, free/init, SetPowerState, `syncMode` or any other `gdx_reset` call.
  (c) `DextClient`, `TapSupervisor` (`mappingOffer` with `maxVersion`), `EngineService`, `TapStatusReport`,
  `ParitySampler` (word applied, skip rule, `FrameRing` filter with its `echoRun`, the masked and aligned compare,
  `echoWordDiffs`, `echoUnarmed`, `echoUnaligned` and `parityEchoOk`, the "now adds" and "not seen" log lines), the GUI
  level wiring from `gdhmMax` and the hello caps.
  (d) Text fixes in the takeover plan §7.1, §7.2 and common rules:
  - U5 reads a `scripts/dext-log.sh` capture started before U4; the "build 25 is proven by" check above stands in when
    the root line was missed or after a reboot; U5 uses the N that U3 printed.
  - "If U3 fails" as above; the pre-U1 latch check; a step "copy layout and mapping, compare after the relaunch".
  - RB4a: about 10 s after RB4, check whether build 25's process exists (`pgrep -lf com.interlinked.gdhub.VirtualHID`,
    read-only, never kill) and whether "update 25 -> 24 deferred until the old driver process has been terminated"
    repeats in a `log stream --info --predicate 'subsystem == "com.interlinked.gdhub" AND category == "vhid"'` started
    before RB4. Judge by the process, not only by the GUI's connection.
  - RB4b: no build-25 process and the deferred line repeats: quit GDHub (`osascript -e 'quit app "GDHub"'`), then
    `open /Applications/GDHub.app` without `--dev-terminate-driver`; the replacement goes through at once. Then RB5.
  - RB4c: the process exists and the GUI shows exclusive: repeat RB1, then RB4. Rejected or protocol mismatch: RB4b;
    the old process then survives (`terminating_for_upgrade`) and the existing reboot rule completes the 24 replacement
    at boot; after the reboot run RB5 again, never RB4 with the flag again. Reboot only if RB4b or RB4c does not reach
    RB5 within 2 min. RB4a–c also go into the L9 rollback drill text.
  - RB5 reads the capture (started again after RB2 if it was stopped) for `replacing dext N -> N-1`, but
    `systemextensionsctl list` decides: N-1 `activated enabled` and N gone or terminating. The `log show` line is
    replaced the same way in takeover :773, and the common rule at :1027 reboots only on the `systemextensionsctl`
    condition.
  - Before RB3: copy the mapping and layout; compare them after the relaunch.
  - After RB5: check the rolled-back 24 like a new build: "selftest pass … build=24" on the first SHADOW or LIVE
    request (from the capture), and RB6's L1. On a self-test failure `inputPath` = engine stays until a fix.
  - RB8, after RB7: read `tapBreakerTrippedAt` and `tapBreakerReason` and record the time and reason as the rollback
    cause. If set, the owner picks Driver in the Driver menu (never `defaults delete`: the pick also bumps
    `inputPathChoice`); then the key is gone, the log shows `cleared by the owner`, and the status shows the Driver path
    armed. If it latches again on build 24, stop and investigate; do not loop.
  - The stale `DriverManager.swift` and `GDHubVirtualHID.cpp` line citations.
  (e) `build-xcode.sh --check` passes, then the independent pre-install review of everything the driver runs on a frame
  or a mapping ("no crash from any validated v2 map or any 16-byte frame"), the echo step in `gdx_step` and its state
  across every reset site (the `:564` keep included), capability gating, parity and `echoRun`, the encoder's version
  choice and the Start/Stop/SetPowerState/`syncMode` diff. Findings fixed, then `--check` again.
- **S7** As under "The replacement (S7)".
- **S8** The owner's sitting in the order under "Templates and checks". Exit in full: every step passes on both paths
  (untouched paddles and SAX keys by `builtInEcho`, the same echo names on both paths); each remapped key of row 11 had
  at least one conclusive hiding verdict on App and on Driver, and its two D-pad-left steps passed on both; in row 11's
  Driver pass the run report shows `echoValid` = 1 at every before and after sample, `echoHiddenFrames` higher after
  than before for each step that holds a remapped key, `echoRecoveredFrames` higher after than before on the two
  D-pad-left steps, and, over the whole pass (the counts are in hundreds), `parityEchoOk` and the parity ok count risen
  with 0 mismatches, not every sample skipped, and `echoWordDiffs` = 0 over aligned armed words; no `fallback:`,
  `limiter: tripped` or `breaker: tripped` line, and `tapBreakerTrippedAt` absent at the end; mapping and layout equal
  to their copies after "Reset all remaps". A Driver-pass failure follows "If the S7 exit fails".
- **S9** Results into this plan, the compatibility table into takeover §5.7, HANDOFF, remap-plan R6 ticked.

## Tests

Kept green, unchanged (the v1 promise): `GDHubXlateGoldenTests` (existing `GDX_DEFAULT`, learned A and B arrays and
the 3×64 vectors byte-identical) · `MappingPinTests:31-37` (default and empty JSON, both `mappingHash` literals) ·
`MapBlobEncoderTests` (factory blob of 15 rules, no `physMask`; step-1 refusal messages at level 1; `remapLimit` nil
for empty `outputs`; `:263-283` at level 1 with the default `maxVersion` 1) · every v1 case in `GDHubXlateBlobTests`
(nEcho 1, nTriggers 3, outSlot 1, three sources, LT twice, trigger reserved byte, trigger padding `:164-171`, fuzz on v1
seeds) · `GDHubXlateSequenceTests:186-199` (a sign case both versions refuse) · `PassthroughPadMapperTests:94-116` and
`RemapLightingTests:139-145` for keys on Controller's profile · `DevExpectationTests` rows outside the six ·
`DextSourceRulesTests`, `DextXlateTests:497-559` (no lock, allocation, log or libm in `shadowFrame`; `-ffp-contract=off`;
the `gdx_reset` string check at `:508`) · `RealSupportFolderTests` · the S1 pins.

Must change: `GDHubXlateBlobTests:67` (version byte 2 is now valid: use 3) · `ControlMappingTests:159-166` (keep
`left_stick`, `nope` and `guide` ignored; paddle and SAX picks are stored; Nothing on a paddle is stored, `.builtIn`
clears the entry) and `:172-187` (29 ids; the paddle examples of non-remappable controls) ·
`PassthroughPadMapperTests:239-245` (the stray entry becomes `left_stick` or `guide`) · `RemapMenuTests:94-95` (Profile
note), `:111-121` (deferred kind and texts), `:167-178` (level 1: existing ids keep {LT, RT}, the six mark every entry
but Controller's profile; level 2: nothing marked) and `:235-249` run at both levels with the same level passed to menu
and `remapLimit` · `RemapMenuItemsTests:71-74` · `DevExpectationTests:12-27` (the six resolve to `builtInEcho`) ·
`DevRunCoreTests:671-696` (skips become judged steps) · `DevTemplateTests:112` (validation message) and `:625-641`
(hashes of rows 10–12 and row 4's reworded notes; appended order; `remap-` prefix for templates with `requires`) ·
`InputPathMenuTests:101`, `LiveLifecycleTests:96` (wording only at level 1) · `scripts/tools/test_echo_survey.py`
(S3(a)): `:115-118` and `:331-346` drop the (W, G) asserts and keep the rest; `:135-163` become one test (a lag of 1
in its own report fails, "already on for 8 reports" passes, the replay reports the unconfirmed press); `:176-190` the
re-emergence is reported, not judged, and G goes; `:199-219` `realDirection` goes, the hat case is judged by the
replay (0 wrong, 0 ghosts); `:221-237` the Profile-edge lag is reported only and the W assert goes; `:311-317` the JSON
keys lose "W" and "G" and gain the replay line; `:319-327` flips: a superseded attempt with a 5-report lag now fails the
gate and names the attempt, and a twin where a superseded attempt touched a neighbour passes with "touched" reported.

New:
- `EchoFilterTests` (S3) and `GDHubXlateEchoTests` (S5) (Swift and C, the same scripted sequences built with the
  controller model of "Facts"; cleaned frames, words and pad bytes compared; factory stored items and factory echoes
  unless a case says otherwise; every sequence starts with a report at rest). V2, the second half of V4, V5's
  paddle-first order, V6 and V7 rest on the controller model, not on the recording (S2 has no real change during a
  hold): V1 each of the six alone, same-report press and release → only the pick, on press, hold and release; OTHER
  and UNCONFIRMED never set · V2 SAX left hidden, real A pressed and let go inside the hold → never shown; pressed
  inside and still held at the release → shown from the release report · V3 A held, SAX left tapped → A without a
  break; A let go during the hold → A stays until the release (pins the limit) · V4 D-pad up held, paddle inner right
  hidden → up on every report (the S2 gate case); paddle held first, D-pad up pressed twice → up twice; RECOVERED set ·
  V5 the opposite cancel for all four paddles in both orders · V6 neighbours: real up + paddle outer right → up; outer
  right and inner right hidden, real up then real left → up, then left; a real up+left with outer right → up+left · V7
  the same direction pressed during the hold → hidden until the release; held from before → kept; let go in the very
  report of the press → kept until the release; rocked to the opposite during the hold → none, then the old direction
  until the release (pins the limit) · V8 both outer paddles hidden: left-right frozen at its value before (none, and
  left held from before), up-down passes; the pair pressed in one report → the same (pins Q10) · V9 outer right hidden,
  outer left untouched, pressed one after the other and held → left; real right held from before → none (the
  controller's own cancel); the two pressed in one report → outer left's left shows only at outer right's release
  (pins the limit) · V10 outer right hidden, inner right untouched → down passes, and the reverse → right passes · V11
  another item at the press (stored D-pad right; the controller adds Y, A, X, B, LB, RB, up, down or left, as after a
  Profile press) → that item and the stored D-pad right hidden for the hold (a real D-pad right pressed during it shows
  at the release), no direction worked out, OTHER set; the next hold with the stored item → no OTHER · V12 the item
  already on at the press (real up held, then inner left; real A held, then SAX left) → the stored item, confirmed;
  plus one other change in the press report: real right held, outer right + Y → Y passes at once; real A held, SAX
  left + X → X passes; A and up held, SAX left as up is let go → up gone at once, no D-pad up, no RECOVERED; real right
  held, outer right + up → up passes, then up let go → right only, no D-pad down; up held, inner left + right → right
  passes, no D-pad left after it; down held, inner right + left → left passes; A held, SAX left + up → up passes, no
  D-pad down after it; up+right held, outer right as up is let go → right; in each the key's own item stays until the
  release (the limit) and no other item appears · V12b after a profile change, the key's new or old button already on
  at the press (pins Q11 (b)): stored D-pad right, now A, real A held first → UNCONFIRMED, a real right during the hold
  never shown, A stays until the release, no ghost after it; stored A, now X, real A and real X held first → A and X
  stay until the release; stored D-pad right, now up, real right held first → up shows for the hold, right while it
  is held, no other direction; stored A, now X, real A held first → X shows for the hold, A stays · V13 unconfirmed:
  two of the six pressed in one report with stored items the report contradicts (pins Q11 (a)), and another item
  changing in the very report of a press after a profile change (stored A, now X, SAX left + Y → X shows for the hold,
  pins Q11 (c)) → the stored item covered, no direction worked out, UNCONFIRMED set, no ghost on any later report of
  the hold · V14 a reset
  (C `gdx_reset`, Swift a fresh state) at every report of a hold → the stored item covered from the first report after;
  a covered real item held from before drops until the release; a real opposite direction held shows at the release;
  ARMED clear until a report with no hidden key held; with the actual echo other than the stored one (outer right now
  adds Y; outer right now adds D-pad left, with a real right during the hold, which shows nothing) → the new button
  shows until the release and UNCONFIRMED is set (pins Q11 (d)); the same holds with the state kept (the `:564` site,
  no reset) → the new button stays hidden for the whole hold · V15 a real opposite direction pressed in the very same
  report as the paddle → shown at the release (pins the limit); another button in that report → passes at once; the
  opposite let go in the press report and pressed again during the hold (D-pad left held; outer right pressed as left
  is let go; left again; the same for inner right with up) → the press seen, left (up) shown at once with RECOVERED,
  UNCONFIRMED never set ·
  V16 Start, a G key, Profile, LT, RT, buttons 18–19 and the sticks in the press report and during the hold → untouched,
  byte for byte · V17 Profile pressed and let go during a hold → nothing else changes · V18 Swift: H = 0 → cleaned
  frames equal raw frames; C: a v2 map with nEcho 0 and the same rules as a v1 map → `gdx_echo_next` returns 0 and
  `gdx_step` output is byte-identical to the v1 map · V19 only untouched keys held (row 11's set with inner right
  pressed alone) → output byte-identical to the input · V20 a repeated report gives the same state and the same word
  except bits 25–26 (set on the first copy only), at every report of the survey fixture with all six hidden, with
  stored items factory and turned by one key (every press "other"), on the cleared-bindings and two-keys-in-one-report
  sequences of V13 and V26, and on the random walk; after any report with no remapped key held the state equals a fresh
  state given that report, all 16 bytes; two different histories ending on the same unheld report give equal states ·
  V21 three inputs on one axis (real up, untouched inner right, hidden inner left, in each order; and a button pressed
  in the very report of the hidden paddle's press there → hidden for that hold) and an untouched key adding the same
  item as a held hidden key → pins both rare limits · V22 timing slips (synthetic, never measured): a release lead of
  one report → one report of the opposite direction; a release lag → one report of the echo; a press lag →
  UNCONFIRMED, no ghost; a press lead → the echo shows for the hold (pins the limit text) · V23 the exhaustive per-axis
  table: for each axis, hidden {+, −, both} × untouched {none, the other one} × real before the press {+, 0, −} × real
  in the press report {unchanged, let go, pressed} × real during the hold {+, 0, −}, plus the key's item already on
  with one other change in the press report, the expected direction written out in the test; Swift equals C equals the
  Python oracle · V24 replay of `02-button-walk.txt` with all six hidden → no echo leaks; frames without a paddle or SAX
  bit unchanged · V25 (Python, `echo_rule.py`) the exhaustive search: every sequence from rest of 4 reports with up to
  two input changes per report (the four real D-pad directions, never two opposite, A, X and the keys outer right,
  outer left, inner right, inner left, SAX left; factory echoes) under hide sets 0x01, 0x09 and 0x3F (0x3F at 3
  reports): 0 ghosts; S2b measured 0 at 5 reports for 0x01, 0x03, 0x13, 0x30 and 0x3F and at 4 reports with up to
  three changes for 0x01 and 0x09, while the rule as first written showed ghosts at 4 reports · V26 bindings cleared (the
  controller adds nothing; pins the limits of "What the owner gets"): D-pad left held, outer right pressed in the very
  report left is let go → left stays shown until the release; outer right + Y in one report → Y hidden for the hold, no
  ghost; outer right + up in one report, then up let go → nothing shown; D-pad right pressed in the very report of
  outer right's press, then let go → D-pad left shows until the release · V27 a key in the hide mask stored with a
  binding that names no single item (outer right learned as `.hat(1)`, a diagonal) → its stored item is the factory
  D-pad right; after a reset and after a two-key press D-pad right stays hidden for the whole hold.
- `EchoReplayTests` (Swift, C from S5) and its Python twin, on a committed fixture made from the survey recording,
  `Tests/GDHubTests/Fixtures/echo-survey-s2.json`. How it is made, with no private data: `scripts/tools/echo-fixture.py`
  reads the S1-pre copy of the S2 run report and keeps, per step and attempt, only `stepId`, `controls`, `superseded`
  and the receiver list as `{n, hex}`. It drops `t`, the header (mapping, builds, decode table), notes, path events,
  timestamps, metrics, verdicts and the pad side. It refuses any entry that is not a 16-byte report 0x06, and it writes
  the oracle's expected words for nine hide sets (none, all six, row 11's set, each key alone). The result holds
  controller reports and words only (789 reports, about 130 KB); it is checked by eye for anything else before the
  commit. A report the recorder left out equals the one before it, and a repeated report changes no state and no cleaned
  byte (V20), so the replay needs no filling; each attempt starts from a fresh state. Checks: under all 64 hide masks
  Swift equals C on every report (masked words, bits 25–26 out, and states); the nine stored sets match the fixture;
  H = 0 leaves every report unchanged; the Python test replays the oracle against the truth model: 0 wrong and 0 ghosts
  under all 64 masks, 0 ambiguous items (measured in S2b on the scratch copy with the reviewed rule: 0, 0 and 0, no
  OTHER and no UNCONFIRMED press; the opposite cancels at n=203344, 234540, 260104 and 260415 come out as D-pad up and
  left, and under masks that hide one paddle of a pair the cancels at 283080, 283789, 339575, 340181, 345833 and 346261
  show the untouched paddle's direction; A and up held through SAX left and inner left taps stay held). "0 wrong"
  covers only holds in which the real controls did not visibly change: S2 has no such change during a hold.
- `GDHubXlateSequenceTests.testRandomWalkWithPaddleEchoes`: 100k frames of the controller model (buttons ORed, the hat
  per axis with opposites cancelling, the real D-pad never on two opposite directions, real diagonals allowed), random
  holds of the six, random real presses; when anything changes, two inputs change in the same report about a third of
  the time, so key edges often come with another change; echo sets that change between holds, on a report with nothing
  held, as after a Profile press (the factory set; A X Y B with RB; the directions turned round with LB and X;
  nothing), stored items = factory, random resets and map pushes; Swift pipeline against C `gdx_step`, byte for byte.
  No ghost (the truth model's definition, with the walk's known real input): strict while the factory set is in use;
  under a changed set a held key's actual echo is exempt (the Q11 cases); under the cleared set a direction on a held
  paddle's axis is exempt (the limit of "What the owner gets"). Real items hidden that are not a held key's stored
  item are counted and printed, not judged (the rare limits). (S2b, the reviewed rule's Python transcription: 0 ghosts
  in about 7.4 million factory-set reports over five hide sets, with and without random resets; the rule as first
  written showed ghosts in the same walk.)
- `VirtualPadSinkTests`, driven through `submit()` (Swift path in S3(b), C path in S5(c)): a still controller (runs of
  identical reports) and a burst that forces coalescing, through row 11's "hold paddle outer right, D-pad left twice"
  and "hold D-pad left, paddle outer right twice" after a still period, and a coalesced paddle tap → the posted pad
  states equal what the Swift pipeline (`EchoFilter.step`/`apply`, then `PassthroughPadMapper.padState`) gives for the
  same report stream, and from S5 what C `gdx_step` gives, byte for byte; real A and a remapped SAX left held across
  `setDriverDrives(true → false)` → the first posted frame shows A plus the pick, on the Swift path and (S5) on the C
  path across the `xlateCache` reset; a paddle let go during LIVE, then a fallback → nothing stays covered; a duplicate
  frame is dropped and its word equals the last one apart from bits 25–26.
- `GDHubXlateBlobTests` v2: versions 1 and 2 accepted, 0 and 3 refused; rules on items 20 and 21 together with item 14
  accepted in v2, refused in v1; 32 rules all on item 20 and 32 all on item 21 accepted; items 15–19 and 22–255 refused
  with `GDX_E_ITEM` before any counter is touched; two trigger entries with distinct fields accepted, same field, 0xFF
  in a pair or three entries refused; a hideMask of 0 or 0x40, an item code of 15, code 0 for a key inside the mask
  (mask 0x01 with item[0] = 0), and a non-zero code for a key outside the mask → `GDX_E_ECHO`, the factory codes
  `0c 0d 0b 0e 01 02` with mask 0x3F accepted; v2
  with nTriggers 3 and a non-zero byte in the 4 padding bytes after the trigger entries → `GDX_E_FLAGS`; nEcho 1 with
  the echo section missing, or followed by 8 extra bytes with `length` patched → `GDX_E_LENGTH`; fuzz with a separate
  v2 corpus. These and the fuzz run once under AddressSanitizer and UBSan in S5.
- `DextXlateTests`: `gdx_reset` zeroes the echo state and `lastEchoWord` with its body unchanged; `gdx_step` on a v1
  map never touches the echo state; `gdx_echo_apply` changes only buttons 1–10 and the hat nibble; a string check that
  `shadowFrame`'s LIVE-gate reset keeps `xstate.echo` around `gdx_reset` and that `syncMode` contains no echo code; a C
  test that the echo state (with ARMED) is unchanged across that keep, so the engine's ring and the driver stay
  aligned.
- `GDHubXlateRemapGoldenTests` v2 cases (paddle → Y, paddle → RT, three sources on Y, A → LT, LT and RT → RT, LT ↔ RT);
  `remapLimit(_, level: 2)` nil on random mappings drawn from a new 29-id seed, with paddle and SAX masks from the table.
- `MapBlobEncoderTests`: every S1 pin still version 1 and byte-identical with `maxVersion: 2`; v2 rule, trigger and
  echo order; analog field dedupe; the full level-1 string "Paddle outer right sends Y: this driver version cannot hide
  the controller's own press"; a twin of `:263-283` at level 2 (`remapLimit` nil, and `encode(…, maxVersion: 2)` gives a
  blob for each of the three level-1 kinds); a stray-bit overlap encodes with `remapLimit` nil; the words table equals
  the layout labels; a default mapping with stray bits on `lt`/`rt`, and the same swapped, stays version 1 and
  byte-identical (`triggerFeed` stays `.analog`).
- `GDHubXlateGoldenTests`: the appended v2 blob (hide mask 0x3F) and sequence regenerate and pass the C runner the
  self-test uses (`GDHubSeqCore.c`, called with the same arrays through the `GDHubXlate` module).
- `GDHubXlateBenchTests`: the worst v2 map (29 rules, echo) in C at or below the Swift mapper.
- `DextProtocolTests` (bit 12; offsets 676–720) · `TapStatusReport` (missing `gdhmMax` → 1; missing echo keys → 0; the
  line never says "driver update" for a signal conflict) · `TapSupervisor` (caps 0xF01 plus a paddle remap →
  stand-down, no driver call, limiter untouched; bit 12 → v2 pushed; a v1 mapping pushed as v1 on both; the
  `maxVersion` passed to `mappingOffer` at `:445` and `:761` follows the caps; offer re-evaluated on a caps change) ·
  `ParitySampler` (word applied; blob with echo and record without the echo flag → skipped; `echoWordDiffs` stays 0 on
  equal words and counts a difference; words that differ only in bits 25–26 are equal; a word without ARMED on either
  side is not compared and counts in `echoUnarmed`; armed words with different `echoRun` counts are not compared and
  count in `echoUnaligned`; a ring that skips a press report, or the last unheld report, gives an unaligned record and no
  word difference; a ring that misses the press report and records its repeat gives no difference; equal counts with
  different words still count in `echoWordDiffs`; `parityEchoOk` counts matches whose record word has bit 31; the
  ring's filter and count reset on enable, reset, revision and tap instance) · `LiveWatch` (`configure` resets the echo
  state with the rest) · `DextTapTests` (`loadMap` counts; the parity word, its flag and `echoRun` in `rec.pad[5]`; the
  four counters; `echoRun` in C and the ring's count in Swift agree on the V cases).
- `ControlMappingTests` (`.builtIn` default for the six; Nothing storable; paddle keys decode; `identityBits` with the
  table written out in the test, 0 for other ids; `echoItem` for every binding kind (a diagonal, a trigger, button 11
  and a missing binding give the key's factory item, never none) and `echoParams` of the default mapping = mask 0 with
  the factory items; the learn of a paddle while D-pad up is held stores `.hat(2)`; a stored paddle bit that differs from the table does not move the
  remap to another paddle; `triggerFeed` by bits only for the six; `signalConflict` with a stray face-control bit; the
  learn refusal; `learnConflict` returns "x", not "sax_left", for G1 learned as button 3 while SAX left is stored as
  button 3 with no bits) · `PassthroughPadMapperTests` (paddle inner left → Y: extra = 4 with no echo sends Y only, an
  echo-only frame sends nothing from the paddle; Nothing silences) · `RemapLightingTests` (hidden echo not lit; target
  lit as linked) · `RemapModeTests` (with a paddle remap and no mapping edit, level 1 → 2 clears `device.remapLimit`,
  2 → 1 brings the hidden-echo message back, nil → 2 clears it, the device publishes the change; level nil → no hint
  and no menu tag; a report from another pid → nil; in-app mode before the first hello → nil; the menu's per-item
  limits follow the level) · `RemapMenuTests` (Reset items left out when nothing is remapped; the conflict note with no
  limit tag) · `DevExpectationTests` (a remapped key expects its pick whatever echo is stored; a paddle with no stored
  bits, stored as hat 2 and remapped to Y, expects {Y}; an untouched paddle resolves to `builtInEcho`) · `DevJudgeTests`
  (`background`: A rises, View twice, A falls → pass; A still held at the end → pass; A drops between the View presses
  → fail; A drops and comes back within one View press → fail; A rises after the first View → fail; `builtInEcho` passes
  on A for a stored echo D-pad right and fails on zero or two items; "cannot judge" with the "same item" wording when
  the filter's item equals the pick, a background item or the probe button, and with the "not seen at its press"
  wording when the press was unconfirmed (a press that changed nothing with a stored D-pad right gives that, never "not
  exercised"); "not exercised" when the covered item never reaches the raw reports during the hold: row 11's D-pad-left
  held frames (raw hat 6, then 8 with extra bit 0, as at survey n=257613..260515) give "not exercised" for D-pad right
  and pass on background D-pad left, while a hold where the covered item shows raw only after the other paddle of the
  pair is let go (survey n=339575..339761) is conclusive; row 11's two D-pad-left steps pass on the cleaned frames and
  fail on raw ones; trigger items; trigger by mapped output) ·
  `DevRunCoreTests` (the run-long filter: for paddle → Y with factory echo hat 2 the reference holds Y without D-pad
  right, `refChanges` counts no echo edges, a D-pad-right step does not open its window during a hidden hold; `record`
  steps: the window opens on a listed control, no early end while an echo bit is still set, early end after the rest
  time, `noMovement` fires; the `built_in` skip text for a paddle and a SAX key) · `DevRequirementCheckTests` (the
  unmet list and start block for the six) · `MappingStoreTests` (after a paddle entry is added beside g1, a backup holds
  `paddle_outer_right`; changing a paddle's pick also writes one; pruning keeps the newest "new" backup) · run-report
  decode of `receiver`; the run report's echo counters before and after each step; the `record` display per v7.
- Python: `echo_rule.py` (V23's table, V22's slips, V25's exhaustive search, the fixture replay: 0 wrong, 0 ghosts and
  0 ambiguous items under all 64 masks); `echo-fixture.py` (keeps only the listed keys, refuses a non-0x06 entry,
  writes the nine sets); `echo-survey.py` on synthetic runs (SAX left and right pressed 5 reports apart → both echoes
  at 0, none attributed across; outer pair one report apart → no lead; a neighbour touch in an alone step → reported,
  the gate passes; a one-report lag and a one-report lead → the gate fails; a release read backwards passes; together-
  outer with both paddles in one report → the gate passes and lists 'shared' unconfirmed presses under the 32 masks
  with exactly one of bits 0 and 3; an opposite D-pad direction pressed in the same report as a paddle → listed 'with
  <item>', the gate passes), on the fixture (the v3 gate passes; the replay line reads "Replay of the v3 rule: N
  reports × 64 masks: wrong 0, ghosts 0, ambiguous 0, unconfirmed clean 0" over all attempts) and on
  `02-button-walk.txt` converted (16 of 16 edges same-report, bits equal to the table); `dev-run-compare.py` new keys and the per-key echo compare; the build guard (missing hash refuses,
  a stale number refuses, a hash mismatch refuses, a match passes, a bump rewrites it, `--check` is allowed and leaves
  `Xcode/build-number` alone, `--same-build` refuses when the build differs from the `activated enabled` one, a failed
  build leaves the number unchanged).

## Safety rules and the data-folder rule

- Never kill the driver extension's process; no `sudo`; never `systemextensionsctl uninstall` or `reset`; no
  disassembly of Corsair's binaries; a hand-set key mapping is undone only with the scoped `hidutil` call in HANDOFF,
  never a bare `--set`.
- Tests and installs never touch the owner's GDHub data folder. Under XCTest every user-data path resolves to a
  throw-away folder (`RealSupportFolderTests` stays green). **Before every install and every app rollback (§7.2 RB3 or an
  S1-pre restore), copy the layout and mapping files; after the relaunch, compare them.** If
  `envision-pro-layout.before-edit.json` exists, do not relaunch. Never relaunch the app while the layout editor is in
  edit mode.
- After any step that enters Edit layout in the installed app: leave only with Cancel, click nothing on the drawing
  while editing, then check that no before-edit file exists, that layout and mapping equal their copies and that
  `layout-backups` has no file newer than the install.
- Release builds only. App-only installs use `--same-build`, which the guard allows only for an unchanged driver source
  at the activated build; the driver changes only through §7.1. Archive before the first install (S1) and before the
  replacement (S7).
- A failed survey gate, a failed S7 or S8 exit, a rollback and any second driver replacement always stop for the owner.
- The breaker latch is cleared only by the owner's Driver pick, never by `defaults delete`.
- No changes to the controller's stored profiles and no Bragi writes in step 2.
- The repository is public: no e-mail addresses, home paths, device identifiers or serial numbers in committed files
  (run reports and captures are checked before they are committed).

## Design choices (for the reviewers)

Plan v3, the new rule (three designs: a fixed table with no state; a learned table saved into the mapping; a small
state), one line per decision:
- Spine: the small-state design (a covered item keeps its value from before; an opposite direction only for a stored
  item seen or confirmed at the press): it kept every survey report right and never shows a ghost when the stored item
  is wrong.
- Not the fixed table with no state: it drops a button held from before at every tap (10 survey reports: A through
  SAX left, D-pad up through inner left) and turns a wrong table into a ghost for the whole hold.
- Not the learned table saved into the mapping: GDHub never rewrites the owner's mapping file by itself.
- Grafted from the learned-table design: the press is read as well as the stored binding, so a Profile press between
  holds is noticed at the next clean press; unlike v3 as first written, the stored item stays covered and only the
  stored item ever works out a direction (below).
- Grafted from the fixed-table design: the stored items travel in the blob, never in driver code; one word carries
  the cleaned buttons and hat, so parity, the App path and apply need no state.
- The press reading is per axis (a direction a cancel took away counts as the opposite, and a straight move from one
  direction to its opposite counts as the new one): it sees exactly the case that failed the v2 gate, and the
  opposite let go in the press report.
- A key whose item cannot be seen or confirmed still has its stored item covered, with no direction worked out: after
  a reset the stored item stays covered, and a wrong stored item can only hide, never invent.
- No window, grace or latch set: S2 measured no lag and no lead; same-report timing is now a gate fact of row 10.
- `gdx_reset` stays the only reset function, with its body unchanged, no new call site and no keep rules outside the
  frame path: the state matters only during a hold. This removes `gdx_reset_delivery`, the `loadMap` compare,
  LiveWatch's and the App's keep rules from the driver change.
- Untouched keys get code 0 in the blob: they never depend on stored data; the cost is the rare three-input case.
- A key in the hide mask always has a stored item (the factory one when its binding names none; the validator refuses
  code 0): with code 0 a press the rule cannot read would cover nothing, and the echo would show for the hold.
- Triggers are never touched: no trigger echo was ever seen, and v2's zeroing would cost real pulls.
- The duplicate drop stays on `(frame, revision)`: a repeated report gives the same state and applies the same bits
  0–13 and 31.
- The engine's word check compares only armed, aligned words with bits 25–26 masked: both states are equal after one
  report with no remapped key held when both sides stepped the same reports, so no quiet-run length is needed.
- No new app text for a changed echo: the rule adapts at the next press, and the engine log and run reports name it.
- The fixture is trimmed to receiver bytes and words: the public repository gets controller reports only.

Plan v3 review (S2b), where findings conflicted or left a choice, and why this way:
- A real change in the same report as a key whose own item was already on (three findings, three fixes): the press is
  read only when the stored item was not already on in the report before (two of the fixes), not "the stored item
  first whenever the report agrees with it" (the third): it is one check on the report before, and the agreement test
  stays where it was, in the stored path. The third fix's AMBIGUOUS bit, with the key left unconfirmed, is not taken:
  confirming the stored item lets a real opposite pressed later in the hold show, and after a profile change it keeps
  the old direction from sticking. The cost all three accepted is listed as Q11 (b): after a profile change, the key
  pressed while its old button is held lets the new button show for that hold.
- Added beyond the findings: an item a press shows that is not the stored one ("other") is covered together with the
  stored item and never used to work out a direction. With "other" items used to work out directions, as first written
  and with only the three fixes, an exhaustive search of short sequences with two changes per report found ghosts with
  the measured echoes (for example D-pad right held against an untouched paddle outer left, then D-pad up pressed in
  the very report of a remapped paddle outer right's press, then up let go: a D-pad down nobody pressed). With this
  rule it finds none. Cost: after a profile change a real press of the old button is hidden during that key's hold, and
  a real opposite of a new D-pad direction is not shown (Q11).
- Repeated reports (three findings): OTHER and UNCONFIRMED stay press-report flags, not flags held through the hold
  (they count presses in the counters and the log), and the guarantee is worded as "the same state, the same word
  except bits 25–26"; `cur` is cleared on the report a hold ends, so "a fresh state for a report with no key held"
  holds byte for byte.
- The engine's word check after a missed frame: the step count `echoRun` is kept by the tap and by the ring, outside
  the rule, not in the rule's state as the finding proposed (`pad[2]`): a count inside the state would change on every
  repeated report and break the guarantee above.
- A reset during a hold after a profile change: the echo state is kept only at the frame path's LIVE gate reset
  (`:564`), where `gdx_step` saw every frame. Not at LIVE turned on (`:434`), which the finding also proposed: that is
  in `syncMode`, whose body another finding keeps untouched, and it happens once per engine start. Map loads, pause
  end, power on, tap open and the SHADOW change keep the full reset and are listed under Q11 (d).
- The driver self-test's golden blob (two findings): row 11's and row 12's picks plus paddle inner right → Y (mask
  0x3F), not row 11's mask 0x3D with V1, V4, V5 and V6 rewritten: the S2 gate case on paddle inner right then runs
  inside the driver too, and the cases stay as written. The S7 v2 soak still uses the owner's real row 11 and 12 picks.
- The paddle-first cancel order: read from row 11's receiver reports in S4, not in an extra sitting before S3; a
  different answer only adds a limit and a V test, and S4 is app-only.
- The unconfirmed-press gate line: it fails only on a clean press; shared and with-item presses are reported with their
  cause, because they are accepted limits, not broken facts (the other proposal, dropping the line, would leave a
  clean press lag to the timing line alone).
- "Not exercised" (two findings) is decided by the raw reports of the hold, not by "no item stored": every key in the
  hide mask now has a stored item, so the old condition could never hold.
- The remapped-key note: its words wait for v7b and land in S3(c); the rest of S3(b) does not wait (the other proposal,
  S3(b) waiting for v7b as a whole, would hold back model work that shows nothing).
- Corrections to "S1 notes" and "S2 result" (v7 approved during S2, not S1; the survey has run; three steps reversed,
  not two) go into the ledger and "Facts", because those two sections stay as written at the time.

Kept from plan v2:
- Spine: the risk-first order (measure, then the App path in Swift, then C, then one replacement), with the owner-first
  menu and the smallest-change blob. Why: the C and driver code are written against an oracle the owner's hands checked.
- Untouched keys default to `.builtIn` (all three designs): the factory blob and today's behaviour stay as they are.
- One echo entry with one hide mask and one item per key, not up to eight entries: the C stays small.
- Start, the G keys and Profile have no item code (the validator enforces it): they cannot be hidden.
- Parity carries the echo word in the record's six spare bytes (not nothing, not the full state): F5 keeps checking the
  posted bytes and the seqlock record does not grow. A separate engine-side word check covers what parity cannot see,
  and S7's judged App-path check covers the shared C, which parity runs on both sides.
- The App path steps its filter at `submit` on every report, also while the posting gate is closed, so App and Driver
  words match report by report; only one filter instance steps there.
- The driver's level reaches the GUI as an integer `gdhmMax`, not a flag: step 3 can add a version without a new key.
- The app-first install keeps `Shared/` and `Dext/` untouched, guarded by a seeded source hash: two different driver
  binaries never carry the same build number, and the rollback archive is provably build 24.
- Two remap templates (paddles; triggers and three sources), not one or three: the families fail independently with
  few picks. Profile-dependent evidence becomes "cannot judge", never a pass or a fail.
- The self-test stays all-or-nothing: a half-passing self-test would be a third state to test. Accepted knowing that a
  v2-only failure also takes v1 mappings off the driver (compatibility table).
- Software mode and clearing onboard bindings stay out: the rule works with or without the echo.

Where review findings conflicted, and why this way:
- Identity of the six comes only from the fixed table, not stored bits first: the table is measured hardware identity,
  and a stored value that differs can only be a mis-learn.
- Untouched paddles in rows 1 and 4 are judged by `builtInEcho`, not by fixed expectations: the Mac cannot see the
  profile and row 1 presses Profile; the same-echo check moves to `dev-run-compare.py`.
- S7 soaks in SHADOW, not 10 min LIVE: the new frame code must be proven before it posts.
- The GUI level is nil until known, not 1: a default of 1 would flash "needs a driver update" on build 25.
- Remapped-key expectations set identity bits only, not a filter run on the simulated frame: same result, less code.
- `tapNeutral` and power on keep the full reset: Stop, SetPowerState and the timer reach no new code; a key held at
  sleep or silence is the V14 case.
- Only the frame path's LIVE gate reset keeps the echo state: there `gdx_step` stepped every frame; the other reset
  sites miss frames or change the map, so a kept state could misread the next press.
- `maxVersion` defaults to 1, not "no default": build 24 can never get v2, and ten unchanged call sites stay unchanged.
- The App echo state is not reset when the gate reopens: it keeps stepping at `submit` all along, so it needs no reset.
- Row 1's Driver pass stays in S4: it is the build-24 baseline for the new trigger judge.
- S7's App-path check uses row 1 on App only, not rows 1 and 4: row 4's Driver pass would go LIVE before the soak.
- Row 11 remaps five keys with picks outside every echo seen and keeps paddle inner right on Controller's profile: it
  covers the most keys while keeping one untouched key for `builtInEcho`.
- v7 is approved before the `record` display, not in S0: the owner reviews it on the phone with the real layout (the
  OK came during S2; the interim display coded before it is aligned in S4(a)).
- The signal conflict is a note, not a learn-time refusal between two of the six: with the fixed table two of the six
  can never share a signal.
- The rollback guard compares with the `activated enabled` build instead of writing 24 back by hand: a hand edit is
  easy to forget and would sit beside a build-25 hash.

## Not in step 2

- Removing the echo at the controller: clearing onboard paddle bindings (iCUE or Bragi key-assignment writes) and Bragi
  software mode (takeover open question 11). If done later, a press shows nothing and the stored item is still hidden
  while the key is held, with the limits under "What the owner gets" (a direction on a remapped paddle's axis can show
  as its opposite or stay shown until the paddle is let go). The follow-up then turns the hiding off for keys with no
  echo (a mapping option that leaves them out of the hide mask; clearing the stored bindings alone no longer does it,
  because a key in the mask always has a stored item).
- Reading which onboard profile is active; showing the last echo seen in a menu (the engine log and run reports name
  it).
- Saving a changed echo into the owner's mapping by itself.
- Showing the D-pad axis between two held paddles of a pair (Q10): the controller does not send it.
- Hiding an echo that lands on a stick, a trigger, Start, a G key or Profile; an echo that is not in the same report as
  its bit (row 10's gate stops).
- Repairing controls that carry a paddle bit from an old learn without the owner (S1 lists them; Q9 decides).
- A time limit on DriverManager's terminate deferral (RB4a–c handle it by procedure; a code change would risk U4).
- The −1 quirk fix (takeover open question 9), the RSUGD rename, step 3 (keyboard, mouse, macros, R7 with T11),
  per-game profiles, removing the `xlateCore` key.
- A wired (USB-C) timing run; row 10 read with the v3 gate covers it later if wanted.

## Done when

The owner remaps paddles and SAX keys from the menu and the controller's own button no longer reaches the pad: row 11
passes on App and on Driver with a conclusive hiding verdict for each of its five remapped keys, and its two D-pad-left
steps (D-pad left held through paddle outer right presses, and the reverse: the opposite cancel worked out) passed,
and every key's signal matched the table in S2. The survey replay is green in Swift, C and Python, and the exhaustive
search finds no ghost. Untouched paddles and SAX keys behave as
before (rows 1 and 4 by `builtInEcho`, the same echoes on both paths). Row 12 passes on App and on Driver. Rows 1, 4, 5 and 6 pass on both paths in S8 and row 7
in S4. The factory blob, the existing `GDHubDefaults.h` arrays, `default.json` and `mappingHash` are unchanged. A mapping
that needs v2 on build 24 leaves the App driving with no fallback entry. One driver replacement was made (or the
owner's decision after a failed S7 is recorded). After the checks the owner's mapping and layout equal their copies.
`swift test` and the Python tests are green.

## Questions for the owner (v3)

Only the two limits that are new in plan v3 (see "The limits in v3 against Q3"); everything else the owner accepted in
S0 stands or got smaller. Asked at the start of S3, before any code; the answers go into "S2b answers".

Q10. **Both paddles of a pair, remapped and held together.** Recommended: accept. If you remap both outer paddles (or
     both inner paddles) and hold the two together, the controller itself reports no left or right (or no up or down)
     on the D-pad, whatever you press. GDHub then keeps that D-pad direction as it was just before you pressed the
     pair, until you let go of one of them; the other D-pad direction works. No software can read it. Row 11 remaps
     both outer paddles, so you will feel it there. Other choice: paddles and SAX keys stay as today for this step
     (Q8 b).

Q11. **What a Profile press can still upset.** Recommended: accept. If a Profile press changes the button the
     controller adds for a remapped key (seen once, on 9 November; the survey saw no change), GDHub notices it at your
     next press of that key and hides the new button too, together with the old one, for that hold: pressing the old
     button yourself then shows only when you let go of the key, and if the new button is a D-pad direction, the
     opposite direction does not work while you hold the key. In four cases it cannot notice, and the new button can
     show next to your pick until you let go of the key: (a) you press two remapped keys in the very same millisecond; (b) you
     were already holding the new button, or the key's old button, when you pressed the key (an ordinary move, no exact
     timing needed); the button you were holding then also stays on until you let go of the key; (c) another button or
     D-pad direction changes in the very same millisecond as the key; (d) GDHub restarts its reading while you hold the
     key (the mapping changes, the controller goes quiet or reconnects, the Mac wakes, GDHub's driver path starts). The
     next clean press of the key picks the new button up again. Other choice: Q8 (b).

## Questions for the owner

Asked and answered in S0 ("OK all", see "S0 answers"). In plan v3, Q3's list is replaced by "The limits in v3 against
Q3", and Q8 was not applied (the owner chose "Rework the rule"; Q8 (b) is the other choice of Q10 and Q11).

Two earlier questions are settled by the owner's own rules and are no longer asked: mockup v7 is drawn from the
layout copy the S1 install backup takes (the real layout; the drawing never opens the data folder), and both Reset items
are hidden when there is nothing to reset (rule of 2026-11-10).

Q1. **What an untouched paddle or SAX key sends.** Recommended: "Controller's profile (built in)" — exactly today: the
    button your controller's profile gives it, and it follows that button's remap. Nothing changes on update day. Other
    choices: Nothing; or always the factory button (D-pad right/down/up/left, A, B) by its own signal. Are the words
    "Controller's profile (built in)" right?

Q2. **Hide the controller's own button only for keys you remap (Nothing counts as remapped).** Recommended: yes.
    Hiding it for every key would change what untouched keys do today.

Q3. **The limits, accepted together for step 2.** Recommended: accept them. The controller sends its own button on the
    same line as the real button, so while you hold a remapped paddle or SAX key:
    - pressing that same button yourself shows only when you let go of the key (lost if you let go of the button
      first); a press of it held from before stays held until you let go of the key;
    - A, B, X, Y, LB, RB, View, Menu, L3, R3 or a D-pad direction pressed at the same moment as the key (within about
      1–4 ms; the survey gives the number) counts as the controller's button: hidden while held, lost if let go before
      the key; the same just after you let go of one of two held remapped keys;
    - LT or RT pulled at that same moment stays at zero until you ease off it;
    - pressing Profile while holding a remapped key: the new profile's button is hidden too if it arrives within those
      few ms (the survey checks this); otherwise it shows until you let go of the key;
    - holding a remapped key while GDHub starts, the controller reconnects, the Mac wakes, or you change which keys are
      remapped hides every such button already held, until you let go of it;
    - rarely, a D-pad direction can flash once when you let go of one remapped key while pressing the D-pad and holding
      another;
    - if the controller itself drops a real D-pad press while a paddle is held, nothing can show it (the survey checks
      this, and we stop if it happens).
    The full fix is clearing the controller's onboard paddle settings with iCUE (Shadow PC over USB-C), a lasting change
    to the controller; GDHub would need no change for it later.

Q4. **The survey (row 10) presses Profile three times.** Recommended: yes. In each of three blocks you hold paddle outer
    right, press Profile once, let go of both, note the light colour, then press the six keys. We learn whether another
    profile behaves differently and what Profile does during a hold. With three profiles you end where you started;
    otherwise press Profile until your colour is back. Profile presses no longer turn rows 1 and 4 red, so the colour
    is only for the survey and for getting back to your profile.

Q5. **Two stages**: an app-only install on today's driver where you check the menus and run rows 11 and 12 on the App
    (S4), then the driver replacement (S7). Recommended: yes. One extra short sitting; it proves the App behaviour
    before the driver code is written, and the rollback copy then keeps your paddle remaps.

Q6. **"apprall" for step 2, and push to `main` after each phase's commit.** Recommended: yes to both. "apprall" still
    stops for: your answers and sittings, mockup v7, the power cycle, a reboot if needed, a failed survey gate, a failed
    S7 or S8 check, a rollback, and any second driver replacement.

Q7. **Keep out of this driver replacement**: the RSUGD rename, step 3, the −1 quirk fix and trying the controller's
    software mode. Recommended: yes; each adds its own risk to the one replacement.

Q8. **If the survey shows the controller's button cannot be hidden reliably** (the S2 gate fails). Recommended: (b) —
    paddles and SAX keys stay on "Controller's profile" in step 2, with a short note in their menu saying why, and the
    other new things (three or more controls on a button, a button sending LT or RT, two controls on a trigger) go ahead
    with the one driver update. Other choices: (a) clear the controller's onboard paddle settings with iCUE on the
    Shadow PC (a lasting change to the controller, a separate sitting, then the survey again); (c) hide on the App only,
    with a wider window: paddle remaps would then always run on the App ("App drives"). With (a) or (c) the plan is
    rewritten and reviewed again before any code.

Q9. **Buttons an old learn tied to a paddle's signal** (only if S1 finds any in the copy of your mapping; such a button
    reacts to the paddle instead of itself). Recommended: you re-learn the listed buttons in Mapping before S4, a minute
    each; everything else stays exactly as tested. Other choice: step 2 ignores such signals on buttons other than the
    paddles and SAX keys, which fixes them without your hands but changes how they behave compared with today.

## S0 answers

2026-11-10, 20:27–20:31 GMT. The nine questions were put in chat with the recommendation first in each.

- On Q1 the owner asked: "But I will be able to map in future?" Answer given: yes, and in this step; "Controller's
  profile (built in)" is only what a key does until it is touched, and each of the six keys gets the full menu.
- On Q3 (the iCUE route) the owner wrote: "you what it doesn't store in controller memory keyboard ampping". Read as:
  the controller does not keep keyboard mappings in its own memory. Recorded as the owner's statement, not measured;
  it does not change the plan (GDHub maps on the Mac and never writes to the controller; the iCUE route stays unused).
- Then: **"OK all"**. Every recommendation is accepted: Q1 "Controller's profile (built in)" as the default and its
  wording; Q2 hide only for remapped keys; Q3 the limits; Q4 the survey presses Profile three times; Q5 two stages;
  Q6 "apprall" for step 2 and a push to `main` after each phase's commit; Q7 nothing else in this driver replacement;
  Q8 (b) if the survey gate fails; Q9 the owner re-learns the listed buttons, if any are found.

## S1 notes (2026-11-10)

- (a) Layout and mapping copied to the rollback folder under `S1-pre`. In the copy only the six keys carry
  `physicalBits`, with the table's values (paddle outer right 1, inner right 2, inner left 4, outer left 8, SAX left 16,
  SAX right 32). No other control has any, so Q9 does not apply: nothing to re-learn.
- (b) `339354f`: today's GDHM v1 bytes pinned (`gdhm-v1-pins.json`): factory blob, learned sets A and B, 200 seeded
  remapped mappings, the step-1 limit messages; stray trigger bits encode byte-identical.
- (c) `62426ae`: build guard. `Xcode/dext-source.hash` seeded for build 24 after `Dext/`, `Shared/` and the driver's
  block of `project.yml` were shown equal to `1fabee0`. Deviation: the hash is recorded in the **app's** Info.plist as
  `GDHubDextSourceHash` (a key in the dext's plist would have changed `Dext/`). New `--check` (compile only) and
  `--seed-source-hash`.
- (e) `fb83ebd`: receiver recorder, `record` step kind, row 10 "Paddles and SAX: what the controller adds (survey)"
  (41 steps; the rest step is last, because a first rest step cannot know the pad's state), `scripts/tools/echo-survey.py`
  (on the committed capture it finds 16 of 16 key edges with the echo in the same report). The owner's local template
  moved from row 10 to row 11.
- (d) Mockup v7 `docs/mockups/remap-buttons-v7.html`, drawn from the S1-pre layout copy, sent in chat at 20:45; the
  owner's OK is part of S2. Four wordings are marked as placeholders until the survey.
  **Approved 2026-11-10 21:56: "v7 OK".** The survey (row 10) is still to be run; it needs the Mac and the controller.
- Install 21:05: the step-1 app archived as `S1-pre/GDHub.app`; `--same-build` passed the guard (first real use);
  driver still build 24, activated and enabled; layout and mapping equal to the copies after the relaunch; no pre-edit
  snapshot file. Tests: `swift test` 1018, Python 71.
- Not yet verified: row 10 on the real controller; the "Recorded" display in the running app; `--check` on the real
  project.

## S2 result (2026-11-10, survey run 23:14–23:22, App path, 41 steps, no reports lost)

Read with `scripts/tools/echo-survey.py`; a copy of the run report is in the rollback folder under `S1-pre`.
Mockup v7 was approved at 21:56 ("v7 OK").

**What the controller does (measured)**
- The extra button of each key, in the starting profile and after each of the three Profile presses (four states, all
  the same): paddle outer right → D-pad right, inner right → D-pad down, inner left → D-pad up, outer left → D-pad
  left, SAX left → A, SAX right → B. Each key raises exactly its table bit (0, 1, 2, 3, 4, 5).
- Timing: in every press of a key alone (about 180 presses) the extra button comes on in the **same report** as the
  key's own bit and goes off in the same report as the release. No lag in either direction.
- Profile pressed and let go while paddle outer right is held (three times): nothing else changes until the key is
  let go.
- The D-pad is a hat that the controller combines itself: a held direction plus a paddle's neighbouring direction
  gives the diagonal (up + right → up-right, up + left → up-left); the **same** direction changes nothing; the
  **opposite** direction cancels to "no direction" (D-pad up held + paddle inner right → neutral; D-pad left held +
  paddle outer right → neutral; paddles outer left + outer right → neutral; inner left + inner right → neutral).
  Two paddles on neighbouring directions give the diagonal (outer right + inner right → down-right).
- A and B are plain bits: SAX left with A held changes nothing.

**The gate: FAIL**, and what each failed line is worth
- Real: "the hat never drops a real direction while a paddle is held". With D-pad up held, pressing the paddle whose
  extra button is D-pad down makes the controller report no direction at all. The plan's rule (learn the extra button
  from the change at the press) cannot handle this case: at that press nothing comes on, a direction goes off.
- Not real, the reader's attribution: "an echo comes 5 reports after its bit" (together-sax) is SAX left's own A,
  pressed 5 reports after SAX right; the "lead 1" in together-outer is the same kind. So W = 6 is not a measured need.
- Not real, the pressing: three "alone" steps saw a second paddle bit (a neighbouring paddle was touched), and two
  steps were done the other way round (D-pad held, paddle pressed, instead of the paddle held). They still gave the
  hat facts above.

**What follows**
The plan's stop rule applies: no S3 code until the owner decides. The facts are better than the plan assumed in two
ways (no lag at all; the same extra button in every profile) and worse in one (the opposite-direction cancel). A rule
that uses them — remove a remapped key's known extra button in the same report, and work out the real D-pad direction
per axis (extra "down" present and no vertical direction reported means "up" is really held) — is a different design
from the reviewed latch and needs its own review before any code. The owner's standing answer for a failed gate is
Q8 (b).

**Owner's decision (2026-11-10 23:29): "Rework the rule".** Asked: rework the hiding rule for paddles (recommended:
remove the known extra button in the same report and work out the real D-pad direction from what is left; a new
design that is reviewed before any code), or keep paddles and SAX keys as today for this step (Q8 b). The plan's
sections on the hiding rule are rewritten as plan v3 and reviewed again before S3.


## S2b answers (2026-11-11)

Asked on 2026-11-11 with the two limits of "Questions for the owner (v3)" and mockup v7b sent in chat. The owner's
answer, 08:19: "apprall" (approve all).

- Q10 (both paddles of a pair remapped and held together): accepted.
- Q11 (what a Profile press can still upset): accepted.
- Mockup v7b (`docs/mockups/remap-buttons-v7b.html`): approved by the same answer, so the UI code of S3(c) and rows 11
  and 12 may be written.
