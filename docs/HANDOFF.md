# GDHub handoff — continue from another Mac user account

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
