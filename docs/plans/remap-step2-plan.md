# Remap step 2: paddles and SAX by their own signal, GDHM v2 (R6 of the remap plan)

Status: **plan v2 (2026-11-10): the plan review is folded in.** Made from a read-only survey of the code and docs and
three independent designs (smallest driver change, risk first, owner first), then reviewed against the code by
independent reviewers and verifiers. The choices between designs and between conflicting findings are listed under
"Design choices". Before any code: the owner's answers to "Questions for the owner" (S0).
Scope (remap plan, R6 row and "Not in step 1"): paddles and SAX as sources by their physical bits with the controller's
own button hidden; GDHM v2 for three-plus sources on a button, a button sending a trigger and two sources on a trigger;
trigger remaps checked in Developer mode; **one** driver replacement.
Mockup: v6 (`docs/mockups/remap-buttons-v6.html`) is approved; v7 is drawn and approved in S1, before any UI code.
Owner's rules that shape it: mockup first, from the real layout; a click on a label or button opens a plain menu; plain
words; hidden, not greyed; cover every button; every hands-on test is a saved Developer-mode template, named by picker
number and title.

## Plan v2: what the review changed (2026-11-10)

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

During R6 the progress line counts this S0–S9 ledger (Phase n/10); S2b, if it is opened, shows as 2b.

| Phase | Title | Driver replacement? | Exit | Status |
|---|---|---|---|---|
| S0 | Plan review and the owner's answers to "Questions for the owner" | No | Review folded in (plan v2, 2026-11-10): done. Outstanding: the owner's answers to Q1–Q9, quoted in "S0 answers"; then plan v2 committed, the remap-plan R6 row and HANDOFF point here | ✅ done 2026-11-10: "OK all" (see "S0 answers") |
| S1 | Safety net, build guard, receiver recorder, survey template, mockup v7 (app-only install) | No | Pins committed; build-24 source hash seeded; `--check` works; v7 approved (quoted) before the `record` display was coded; `swift test` + Python green; installed with `--same-build`; layout and mapping equal to their copies | ✅ done 2026-11-10 21:05 (see "S1 notes") |
| S2 | Owner sitting 1: run row 10 (survey) | No | "S2 result" written: echoes and light colour per profile, each key's bit, lags, leads, hat behaviour, Profile during a hold; W, G and row 11's probe and picks fixed; gate passed, or the Q8 answer applied (S2b opened when needed) | ▶ current |
| S2b | Re-plan after a failed gate (only if the S2 gate fails) | No | Q8 = (b): the (b) changes applied and v7b approved; any other case: plan v3 written, reviewed against the code, owner's OK quoted. "skipped" when the gate passes | pending |
| S3 | Model, Swift echo filter, menus, labels, lighting (App path only) | No | Tests green; S1 pins byte-identical; echo cases E1–E29 pass in Swift | pending |
| S4 | Developer mode judges triggers, `builtInEcho`, "cannot judge"; rows 11 and 12; app-only install; owner runs them on App | No | Rows 11 and 12 pass on App with a conclusive hiding verdict per remapped key; their Driver pass stands down quietly on build 24; rows 4, 1 and 7 pass on App and Driver; layout and mapping equal to their copies; no before-edit file | pending |
| S5 | GDHM v2 in the shared C translator and the encoder | No (shared C; reaches the driver in S7) | Tests green; v1 bytes, golden vectors and existing `GDHubDefaults.h` arrays unchanged; C equals Swift on random sequences; `build-xcode.sh --check` passes | pending |
| S6 | Driver code, capability bit, §7.1/§7.2 text fixes, independent pre-install review | Prepares it | Tests green; `--check` passes before and after the review; Start, Stop and SetPowerState source unchanged; review findings fixed | pending |
| S7 | The driver replacement, build 24 → 25 (takeover plan §7.1), with two SHADOW soaks | **Yes (the only one)** | Build 25 activated enabled, one driver process, `tapPid == rootPid`, self-test passes; row 1 passes on App; 10 min v1 and 5 min v2 SHADOW soaks with 0 parity mismatches, 0 echo-mask differences and no fallback; `inputPath` absent and the engine LIVE; no latch; layout and mapping equal to their copies | pending |
| S8 | Owner sitting 3: rows 11 and 12 on App and Driver; regression rows 4, 5, 6, 1 | No | Every step passes on both paths; each remapped key had a conclusive hiding verdict on both; row 11's Driver pass shows echo parity checked; no fallback, limiter or breaker line and no latch; mapping and layout equal to their copies after "Reset all remaps" | pending |
| S9 | Results, docs, HANDOFF | No | Committed; pushed on the owner's word; remap-plan R6 row ticked; compatibility table in takeover §5.7 | pending |

Needs the owner's hands: S0 (answers only), S1 (look at mockup v7 on the phone and say OK), S2 (controller on, run row
10), S4 (picks in Mapping, runs, Profile back to the noted colour, resets), S7 (power-cycle the controller at U6; a
reboot only if U5 does not match within 2 min; any System Settings prompt; row 1 on App; use the controller for 10 min,
then 5 min with the row 11 and 12 picks), S8 (picks, runs, resets). S7 and S8 are one sitting.
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
  GDHub hides the button the controller adds for it. The hiding learns that button from the press itself, never from a
  stored value, so a Profile press between holds does not upset a remapped key.
- **The limits** (Q3), because the controller sends its own button on the same line as the real button: while a
  remapped key is held, a press of that same button is not visible until the key is let go (lost if let go first); a
  button pressed at the same moment as the key (within W reports, about 1–4 ms) counts as the controller's; a few rarer
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
- The standard fields also carry the onboard profile's button for that key (the "echo"). It differs per profile and the
  Mac cannot see the active profile: a Profile press sends only button 17 (`envision-pro-receiver.md:113-126`). Echoes
  seen so far on this unit: the four D-pad directions, A, B, X, Y, LB and RB (protocol notes; takeover plan T7 runs).
- Timing measured once: in `scuf-envision/captures/02-button-walk.txt` (one profile, wireless) all 16 edges of 8
  paddle and SAX presses had the bit and its echo change in the same report. Nothing else is measured: other profiles,
  hat combinations, Profile during a hold, wired mode. Developer-mode run files keep no receiver frames today.
- The report ORs the echo with the real control, so nothing in software can tell them apart while the key is held.
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
- New `signalConflict()`, the same on every driver build: a remapped key of the six whose table bit is also stored in
  the `physicalBits` of a control outside the six (an old learn). It gives "<Other> was learned with <Paddle>'s signal:
  re-learn <Other>." It is shown as a note and a hint line (UI item 9), never through `remapLimit`, and the encoder
  does not refuse it (App and driver do the same thing with it). What to do with such controls is Q9.
- `LearnSession` (`:191-195`): attach extra bits only when learning one of the six. A learn of one of the six whose
  rising bit is not its table bit is refused: "That was <Other>'s signal: press <Label> itself."
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

### The rule (the same in Swift `EchoFilter` and in C `gdx_echo_next`)

It never reads which button the echo is. A button or hat direction that comes on in the same report as a hidden key
goes down (or within `W` reports after, or one report before) belongs to that key, and stays hidden until it goes off
or every hidden key is up. While a key is held, a direction the hat dropped and brings back is hidden again.

Parameters (from the blob's echo entry; `EchoParams` in Swift): `H` hide mask (extra bits), `W` window (0..4 reports),
`G` grace (0..8 reports), `S` latch set (which standard bits may be hidden).

Standard word `std` of a frame: bits 0..18 = receiver buttons 1..19; bits 19..22 = hat up, right, down, left (hat 0 up,
1 up+right, 2 right, 3 right+down, 4 down, 5 down+left, 6 left, 7 left+up, 8 and above none); bit 23 = LT raw above
`triggerActiveRaw`; bit 24 = RT the same; bits 25..31 = 0.
Default `S` = 0x01F803FF: buttons 1–10 (A B X Y LB RB View Menu L3 R3), the four directions, LT and RT. Start (11),
G1–G5 (12–16) and Profile (17) are never hidden. The survey reports trigger echoes for information only.

State `gdx_echo` / `EchoState`, 24 bytes (21 used): `u32 prevStd, latched, echoSet, prevRose; u16 prevHeld;
u8 window, grace, relWin`. All zero = fresh. `PROFILE` = bit 16 (receiver button 17).

Per report:

```
held     = extra & H
pressed  = held & ~prevHeld                       // a hidden key went down
released = prevHeld & ~held                       // a hidden key came up
if (pressed)                              window = max(window, W + 1)
if (held && ((std ^ prevStd) & PROFILE))  window = max(window, W + 1)   // Profile pressed or let go during a hold
if (released) { window = max(window, max(W, G) + 1); relWin = max(W, G) + 1 }
rose = std & ~prevStd & S
if (window) { if (held) latched |= rose | (pressed ? prevRose : 0); window -= 1 }
if (held)   latched |= rose & echoSet          // an echo the hat dropped and brought back is hidden again
latched &= std                                 // a hidden bit that went off is free at once: its next rise is real
if (relWin) { echoSet = latched; relWin -= 1 } // after a release the set follows what is still hidden
else          echoSet |= latched
if (held)          grace = G
else if (grace)    grace -= 1
else             { latched = 0; echoSet = 0 }  // every hidden key is up and the grace is over: forget the rest
prevStd = std; prevHeld = held; prevRose = rose
return latched                                 // the mask for this report
```

Applying the mask (`gdx_echo_apply` / `EchoFilter.apply`, pure): buttons `&= ~(mask & 0x7FFFF)`; the hat nibble is
re-encoded from its directions minus the masked ones **only when they intersect** (nothing left → 8); the LT or RT
10-bit field is zeroed when bit 23 or 24 is in the mask; extra bits are never touched, so the remapped key's own rule
still fires. A mask of 0 gives the input bytes unchanged.

### What the owner gets (factory echo as the example: paddle outer right → Y, its echo D-pad right)

- Paddle alone → Y; D-pad right never reaches the pad, on press, hold and release.
- D-pad right alone, with no hidden key held → D-pad right at once.
- D-pad up held, then the paddle: if the controller sends up+right, right is hidden and up stays.
- Paddle held, then a real D-pad left (the hat drops right) and let go: right comes back hidden, not as a ghost.
- Two hidden keys, "last press wins" on the hat, or opposite directions cancelling: no ghost press. The per-hold echo
  set re-hides a direction the hat brings back, and a release opens a window of max(W, G) reports for the direction
  of the key still held.
- An echo that arrives one report before its bit shows for that one report only.
- Other buttons and other directions during the hold pass at once.
- A key left on Controller's profile is not in `H`: its echo passes as today.
- If the onboard bindings are ever cleared, nothing comes on with the bit and the filter does nothing; no change needed.
- W and G in milliseconds go here after S2 (one report is about 1 ms).

### What cannot be told apart (the report ORs the echo with the real control)

These are the limits Q3 asks the owner to accept together.
- While a hidden key is held: a press of its echo button that starts during the hold shows only at the key's release
  (lost if let go first); a release of it during the hold shows only at the key's release. After the hat dropped the
  echo direction, a real press of that direction during the hold also counts as echo.
- A press of any button in `S` landing in the key's own press report, within `W` reports after it, or one report
  before it, counts as echo: hidden while held, lost if let go before the key.
- After one of two hidden keys is let go, a press of the other key's echo direction within max(W, G) reports counts as
  echo.
- A real LT or RT crossing `triggerActiveRaw` (100 of 1023) inside such a window is zeroed until it drops to 100 or
  below, or until every hidden key is up and G reports have passed. A trigger already pulled before the edge is never
  affected.
- A Profile press **during** a hold: the new echo is hidden if it changes within W reports of the Profile edge (the
  survey measures this); a later change shows until release.
- If a hidden key is let go while the hat has dropped another hidden key's echo for a real press, that echo can come
  back once as a ghost.
- After a tap start, an interface reopen, sleep or controller silence, or a mapping change that alters the echo entry,
  with a hidden key already held: everything in `S` that is down (a held trigger included) is hidden until let go.
- If the controller drops a real D-pad direction while a paddle's direction is held, no software can show it (the
  survey checks this and the gate stops). An echo onto a stick is never hidden (the survey checks that none exists).
  An echo arriving two or more reports before its bit would show for the whole hold (the gate stops).
- Only removing the echo at the controller removes these limits (Q3, "Not in step 2").

### Where it runs

- **Driver path**: `gdx_step` runs `gdx_echo_next` and `gdx_echo_apply` into a 16-byte stack copy **only when the map
  has an echo entry**, then evaluates the copy; a v1 map pays one branch. `gdx_state` gains `gdx_echo echo` and
  `u32 lastEchoMask`.
- **Resets**: `gdx_reset` stays the full reset the header documents (everything but the four counters, the echo state
  and `lastEchoMask` included); its body needs no change. New `gdx_reset_delivery` clears only the delivery fields
  (`haveLast`, `haveBytes`, `last`, `lastBytes`, `lastLen`) and keeps the echo state; the header says "only for
  re-opening delivery on the same map". The tap uses it at LIVE turned on (`GDHubReceiverTap.cpp:434`), the LIVE gate's
  `needReset` (`:564`) and pause end (`:644`). Everywhere else keeps the full reset: tap open (`:491`), a SHADOW change
  (`:426`), `tapNeutral` (`:291`) and power on (`:372`), so Stop, SetPowerState and the timer reach no new code.
- **Loading a map**: `loadMap` (`:203-223`) compares the old and new echo entries before the memcpy at `:212` (new C
  helper `gdx_echo_same(a, b)`). It keeps the echo state (`gdx_reset_delivery`) only when the tap had a valid map at
  entry, both maps have an echo entry and the entries are byte-equal; otherwise it does the full `gdx_reset`. Forced
  reloads after Open (`:489-491`), Close (`:320-321`) and a SHADOW change (`:424-426`) clear `haveMap` first, so they
  always reset. A new tap instance starts zeroed (`IONewZero` ivars, `:74`); tap Start gets no new code.
- **Parity (F5)**: the tap builds the parity record from `gdx_eval` + `gdx_build` of the frame with `lastEchoMask`
  applied, and stores the mask in the record's spare bytes (`rec.pad[0..3]`, little-endian; `rec.pad[4]` = 1 when the
  map has an echo entry; `GDHubDextCore.h:410-418`). The engine's `ParitySampler` applies that mask with its own C core
  and compares bytes exactly as today. If the pushed blob has an echo entry and the record has no mask, the sample is
  skipped (counted in `skipped`), never counted as a mismatch. `gdx_eval` itself stays stateless and keeps its
  signature. Parity checks the driver's eval and build under the driver's own mask; it cannot see a wrong mask, and
  it cannot see a fault in the shared C (both sides run it).
- **Independent mask check**: the engine's `FrameRing` (`ParitySampler.swift`) steps its own Swift `EchoFilter` on
  every frame it records and stores the mask next to the bytes. `ParitySampler` compares that mask with the record's
  `PARITY_ECHO_MASK` and counts differences in `echoMaskDiffs`. It arms only after a run of quiet frames (no hidden key
  held, no latch-set bit down) longer than max(W, G) + 1 reports since its own reset, a revision change or a new tap
  instance, because the two filters start at different times. It is a gate in S7 and S8, not a fallback trigger.
- **App path**: `VirtualPadSink.submit(frame:)` steps one Swift `EchoState` under the mailbox lock on **every** call,
  right after `received += 1` and before the `gateClosed` return and the duplicate drop (`VirtualPadSink.swift:516-527`).
  `EchoParams` (H from `echoHideMask`, W, G, S) are derived from the mapping and cached in the mailbox per `revision`.
  The state is reset by the same rule as `loadMap`: when the params change, or when the old or new params have no hide
  mask. It is never reset by `setDriverDrives`, `resetDeliveryState` or a rebuild of `xlateCache`. The slot carries
  `(frame, mask)`; the duplicate drop compares `(frame, mask, revision)`, so a frame whose mask alone changed still
  posts, and a coalesced slot carries the newest mask. `handle` applies the mask and never steps a second state: the
  Swift path runs `EchoFilter.apply` then `PassthroughPadMapper.padState` (pure, unchanged); from S5 the C path calls
  `XlateCore.eval(frame, mask:)`, which runs `gdx_echo_apply` into a 16-byte copy and then the stateless `gdx_eval`.
  App and Driver masks are then the same report by report.
- **LiveWatch (F6)**: its C core steps its own echo state through `gdx_step`. `configure(core:)` keeps the echo state
  only when the watch was enabled until now and the new core's echo entry equals the old one's (`gdx_echo_same`);
  otherwise it does the full `gdx_reset` (its state does not advance while disabled; F6 tolerates the difference).
- **GUI**: `EnvisionProDevice.ingest` runs its own filter on every frame (not at the publish rate) and gives
  `RemapLighting.levels` the cleaned frame. `LearnSession` keeps reading raw frames.
- **Developer mode** (S4(a)): one `EchoState` per run, built from the setup mapping's `echoHideMask` and the S2
  `EchoParams`, reset at run start and when the mapping or params change. `DevRunCore.onFrame` steps it once on every
  frame, before and outside the frame-keyed cache of `summary(for:)` (`DevRunCore.swift:1028`), which is keyed on
  `(frame, mask)`. The cleaned frame feeds the summary (reference pad, neutral check) and `wantedActive`/`isActive`;
  extra bits are never touched, so paddle activity still reads right. `recordReceiver` keeps the raw frame.

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

Echo entry (new); it has no reserved or padding bytes:

| Offset | Field | Valid |
|---|---|---|
| +0 | u16 hideMask | 0x0001..0x1FFF |
| +2 | u8 window (W) | 0..4 |
| +3 | u8 grace (G) | 0..8 |
| +4 | u32 latchSet (S) | non-zero; bits 10..16 and 25..31 zero |

Validation: version 1 runs **exactly today's checks** (every existing blob test keeps its reason code). Version 2:
the button item check is `item < GDX_BUTTON_ITEMS || item == GDX_ITEM_LT || item == GDX_ITEM_RT`, else `GDX_E_ITEM`;
the per-item counter `itemRules` (`GDHubXlate.c:158, 219`) runs **only for version 1** and is neither read nor written
in version 2; the range check comes strictly before any array access in both versions. A third trigger entry, a
repeated field or 0xFF next to another entry → `GDX_E_TRIGGER`; nEcho > 1 or nTriggers > 4 → `GDX_E_COUNTS`; any bad
echo field → new **`GDX_E_ECHO` = 22** (driver reasons stay below 100).

Sizes: largest v2 blob 64 + 16 + 256 + 64 + 16 + 256 + 8 = 680 B (v1: 664). Factory blob 408 B, unchanged. Native
`gdx_map` gains version, nEcho, the echo fields and `triggers[4]`; it stays far below `GDH_MAP_MAX` 1024 (the static
asserts in `GDHubReceiverTap.cpp:21` and `GDHubXlateGlue.cpp:8-9` hold; `--check` compiles them before S7).

Defines: `GDX_BLOB_VERSION` stays 1; new `GDX_BLOB_VERSION_MAX` 2, `GDX_MAX_ECHO` 1; `GDX_MAX_TRIGGERS` 4 (v1's limit of 2
is checked by version). C API: `gdx_echo_next(map, state, in, len) -> u32 mask` (0 when the map has no echo entry or the
frame is bad); `gdx_echo_apply(map, mask, in[16], out[16])`; `gdx_echo_same(a, b)`; `gdx_reset_delivery(state)`. All in
`GDHubXlate.c` (the only `Shared` file the dext compiles, `project.yml:39-41`). Integer only, no allocation, no libm,
compiled with `-ffp-contract=off` as today.

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
- v2 order: items 0..14 as today (default owner first, then `remappableIDs` order, so paddles come last), then item 20
  rules, then item 21; trigger entries LT then RT, distinct analog fields in source order or one 0xFF entry; then echo.

## Driver and engine (S6), and the replacement (S7)

Driver changes, only these:
- `GDHUB_CAP_GDHM2` = `1u << 12` in hello `out[2]`, set together with `XLATE` (build 25 reports 0x1F01 = 7937; a
  `GDHUB_TAP_DECLINE` build does not set it). No protocol bump, no new selector.
- `loadMap` (`GDHubReceiverTap.cpp:203-223`): count checks gain nTriggers ≤ 4 and nEcho ≤ 1; the echo-entry compare
  and reset rule under "Where it runs". `gdx_reset_delivery` at `:434`, `:564`, `:644` only.
- Parity record: the echo mask as above. status2 appended (version stays 1, size 676 → 704): 676 u32 `PARITY_ECHO_MASK`,
  680 u8 `PARITY_ECHO_VALID`, 681–687 zero, 688 u64 `ECHO_LATCHES` (bits newly hidden), 696 u64 `ECHO_HIDDEN_FRAMES`.
- Self-test (`GDHubXlateGlue.cpp:17-66`): also runs the v2 golden blob and its 128-frame sequence with carried echo
  state, starting from `memset(&st, 0, sizeof st)`; the sequence runner is plain C in the Dext Core folder so SwiftPM
  runs the same code. Still all-or-nothing.
- **Do not touch**: the bodies of tap Start, Stop, free/init and SetPowerState, and the timer setup in Start (an empty
  `git diff` of those functions against build 24, recorded in the S6 notes; new code is reachable only from `loadMap`,
  `syncMode` and the frame path); registry sizes (`GDH_MAP_MAX`); `GDHUB_PROTOCOL_VERSION`; the −1 quirk (takeover open
  question 9). New frame code then runs only after SHADOW is asked for and the self-test passes.

Engine and GUI:
- `DextClient.acceptsGDHM2`. `TapSupervisor.mappingOffer` becomes `(revision, maxVersion) -> MappingOffer`.
  TapSupervisor already holds the hello caps and the instance nonce; it passes 2 only when the **running** driver's
  hello has `GDHUB_CAP_GDHM2`, else 1, and uses the same value at the stand-down check (`:445`) and the push (`:761`). It
  re-evaluates the offer when the caps or the nonce change. `EngineService.swift:93-100` forwards `maxVersion` to
  `encode`. `VirtualPadSink.swift:571` passes `maxVersion: 2` explicitly; its fallback note (`:574`) says "not
  expressible in GDHM" without a version.
- A mapping that needs v2 on build 24 is `.unsupported`: quiet stand-down, the App drives, no limiter count, never
  pushed, so `GDX_E_VERSION` cannot happen.
- `TapStatusReport`: `gdhmMax` (an integer; a missing key decodes to 1); `echoValid`, `echoMask`, `echoLatches`,
  `echoHiddenFrames` and `echoMaskDiffs` (missing keys decode to 0); one engine log line with them. Developer-mode run
  reports carry them next to the parity numbers, with the sampler's `skipped` count.
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
    and combinations. Pass: the "mapping revision accepted" line shows a blob size other than 408; `ECHO_LATCHES` and
    `ECHO_HIDDEN_FRAMES` rise; `PARITY_ECHO_VALID` = 1 on the samples; 0 parity mismatches; `echoMaskDiffs` = 0; no
    `driverRefused` or fallback; the self-test still passes.
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
any parity mismatch or echo-mask difference in a soak; the layout or mapping differing from its copy. First, with no
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

## UI (mockup v7 first, approved in S1; code in S3 and S4)

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
the `built_in` wording for a paddle and the trigger-remap skip gone. The owner's OK is quoted before any UI code,
including S1's `record` display.

What changes on screen:

1. Paddle and SAX menus become full menus with ✓ "Controller's profile (built in)" as the default; `deferredNote` and
   the `.deferred` kind go (`RemapMenuModel.swift:41-48,76,122-130`).
2. Their note: on Controller's profile, "Sends the button the controller's profile gives it, and follows that button's
   remap."; remapped, "Sends only your pick. The controller's own button for this key is hidden while you hold it, so
   pressing that same button yourself, or any button at the same moment as the key, shows only when you let go." (final
   words in v7).
3. Labels: "Paddle outer right → Y", "SAX left → Nothing" (grey). Check the leading and trailing labels on Back and
   Sides for overlap: they grow sideways (only centred labels keep their place).
4. Lighting: a remapped paddle lights itself and Y (linked) on Front and All, not D-pad right; a paddle on Controller's
   profile still lights D-pad right as today.
5. Profile note: "Each press also switches the controller's own profile. Paddles and SAX keys left on Controller's
   profile change with it." plus one sentence on pressing Profile while holding a remapped key, worded after S2.
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
    claim the profile hides reads "cannot judge: the controller's current profile sends <X> for this key", and with no
    echo "not exercised (no echo from the controller)"; a `built_in` requirement on one of the six reads "needs Paddle
    inner right on Controller's profile: Reset it in Mapping" (G2–G4 keep "at its built-in function"); `background` fail
    messages such as "A dropped while View was being pressed"; the Developer prompt names keys in words; rows 10, 11
    and 12 appear in the picker.
12. No new line in the Driver menu; the echo counters go to the engine log and the run report.

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
  combination, the echo change after a Profile edge during a hold, and any analog field moving.
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
  - "cannot judge", for steps with `recordReceiver`: per press the judge takes the standard bits and directions that
    rose with the key's extra bit, within W reports, from the receiver frames (the observed echo, named in the report).
    The verdict is split: the pick arriving passes or fails as usual; the claim that the echo was hidden is "cannot
    judge" when the echo equals the pick, a `background` item or the button pressed during the hold, and "not
    exercised" when no echo rose. A `builtInEcho` step with no echo is "cannot judge", not a fail.
  - Rule for templates: a step with several sources on one pad item is split into one step per source (the judge counts
    rises of the item, not which control caused them).
  `triggerRemapSkip` and its wording go (`DevRunCore.swift:172-191`). The `built_in` wording for the six
  (`DevRunCore.swift:135, 167`; `DevRequirementCheck.swift:39`) comes from one helper next to the menu's own label.
  `dev-run-compare.py` and `docs/protocol/developer-mode-files.md` learn every new key; the compare names the echo per key
  on both paths and fails on a difference.

**10. "Paddles and SAX: what the controller adds (survey)"** (`echo-survey`, S1; steps of kind `record`, no `requires`):
rest · each of the six keys alone, ten times · hold D-pad up, press each paddle once (same, next and opposite direction
in the factory profile) · hold paddle outer right, press D-pad up twice (shows "last press wins") · hold paddle outer
right, press D-pad left twice · hold paddle outer right, press paddle outer left twice (an untouched key with the
opposite echo) · hold paddle outer right, press paddle inner right twice (a cross pair: right and down) · hold A, press
SAX left twice · hold SAX left, press A twice · both outer paddles together twice · both inner paddles together twice ·
SAX left and right together twice · only if Q4 is yes: three blocks, each "hold paddle outer right, press Profile once,
let go of both, note the light colour", then the six keys three times each.
Notes: "Do not press Profile except where a step says so." and "After the last block, press Profile until your
starting colour is back."
**Gate (S2)**, in every profile seen: for each key pressed alone exactly one extra bit rises, it equals the table entry,
and no other key's bit moves; each echo changes at most 1 report before its own bit and at most 3 reports after it on
press, at most 7 on release; in two-key blocks the remaining key's direction comes back at most 7 reports after the
release; the hat never drops a real direction while a paddle is held; no echo on a stick; after a Profile edge during
a hold the echo changes within 3 reports or not until release; no combination shows up that the E-cases do not cover.
Then W = max(1, worst press or Profile-edge lag + 1) and G = max(1, worst release or re-emergence lag + 1): the
margin, because few edges are measured, costs about 1 ms of swallowed real presses. S = 0x01F803FF. "S2 result"
records the measured worst values and the chosen W and G separately, the number of profiles and their colours, each
key's echo per profile, and row 11's probe direction (a direction the survey shows is not paddle outer right's echo in
any profile seen; up by default) with row 11's picks re-checked against every echo seen. If Q4 is no, W and G come from
one profile: recorded as a known limit.
**If the gate fails, or the hat drops a real direction while a paddle is held**: apply the owner's Q8 answer. (b) is
written out below; for (a), (c) or a failure Q8 does not cover, S2b writes plan v3, which is reviewed against the code,
and the owner's OK is quoted before S3. For (a), v3 lifts the "no changes to the controller's stored profiles" rule
and the matching "Not in step 2" line in so many words, adds "Shadow stops forwarding before the run", and re-runs row
10 after the clearing. For (c), v3 adds a limit kind that the driver level never clears (tag "App drives", "With this
pick the App drives the controller.", status "Driven by: App (paddle and SAX remaps run in the App)"), a compatibility
row, and no Driver pass for row 11.
**Q8 = (b), written out now**: paddles and SAX keep the `.deferred` kind and its note, reworded to "Remapping paddles and
SAX is not available yet: the controller's own button for these keys could not be hidden reliably. This key sends the
button the controller's profile gives it, and follows that button's remap." The six stay out of `remappableIDs`; UI
items 1–5, 8, 9 and 10 are dropped, and row 11. S3's echo filter, S5's echo entry and `gdx_echo_*`, the parity mask and the echo counters are dropped; the GDHM
v2 version byte and the other three v2 items stay. "Done when" loses its paddle clause. A short v7b is approved before
S3.

**11. "Remap check: paddles and SAX (App, then Driver)"** (`remap-paddles`, S4; `recordReceiver: true`). Picks, outside
every echo seen so far: paddle outer right → R3, paddle outer left → L3, paddle inner left → Nothing, SAX left → View,
SAX right → Menu; paddle inner right stays on Controller's profile. `requires` on every step: the five picks and
`built_in` for paddle inner right. Steps, all with written-out expectations: rest · paddle outer right ten times → R3 ·
paddle outer left ten times → L3 · paddle inner left ten times → nothing · SAX left ten times → View · SAX right ten
times → Menu · paddle inner right twice → `builtInEcho` · hold paddle outer right, press D-pad up (the S2 probe) twice →
D-pad up twice, `background` R3 (controls paddle_outer_right, dpad_up) · hold A, press SAX left twice → View twice,
`background` A (controls a, sax_left) · both outer paddles together twice → R3 and L3, no D-pad · D-pad right twice
alone → D-pad right · A twice alone → A. Notes list the picks, "Do not press Profile" and end with "Afterwards: Mapping →
Reset all remaps".

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
- **S3** (a) `Sources/GDHub/Mapping/EchoFilter.swift` (pure, no AppKit, listed in `EngineIsolationTests`) with
  `EchoParams` from the S2 result, and its tests. (b) The model changes above; the menu-model part of UI items 1 and 2
  (in `RemapMenuModel`, the `.deferred` kind and `deferredNote` go, `builtInTitles` gains "Controller's profile (built
  in)" for the six, the paddle and SAX notes join `notes`) with the rewrites of `RemapMenuTests:111-121` and
  `RemapMenuItemsTests:71-74`; the `remapLimit` level-1 message with the words table; `signalConflict`; the learn
  refusal and `learnConflict`; the requires vocabulary and its validation message; the sink stepping in `submit` on the
  Swift path; the backup rule; DriverManager's `replacing dext` and `request finished` lines (`DriverManager.swift:504,
  514`) raised from `.info` to `.notice`, so the S4 build (the future S7-pre) logs them at a kept level. Before each S3
  commit, `grep -rn "deferred\|remappableIDs" Sources Tests` finds no stale use. (c) Native menu look, labels,
  lighting through the cleaned frame, the Profile note, the hidden Reset items, the conflict hint line, per v7.
- **S4** (a) Judge changes, `builtInEcho` for untouched keys everywhere, `background`, "cannot judge", the Developer-mode
  run-long filter, `DevExpectation` for the six, the `built_in` wording, the template checks, `dev-run-compare.py`.
  (b) Rows 11 and 12 from `DevBuiltins`; row 4's notes reworded. (c) App-only install (copy, `--same-build`, compare).
  I open every paddle and SAX menu through the accessibility ids on Back and Sides, again after cycling Developer →
  Mapping → Edit layout → Mapping on every tab (the anchor-loss regression). Edit layout is left only with Cancel,
  never with "Done (lock layout)" and never by quitting or relaunching; no label is clicked, dragged or selected while
  editing; the app is not quit until the checks pass. Right after the cycle: no `envision-pro-layout.before-edit.json`;
  layout and mapping byte-equal to the S4 copies; no `layout-backups` file newer than the install. If a check fails,
  stop, leave the app running and ask the owner; never restore over the data folder without the owner's word.
  (d) The owner's sitting, in the order under "Templates and checks". Rows 11 and 12: the App pass must pass, with a
  conclusive hiding verdict for each remapped key (all "cannot judge": press Profile and run again, or ask); at the
  Driver pass the prompt "Driver pass cannot be confirmed: …" is expected — press Stop, not Run anyway (that prompt is
  the check that the new app stands down on build 24). Afterwards I compare the mapping and layout with the copies,
  check for no before-edit file, and check the engine log for no `driverRefused`, no `fallback:`, no `limiter: tripped`
  and no `breaker: tripped`, and that `tapBreakerTrippedAt` is absent.
- **S5** (a) Version-gated validator and the echo entry. (b) `gdx_eval` item 20/21 and trigger max, `gdx_echo_next`,
  `gdx_echo_apply`, `gdx_echo_same`, `gdx_step`, `gdx_reset_delivery`. (c) Encoder versions with `maxVersion: Int = 1`,
  `remapLimit(_:level:)`, the sink's C core at version 2 through `XlateCore.eval(frame, mask:)` (the Swift filter in
  `submit` still does the stepping), the `LiveWatch.configure` rule, `EnvisionProDevice.gdhmLevel` and the menu model's
  level (wired to real values in S6). (d) The `GDHubDefaults.h` generator **appends** a v2 blob and a 128-frame
  sequence (expected bytes from the Swift oracle: same-report and lag-1 echoes, a lead of 1, combinations, a dropped
  and returning direction, an echo change between holds, a Profile edge mid-hold, a reset mid-hold) and a plain-C
  sequence runner that starts from a zeroed state. Exit includes `build-xcode.sh --check`. From here the seeded hash
  makes the guard refuse `--same-build`: the next install is S7.
- **S6** (a) Cap bit and status2 offsets in `GDHubProtocol.h`, the `DextProtocol.swift` mirror, the status2 writer.
  (b) Driver C++: hello caps, `loadMap` (counts, echo-entry compare, reset sites), parity mask and counters, self-test;
  no change in Start, Stop, free/init or SetPowerState. (c) `DextClient`, `TapSupervisor` (`mappingOffer` with
  `maxVersion`), `EngineService`, `TapStatusReport`, `ParitySampler` (mask applied, skip rule, `FrameRing` filter and
  `echoMaskDiffs`), the GUI level wiring from `gdhmMax` and the hello caps. (d) Text fixes in the takeover plan §7.1,
  §7.2 and common rules:
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
  or a mapping ("no crash from any validated v2 map or any 16-byte frame"), the reset sites, capability gating, parity,
  the encoder's version choice and the Start/Stop/SetPowerState diff. Findings fixed, then `--check` again.
- **S7** As under "The replacement (S7)".
- **S8** The owner's sitting in the order under "Templates and checks". Exit in full: every step passes on both paths
  (untouched paddles and SAX keys by `builtInEcho`, the same echo names on both paths); each remapped key of row 11 had
  at least one conclusive hiding verdict on App and on Driver; during row 11's Driver pass status2 shows
  `PARITY_ECHO_VALID` = 1 and `PARITY_ECHO_MASK` ≠ 0 while a remapped key is held, the parity ok count rose with 0
  mismatches and not every sample was skipped, `ECHO_HIDDEN_FRAMES` > 0 and `echoMaskDiffs` = 0; no `fallback:`,
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
`InputPathMenuTests:101`, `LiveLifecycleTests:96` (wording only at level 1).

New:
- `EchoFilterTests` and `GDHubXlateEchoTests` (Swift oracle and C, the same scripted sequences, cleaned frames and pad
  bytes compared; every case states its W, G and lags):
  E1 same-report press and release → only the pick · E2 hidden SAX left (echo A), real A during the hold → not seen,
  appears G+1 reports after release if still held · E3 A held before SAX left → stays held until release · E4 press lag
  W hidden, lag W+1 leaks (pins the limit) · E5 release lag G hidden · E6 hidden right plus real up as a diagonal → pick
  plus D-pad up · E7 two hidden paddles, last press wins → no ghost, with release lag 0 and with release lag above W
  (W = 1, G = 3) · E8 two hidden keys with the same echo, one released → no ghost · E9 hidden and Controller's-profile
  keys with different echoes → the latter's echo passes · E10 echo changes between holds (as after a Profile press) →
  still hidden · E11 reset with a hidden key held → every `S` bit down hidden until let go, a held trigger included ·
  E12 Swift: `EchoParams` with H = 0 → cleaned frames equal raw frames; C: a hand-built v2 map with nEcho 0 and the same
  rules as a v1 map → `gdx_echo_next` returns 0 and `gdx_step` output is byte-identical to the v1 map · E13 Start, a G
  key or Profile in the hidden key's press report → visible · E14 LT/RT echo hidden with the default `S`; a real trigger
  pull outside the window passes · E15 replay of `02-button-walk.txt` with all six hidden → no echo leaks, frames
  without a paddle or SAX bit unchanged · E16 opposite directions cancelling → no ghost, also with release lag above W ·
  E17 the echo direction dropped by a real opposite press (hat 6, and hat 8) and coming back → stays hidden · E18 the
  same with a perpendicular press on a last-press-wins hat (hat 0) · E19 the echo direction dropped by an untouched
  paddle's opposite echo and coming back → hidden · E20 two hidden keys with different echoes: after one is let go and
  its window ends, a real press of its echo passes while the other is held; its echo with release lag 1 does not stay
  in the echo set · E21 the remaining key's direction coming back at max(W, G) + 1 after a release leaks (pins the
  limit) · E22 an echo leading its bit by 1 → one-report flash, then hidden for the hold, released cleanly · E23 a lead
  of 2 → leaks for the whole hold (pins the limit) · E24 a real press one report before the press edge → hidden until
  let go (pins the cost) · E25 a rise one report before a release edge while another hidden key stays held → not
  latched · E26 a Profile edge during a hold with the echo changing within W → hidden; at W+1 → leaks · E27 a new map
  with an identical echo entry pushed mid-hold (A held plus a hidden paddle) → A visible, output byte-identical to no
  push · E28 a new map with a changed `S`, or after a map without an echo entry → behaves as E11 · E29 W = G = 1 on a
  lag-0 sequence → the same output as W = G = 0 except a press within one report of an edge.
- `GDHubXlateSequenceTests.testRandomWalkWithPaddleEchoes`: 100k frames, random per-key echoes that change at random
  "Profile presses" (also mid-hold), random real presses, hat drops and returns, leads of 0–1, release lags and new-map
  pushes with equal and changed echo entries; Swift pipeline against C `gdx_step`, byte for byte.
- `VirtualPadSinkTests`, driven through `submit()`: a still controller (runs of identical reports) and a burst that
  forces coalescing, with W = G = 1, through row 11's "hold paddle, D-pad up twice" after a still period, E2's grace
  ending at rest and a coalesced paddle tap → the posted pad states equal what `gdx_step` gives for the same report
  stream; real A and a remapped paddle held across `setDriverDrives(true → false)` → the first posted frame shows A
  plus the pick and no D-pad right, on the Swift path and on the C path across the `xlateCache` reset; a paddle let go
  during LIVE, then a fallback → no stale latch hides a real press; a frame whose mask alone changed still posts.
- `GDHubXlateBlobTests` v2: versions 1 and 2 accepted, 0 and 3 refused; rules on items 20 and 21 together with item 14
  accepted in v2, refused in v1; 32 rules all on item 20 and 32 all on item 21 accepted; items 15–19 and 22–255 refused
  with `GDX_E_ITEM` before any counter is touched; two trigger entries with distinct fields accepted, same field, 0xFF
  in a pair or three entries refused; each echo field out of range (bits 10..16 in `S` included) → `GDX_E_ECHO`; v2
  with nTriggers 3 and a non-zero byte in the 4 padding bytes after the trigger entries → `GDX_E_FLAGS`; nEcho 1 with
  the echo section missing, or followed by 8 extra bytes with `length` patched → `GDX_E_LENGTH`; fuzz with a separate
  v2 corpus. These and the fuzz run once under AddressSanitizer and UBSan in S5.
- `DextXlateTests`: `gdx_reset` zeroes the echo state and `lastEchoMask`; `gdx_reset_delivery` keeps them;
  `gdx_echo_same`.
- `GDHubXlateRemapGoldenTests` v2 cases (paddle → Y, paddle → RT, three sources on Y, A → LT, LT and RT → RT, LT ↔ RT);
  `remapLimit(_, level: 2)` nil on random mappings drawn from a new 29-id seed, with paddle and SAX masks from the table.
- `MapBlobEncoderTests`: every S1 pin still version 1 and byte-identical with `maxVersion: 2`; v2 rule, trigger and
  echo order; analog field dedupe; the full level-1 string "Paddle outer right sends Y: this driver version cannot hide
  the controller's own press"; a twin of `:263-283` at level 2 (`remapLimit` nil, and `encode(…, maxVersion: 2)` gives a
  blob for each of the three level-1 kinds); a stray-bit overlap encodes with `remapLimit` nil; the words table equals
  the layout labels; a default mapping with stray bits on `lt`/`rt`, and the same swapped, stays version 1 and
  byte-identical (`triggerFeed` stays `.analog`).
- `GDHubXlateGoldenTests`: the appended v2 blob and sequence regenerate and pass the C runner the self-test uses.
- `GDHubXlateBenchTests`: the worst v2 map (29 rules, echo) in C at or below the Swift mapper.
- `DextProtocolTests` (bit 12; offsets 676–704) · `TapStatusReport` (missing `gdhmMax` → 1; missing echo keys → 0; the
  line never says "driver update" for a signal conflict) · `TapSupervisor` (caps 0xF01 plus a paddle remap →
  stand-down, no driver call, limiter untouched; bit 12 → v2 pushed; a v1 mapping pushed as v1 on both; the
  `maxVersion` passed to `mappingOffer` at `:445` and `:761` follows the caps; offer re-evaluated on a caps change) ·
  `ParitySampler` (mask used; blob with echo and record without mask → skipped; `echoMaskDiffs` stays 0 on equal masks,
  counts a difference, and does not arm before the quiet run) · `LiveWatch` (a same-echo push while enabled keeps the
  echo state; after a disabled period it resets) · `DextTapTests` (`loadMap` counts; the echo state kept on a same-echo
  push and reset on a changed or missing echo entry and on a forced reload; parity mask).
- `ControlMappingTests` (`.builtIn` default for the six; Nothing storable; paddle keys decode; `identityBits` with the
  table written out in the test, 0 for other ids; a stored paddle bit that differs from the table does not move the
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
  on A for a stored echo D-pad right and fails on zero or two items; "cannot judge" when the echo equals the pick, a
  background item or the probe button; "not exercised" with no echo; trigger items; trigger by mapped output) ·
  `DevRunCoreTests` (the run-long filter: for paddle → Y with factory echo hat 2 the reference holds Y without D-pad
  right, `refChanges` counts no echo edges, a D-pad-right step does not open its window during a hidden hold; `record`
  steps: the window opens on a listed control, no early end while an echo bit is still set, early end after the rest
  time, `noMovement` fires; the `built_in` skip text for a paddle and a SAX key) · `DevRequirementCheckTests` (the
  unmet list and start block for the six) · `MappingStoreTests` (after a paddle entry is added beside g1, a backup holds
  `paddle_outer_right`; changing a paddle's pick also writes one; pruning keeps the newest "new" backup) · run-report
  decode of `receiver`.
- Python: `echo-survey.py` on a synthetic run and on `02-button-walk.txt` converted (16 of 16 edges same-report, bits
  equal to the table); `dev-run-compare.py` new keys and the per-key echo compare; the build guard (missing hash refuses,
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

- Spine: the risk-first order (measure, then the App path in Swift, then C, then one replacement), with the owner-first
  menu and the smallest-change blob. Why: the C and driver code are written against an oracle the owner's hands checked.
- Untouched keys default to `.builtIn` (all three designs): the factory blob and today's behaviour stay as they are.
- Echo hiding by an edge latch learned from the press (all three), never the stored echo: a Profile press would make a
  stored echo wrong.
- One echo entry with one hide mask, W, G and a latch set, not up to eight per-key entries: the C stays small and no
  per-key lag difference has been seen.
- A hidden bit is freed as soon as it goes off; a per-hold echo set re-hides what the hat brings back; after a release
  the set follows what is still hidden for max(W, G) reports: fewer real presses swallowed with two keys held, and no
  ghost when the hat shows the last press.
- A one-report "before" window on press edges only: a lead of one shows for one report; a longer lead stops the gate.
- Start, the G keys and Profile are never in the latch set (the validator enforces it): they cannot be swallowed. LT and
  RT always are: a profile the survey missed can echo a trigger.
- W and G are the measured worst lag plus one, at least 1: few edges are measured, and one report costs about 1 ms.
- Parity carries the applied mask in the record's six spare bytes (not nothing, not the full state): F5 keeps checking
  the posted bytes and the seqlock record does not grow. A separate engine-side mask check covers what parity cannot
  see, and S7's judged App-path check covers the shared C, which parity runs on both sides.
- The echo state survives the LIVE gate and a same-echo map push, and clears on a tap open, a SHADOW change, a forced
  reload or a changed echo entry: delivery re-opening mid-hold must not leak the echo, and a stale state must not
  outlive a gap in stepping.
- The App path steps its filter at `submit` on every report, also while the posting gate is closed, so App and Driver
  masks match report by report; only one filter instance steps there.
- The driver's level reaches the GUI as an integer `gdhmMax`, not a flag: step 3 can add a version without a new key.
- The app-first install keeps `Shared/` and `Dext/` untouched, guarded by a seeded source hash: two different driver
  binaries never carry the same build number, and the rollback archive is provably build 24.
- Two remap templates (paddles; triggers and three sources), not one or three: the families fail independently with
  few picks. Profile-dependent evidence becomes "cannot judge", never a pass or a fail.
- The self-test stays all-or-nothing: a half-passing self-test would be a third state to test. Accepted knowing that a
  v2-only failure also takes v1 mappings off the driver (compatibility table).
- Software mode and clearing onboard bindings stay out: the latch works with or without the echo.

Where review findings conflicted, and why this way:
- Identity of the six comes only from the fixed table, not stored bits first: the table is measured hardware identity,
  and a stored value that differs can only be a mis-learn.
- Untouched paddles in rows 1 and 4 are judged by `builtInEcho`, not by fixed expectations: the Mac cannot see the
  profile and row 1 presses Profile; the same-echo check moves to `dev-run-compare.py`.
- S7 soaks in SHADOW, not 10 min LIVE: the new frame code must be proven before it posts.
- The GUI level is nil until known, not 1: a default of 1 would flash "needs a driver update" on build 25.
- Remapped-key expectations set identity bits only, not a filter run on the simulated frame: same result, less code.
- `gdx_reset` stays the full reset and `loadMap` keeps the echo state only for a same-echo content push: both the
  "reset on every load" and "keep when unchanged" findings hold, because forced reloads clear `haveMap` first.
- `tapNeutral` and power on keep the full reset, not the delivery reset: Stop, SetPowerState and the timer reach no
  new code; a key held at sleep or silence is the E11 case.
- LiveWatch keeps the loadMap rule while it runs and resets fully after a disabled period: its state does not advance
  while disabled.
- `maxVersion` defaults to 1, not "no default": build 24 can never get v2, and ten unchanged call sites stay unchanged.
- The App echo state is not reset when the gate reopens: a reset would bring back the leak the driver avoids.
- The release window of max(W, G) and the per-hold echo set are both kept: the rebuilt set alone would leak the other
  key's returning direction.
- A Profile edge during a hold always reopens the window, whatever S2 shows: one line, and it costs at most W+1 reports
  after a Profile press during a hold.
- Row 1's Driver pass stays in S4: it is the build-24 baseline for the new trigger judge.
- S7's App-path check uses row 1 on App only, not rows 1 and 4: row 4's Driver pass would go LIVE before the soak.
- Row 11 remaps five keys with picks outside every echo seen and keeps paddle inner right on Controller's profile: it
  covers the most keys while keeping one untouched key for `builtInEcho`.
- v7 is approved in S1 before the `record` display, not in S0: the owner reviews it on the phone with the real layout.
- The signal conflict is a note, not a learn-time refusal between two of the six: with the fixed table two of the six
  can never share a signal.
- The rollback guard compares with the `activated enabled` build instead of writing 24 back by hand: a hand edit is
  easy to forget and would sit beside a build-25 hash.

## Not in step 2

- Removing the echo at the controller: clearing onboard paddle bindings (iCUE or Bragi key-assignment writes) and Bragi
  software mode (takeover open question 11). If done later, the filter finds nothing to hide; no change needed.
- Reading which onboard profile is active; showing the last echo seen in a menu.
- Hiding an echo that lands on a stick; an echo that arrives two or more reports before its bit (the gate stops).
- Repairing controls that carry a paddle bit from an old learn without the owner (S1 lists them; Q9 decides).
- A time limit on DriverManager's terminate deferral (RB4a–c handle it by procedure; a code change would risk U4).
- The −1 quirk fix (takeover open question 9), the RSUGD rename, step 3 (keyboard, mouse, macros, R7 with T11),
  per-game profiles, removing the `xlateCore` key.
- A wired (USB-C) timing run; the S1 recorder makes it a later template if wanted.

## Done when

The owner remaps paddles and SAX keys from the menu and the controller's own button no longer reaches the pad: row 11
passes on App and on Driver with a conclusive hiding verdict for each of its five remapped keys, and every key's
signal matched the table in S2. Untouched paddles and SAX keys behave as before (rows 1 and 4 by `builtInEcho`, the
same echoes on both paths). Row 12 passes on App and on Driver. Rows 1, 4, 5 and 6 pass on both paths in S8 and row 7
in S4. The factory blob, the existing `GDHubDefaults.h` arrays, `default.json` and `mappingHash` are unchanged. A mapping
that needs v2 on build 24 leaves the App driving with no fallback entry. One driver replacement was made (or the
owner's decision after a failed S7 is recorded). After the checks the owner's mapping and layout equal their copies.
`swift test` and the Python tests are green.

## Questions for the owner

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

