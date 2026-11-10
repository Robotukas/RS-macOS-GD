# GDHub handoff — continue from another account

## Start here (written 2026-11-10 08:30 GMT, updated 18:30 GMT)

The owner is moving this work to another Claude account. Everything needed is in this repository; nothing lives only in
the old chat. Read in this order:

1. This section.
2. `docs/plans/remap-plan.md` — **the work in progress** (phase ledger R0–R7; step 1 = R0–R5 is done, R6 is next and needs a driver replacement).
3. `docs/plans/receiver-takeover-plan.md` — done through T8 (ledger near the top; results sections at the end).
4. `docs/plans/developer-mode-plan.md` and `docs/protocol/developer-mode-files.md` — the test tool.
5. The conversation itself, if a decision's reason is unclear: `docs/sessions/2026-11-08-to-10-driver-takeover-developer-mode-remap.md`
   (owner and assistant messages, redacted; made with `scripts/tools/session2md.py`). The first session is
   `docs/sessions/2026-11-08-scuf-envision-macos-support.md`.

### State of the Mac right now

- `/Applications/GDHub.app` at the remap step 1 build (2026-11-10 18:14) or later, driver extension `com.interlinked.gdhub.VirtualHID` **build 24**
  (activated, enabled). The background engine runs as the LaunchAgent `com.interlinked.gdhub.engine`.
- **The driver drives the virtual pad by default** (no `inputPath` stored = `driver`). First night as default was clean.
  App path back: Driver menu → "Controller driven by" → App, or `defaults write com.interlinked.gdhub inputPath -string engine`.
- Tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (992) and
  `python3 -m unittest discover -s scripts/tools` (27) are green at `HEAD`.
- App-only change: `osascript -e 'tell application "GDHub" to quit'`, then
  `scripts/build-xcode.sh --no-open --release --same-build` (keeps driver build 24, refreshes the engine), then
  `open /Applications/GDHub.app`. A driver change needs the upgrade procedure in the takeover plan §7.1 — do not improvise it.
- Rollback app bundles: `~/GDHub-rollback/` (outside the repo). **A bundle from before remap step 1 does not know
  remaps:** it ignores the `outputs` of the mapping file and writes the file without them the next time it saves, so the
  owner's remaps are gone after a rollback (the app keeps copies in `mapping-backups` in its data folder whenever remaps
  appear or disappear). The volume-key switch-off is not persistent: it ends when the engine quits. Run reports: `~/Library/Application Support/GDHub/dev-runs/`.

### What is in flight

- **Remap step 1 is done** (R0–R5, 2026-11-10; results in `docs/plans/remap-plan.md`). Mapping mode (toolbar → Mapping →
  click a label or a button → menu), 23 remappable controls, a mapped G2–G4 loses its volume function (the engine sets
  `UserKeyMapping` on the receiver's consumer service only; read it with `scripts/receiver-check.sh`). The templates in
  picker rows 5, 6 and 7 pass on App and on Driver. No driver replacement was needed. The owner's mapping has no remaps
  (reset after the tests, equal to the copy from before them).
  - Not yet seen: the engine applying the volume switch-off after the controller sleeps and wakes with a remap in
    place (the case that failed before the fresh-client fix). Check the log: category `volume-keys`, reason other
    than "start".
  - Known gaps: the status line does not say when the engine started on defaults because the mapping file was
    unreadable (logged only); the label font setting lost in the layout incident is the owner's to set again.
  - Undo of a hand-set key mapping is always scoped:
    `hidutil property --matching '{"VendorID":0x1b1c,"ProductID":0x3a08,"PrimaryUsagePage":12}' --set '{"UserKeyMapping":[]}'`
    (never a bare `--set`: it writes to every keyboard).
- **Next: R6** (paddles and SAX by their physical bits, GDHM v2) — needs a plan review and a driver replacement by the
  takeover plan §7.1.
- **Carried from T8:** Shadow play test with the Slipstream receiver *not* USB-forwarded by the Shadow client; a 30-flick
  variant of the `t8-latency` template; the owner's verdict on how last night's play on the driver felt (asked, not answered).
  Do **not** delete `PassthroughPadMapper` with the `xlateCore` key: it is the oracle and the fallback (see the remap plan).
- **Blocked:** T10 rumble needs a USB capture of report 0x09 on an x64 Windows with iCUE (the Shadow PC; ask before
  installing anything there). The Parallels VM is ARM64 and cannot load Corsair's drivers.

### Layout incident of 2026-11-10 (read before running tests or installing)

Tests added for Mapping mode called `beginEditingLayout()` and left a pre-edit snapshot in the owner's real data folder; at
the next app start `recoverInterruptedEditIfNeeded()` replaced the owner's layout with the built-in default. Fixed: under
XCTest every user-data path resolves to a throw-away folder (`MappingStore.testSupportDirectory`, pinned by
`RealSupportFolderTests`). The layout of 9 November was rebuilt from a session record and sits in the app's
"Restore layout from backup" list as "layout 2026-11-10 12-15-00 from 9 Nov" (master copies are outside the repo, in the
rollback folder under `layout-incident`); its font setting and view arrangement could not be recovered. Before every
install, copy the layout and mapping files first and compare after the relaunch.

### How the owner works (standing rules; they are not in the code)

- Added 2026-11-10: name a Developer-mode template by its picker number and the title shown ("7. Volume keys under a
  remap: …"), never by its id. A mode or function that cannot be used right now is hidden, not greyed. The volume
  templates need the Mac's own speakers as the sound output (a headset with its own volume wheel cannot be checked).

- **"apprall"** = approve all: work through the phases without asking again; stop only where the owner's hands are needed
  (System Settings approval, controller on/off, reboots, pressing buttons, play tests). The owner decides against a
  recommendation sometimes (the takeover itself; Driver as default with one gate margin missed) — record it and do not re-argue.
- **Every multi-phase message starts with a progress line** from the plan's `## Phases` ledger
  (`Phase n/N  ▓▓░░  %  ·  title`), and the ledger is kept current.
- **UI: mockup first.** HTML mockup drawn from the owner's real layout, stored in `docs/mockups/`, shown to the owner, approved,
  then built. Direct manipulation on the controller drawing; a click on a label or button opens a plain menu; modes like
  Edit layout; cover every control and phase the build, not the scope; show state on the drawing; plain words ("who drives
  the controller", not "input path").
- **Every hands-on test is a saved Developer-mode template** (`Sources/GDHub/Resources/dev-script-<id>.json`, generated by
  `DevBuiltins`), run from the app's picker; never a stopwatch session in chat. Reports are compared with
  `scripts/tools/dev-run-compare.py`.
- **Planning uses reviewed plans** (several independent reviewers before building); **implementation is sequential**, one
  implementer at a time, with the test suite green before every install. Commit and push to `main` after each step.
- **Safety:** never kill the driver extension's process; no `sudo`; never `systemextensionsctl uninstall` or `reset`; no
  disassembly of Corsair's binaries (reading their `.inf` text files is fine); the repository is **public** — no e-mail
  addresses, home paths, device identifiers or serial numbers in committed files.
- **Things that take the controller away from the Mac:** the Shadow client's USB forwarding of the receiver, and the running
  Parallels VM. Either makes GDHub see "controller interface down".
- **Controller facts learned the hard way:** the Profile button cycles the controller's onboard profile, which changes what
  the paddles and SAX keys echo (identify them by their physical extra bits); G2/G3/G4 also send volume keys on USB
  interface 4; the controller cannot wake the Mac (a key is needed).

---

# Earlier handoff (2026-11-08) — continue from another Mac user account

*Written 2026-11-08. Read this first; the full conversation is in `docs/sessions/2026-11-08-scuf-envision-macos-support.md`.*

## Why this handoff exists

The macOS user account that built this repo originally had **no Apple Developer signing identity**. Update, same day: the owner's Apple Developer account (team `79XF6HYX8A`) was added to Xcode on this user, an Apple Development certificate was created, and `scripts/bundle.sh` now signs with it. Work can continue on either macOS user; the notes below still apply when setting up a fresh account.

Gotcha hit during setup: Xcode created the certificate but left out its issuer, the **Apple WWDR G3 intermediate**, so `codesign` failed with `errSecInternalComponent` / "unable to build chain to self-signed root". Fix: import Xcode's bundled copy:
```bash
security import /Applications/Xcode.app/Contents/SharedFrameworks/DVTFoundation.framework/Versions/A/Resources/AppleWWDRCA-2030.cer -k ~/Library/Keychains/login.keychain-db
```

## Where the project stands

- **Input side works.** GDHub reads the SCUF Envision Pro through the Slipstream receiver (USB `1B1C:3A08` linked, `1B1C:3A09` idle) over IOHIDManager, decodes report `0x06` into `GamepadFrame`, and has a full learned factory mapping including the four paddles and two SAX buttons (`docs/protocol/envision-pro-receiver.md`). Wired identities `1B1C:3A05` / `3A06` are documented but not yet supported.
- **Visual mapping UI works.** Layout editor with callouts, leaders, align, marquee, zoom, font controls, autosave with backups. 17 unit tests pass (`Tests/GDHubTests`).
- **Output side (2026-11-10):** GDHub publishes a virtual Xbox pad from its own DriverKit extension (`com.interlinked.gdhub.VirtualHID`, build 24), and since T8 the **driver itself drives the pad by default** (`inputPath` absent = `driver`): the dext's receiver tap owns interface 3 of the Slipstream receiver, translates every report with the shared C translator and posts it, with the background engine (`GDHub --engine`, LaunchAgent) supervising, falling back to the App path on a stall and restoring it. Gate numbers of 2026-11-10: controller→pad 0.13 ms (buttons) and 0.12 ms (stick onset) on the driver vs 0.41 / 0.26 ms on the App path; no lost inputs. Plan and results: `docs/plans/receiver-takeover-plan.md` (T0–T8). The GUI's **Developer mode** runs saved test templates (highlight → record → judge → JSON report; `docs/plans/developer-mode-plan.md`, `scripts/tools/dev-run-compare.py`). `defaults write com.interlinked.gdhub inputPath -string engine` puts the App path back.
- **Shadow PC:** do not let the Shadow client USB-forward the Slipstream receiver (it pulls the receiver off the Mac entirely and bypasses GDHub; it is laggy). Shadow forwards GDHub's pad as an "Xbox 360 Controller" by itself.
- **Older note, kept for history — output side did not exist yet (2026-11-08):** macOS, Steam, Shadow PC and GeForce NOW do not see the controller because the receiver's HID collection sits on vendor usage page `0xFF58`. The hosts need a **virtual gamepad** published by us (`docs/plans/output-layer-plan.md`).

## The decision taken

Route **R3 in the output-layer plan: GDHub's own engine plus our own DriverKit extension (dext)** that publishes a virtual HID gamepad, later also a keyboard and pointer for macros. Rejected: USB-forwarding into Shadow PC (far too laggy), lowering SIP/AMFI (not acceptable on a gaming Mac), and depending on OpenJoystickDriver (its 0.6+ licence is non-commercial and it owns the device exclusively). OpenJoystickDriver stays useful only as a **reference** for the identity/descriptor choices that Steam, GameController and SDL2 2.24 accept (see plan §1 and §2).

Personal use only; not for the App Store. The dext is signed with a **development** provisioning profile that lists this Mac, which is all a paid account needs.

## First steps on the new account

1. Clone `https://github.com/Robotukas/RS-macOS-GD` and run the existing build to confirm the toolchain:
   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
   ```
   ```bash
   scripts/bundle.sh
   ```
   `bundle.sh` signs with the first Apple Development identity it finds (`GDHUB_SIGN_IDENTITY` overrides), falling back to ad-hoc.
2. In Xcode, sign in with the Developer account. Create an App ID for `com.interlinked.gdhub` and a second one for the dext, `com.interlinked.gdhub.driver`. Enable the **DriverKit** capability and the **HID device** family on the dext App ID. These development entitlements are self-serve on a paid account (`com.apple.developer.driverkit`, `com.apple.developer.driverkit.family.hid.device`); the distribution variants need an Apple request and are *not* needed for personal use.
3. Register the Mac's provisioning UDID (Xcode does this on first run) so the development profile covers it. A dev-signed dext loads with SIP **on**, provided the app bundle that embeds it is run from `/Applications`.
4. Build the dext as an Xcode target (SwiftPM cannot build dexts). Plan: keep the Swift package for the app, add an `Xcode/` project that links the package and embeds `GDHubDriver.dext`.
5. Driver design, per plan §3: `IOUserHIDDevice` subclass; descriptor and identity chosen from the plan's matrix. Candidate first identity: Xbox Wireless Controller `045E:0B13` with dual collections (report `0x01` plus GIP `0x20`) because it is on the `GCIOMatchVirtual` list macOS honours, and SDL2 2.24 (Shadow) parses `0B13` as the Bluetooth report. Verify in this order: System Settings → Game Controllers, then Steam, then Shadow PC with ShadowUSB forwarding disabled, then GeForce NOW.
6. App ↔ dext channel: `IOUserClient` with a shared-memory frame or external method per input change; GDHub sends on change, rate-capped at 250 Hz (plan §7).
7. Then the mapping engine: Xbox remap, keyboard/mouse output via CGEvent first, macros, per-game profiles (plan §3–§6).

## Things to keep in mind

- Never relaunch the app (`scripts/bundle.sh`) while the layout editor is in edit mode; the autosaved in-progress state becomes the layout. Use Layout → Cancel editing first. Backups live in `~/Library/Application Support/GDHub/layout-backups/`.
- User data: layout `~/Library/Application Support/GDHub/envision-pro-layout.json`, mapping `envision-pro-mapping.json`. These are per macOS user, so the new account starts from the bundled defaults; copy both files across if the old account's edits are wanted.
- The receiver stream is ~1 kHz with no handshake and stops when the controller sleeps. Output report `0x09` (12 bytes) is probably rumble/LED; not yet exercised.
- Open decisions from plan §8 still open: GeForce NOW keyboard path (turn "Direct mouse input" off vs. a HID keyboard from the dext), whether to disable Razer's phantom `045E:028E` pad, which games per host to test with.
