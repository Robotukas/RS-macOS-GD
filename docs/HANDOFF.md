# GDHub handoff — continue from another Mac user account

*Written 2026-11-08. Read this first; the full conversation is in `docs/sessions/2026-11-08-scuf-envision-macos-support.md`.*

## Why this handoff exists

The macOS user account that built this repo has **no Apple Developer signing identity** (only an "Apple Configurator" certificate). The owner has an **Apple Developer licence under a different macOS user account**, and work continues there. Nothing in the repo depends on the old account: clone, build, and carry on.

## Where the project stands

- **Input side works.** GDHub reads the SCUF Envision Pro through the Slipstream receiver (USB `1B1C:3A08` linked, `1B1C:3A09` idle) over IOHIDManager, decodes report `0x06` into `GamepadFrame`, and has a full learned factory mapping including the four paddles and two SAX buttons (`docs/protocol/envision-pro-receiver.md`). Wired identities `1B1C:3A05` / `3A06` are documented but not yet supported.
- **Visual mapping UI works.** Layout editor with callouts, leaders, align, marquee, zoom, font controls, autosave with backups. 17 unit tests pass (`Tests/GDHubTests`).
- **Output side does not exist yet.** macOS, Steam, Shadow PC and GeForce NOW do not see the controller because the receiver's HID collection sits on vendor usage page `0xFF58`. The hosts need a **virtual gamepad** published by us (`docs/plans/output-layer-plan.md`).

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
   `bundle.sh` ad-hoc signs today; it must switch to the Development certificate once the dext exists, so TCC grants survive rebuilds.
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
