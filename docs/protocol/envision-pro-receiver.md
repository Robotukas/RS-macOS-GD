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
