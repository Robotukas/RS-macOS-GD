# Host × identity matrix (M1 and H1–H7)

Design: `docs/plans/driverkit-dext-design.md` §4.1, §7.2, §7.3. Status values: `pending` (not run), `pass`, `fail`, `n/a`.

Checks: H1 ioreg (`scripts/vhid-check.sh`), H2 GameController (`gcprobe --watch` + System Settings › Game Controllers),
H3 Steam (SDL3), H4 GeForce NOW (SDL2 2.32 + Forge), H5 Shadow PC (SDL2 2.24), H6 duplicates (Steam open/closed, Razer pad on),
H7 rumble.

## M1 first light (end of D3), run 2026-11-08 on dext build 11/12

Dext build 11 + app build 11/12; test pattern = `VirtualPadSink.runTestPattern` (A B X Y LB RB View Menu LS RS Guide, D-pad N E S W,
LT ramp, RT ramp, left then right stick circle, 100 Hz). Published with `--publish-pad <identity> --test-pattern`.

| Identity | VID:PID | H1 ioreg (`scripts/vhid-check.sh`) | Bound driver | H2 GameController (`gcprobe --watch`) | Test pattern values | Unpublish removes pad | Verdict |
|---|---|---|---|---|---|---|---|
| `xbox-bt16-02e0` | 045E:02E0 | pass: ProductID 736, VendorID 1118, VersionNumber 1299, Transport "Bluetooth Low Energy", SerialNumber "GDHub-1", LocationID 1195657217, MaxInput 16, MaxOutput 9, no `HIDVirtualDevice`, 1 pad | `AppleGCHIDUserEventDriver`, `GameControllerSupport = Yes` | pass: 1 controller, vendor "Xbox Wireless Controller", category "Xbox One", `extendedGamepad` present | pass: A B X Y, Left/Right Shoulder, Button Options (View), Button Menu, L/R Thumbstick Button in order, D-pad N E S W, both triggers 0 to 1, both sticks full circle with y up positive. Guide (Button Home) not reported (expected, design §4.1) | pass: pad count 0 within 1 s of `kill -9` and after Unpublish; gcprobe prints "controller disconnected" | **pass** |
| `xbox-bt16` | 045E:0B13 | pass: ProductID 2835, same other values | `AppleGCHIDUserEventDriver`, `GameControllerSupport = Yes` | pass: same as above | pass: same values and order | pass | **pass** |

Outcome (§7.3): both identities pass, so `xbox-bt16-02e0` stays the default.

Also checked: identity switch `xbox-bt16` to `xbox-bt16-02e0` (destroy, 300 ms, create) leaves exactly one pad (ProductID 2835 then 736);
`kill -STOP` on the app while a D-pad direction was held: the dext watchdog released it 2.05 s later and the pad stayed neutral until `kill -CONT`.

## Hosts (D6)

| Identity | H1 | H2 GameController | H3 Steam | H4 GFN | H5 Shadow | H6 Duplicates | H7 Rumble |
|---|---|---|---|---|---|---|---|
| `xbox-bt16-02e0` | pass (M1) | pass (M1) | pending | pending | pending | pending | pending |
| `xbox-bt16` | pass (M1) | pass (M1) | pending | pending | pending | pending | pending |
| `xbox-bt17-remap` | not built (D6) | | | | | | |
| `xbox-dual-usb` | not built (D6) | | | | | | |
| `xbox-pr208` | not built (D6) | | | | | | |
| `x360-usb` | not built (D6) | | | | | | |

## Notes

## D4 hands-on check, 2026-11-09 00:17 (identity `xbox-bt16-02e0`, GameController via `gcprobe --watch`)

The user pressed every control once on the physical SCUF; the recorder saw the virtual pad report:

| Physical control | Virtual pad (GameController name) | Result |
|---|---|---|
| A, B, X, Y | Button A, B, X, Y | ok |
| LB, RB | Left / Right Shoulder | ok |
| View, Menu | Button Options, Button Menu | ok |
| Centre Start | (nothing) | Guide is not delivered to GameController with this identity, as the design predicted |
| L3, R3 | Left / Right Thumbstick Button | ok |
| D-pad up, right, down, left | Direction Pad y=+1, x=+1, y=−1, x=−1 | ok |
| LT, RT | Left / Right Trigger to 1.00 and back | ok |
| Left stick, right stick circle | x and y each reach −1.00…+1.00, return to 0 | ok |
| Paddles outer-left, inner-left, inner-right, outer-right | Button X, A, Y, B | the controller's onboard profile echo (see note) |
| SAX left, SAX right | Left / Right Shoulder | onboard profile echo |
| G1–G5, Profile | (nothing) | ok |
| 18 s hard left-stick circling | 3649 value changes, 199/s average | under the 250/s cap |

Note: during the mapping session on 2026-11-08 the paddles echoed as D-pad directions and SAX as A/B. Tonight they echo as X/A/Y/B and LB/RB, so the controller was on a different onboard profile. The passthrough forwards whatever the onboard profile emits; pressing the Profile button changes it. GDHub's own remapping (using the paddle/SAX identity bits, independent of the onboard profile) arrives with the mapping engine.
