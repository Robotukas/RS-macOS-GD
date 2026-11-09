# SCUF Envision Pro — Slipstream receiver V2, what the Mac sees

Captured 2026-11-08 on macOS 27.0.1 (arm64) with the tools in `scuf-envision/tools`.

## USB device
- Product "SCUF Envision Pro Wireless USB Receiver V2", manufacturer "Scuf Gaming"
- idVendor 0x1b1c (Corsair), idProduct 0x3a08, bcdDevice 0, USB 2.0 full speed, composite
- Interfaces 0–2: USB Audio (headset audio travels over the dongle)
- Interface 3: HID, usage page 0xFF58 — **this is the gamepad interface**
- Interface 4: HID, Consumer page + Corsair vendor page 0xFF42 (iCUE-style channel)

## Interface 3 report descriptor (decoded)
| Report | Dir | Size | Content |
|---|---|---|---|
| 0x58 | in/out | 63 bytes | vendor channel (usage page 0xFF58) |
| **0x06** | in | 15 bytes + ID | Generic Desktop **Gamepad** collection, see below |
| 0x09 | out | 12 bytes | unknown, likely rumble / LEDs |

Report 0x06 layout (16 bytes including the ID byte):
| Bytes | Field | Encoding |
|---|---|---|
| 0 | report ID | 0x06 |
| 1–2 | X | int16 LE, −32768..32767 |
| 3–4 | Y | int16 LE |
| 5–6 | Z | int16 LE |
| 7–8 | Rz | int16 LE |
| 9–11 | 24 bits LE | bits 0–9 Rx trigger 0..1023, bits 10–19 Ry trigger 0..1023, bits 20–23 hat (0=N,1=NE..7=NW, 8=null) |
| 12–15 | 32 bits LE | bits 0–18 buttons 1..19, bits 19–31 "vendor padding" (13 bits, **not padding**: they change with some presses, see below) |

Idle frame: `06 00 00 00 00 00 00 00 00 00 00 80 00 00 00 00`.

## Behaviour observed
- The receiver streams report 0x06 at ~1 kHz **with no handshake** as soon as the controller is awake.
- When the controller sleeps, the stream stops entirely (no frames at all), so "frames arriving" doubles as presence detection.
- `GCController` (Apple GameController framework) does **not** see the device. SDL-style IOHIDManager matching on usage page 1 / usage 5 does, as 6 axes, 19 buttons, 1 hat.
- Extra bits (the 13 "padding" bits): during the free-form capture, D-pad directions came with extra bits 0–3 and buttons 1/2 came with extra bits 4/5 on some presses but not others. Working theory: paddles/SAX report their *mapped* function in the standard fields and their *physical* identity in the extra bits.
- Known from the aborted guided run: Menu = button 7, the centre Start/power button = button 11. Everything else is to be learned in the app.
- Interface 4 (Consumer/0xFF42) produced no reports during any capture so far.

## Interface 4 report descriptor (decoded)
| Report | Dir | Size | Content |
|---|---|---|---|
| 0x11 | in | 1 byte | Consumer: volume up (bit0), volume down (bit1), mute (bit2), 5 pad bits |
| 0x01 | in | 63 bytes | vendor 0xFF42 usage 1 |
| 0x02 | out | 63 bytes | vendor 0xFF42 usage 1 |
| 0x0C | feature | 63 bytes | vendor 0xFF42 usage 1 |
| 0x03 | in | 63 bytes | vendor 0xFF42 usage 2 |

Raw descriptors: `scuf-envision/captures/desc_if3_ff58.hex`, `desc_if4_consumer.hex`. Decoder: `scuf-envision/tools/hiddesc.py`.

## Two USB identities (added after the prior-art research, 2026-11-08)
- **0x1b1c:0x3a08** — composite identity seen while a controller is linked over Slipstream: 3 audio interfaces + HID if3 (0xFF58 vendor + Gamepad collection) + HID if4 (Consumer + 0xFF42).
- **0x1b1c:0x3a09** — HID-only identity observed on this Mac at another moment: a single interface whose descriptor is just the 0xFF58 vendor collection plus the two 0xFF42 collections, with **no Gamepad and no Consumer collection**. OpenLinkHub's maintainer notes the receiver's product ID "will change once controller is connected via Slipstream", so 0x3a09 is the unlinked / controller-off state. **Confirmed live 2026-11-08 13:28**: when the controller switched off, the 0x3a08 interfaces disappeared and a single 0xFF58 interface with product 0x3a09 appeared; GDHub showed "Receiver idle (controller off)".
- GDHub matches both and shows "Receiver idle (controller off)" for 0x3a09.
- Related prior art, ranked in `docs/research/slipstream-prior-art-brief.md`: OpenLinkHub (Go) has a driver for this exact receiver including rumble on if3 output report 0x09; ZeroCue (C#, Windows) implements the Corsair Bragi control protocol on the 0xFF42 channel; Scuf2Switch documents the V1 dongle.
- This Mac also has iCUE 5 for Mac installed with its DriverKit extension `com.corsair.cue.main.VirtualHIDDeviceDriver` active, plus OpenJoystickDriver and Razer's virtual HID dext. Any of these can interfere with or explain device behaviour.

## Report 0x06 control table (learned in GDHub, 2026-11-08, factory profile)
| Control | Field |
|---|---|
| A, B, X, Y | buttons 1, 2, 3, 4 |
| LB, RB | buttons 5, 6 |
| View, Menu | buttons 7, 8 |
| L3, R3 | buttons 9, 10 |
| Start (centre power button) | button 11 |
| G1 … G5 | buttons 12 … 16 |
| Profile | button 17 |
| buttons 18, 19 | not seen |
| LT, RT | Rx (0..1023), Ry (0..1023) |
| Left stick | X (right +), Y (down +) |
| Right stick | Z (right +), Rz (down +) |
| D-pad | hat 0 up, 2 right, 4 down, 6 left |

Extra bits (the 13 "vendor padding" bits) are the **physical** paddle / SAX state. The standard fields carry whatever the on-controller profile maps them to (factory profile: paddles = D-pad, SAX = A / B).
| Physical control | Extra bit | Factory-profile function |
|---|---|---|
| Paddle outer right (as seen from the back) | bit 0 | hat 2 (right) |
| Paddle inner right | bit 1 | hat 4 (down) |
| Paddle inner left | bit 2 | hat 0 (up) |
| Paddle outer left | bit 3 | hat 6 (left) |
| SAX left | bit 4 | button 1 (A) |
| SAX right | bit 5 | button 2 (B) |

## Wired identities (from the ShadowUSB daemon log, 2026-11-08)
When the controller was plugged in by USB-C the Mac enumerated it as **1b1c:0x3a06 "SCUF Envision Pro Controller V2"** (one HID interface, serial `1c637ca3…`) and, in another moment, as **1b1c:0x3a05** (composite: audio control + streaming interfaces + two HID interfaces, the same shape as the linked receiver 0x3a08). Hypothesis: 0x3a06 is a charging / wireless-mode state, 0x3a05 the full wired controller. To be captured in the wired phase.

## Control channel (Corsair "Bragi"), verified on this Mac 2026-11-09 over wireless

Tool: `scuf-envision/tools/bragi.swift` (`bragi <target>:<hex> …`). Transport: the 0xFF42 collection on interface 4.

- **Request:** output report `0x02`, 63 bytes: `<target> <command…>`. Targets: `08` = receiver, `09` = paired controller.
- **Reply:** input report `0x01`: `01 <00 receiver | 01 controller> <command echo> <status> <value, little-endian>…`. Status `00` = ok, `09` = rejected.
- **GET property:** `02 <prop>`. **SET property:** `01 <prop> 00 <value LE>`.
- **SET is rejected (status 9) in hardware mode.** Switch the controller to software mode first (`01 03 00 02`), write, then restore hardware mode (`01 03 00 01`). The gamepad report 0x06 kept streaming at ~1 kHz throughout, and values survive the return to hardware mode.

| Property | Target | Read on this unit | Meaning |
|---|---|---|---|
| `03` | 08, 09 | 1 | Mode: 1 hardware, 2 software |
| `12` | 08 / 09 | 0x3A08 / 0x3A05 | Product ID (receiver / controller) |
| `13` | 08 | `00 0c 35` | Receiver firmware |
| `0D` | 09 | 1 | Sleep enabled (0 = never sleep, per OpenLinkHub) |
| `0E` | 09 | 600000 → set to 3600000 | Sleep timer in ms (factory 10 min; set to 60 min on 2026-11-09) |
| `0F` | 09 | 490 | Battery, tenths of a percent |
| `40` | 09 | rises ~1000/s | Uptime since power-on, ms |

Sequence used to change the sleep timer (all acknowledged with status 0, read back correctly):
`09:01030002` → `09:010e00<ms LE32>` → `09:01030001`. Not yet confirmed: persistence across a controller power cycle, and whether the new timer is honoured without OpenLinkHub's extra `01 03 00 04` step.

## G keys, Start and Profile: what each press sends (captured 2026-11-09)

Two identical passes with `scuf-envision/tools/hidcap` over the Slipstream receiver, factory profile, short presses.

| Key | Report 0x06 (interface 3) | Report 0x11 (interface 4, Consumer) |
|---|---|---|
| G1 | button 12 | nothing |
| G2 | button 13 | `11 02` on press, `11 00` on release: **volume down** (bit 1) |
| G3 | button 14 | `11 01` / `11 00`: **volume up** (bit 0) |
| G4 | button 15 | `11 04` / `11 00`: **mute** (bit 2) |
| G5 | button 16 | nothing |
| Start (centre) | button 11 | nothing |
| Profile | button 17 | nothing |

- For G2–G4 the button and the media key arrive in the same millisecond, on two different interfaces. macOS acts on the media key through Apple's event driver on interface 4. To make a remapped G2–G4 stop changing the volume, that media-key path has to be intercepted; the button on interface 3 is unaffected by that.
- A short press of Profile produced no other report on either interface. Whether it switched the controller's stored profile (which would change what the paddles and SAX echo) was not checked in this capture.
- In one earlier pass an accidental squeeze showed `LB` (button 5) together with extra bit 4 (SAX left). The table above lists SAX left's echo as button 1 (A), so either the stored profile differs from the factory one or that table is wrong for SAX; to be checked before the paddle/SAX remap step.
- 2026-11-09, Developer-mode run `dev-runs/2026-11-09T22-33-23_driver_full.json`, step `sax_left`: the pad showed **X** (button 3) going down and up with the SAX left presses ("unexpected change on X", 4 pad reports) and no A. Three different echoes have now been seen for SAX left (A in the table, LB once, X today), which fits the working theory above: the standard fields carry whatever the controller's *current onboard profile* maps the paddle or SAX key to, and that profile has evidently changed on this unit (the Profile button is easy to press by accident). Consequence for the remap step: identify paddles and SAX keys by their extra bits (physical identity), never by the echoed button, and treat the echo as something the mapping must suppress or ignore.

## Windows reference: what Corsair's own software does (observed 2026-11-09)

Read from a Windows 11 guest with iCUE 5.42.70 installed (Parallels, read-only queries and iCUE's driver `.inf` files; no binaries were opened).

- **iCUE ships a SCUF kernel driver that takes over interface 3.** `drivers\scuf\hid\ScufDriver5.inf` ("Scuf Gaming driver", device name "SCUF ENVISION Controller", class System, version 1.0.100.0 of 2024-05-16) installs `Scufdriver5.sys` on `USB\VID_1B1C&PID_3A08&MI_03` (the Slipstream receiver), `USB\VID_1B1C&PID_3A05&MI_03` and `USB\VID_1B1C&PID_3A04&MI_03` (wired), and three `VID_2E95` SCUF IDs. So the vendor's Windows design replaces the generic HID driver on the controller interface with its own driver, which is the same interface GDHub's tap takes on macOS.
- **A second SCUF driver takes the audio interface:** `drivers\scuf\audio\Scufdriver6.inf` binds `…&MI_00` of the same devices (class MEDIA).
- **Virtual keyboard/mouse for remaps and macros:** `drivers\vhid\CorsairVBusDriver` (a virtual bus) and `CorsairVHidDriver` (HID devices enumerated on it as `CorsairBus\virtualdevice`, with keyboard and mouse install sections).
- **Without those drivers the receiver is a plain HID device.** The guest is ARM64 and the drivers are x64/x86 only, so none was loaded there. Windows then drives the receiver with inbox drivers only: `usbccgp` (composite), `usbaudio` on interface 0, `HidUsb` on interfaces 3 and 4. Interface 3 shows as two collections, a vendor-defined one and a "HID-compliant game controller" (DirectInput, no XInput); interface 4 as consumer control plus two vendor-defined collections. What `Scufdriver5.sys` exposes to games when it is loaded (an XInput pad or something else) is not visible in an ARM guest; an x64 Windows with iCUE (the owner's Shadow PC) would show it in Device Manager.
- **Wired mode uses the same interface numbers:** product `3A05` ("SCUF Envision Pro Controller V2") has interface 0 audio, interface 3 with the same two collections, and interface 4 with one extra collection (a headset control).
- **Other device IDs Windows has seen from this hardware:** `3A09` (receiver, controller off: one HID interface with three vendor collections).
- **Parallels behaviour worth knowing:** a running guest captures the whole receiver (every interface), so macOS has no driver on it until the guest is suspended or the device is released; GDHub's tap stops and is freed cleanly when that happens and re-attaches afterwards. Parallels also offers macOS game controllers to the guest as a "Virtual Xbox Controller" (`VID_045E&PID_028E`, `xusb22`), so the guest sees GDHub's virtual pad that way.
- **Not obtained:** the rumble command format. Windows' built-in USB event tracing (UCX/USBXHCI providers) works in the guest (about 950 interrupt transfers per second from the receiver) but its events carry no payload bytes, and the usual capture driver (USBPcap) has no ARM64 build. A payload capture needs an x64 Windows.
