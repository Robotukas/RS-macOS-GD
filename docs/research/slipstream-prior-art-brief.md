# SCUF Envision Pro V2 wireless receiver (1B1C:3A08 / 3A09): protocol brief for a macOS user-space driver

Confidence tags used below:
- **[Mac]**: observed on the target Mac.
- **[3A08-hw]**: output captured on real 3A08 hardware and posted, such as an lsusb dump.
- **[3A08-reported]**: an owner says it worked on 3A08 hardware, but no raw log has been published.
- **[3A08-code]**: open-source code written for this receiver. Not captured by us.
- **[SCUF-hw-log]**: real device→host bytes from other SCUF hardware, taken from ZeroCue issue logs. The hardware is the wired 3A05 and 3A04 and the V1 dongle in its 2E95:5046 state.
- **[V1-measured]**: measured on the older 2E95:434D wired pad or on the 2E95:434E / 5046 dongle.
- **[apple-src]**: Apple's open-source IOHIDFamily (tag IOHIDFamily-2238.100.59) or Apple's documentation.
- **[generic]**: Corsair Bragi/Slipstream in general, not proven on the SCUF.
- **[inferred]**: my own reasoning.

---

## 1. What is known about this exact device

**Observed on the Mac [Mac]: the receiver has shown two identities**
- **Earlier session: 1B1C:3A08.**
  - Product "SCUF Envision Pro Wireless USB Receiver V2", vendor "Scuf Gaming", bcdDevice 0.
  - There were two IOHIDDevices, with primary usages 0x0C/0x01 (Consumer) and 0xFF58/0x01 (vendor).
  - Neither has a Generic Desktop 1/4 or 1/5 primary usage, so GameController and SDL's IOKit backend skip both.
  - The descriptors were not dumped in that session.
- **Latest check (2026-11-08, read-only `ioreg`/`hidutil`): 1B1C:3A09.**
  - idProduct is 14857. The product string is the same and bcdDevice is 0.
  - There is one HID interface, bound by `AppleUserUSBHostHIDDevice`. PrimaryUsagePage is 0xFF58, ReportInterval is 1000 µs, and the maximum input, output and feature report size is 64 B.
  - `hidutil list` shows a single row: `0x1b1c 0x3a09 65368/1`.
  - `DeviceUsagePairs` is FF58/1, FF42/1, FF42/2. There is no Consumer, Generic Desktop or Button usage anywhere, so matching on 1/4 or 1/5 can never find this device.
  - There is no `RequiresTCCAuthorization` key. On this Mac only the built-in keyboard and trackpad, the Magic Keyboard and a Razer mouse carry it.
  - The live ReportDescriptor is 100 B by my count. It has the same structure Scuf2Switch measured for the V1 HID-only identity 2E95:5046:
    ```
    06 58 FF 09 01 A1 01  85 58 09 01 15 00 26 FF 00 95 3F 75 08 81 02  85 58 09 01 15 00 26 FF 00 95 3F 75 08 91 02  C0
    06 42 FF 09 01 A1 01  85 01 15 00 26 FF 00 75 08 95 3F 09 01 81 02  85 02 95 3F 09 01 91 02  85 0C 95 3F 09 01 B1 02  C0
    06 42 FF 09 02 A1 01  85 03 15 00 26 FF 00 75 08 95 3F 09 01 81 02  C0
    ```
    - FF58/1 has input 0x58 and output 0x58.
    - FF42/1 has input 0x01, output 0x02 and feature 0x0C.
    - FF42/2 has input 0x03.
    - Every report is 63 B plus the ID.
  - [inferred] These blocks are exactly IF3's FF58 collection (38 B) plus IF4's two FF42 collections (39 + 23 B). The 3A09 identity drops the Game Pad and Consumer collections. It probably drops the audio interfaces too, because ZeroCue marks 3A09 as non-composite.
  - Nobody recorded what changed between the two sessions: controller on or off, controller asleep, or iCUE running.
- **Other software on this Mac that touches HID:**
  - iCUE 5 for Mac, with its dext `com.corsair.cue.main.VirtualHIDDeviceDriver` active.
  - OpenJoystickDriver's dext `com.openjoystickdriver.XboxUSBDevice` 0.5.0-beta.4, active.
  - Razer's dext `com.razer.appengine.virtual.driver`. It publishes a virtual "Xbox 360 Controller" 045E:028E with Transport USB, no HIDVirtualDevice key and pairs 1/5. It also publishes a VirtualJoystick 1532:27DB (1/4).
- macOS takes the primary usage from the first top-level collection. `DeviceUsagePairs` lists every Application and Physical collection at any depth, including nested ones, but not Logical ones [apple-src: `IOHIDDevice.cpp` `newDeviceUsagePairs`].

**USB topology of 3A08 [3A08-hw, from lsusb in OpenLinkHub #256 and OpenLinkHub docs]**
- The device is composite:
  - IF0 is AudioControl.
  - IF1 and IF2 are AudioStreaming (iso EP 0x83 IN / 0x03 OUT).
  - IF3 and IF4 are HID.
  - Config wTotalLength is 0x1A3 (419 B). It draws 500 mA (bmAttributes 0xA0), supports remote wakeup and runs at Full Speed.
  - IF3: EP 0x81 IN / 0x01 OUT, interrupt, 64 B. Its HID report descriptor is 156 B, byte-for-byte the length of the wired controller's gamepad-interface descriptor.
  - IF4: EP 0x82 IN / 0x02 OUT, 64 B. Its report descriptor is 99 B.
  - The wired V2 Pro (3A05) dump in the same thread has IF3 = 156 B and IF4 = 154 B.
  - The audio card appears as `Scuf_Gaming_SCUF_Envision_Pro_Wireless_USB_Receiver_V2`.
  - When the reporter took this dump, the rear switch was on Slipstream and the controller was linked and working. 3A08 was the only identity present.
  - Sources: https://github.com/jurkovic-nikola/OpenLinkHub/issues/256 and https://raw.githubusercontent.com/jurkovic-nikola/OpenLinkHub/main/docs/scuf-controller.md
- **No public byte dump of any 3A08 descriptor exists.**
  - OLH #256 prints `** UNAVAILABLE **` for every HID descriptor.
  - linux-hardware.org has no page for 3A08, 3A05 or 3A09 (https://linux-hardware.org/?id=usb:1b1c-3a08 returns 404).
  - GameControllerDB and SDL have no 1B1C SCUF entry.
  - The Tealdragon204 Linux driver that claimed 3A08 support now returns 404 (https://github.com/Tealdragon204/scuf-envision-pro-V2-Linux).
- Scuf2Switch measured the same shape on the V1 dongle (2E95:434E) [V1-measured]:
  - IF3 is HID (156 B, EP 0x81 IN / 0x01 OUT, 64 B, bInterval 1).
  - IF4 is HID (99 B, EP 0x82 IN / 0x02 OUT, starting `05 0C 09 01 A1 01 85 11`).
  - 1B1C:3A08 never appeared on that unit.
  - Source: https://github.com/MichaelRColton/Scuf2Switch/blob/main/docs/protocol.md

**Interface roles in the 3A08 state [3A08-code; the mapping to the Mac is inferred but fits exactly]**
- **IF3 / MI_03: gamepad interface. This is the Mac's FF58-primary device.**
  - It carries the vendor FF58 collection (report 0x58, 63 B in and out, undecoded).
  - It also carries a sibling Generic Desktop Game Pad collection, with input report 0x06 and output report 0x09 (rumble).
  - The content is almost certainly the 156-B descriptor that B3Mac captured on the wired V1 (§2d). Confidence: likely. Five things point that way:
    - The length matches.
    - besseddrest's 3A08 layout is exactly what that descriptor declares: 4×16 + 2×10 + 4 + 19 + 13 = 120 bits, plus the ID = 16 B.
    - Scuf2Switch measured the same thing on the V1 dongle.
    - GameControllerDB's Linux mapping for the V1 dongle 434E (a0..a5 = X, Y, Z, Rx, Ry, Rz, plus a hat) only makes sense with this descriptor.
    - The Mac showed FF58/1 as the primary usage.
  - OpenLinkHub `setAnalogDevice()` opens `InterfaceNbr == 3` for sticks and rumble (https://raw.githubusercontent.com/jurkovic-nikola/OpenLinkHub/main/src/devices/scufenvisionproV2W/scufenvisionproV2W.go).
  - ZeroCue reads radio input from MI_03 IN 0x81.
- **IF4 / MI_04: Consumer + Bragi control. This is the Mac's 0x0C-primary device.**
  - The 99 B break down as 37 B Consumer (report 0x11) + 39 B FF42/1 (0x01 in, 0x02 out, 0x0C feature, 63 B each) + 23 B FF42/2 (0x03 in). The bytes are in §2d.
  - The blocks come from B3Mac's 154-B wired consumer descriptor minus a 55-B Telephony/LED block. Scuf2Switch confirms the V1 dongle prefix.
  - OpenLinkHub registers `14856: {4, 0, "SCUF PC Controller Dongle V2", nil, scufdongleV2.Init}` (https://github.com/jurkovic-nikola/OpenLinkHub/blob/main/src/devices/devices.go).
  - ZeroCue accepts only the collection with UsagePage 0xFF42, Usage 1 and 64/64/64 caps, prefers `mi_04&col02`, and rejects col01 = 0x0C (https://raw.githubusercontent.com/N7Steve/ZeroCue/HEAD/ZeroCue.DataProbe/Services/WirelessHidDetectionService.cs).
- **In the 3A09 state** both roles collapse into one interface that has FF58 and FF42 only [Mac].
- **Conflict:** B3Mac's wired V1 notes number these the other way round (Consumer = "3", gamepad = "4"). That is most likely macOS enumeration order rather than bInterfaceNumber. Match by usage, never by interface number.

**Other identity facts**
- **Paired controller [3A08-code]:**
  - Querying the paired controller's PID (`02 09 02 12`) is expected to return 0x3A05, the wired Envision Pro V2 PID (OpenLinkHub `getDevices`).
  - On a wired 3A05, `02 08 02 12` really returns `01 00 02 00 05 3A` [SCUF-hw-log].
  - No relayed (channel 0x09) reply through a 3A08 has been captured.
- **Second receiver PID 3A09 (what triggers it is disputed):**
  - **What ZeroCue says** (https://raw.githubusercontent.com/N7Steve/ZeroCue/main/README.md, https://github.com/N7Steve/ZeroCue/blob/main/ZeroCue.DataProbe/Services/SupportedScufDeviceProfile.cs):
    - ZeroCue is the only public source for 1B1C:3A09. It has listed it since its first public commit (2026-07-22).
    - It labels 3A08 "base" / "receiver-base" and 3A09 "active" / "controller-active". It calls a 3A08→3A09 transition "normal" and says the two states are mutually exclusive.
    - Its README never says what triggers the change.
    - It describes 3A09 as a whole-device HID state, not DFU. One OUT 0x01 / IN 0x81 pipe carries commands, ACKs and, according to a code comment only, controller input.
    - ZeroCue also runs full sessions in the 3A08 state, reading input from MI_03, so by its account input flows in both states.
  - **Evidence that the composite 3A08 is the normal linked state:**
    - In OLH #256 the maintainer predicted the ID "will change once controller is connected via Slipstream". The reporter switched to Slipstream, the controller worked, and 3A08 was still the only identity. The prediction was contradicted.
    - OLH supports V2 only as 3A08. No OLH file or issue mentions 3A09.
    - Linux V1 users with a working wireless controller (OLH #402, #436) saw only 434E.
    - Scuf2Switch [V1-measured]: the composite 434E means the controller is awake and linked, and the HID-only 5046 means it is asleep or absent. The switch is a full re-enumeration.
    - ZeroCue's own V1 5046 logs [SCUF-hw-log]: channel 0x08 commands were answered, every channel 0x09 command timed out, and GET 0x36 returned 0. That is consistent with no controller being reachable.
  - **Hints that host software can trigger the switch [inferred]:**
    - In one ZeroCue log the receiver was in 3A09 while `Corsair.Service` was running.
    - ZeroCue commit 0d7c111 handles the PID flipping during driver install (https://github.com/N7Steve/ZeroCue/commits/main).
    - iCUE is installed on this Mac.
  - **Analogy:** the SCUF Valor Pro on Corsair's adaptor enumerates "in two stages", 3A1E then 3A20 (https://github.com/jurkovic-nikola/OpenLinkHub/issues/486).
  - No Windows hardware-ID database lists 3A09, and no vendor INF binds it.
  - **The app must handle both PIDs and a re-enumeration mid-session.**
- **Linux passive read on 3A08 [3A08-reported, one owner]:**
  - besseddrest/my-padctl@120b4635 (https://github.com/besseddrest/my-padctl/blob/main/devices/scuf-envision-pro-v2.toml) maps vid 0x1b1c / pid 0x3a08, interface 3, 16-byte reports with byte0 == 0x06.
  - It has no `[device.init]` block, and padctl sends nothing to a device unless one is configured.
  - The owner reported playing in padctl issue #514 (padctl v0.1.26 on Arch), where Steam recognised padctl's output "as a Dualsense Edge". There was no Xbox mode.
  - #514 does not name 1b1c:3a08 and has no log. The only tie to 3A08 is the TOML's pid, which has no capture-provenance comment. Reviews disagree on whether the title says "Wireless".
  - Caveats: the unit was refurbished and may keep iCUE remaps, and nobody ruled out an earlier iCUE or OLH session leaving state behind.
  - The port, padctl PR #521, is still open and says "SCUF hardware has not been tested here". Its Home = bit 11 is wrong (bit 11 is G1). https://github.com/BANANASJIM/padctl/pull/521
- **Windows [driver binding confirmed; XInput role inferred]:**
  - treexy confirms the following:
    - 3A08 MI_00 is "SCUF Audio".
    - 3A08 MI_03 is "SCUF ENVISION Controller", in both the HID and System classes.
    - The binding comes from `scufdriver5.inf`: v1.0.97.0 in the HID listing, v1.0.100.0 (2024-05-16) in the System listing.
    - The INF binds MI_03 of 3A04, 3A05, 3A08, 434B, 434D and 434E. It does not list 3A09 or 5046.
    - Sources: https://treexy.com/products/driver-fusion/database/human-interface-devices/scuf/envision-controller/ · https://treexy.com/products/driver-fusion/database/system/scuf/envision-controller/ · https://treexy.com/products/driver-fusion/database/id/usb/vid_1b1c/pid_3a08/
  - A ZeroCue log shows MI_03 on `Scufdriver5` (System class) and MI_04 on `HidUsb`. ZeroCue issue #2 also mentions "Scufdriver6" on interface 0.
  - [inferred] XInput most likely comes from this layered driver on MI_03, but no source says so.
  - No source shows an Xbox vendor-class (0xFF/0x5D) interface, so macOS gets no XInput path.
  - iCUE runs the controller in software mode. Onboard ("Hardware") mappings apply only when iCUE has quit.
  - There are 3 onboard slots (blue, red, green). Only paddles and SAX buttons can be hardware-mapped. Saving profiles needs wired USB-C.
  - A rear switch selects USB or Slipstream mode (OpenLinkHub #256).
- **FCC and hardware (V1-era grants; nothing ties them to the V2 receiver):**
  - The real grants are under Corsair's code 2AAFM:
    - Dongle 2AAFM-SG601-05 ("DONGLE"): granted 2023-05-16, §15.249, GFSK, 2401–2478 MHz. https://fccid.io/2AAFM-SG601-05
    - Controller 2AAFM-SG601-02: granted 2023-05-10, §15.249, GFSK at 1/2 Mbps, 2402–2480 MHz. https://fccid.io/2AAFM-SG601-02
  - SCUF's quick-start guide prints "2AGLM-SG601-02 / -05". Those IDs do not exist: 2AGLM (Scuf Gaming Europe Ltd) has only five older IDs, none of them SG601 (https://fccid.io/2AGLM).
  - **Dongle chips** (from the internal photos):
    - Radio: Nordic nRF52832 (QFAB) with a Skyworks SKY66110-11 front-end, two ceramic antennas, and SWD/UART pads.
    - USB side: a Dialog DA14195, a USB 2.0 audio SoC.
    - The nRF52832 has no USB, so the DA14195 is the USB device and bridges to the radio [inferred]. That fits the receiver's USB Audio interfaces.
    - https://fccid.io/2AAFM-SG601-05/Internal-Photos/Internal-Photos-6532760
  - **Controller chips:** an ST STM32WB55 plus its own DA14195. The link is proprietary 2.4 GHz under §15.249, not Bluetooth.
  - **No V2 grant found:** there is no separate FCC ID for the V2 (2025) controller or for the 3A08 receiver among Corsair's 109 2AAFM IDs (https://fccid.io/2AAFM). Only the label on this receiver can settle which grant it ships under.
  - **Codename:** the pre-release codename was "GENI". The FCC manual calls the receiver "Slipstream Dongle (GENI Pro only)". https://fccid.io/2AAFM-SG601-05/User-Manual/Users-Manual-2-6532754
  - **Firmware updates:**
    - iCUE updates both the controller and the receiver. This comes from a search snippet; the page itself returned 403. https://help.corsair.com/hc/en-us/articles/20234992914957-Envision-Controller-iCUE-Overview
    - SCUF says to update the controller wirelessly, then the receiver: https://customercare.scufgaming.com/hc/en-us/articles/30393776726157-How-to-Troubleshoot-Firmware-Issues-on-Envision-Pro
    - A dongle went into a boot loop on its first update (OLH #223), so an update or boot mode exists. Its PID is unpublished, and nothing ties it to 3A09.

---

## 2. The Slipstream / Bragi control protocol

### 2a. Generic Corsair Bragi (ckb-next, OpenRGB) [generic]
- **Frame:** `[magic][cmd][args…]`. Keyboards and mice use no HID report ID. ckb-next uses EP OUT 0x04 / IN 0x84. OpenRGB matches interface 1 with usage page 0xFF42.
  - magic is 0x08 for the device itself or the receiver.
  - A child behind a receiver is addressed as `0x08 | slot`, so slot 1 is 0x09 (ckb-next `usb_bragi.c`: `pkt[0] |= bragi_child_id`; OpenRGB `WRITE_WIRED_ID 8`, `WRITE_WIRELESS_ID 9`).
- **Commands** (`bragi_proto.h`): SET 0x01, GET 0x02, CLOSE_HANDLE 0x05, WRITE_DATA 0x06, CONTINUE_WRITE 0x07, READ_DATA 0x08, PROBE_HANDLE 0x09, OPEN_HANDLE 0x0D. A bare 0x12 is a poll or heartbeat.
- **Properties:** 0x01 poll rate, 0x02 brightness, 0x03 mode (1 = HW, 2 = SW), 0x0F battery level, 0x10 battery status, 0x11 VID, 0x12 PID, 0x13 app firmware, 0x14 bootloader firmware, 0x15/0x16 radio firmware, 0x36 sub-device bitfield, 0x41 HW layout.
- **SET frame:** `[magic] 01 <prop> 00 <val lo> <val hi>`.
- **Reply:** `[magic][cmd echo][status][value LE…]`. ckb-next checks `response[1]==0x12`, status in [2], value in [3..5]. ERROR_NOTSUPPORTED is 0x05.
- **Multiplexing:**
  - GET 0x36 returns a slot bitfield (bits 1–7). For each set bit, GET 0x11 and 0x12; a value of 0xFFFF means the slot is empty.
  - On the SCUF V1 dongle (5046), GET 0x36 returned 0 while every channel 0x09 command timed out [SCUF-hw-log]. That is consistent with "no linked child" [inferred].
  - Notification 0x36 (`buf[2]==0x36`, new bitfield at `buf[4]`) triggers re-enumeration.
  - OpenRGB retries `GetAddress(0x12)` 8× at 120 ms because a child that has just woken answers 0.
- **Poll cadence:** ckb-next polls every 50 s ("CUE polls devices every 52 seconds").
- Sources: https://raw.githubusercontent.com/ckb-next/ckb-next/master/src/daemon/bragi_proto.h, https://raw.githubusercontent.com/ckb-next/ckb-next/master/src/daemon/usb_bragi.c, https://gitlab.com/CalcProgrammer1/OpenRGB/-/raw/master/Controllers/CorsairPeripheralV2Controller/CorsairPeripheralV2Controller.cpp

### 2b. Generic Slipstream receivers in OpenLinkHub (keyboards and mice, NOT SCUF) [generic]
- `slipstream.go` sends commands on interface 1 and gets notifications on interface 2. The header is `[00][08][cmd]`, with no report ID.
- **Device list:** command/resource 0x24, read through the handle dance `05 01` / `0D 00` / `09 00` / `08 00`. The reply has the channel count at [5], then for each device: VID LE, PID LE (+4), type (+6), id length (+7), then the id.
- **Connection notification:** `data[1]=01 data[2]=36`, status at `data[4]` (02 online, 00 offline), PID LE at `data[10:12]`.
- `slipstreamV2.go` uses yet another header (`[00][tgt][01][cmd]`, heartbeat GET 0xE1).
- Source: https://raw.githubusercontent.com/jurkovic-nikola/OpenLinkHub/main/src/devices/slipstream/slipstream.go
- **Relevance [inferred]:** ZeroCue's iCUE replay on 3A08 sends `02 08 0D 00 24` and `02 08 0D 00 36`, the same resource IDs. The wired 3A05 answers OPEN on 0x24/0x36/0x25 with `01 00 0D 01` [SCUF-hw-log]. Nobody has decoded the device-list or connection-status contents for the SCUF.

### 2c. SCUF V2 variant [3A08-code for the framing; reply layout confirmed on other SCUF hardware]

The framing comes from code for 3A08 and was cross-checked with HeadsetControl PR #570 on the Virtuoso XT. The reply layout has been confirmed on real SCUF hardware [SCUF-hw-log], but not on 3A08.

**Host → device: HID output report 0x02, 64 B, on the FF42/1 collection**

The collection is on IF4 in the 3A08 state, or on the single interface in the 3A09 state [Mac descriptor; inferred].
```
02 <tgt> <cmd> <args…> 00…            tgt: 08 = receiver, 09 = paired controller (hard-coded; OLH never enumerates slots)
```
- hidapi writes 65 B with a leading 00.
- On macOS, call `IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x02, buf, 64)` with `buf[0]=0x02`. hidapi/mac keeps the ID byte in the buffer when the ID is non-zero [inferred].

**Device → host reply: input report 0x01**
```
01 <src: 00 = answer to channel 08 | 01 = relayed from controller (code only, never captured)> <cmd echo> <status> <value LE @4…>
```
- **Confirmed on hardware [SCUF-hw-log: wired 3A05/3A04, V1 dongle 5046]:**
  - `02 08 02 11 → 01 00 02 00 1C 1B`
  - `02 08 02 12 → 01 00 02 00 05 3A` (3A04: `04 3A`; V1 dongle: `46 50`, its own live PID 0x5046)
  - `02 08 02 13 → 01 00 02 00 00 1C 85` (fw 0.28.133)
  - `02 08 12 → 01 00 12 00`
  - No log shows a 3A08 reply or any `01 01 …` reply.
- **Status codes:**
  - 00 OK.
  - 05 unsupported property (seen).
  - 01 and 03 seen in reply to OPEN `0D`.
  - 09 ("write refused" / ZeroCue "session rejected") appears only in ZeroCue's code and has never been logged.
- The V1 dongle fills r[8..11] with constant filler (`95 63 39 64`). Parse only the expected value length.
- One scout put "target" at byte 1. It is actually the source flag (PR #570 `replySourceFor`; ZeroCue `InitAckChannel=0x00`, `RuntimeAckChannel=0x01`).
- Replies carry no property ID. Drain pending reports before each write, then match `r[0]==01 && r[1]==src && r[2]==cmd`. OpenLinkHub doesn't do this and can mistake a 0x03 event for a reply.
- Sources: https://github.com/Sapd/HeadsetControl/pull/570, https://raw.githubusercontent.com/jurkovic-nikola/OpenLinkHub/main/src/devices/scufdongleV2/scufdongleV2.go, https://github.com/jurkovic-nikola/OpenLinkHub/blob/main/src/devices/scufdongleV2/scufdongleV2.go, https://github.com/N7Steve/ZeroCue/issues/2, https://github.com/user-attachments/files/31308298/zerocue-communication.log

**Device → host events: input report 0x03 (FF42/2)**

Wired logs show `xx` = 00. ZeroCue's code expects 01 (the controller source) for wireless, but that has not been captured.

| Frame | Meaning |
|---|---|
| `03 xx 02 <u32 LE @3..6>` | Button mask (only for keys routed to software). Wired log: `03 00 02 00 00 <buf5> <buf6>`. ZeroCue calls buf5 bits 0x01/0x02/0x40/0x80 "paddles"; OLH's table names those bits LOCK, MENU, S1 and S2. buf6 holds the G-keys |
| `03 xx 0A ?? <LT u16 LE @4> <RT u16 LE @6>` | Triggers, 10-bit, max 0x3FF in wired 3A05/3A04 logs [SCUF-hw-log]. OLH enables them with `SET C0=1` (ZeroCue's replay also sends `02 09 01 C0 00 01`). OLH uses 512 as "pressed" and 450 as release |
| `03 xx 01 0F ?? <batt u16 LE @5>` | Battery, value /10 = % |

Wired G-keys also arrive as report `11 <bitmask>`.

Event-mask bits (OpenLinkHub key table; ZeroCue agrees on G4 = bit 29 and G5 = bit 30, i.e. buf[6] 0x20/0x40):

| Bit | Function |
|---|---|
| 0 | "Left Button" (?) |
| 1–4 | D-pad Up / Down / Left / Right |
| 5–8 | A, X, Y, B (not Xbox order) |
| 9–10 | LB, RB |
| 11–12 | LT, RT |
| 13–14 | LS click, RS click |
| 16 | LOCK |
| 17 | MENU |
| 18–21 | P1–P4 |
| 22–23 | S1, S2 |
| 24 | Power |
| 26–30 | G1–G5 |
| 31 | Profile |

**Command catalogue (bytes after `02 <tgt>`)**

| Purpose | Bytes | Reply / notes |
|---|---|---|
| Heartbeat | `12` | `01 00 12 00` (tgt 08, confirmed wired) / `01 01 12 00` (tgt 09, code only) |
| VID | `02 11` | Wired: `1C 1B` |
| Firmware | `02 13` | Version is r[4].r[5].r[6] (wired 0.28.133, V1 dongle 0.12.53). OpenLinkHub parses the receiver as r[3].r[4].LE16(r[5:7]), but r[3] is the status byte, so its major version always reads 0 (bug) |
| PID | `02 12` | On tgt 08 the device returns its own live PID. On tgt 09 the paired PID is LE r[4..5], expected 0x3A05 |
| Battery | (09) `02 0F` | LE r[4..5], ‰ (wired returned 940) |
| Charge state | (09) `02 10` | r[4] (wired on USB: 1) |
| Mode | `01 03 00 {01 HW \| 02 SW \| 04 sleep}`; get `02 03` | Writes need SW mode. Wired readback was 1, then 2 after the SET |
| Sleep timer (?) | `02 0E` | Wired: 600000 (probably ms) |
| Trigger events on | (09) `01 C0 00 01` | Enables 0x0A events |
| Motor strength | (09) `01 84 00 <0–100>`, `01 85 00 <0–100>` | Scaling only, not motor drive |
| Brightness | (09) `01 02 00 <LE16 0–1000>`; get `02 02` | Wired default 1000 |
| Eco off | (09) `01 0B 00 00` | G5 toggles eco in hardware |
| Dead zones | init props 80/81/7E/7F; min/max 7C/DD (LS), 7D/DE (RS), 7A/DB (LT), 7B/DC (RT), values 0–15 | |
| Handles | OPEN `0D <h> <res>`, PROBE `09 <h>`, WRITE `06 <h> <len LE16> 00 00 <data>`, CONTINUE `07 <h> <data>` (60-byte chunks), READ `08 <h>`, CLOSE `05 01 <h>` | Wired PROBE returned e.g. `08 0E 08`. Wired READ chunks contain zlib (`78 DA`) profile blobs and "ENVI…" strings |
| Key assignment | `0D 01 02` → `06 01 20 00 00 00` + 32 bytes → `05 01 01` | Byte i = 1 keeps the onboard function; 0 routes bit i to 0x03 events |
| Analog curves | `0D 01 2B` → `09 01` → `06 01 <len> 00 00 26 00 <n> {idx, npts, (x,y)…}` → `07 01…` → `05 01 01` | |

**Sequences**
- **OpenLinkHub init** (https://raw.githubusercontent.com/jurkovic-nikola/OpenLinkHub/main/src/devices/scufenvisionproV2W/scufenvisionproV2W.go):
  - Receiver: GET 13, then SET mode=SW. Controller: GET 12, then heartbeat.
  - On controller connect, in order:
    - GET 13, SET mode=SW, GET 0F.
    - OPEN `0D 00 01`, SET C0=1, LED write, SET 84/85.
    - Dead zones, curve, key assignment.
    - Sleep settings: `0D`, `0E`, GET 40, `01 03 00 04`.
    - `01 0B 00 00`, then open IF3.
  - Heartbeat 0x12 to both targets every 10 s. On exit, `01 03 00 01` (HW mode) on the receiver.
  - OpenLinkHub's default key assignment zeroes D-pad, face buttons, bumpers, triggers and stick clicks. If an app dies after that write, those buttons may lose their native output. Whether this also removes them from report 0x06 is unverified.
- **ZeroCue:**
  - Replays a captured iCUE session of about 106–107 entries over about 6 s (different reads give different counts).
  - It starts `02 08 02 03 | 02 08 01 03 00 02 | 02 08 0D 00 24 | 02 08 0D 00 36 | 02 08 01 03 00 01 …`, switches to tgt 09 at about 623 ms, and ends `… 02 09 07 01 42 64 64 | 02 09 05 01 01`.
  - It opens the MI_03 input reader before the replay.
  - Its `EnterSoftwareModeAsync` is really a key-mask write (all 01 except index 30 = 00, to stop G5's eco toggle), re-applied every 45 s.
  - Heartbeat `02 09 12 00` at 750 ms, then every 2 s, skipped if input arrived in the last 5 s. A radio keepalive `02 08 12 00` is defined; an earlier read found it disabled in the session loop.
  - Files: https://raw.githubusercontent.com/N7Steve/ZeroCue/HEAD/ZeroCue.DataProbe/Services/WirelessInitializationSequence.cs, https://raw.githubusercontent.com/N7Steve/ZeroCue/main/ZeroCue.DataProbe/Services/DeviceModeController.cs, https://raw.githubusercontent.com/N7Steve/ZeroCue/main/ZeroCue.DataProbe/Services/WirelessSessionController.cs
- **Software-mode lifetime:**
  - One Virtuoso XT dropped back to HW mode "after a few minutes without host traffic". The "≈90 s" figure some summaries quote is actually a sleep-timer limit.
  - Settings written in SW mode persist across power cycles.
  - So send a heartbeat every ≤10 s while in SW mode, and always restore HW mode (PR #570 `SoftwareModeGuard`).

### 2d. How input arrives
1. **HID report 0x06 on IF3, in the 3A08 state, with no host writes.** This is the primary path.
   - [3A08-reported] besseddrest/padctl.
   - [V1-measured] Scuf2Switch.
   - [3A08-code] OpenLinkHub reads sticks there, but only after its SW setup, so it is not evidence for passive input.
   - ZeroCue reads MI_03 on 3A08, but it opens the reader before its replay, so this neither proves nor disproves passive input.
2. **0x03 events on FF42/2**: only in SW mode, and only for keys whose key-assignment byte is 0. Trigger events need `C0=1`.
3. **Consumer report 0x11 on IF4 (3A08 only)**: G3 sends bit0 (vol+), G2 bit1 (vol−), G4 bit2 (mute), each followed by `11 00`. macOS acts on these.
4. **3A09 unified pipe (ZeroCue code only, never logged)**:
   - ZeroCue describes 64-byte transfers carrying up to four 16-byte 0x06 frames at offsets 0, 16, 32 and 48. It keeps the last frame's axes and ORs the buttons across frames.
   - This Mac's 3A09 descriptor declares no report 0x06. Two things are untested: whether the device sends 0x06 frames there, and whether macOS passes an undeclared report ID to an input-report callback.

**Report 0x06, 16 B including the ID.** Measured on the V1 wired pad, the V1 dongle and the V2 wired pad. ZeroCue's 3A08 wireless parser, besseddrest's TOML and OpenLinkHub's stick offsets all use the same decode.
```
idle: 06 00 00 00 00 00 00 00 00 00 00 80 00 00 00 00
[1..2] LX  [3..4] LY  [5..6] RX  [7..8] RY   int16 LE, rest = 0, up/left negative, full ±32767, round gate (~±26.4k per axis on diagonals)
w = b9 | b10<<8 | b11<<16 :  LT = w & 0x3FF   RT = (w>>10) & 0x3FF   hat = w>>20  (0 U,1 UR,2 R,…,6 L,7 UL, 8 = null/centre)
b12: A 01  B 02  X 04  Y 08  LB 10  RB 20  View 40  Menu 80
b13: L3 01 R3 02 Home 04 G1 08 G2 10 G3 20 G4 40 G5 80
b14: Profile 01 (B3Mac only) | rear 08 (right-outer) 10 (right-inner) 20 (left-inner) 40 (left-outer) | SAX-L 80
b15: SAX-R 01
```
- Linux evdev sees this descriptor as ABS_X/Y = left stick, ABS_Z/RZ = right stick, ABS_RX = LT and ABS_RY = RT.
- Triggers peak at about 1010–1023.

**Conflicts in report 0x06**
- **Paddle names:**
  - Scuf2Switch and padctl: b14 bit3 = P1 … bit6 = P4 (padctl numbers them u32 bits 19–22).
  - B3Mac swaps bits 5 and 6 (bit5 = P4, bit6 = P3).
  - ZeroCue: 08 R5, 10 R4, 20 L4, 40 L5.
  - Nobody disputes the bit positions. Label them by position in the UI.
- **Profile echo:**
  - B3Mac (V1 wired) found the factory profile maps P1→A, P2→Y, P3→B, P4→X, SAX-L→LB, SAX-R→RB, and sets the paddle's own bit as well.
  - Scuf2Switch found the bindings differ per profile across 3 profiles. With all profiles cleared, the rear bits arrive alone.
- **Hat:** ZeroCue keeps only the cardinal directions. The HID descriptor declares logical 0–7 with a null state, so odd values are diagonals.
- **Home:** padctl's Home = bit 11 is wrong. Home is b13 bit2 (bit 10 of the u32 at offset 12).
- **Rate:**
  - About 1 kHz over HID on V1 (Scuf2Switch).
  - ZeroCue's comment says "nominally 4 ms" over WinUSB.
  - ZeroCue issue #4 reports about 1000 Hz wired and about 235 Hz wireless through XInput on Windows.

**Rumble [3A08-code]:** output report 0x09 on IF3, 13 B: `09 00 6A 09 00 03 00 00 <L 0–255> <R 0–255> 10 00 EB`.
- The motors latch, so send `…00 00…` to stop.
- One summary said rumble needs the Bragi channel, and padctl #514's author believed it needs iCUE. Both OpenLinkHub and ZeroCue write report 0x09 directly. Bragi 0x84/0x85 only scale intensity.
- The 3A09 descriptor declares no output 0x09, so this path probably doesn't exist in that state [inferred].

**Wired gamepad-interface descriptor (V1 434D, 156 B, captured on macOS; expected to be identical on 3A08 IF3)**

Sources: https://raw.githubusercontent.com/B3Mac/ScufEnvisionPro_macOS/main/docs/PROTOCOL.md, https://github.com/B3Mac/ScufEnvisionPro_macOS/blob/main/docs/PROTOCOL.md
```
06 58 FF 09 01 A1 01 85 58 09 01 15 00 26 FF 00 95 3F 75 08 81 02 85 58 09 01 15 00 26 FF 00 95 3F 75 08 91 02 C0
05 01 09 05 A1 01 A1 00 85 06 09 30 09 31 09 32 09 35 16 00 80 26 FF 7F 36 00 80 46 FF 7F 75 10 95 04 81 02
05 01 09 33 09 34 15 00 26 FF 03 75 0A 95 02 81 02 09 39 15 00 25 07 35 00 46 3B 01 65 14 75 04 95 01 81 42
65 00 05 09 19 01 29 13 15 00 25 01 75 01 95 13 81 02 06 00 FF 09 20 75 0D 95 01 81 02 C0
85 09 15 00 26 FF 00 75 08 95 0C 09 01 91 02 C0
```
- The FF58 collection closes (`C0`) before `05 01 09 05 A1 01`, so the Game Pad is a sibling top-level collection. kem200's "nested" is wrong.
- Usages: the sticks are X, Y, Z and Rz (Z/Rz = right stick), int16. The triggers are Rx and Ry, 10-bit (0–1023). The hat is 4-bit with a null state.
- Only 19 Button usages are declared. Paddles, SAX and Profile sit in a 13-bit vendor field (FF00:0x20), so a generic HID parser such as SDL never sees them as buttons.
- Report 0x09 is a 12-B FF00:1 output.

**IF4 descriptor, 99 B [inferred arithmetic from B3Mac's 154-B wired capture; the prefix is confirmed by Scuf2Switch on the V1 dongle]**
```
Consumer (37):  05 0C 09 01 A1 01 85 11 15 00 25 01 09 E9 09 EA 75 01 95 02 81 02 09 E2 75 01 95 01 81 02 75 01 95 05 81 03 C0
FF42/1   (39):  06 42 FF 09 01 A1 01 85 01 15 00 26 FF 00 75 08 95 3F 09 01 81 02 85 02 95 3F 09 01 91 02 85 0C 95 3F 09 01 B1 02 C0
FF42/2   (23):  06 42 FF 09 02 A1 01 85 03 15 00 26 FF 00 75 08 95 3F 09 01 81 02 C0
```
The 154-B wired version adds a 55-B Telephony (RID 0x12) and LED-output (RID 0x13) block.

---

## 3. Does the receiver push input with no host command?

**Short answer: in the 3A08 state, most likely yes. In the 3A09 state, which this Mac showed most recently, nobody knows, and it looks doubtful.**

**3A08 (composite) state**
- The receiver most likely streams report 0x06 on IF3 continuously, with no handshake. The controller must be on, in Slipstream mode, and linked.
- The data lives in the Game Pad top-level collection that macOS hides behind the FF58 primary usage. FF58 report 0x58 is unrelated vendor traffic.
- Evidence:
  1. [3A08-reported] besseddrest's padctl config has no init. It is author-reported, with no log, and the caveats in §1 apply.
  2. [V1-measured] Scuf2Switch: a Pico USB host sent no OUT or vendor traffic (only `tuh_hid_receive_report`) and received 0x06 at about 1 kHz. It played for minutes with no keepalive.
  3. B3Mac and kem200 read the wired V1 on macOS with plain IOHIDManager and no writes. `AppleUserUSBHostHIDDevice` binds without a driver.
  4. GameControllerDB's Linux mapping for the V1 dongle 434E (https://github.com/mdqinc/SDL_GameControllerDB/pull/759, issue #925) proves that hid-generic builds a gamepad from the V1 dongle's descriptor. No 1B1C entry exists.
  5. OLH #256: the controller was linked and working while the receiver stayed at 3A08.
- **Withdrawn evidence:** Athae1218/Scufpad only adds 3a08 to its udev rules, discovery and an SDL ignore entry, and it requires a `js*` node. It shows no log and warns that a recognised PID doesn't guarantee the same mappings, so it is not evidence.
- ZeroCue's replay and heartbeats exist because it swaps the HID driver for WinUSB and runs software mode. It also opens its reader before the replay. None of this is evidence that the host must speak first.
- SDL and Steam showing no pad on macOS is not evidence against a Game Pad collection, because SDL's IOKit backend checks only the primary usage.

**3A09 (single-interface) state**
- There is no Game Pad, no Consumer collection and no declared report 0x06.
- There are two readings:
  - (a) The controller is asleep, absent or unreachable. This is supported by Scuf2Switch on V1 and by ZeroCue's own 5046 logs.
  - (b) The receiver is "active" and input arrives packed on the unified pipe. This comes from ZeroCue's code and has never been logged.
- Host software may cause the switch [inferred]. iCUE is installed on this Mac.

**Remaining risk:** nobody has published a byte dump of this receiver's 3A08 IF3 descriptor.

**First commands to try, in order:**

0. **Set up the state.**
   - Quit iCUE completely and check that no Corsair process remains. Its dext may stay loaded.
   - Put the rear switch on Slipstream, turn the controller on and press Home.
   - After each change, record the PID with `hidutil list | grep -i 1b1c`. Note which PID appears with the controller off, on and asleep, and with iCUE running versus quit.

1. **Look, no I/O:**
   ```
   hidutil list | grep -i 1b1c
   ioreg -r -c IOHIDDevice -l -w0 | grep -E '"(ProductID|PrimaryUsagePage|PrimaryUsage|DeviceUsagePairs|ReportDescriptor|MaxInputReportSize|MaxOutputReportSize|MaxFeatureReportSize|Transport|LocationID|RequiresTCCAuthorization)"'
   ioreg -p IOUSB -l -w0 | grep -E '"(idProduct|bInterfaceNumber|bInterfaceClass|USB Product Name)"'
   ```
   - **In 3A08**, expect two devices.
     - The FF58 device should list `{UsagePage=1, Usage=5}` in `DeviceUsagePairs`. Its ReportDescriptor should be 156 B, start `06 58 FF` and contain `05 01 09 05 A1 01`.
     - The 0x0C device should be 99 B.
   - **In 3A09**, expect the single 100-B descriptor from §1.
   - B3Mac's `scripts/capture.swift` already dumps descriptors for VID 0x1B1C and can be run unchanged.

2. **Passive read, 3A08 state** (B3Mac's `ControllerService.swift` approach, with the VID changed):
   ```swift
   IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x1B1C, kIOHIDProductIDKey: 0x3A08,
       kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x05] as CFDictionary)   // matches via DeviceUsagePairs
   // on match: IOHIDDeviceOpen(dev, 0); IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, cb, ctx); schedule on a run loop
   ```
   - Always include the VendorID. `validateMatchingTable` rejects some vendor-page tables that lack it [apple-src].
   - The CoreHID equivalent is `DeviceMatchingCriteria(deviceUsages: [GD Game Pad], vendorID: 0x1B1C)`. That `deviceUsages` maps to `DeviceUsagePairs` is inferred.
   - Expect reportID 0x06, length 16, idle `06 00…00 80 00 00 00 00`.
   - **Input Monitoring should not be needed:**
     - The kernel sets `RequiresTCCAuthorization` only on devices that conform to keyboard (1/6), mouse (1/2) or touchpad (0D/05).
     - `IOHIDDeviceOpen` asks TCC only when that key is set [apple-src].
     - This receiver doesn't carry it [Mac].
     - B3Mac's and OJD's docs say otherwise, but the source doesn't support them.
   - **Errors to expect instead:**
     - `kIOReturnExclusiveAccess` (0xE00002C5) if another client, such as iCUE, has seized the device.
     - `kIOReturnNotPrivileged` if the process is not running as the logged-in console user.
   - If length > 16 ever appears, step through it in 16-byte strides.

3. **3A09 state:**
   - Match `{VendorID 0x1B1C, ProductID 0x3A09}`, or primary FF58/1 plus VendorID. There is no 1/5 to match.
   - Open shared and register an input-report callback with a 64-B buffer.
   - Log every report ID and length for 30 s while moving the sticks. Look for 0x58, 0x01, 0x03 and any undeclared 0x06.

4. **Read-only Bragi probes.** Send these on the 0x0C-primary device in 3A08, or on the single device in 3A09. Each is a 64-byte output report with ID 0x02; read replies through an input-report callback on the same device.
   ```
   02 08 12            → 01 00 12 00          (confirmed on wired 3A05)
   02 08 02 11         → 01 00 02 00 1C 1B    (VID)
   02 08 02 12         → receiver's own live PID (V1 dongle answered with its current PID)
   02 08 02 13         → receiver fw at r[4].r[5].r[6]
   02 08 02 36         → linked-subdevice bitfield? (V1 5046 returned 0 while channel 09 timed out)
   02 09 12            → predicted 01 01 12 00 (never captured; timeout = controller not reachable; retry 8×120 ms)
   02 09 02 12         → predicted 01 01 02 00 05 3A   (paired PID 0x3A05)
   02 09 02 0F         → battery ‰ at r[4..5]
   ```

5. **Last resort: software mode** (only with iCUE quit).
   - Send `02 08 01 03 00 02`, then `02 09 01 03 00 02`.
   - Watch for 0x06 on IF3 and 0x03 on FF42/2. Heartbeat both targets every ≤10 s.
   - On exit, always send `02 09 01 03 00 01` and `02 08 01 03 00 01`.
   - Do not write key-assignment (`0D 01 02`) or curve (`0D 01 2B`) blobs at this stage.
   - If even this fails, port ZeroCue's replay and its 3A09 unified-pipe handling.

---

## 4. macOS: publishing the virtual gamepad

### 4a. Routes and the entitlement situation

| Route | What it needs | Reality for personal use |
|---|---|---|
| **CoreHID `HIDVirtualDevice`** (macOS 15+) | `com.apple.developer.hid.virtual.device` (restricted; paid program + capability request) | • DTS recommends this route ("no reason to prefer a DEXT"). There is **no development-only variant** (r.173531752) (https://developer.apple.com/forums/thread/820708).<br>• One request sat at "Submitted" for about 2.5 months (https://developer.apple.com/forums/thread/845599).<br>• Returns nil without the entitlement (B3Mac).<br>• **For any third-party creator, Transport is forced to "Virtual" and HIDVirtualDevice to true.** Only the Apple-private `com.apple.hid.manager.user-access-device` can override this [apple-src: `IOHIDUserDevice.cpp`]. Apple's doc saying the transport "can be any HIDDeviceTransport" holds only for Apple-entitled processes.<br>• Creating one raises an Accessibility (PostEvent) prompt, not Input Monitoring (https://developer.apple.com/forums/thread/820676). |
| `IOHIDUserDeviceCreateWithProperties` (legacy) | Same entitlement | Same forced "Virtual" transport. kem200 fails unsigned. |
| DriverKit dext publishing an IOUserHIDDevice | `driverkit` + `driverkit.family.hid.device`. Per DTS, every DriverKit entitlement has a self-serve dev-only variant | • Needs the paid program, System Extension approval, and runs only on Macs registered in the profile (B3Mac README; planned, not built).<br>• `driverkit.family.hid.virtual.device` is defunct (https://developer.apple.com/forums/thread/843327).<br>• **This is the only route that can publish Transport USB or Bluetooth without the HIDVirtualDevice flag.** Razer's dext on this Mac does exactly that for 045E:028E [Mac].<br>• [inferred] It is also the only route with no approval wait that keeps SIP/AMFI on. |
| SIP off + AMFI off (boot-arg) | Self-added entitlement | • Works: the OP confirmed it in https://developer.apple.com/forums/thread/764540. SIP-off alone does not.<br>• DTS suggests doing this in a VM. Heavy security cost.<br>• [inferred, untested] With AMFI off you could also self-grant `com.apple.hid.manager.user-access-device` and set a non-Virtual transport. |
| **OpenJoystickDriver signed tester build + your own controller record** | None from you | **The fastest way to play today, but only if the receiver sits in 3A08 and step 3.2 works.**<br>• Write `~/Library/Application Support/OpenJoystickDriver/Controllers/1b1c-3a08.json` with `interfaceSignature {usagePage: 65368, usage: 1}`, an input layout for report id 6 / length 16, and `session.rumble` → output 0x09 len 13.<br>• Records cannot do request/response, so this cannot work in 3A09 or SW mode.<br>• OJD reads through IOHIDManager: it matches GD Game Pad by device usage plus exact VID/PID per record, and opens seize-first, falling back to shared.<br>• Its docs say it needs Input Monitoring + Accessibility. Per IOHIDFamily, only Accessibility (for publishing) should apply.<br>• OJD's dext is already installed here.<br>• PolyForm Noncommercial from 0.6.0-alpha.2.<br>• The existing SCUF record is 2E95:434D wired: report 6, page-9 buttons 1–10, X/Y/Z/Rz sticks, Rx/Ry 10-bit, hat. Its gaps (issue #33): buttons 11–19, S1/S2, Y inversion, paddles, output, and wireless.<br>https://github.com/xsyetopz/OpenJoystickDriver/wiki/Controller-Records |
| GCVirtualController / CGEvent keyboard injection | — | GCVirtualController is app-local (the forum OP says so; DTS does not). Keyboard injection plays poorly with games that support gamepads. |

**Recommendation:**
- Build the reader and decoder now. They need no entitlement, and per the IOHIDFamily source they need no Input Monitoring either.
- First settle the 3A08/3A09 state machine (§6.1).
- File the capability request now.
- If 3A08 passive works, play through an OJD record in the meantime.
- Build the CoreHID publisher in a VM with AMFI off, or as a dev-signed dext if you have a paid account. Expect a CoreHID pad to show Transport "Virtual", and design its descriptor for that (§4b).
- A dext is the only way to present USB or Bluetooth.

### 4b. What Steam, SDL and GameController accept (SDL main, checked)

**SDL IOKit backend** (https://raw.githubusercontent.com/libsdl-org/SDL/main/src/joystick/darwin/SDL_iokitjoystick.c)
- The primary collection must be GD page 0x01 with usage 4, 5 or 8.
- Axes are GD X…Wheel, the hat is 0x39, buttons come from page 9.
- Bus is Bluetooth if `kIOHIDTransportKey` starts with "Bluetooth"; otherwise USB.
- Rumble only works through a ForceFeedback plugin, so a CoreHID pad gets no rumble on this path.
- Xbox One VID/PIDs are rejected unless the 360Controller driver owns them.
- A generic usage-5 pad needs a GUID-keyed `SDL_GAMECONTROLLERCONFIG` entry.
- SDL's HIDAPI layer treats VID 0x1B1C as eligible for PlayStation detection, so SDL may send the Sony feature query to the receiver. 0x2E95 is in its Xbox One vendor list (https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapijoystick.c).

**045E:028E (Xbox 360)**
- On macOS, SDL treats `045E:028E` with **version == 0** as Steam's virtual gamepad (`SDL_IsJoystickSteamVirtualGamepad`, verified).
- The IOKit backend rewrites version to 1 for 028E devices that lack `kIOHIDVirtualHIDevice`.
- B3Mac's version 0x0114 avoids the Steam classification. Its code comment that "version 1" is the Steam marker is inaccurate; the marker is version 0.
- This Mac already has Razer's dext-published 028E with no HIDVirtualDevice key. Expect it to show up in controller lists.
- This identity is still unproven end to end.

**GameController handoff** (https://raw.githubusercontent.com/libsdl-org/SDL/main/src/joystick/apple/SDL_mfijoystick.m)
- `GCController_SupportedHIDDevice` returns false for any device with `kIOHIDVirtualHIDevice` = true. So SDL never routes a virtual pad through GameController.
- On macOS 27.4+, physical devices defer to `[GCController supportsHIDDevice:]`.

**SDL HIDAPI Xbox One driver on macOS** (https://raw.githubusercontent.com/libsdl-org/SDL/main/src/joystick/hidapi/SDL_hidapi_xboxone.c)
- It accepts only Bluetooth PIDs: Adaptive 0B0C, Series X BLE 0B13, One S BLE 0B20, Elite 2 BT/BLE, and others.
- With a Bluetooth transport it parses report 0x01 (≥16 B); with any other transport it parses GIP 0x20.
- SDL's mac hidapi maps Transport "USB" to USB and a "Bluetooth" prefix to Bluetooth. Anything else, including "Virtual", becomes unknown. So `is_bluetooth` is false for every CoreHID or IOHIDUserDevice pad, and the GIP path is taken.

**Best-known recipe for GameController and Steam together**
- Source: libvirtualhid PR #208, merged 30 Oct 2026 (https://github.com/LizardByte/libvirtualhid/pull/208, https://github.com/LizardByte/libvirtualhid/blob/master/src/platform/macos/macos_xbox_transport.hpp).
- Testing: checked by hand with GameController. A later review on the PR notes "Steam was not retested". SDL is not stated.
- Identity: `045E:0B13` (or 0B20), version 0x0513.
  - The version is set in code; the PR page states neither the version nor the transport.
  - The broker requests Transport Bluetooth, but the code's own comment ("IOHIDUserDevice exposes its transport as Virtual even when Bluetooth is requested") and the kernel source say the result is "Virtual".
- That is why the descriptor carries two collections:
  - (1) The Xbox BT gamepad collection: input 0x01 and rumble output 0x03. This one is for GameController.
  - (2) A vendor collection FF00/1: GIP input 0x20 (24 B + ID) and output 0x09 (12 B). This one is for SDL and Steam on the GIP path.
- Send report 0x01 and then 0x20 every frame.
- Report 0x01: b1–12 sticks and triggers, b13 hat, b14 A B X Y LB RB View Menu, b15 LS RS Guide, b16 Share.
- Report 0x20:
  - b3 = 0x10 (length).
  - b4: Start/Back/A/B/X/Y in bits 2..7.
  - b5: D-pad, shoulders and stick clicks.
  - b6–9: triggers. b10–17: sticks.
  - b20 = 0x07 (guide command). b24: guide state.
- Guide and Share never surface in GameController (PR #208).
- Field data from OJD (https://github.com/xsyetopz/OpenJoystickDriver/wiki/Playing-Games):
  - 0B13 without the 0x20 collection works in GameController, but Steam shows no input.
  - 0B0C over USB GIP works in SDL and Steam, but GameController doesn't see it.
- Paddles: none of these identities expose paddles. The Elite 2 BT PIDs are on SDL's list and could carry paddles [untested idea].
- Steam publishes its own `045E:028E "GamePad-N"` virtual pad, so expect a possible double controller (see ZeldaWWHDRecomp PR #348 for de-duplication).

---

## 5. Code to reuse or port (ranked)

1. **B3Mac/ScufEnvisionPro_macOS** (Swift, closest fit). Verified on the wired V1 only.
   - `Sources/ScufBridge/ControllerService.swift`: matches `{VendorID, DeviceUsagePage 1, DeviceUsage 5}`, registers the input-report callback, and seizes the Consumer interface (`{VendorID, PrimaryUsagePage 0x0C}` + `kIOHIDOptionsTypeSeizeDevice`). Change VID 0x2E95 → 0x1B1C and the PID.
   - `Sources/ScufCore/EnvisionDecoder.swift`: decoder and the paddle-echo de-dup `attribute()`.
   - `Sources/ScufBridge/VirtualGamepad.swift` and `Sources/ScufCore/VirtualPadReport.swift`: CoreHID publisher. Swap the identity per 4b and expect Transport "Virtual".
   - `scripts/capture.swift`: descriptor and report dumper for VIDs 0x2E95/0x1B1C. It runs unchanged against 3A08/3A09 (https://github.com/B3Mac/ScufEnvisionPro_macOS/blob/main/scripts/capture.swift).
2. **MichaelRColton/Scuf2Switch**:
   - `include/scuf_report.h` and `src/scuf_parse.c`: C decoder built from measurements.
   - `src/usb_host.c`: sends no OUT. It uses a 250 ms report-freshness gate instead of trusting mount state.
   - `docs/protocol.md`: includes the 434E/5046 identity switch.
3. **N7Steve/ZeroCue** (promoted, because it is the only code for the 3A09 state):
   - `SupportedScufDeviceProfile.cs` (3A08/3A09 identities and pipes)
   - `ScufDeviceService.WirelessInput.cs` (packed-frame merge)
   - `ScufAckReader.cs` (ACK matching)
   - `WirelessInitializationSequence.cs` (replay)
   - `WirelessSessionController.cs` (heartbeat and ACK)
   - `DeviceModeController.cs` (G5 suppression)
   - `ScufDeviceService.Usb.cs` (wired 3A05 handshake: SET_REPORT wValue 0x0303 `03 1D 01`, 0x03CC `CC 60`, SET_IDLE(0) on IF3/IF4)
   - Its issue #2 and #3 log attachments hold real reply bytes; use them as test vectors.
4. **LizardByte/libvirtualhid**: `src/platform/macos/macos_xbox_transport.hpp` (BT + GIP descriptor, report builders, rumble re-wrap), `macos_broker_client.cpp`, `docs/macos-gamepad.md`, and the unit tests.
5. **jurkovic-nikola/OpenLinkHub** (GPL-3; port the ideas, not the code, unless your app is GPL):
   - `src/devices/scufdongleV2/scufdongleV2.go`: transfer framing, init, heartbeat, 0x03 listener.
   - `src/devices/scufenvisionproV2W/scufenvisionproV2W.go`: `Connect()`, the command table, `setupKeyAssignment`, `loadKeyAssignments` (bit table), `TriggerHapticEngineExternal` (rumble).
6. **Sapd/HeadsetControl PR #570** `lib/devices/corsair_virtuoso_xt.hpp`: a clean Bragi transaction layer (`discardStaleReports`, `readReply` filter, `SoftwareModeGuard`).
7. **xsyetopz/OpenJoystickDriver**: no code to port. Use it as the record-based output path (issue #33, and the record schema in `Resources/Schemas/controller.schema.json`). Worth reading:
   - `HIDDeviceStream.swift`: matching.
   - `HIDInputClaim.swift`: seize first; a second open by the same client is ignored.
   - `IOHIDVirtualDevicePublisher.swift`.
8. **apple-oss-distributions/IOHIDFamily** (reference only):
   - `IOHIDDeviceClass.m`: the TCC check.
   - `IOHIDLibUserClient.cpp`: seize rules.
   - `IOHIDDevice.cpp`: usage pairs and `validateMatchingTable`.
   - `IOHIDUserDevice.cpp`: forced Virtual transport.
9. **ckb-next** `bragi_proto.h`: constants. `bragi_update_dongle_subdevs`: 0x36 slot enumeration, if you ever want to replace the hard-coded 0x09.
10. **kem200/ScufControllerMac**: `VirtualGamepad.swift` (IOHIDUserDevice variant) and `EnvisionConstants.swift` (SDL mapping string).
11. **ChaseDRedmon/Scufpad**:
    - `tests/fixtures/envision-v2-usb.json`: raw wired 3A05 reports for every control, usable as decoder unit-test vectors.
    - `crates/scufpad/src/discovery.rs`: requires report 6 with a 120-bit input field on interface 03.
12. **padctl** `devices/scuf/envision-pro-v2.toml`: field map only. Fix Home, the 10-bit LT and the X/Y swap.
13. **SDL_GameControllerDB** lines 1776–1778: the V1 Linux mapping (434B/434D/434E). G1–G5 are buttons 11–15 and Profile is button 16.

---

## 6. Open questions to settle with a live capture on the Mac

1. **Identity state machine (do this first).**
   - Register matching and removal callbacks for VID 0x1B1C with any PID.
   - Log PID, interfaces and descriptor in each of these conditions:
     - iCUE running, and iCUE fully quit.
     - Controller off, on, and left idle until it sleeps.
     - Rear switch flipped to USB.
     - USB-C plugged in.
   - Which PID appears with the controller linked and iCUE quit? Do the audio interfaces come and go with 3A08? Does `02 08 02 12` return the live PID?
2. **Descriptor match (3A08 state).**
   - Dump `ReportDescriptor` and `DeviceUsagePairs` for both IOHIDDevices.
   - Expect the FF58 device to be 156 B, byte-identical to the §2d hex, with pairs {FF58/1, 1/5}.
   - Expect the 0x0C device to be 99 B, matching §2d, with pairs {0C/1, FF42/1, FF42/2}.
   - Also run `ioreg -p IOUSB -l -w0` and confirm that bInterfaceNumber 3 = FF58 and 4 = 0x0C.
3. **3A09 traffic.**
   - With the controller on and the receiver in 3A09, does any report arrive unprompted?
   - Does an undeclared 0x06, packed in 64-B transfers, ever reach the callback?
   - Does GET 0x36 return non-zero? Do channel 09 commands answer?
4. **Passive stream (3A08).**
   - Open the 1/5-matched device with no writes and log every input report for 30 s idle, then press A.
   - Expect ID 0x06, 16 B, b12 = 0x01 on A.
   - Note any open error: exclusiveAccess means iCUE holds a seize.
5. **Field verification.**
   - Press each control alone and log the diff: Home → b13 0x04 (not 0x08), G1–G5, Profile → b14 0x01, and each paddle and SAX → b14/b15 bits.
   - Push LY up and expect a negative value. Press up + right and expect hat = 1.
   - Pull LT fully and record the maximum (expect about 1010–1023).
6. **Rate and packing.**
   - Timestamp the callbacks. Is the rate about 1 kHz, about 250 Hz, or about 235 Hz?
   - Does any callback deliver length > 16 (packed frames)?
7. **Profile echo.**
   - Press each paddle and SAX in profiles 1, 2 and 3. Record which standard bit rises with it, to decide between de-duplicating in software and clearing the onboard bindings.
8. **Consumer interface (3A08).**
   - Open the 0x0C device without seizing. G2, G3 and G4 should produce `11 02` / `11 01` / `11 04` and change the system volume.
   - Re-open with `kIOHIDOptionsTypeSeizeDevice` and confirm the volume no longer changes.
   - Per the source, the seizer can still send `IOHIDDeviceSetReport` on report 0x02; only other clients are locked out [apple-src]. Verify it.
   - With CoreHID, call `seizeDevice()` before `monitorNotifications`. There is no unseize; deinit the client to release it.
9. **Keepalive.** Read passively for at least 15 minutes in HW mode with no writes, including periods of no touch. Expect continuous reports and no drop or PID change.
10. **Bragi probes.**
    - Send the read-only commands from §3 step 4.
    - Record each exact reply, latency and status. In particular: is r[1] = 00 / 01 as predicted? Is the paired PID 0x3A05? What does GET 0x36 on 08 return?
11. **Software mode.**
    - After `01 03 00 02` on 08 and 09, does report 0x06 keep flowing? Do 0x03 events appear without a key-assignment write?
    - After `01 C0 00 01`, is the wireless trigger full scale 0x3FF, as it is on wired?
    - With heartbeats stopped, how long until the device reverts to HW mode? Watch for a status on a test SET; 0x09 is predicted but has never been observed.
    - Restore with `01 03 00 01` afterwards.
12. **Rumble.**
    - In HW mode with no Bragi traffic, send output report 0x09 `09 00 6A 09 00 03 00 00 80 80 10 00 EB` on the FF58 device. Expect the motors to run. Then send L = R = 00.
    - Repeat with 0x84/0x85 at 100 to check the scaling.
13. **Virtual pad acceptance (once publishing works).**
    - Test each candidate identity (0B13 dual collection, 028E v0x0114, generic 1/5) against SDL3 `testcontroller`, Steam (Big Picture → Controller), `GCController.controllers()`, and an SDL2 game.
    - Confirm in ioreg that a CoreHID pad shows Transport "Virtual".
    - Note extra controllers: Steam's "GamePad-N" and Razer's dext-published 028E.
14. **Wired path (later).**
    - Plug in USB-C and expect 1B1C:3A05 with the same 156-B gamepad interface (IF4 is 154 B there).
    - On wired, Bragi uses target 0x08 only, which ZeroCue logs confirm.
    - ZeroCue's wired path also sends SET_REPORT 0x0303 `03 1D 01`, 0x03CC `CC 60` and SET_IDLE(0). Whether macOS needs any of this is unknown.
15. **Regulatory label.** Read the FCC/IC ID printed on this receiver, to tell whether it ships under the 2023 SG601-05 grant.

---

## 7. Sources

**Device protocol and drivers**
- OpenLinkHub: https://github.com/jurkovic-nikola/OpenLinkHub/blob/main/src/devices/devices.go · https://raw.githubusercontent.com/jurkovic-nikola/OpenLinkHub/main/src/devices/scufdongleV2/scufdongleV2.go · https://github.com/jurkovic-nikola/OpenLinkHub/blob/main/src/devices/scufdongleV2/scufdongleV2.go · https://raw.githubusercontent.com/jurkovic-nikola/OpenLinkHub/main/src/devices/scufenvisionproV2W/scufenvisionproV2W.go · https://raw.githubusercontent.com/jurkovic-nikola/OpenLinkHub/main/src/devices/slipstream/slipstream.go · https://raw.githubusercontent.com/jurkovic-nikola/OpenLinkHub/main/docs/scuf-controller.md · https://github.com/jurkovic-nikola/OpenLinkHub/issues/256 · https://github.com/jurkovic-nikola/OpenLinkHub/issues/486 · https://github.com/jurkovic-nikola/OpenLinkHub/issues?q=scuf
- ZeroCue: https://github.com/N7Steve/ZeroCue · https://raw.githubusercontent.com/N7Steve/ZeroCue/main/README.md · https://github.com/N7Steve/ZeroCue/blob/main/README.md · https://github.com/N7Steve/ZeroCue/commits/main · https://raw.githubusercontent.com/N7Steve/ZeroCue/main/ZeroCue.DataProbe/Services/SupportedScufDeviceProfile.cs · https://github.com/N7Steve/ZeroCue/blob/main/ZeroCue.DataProbe/Services/SupportedScufDeviceProfile.cs · https://raw.githubusercontent.com/N7Steve/ZeroCue/HEAD/ZeroCue.DataProbe/Services/WirelessHidDetectionService.cs · https://github.com/N7Steve/ZeroCue/blob/main/ZeroCue.DataProbe/Services/WirelessHidDetectionService.cs · https://raw.githubusercontent.com/N7Steve/ZeroCue/main/ZeroCue.DataProbe/Services/WirelessSessionController.cs · https://raw.githubusercontent.com/N7Steve/ZeroCue/HEAD/ZeroCue.DataProbe/Services/WirelessInitializationSequence.cs · https://raw.githubusercontent.com/N7Steve/ZeroCue/main/ZeroCue.DataProbe/Services/ScufDeviceService.WirelessInput.cs · https://github.com/N7Steve/ZeroCue/blob/main/ZeroCue.DataProbe/Services/ScufDeviceService.WirelessInput.cs · https://raw.githubusercontent.com/N7Steve/ZeroCue/main/ZeroCue.DataProbe/Services/DeviceModeController.cs · https://raw.githubusercontent.com/N7Steve/ZeroCue/HEAD/ZeroCue.DataProbe/Services/WirelessWinUsbAggressiveSessionProbe.cs · https://github.com/N7Steve/ZeroCue/blob/main/ZeroCue.DataProbe/Services/WirelessWinUsbAggressiveSessionProbe.cs
- ZeroCue issue logs (real SCUF replies): https://github.com/N7Steve/ZeroCue/issues/2 · https://github.com/user-attachments/files/31308298/zerocue-communication.log · https://github.com/user-attachments/files/31324864/zerocue-communication.log · https://github.com/user-attachments/files/31439037/zerocue-communication.log
- ckb-next: https://github.com/ckb-next/ckb-next · https://raw.githubusercontent.com/ckb-next/ckb-next/master/src/daemon/bragi_proto.h · https://raw.githubusercontent.com/ckb-next/ckb-next/master/src/daemon/usb_bragi.c
- OpenRGB: https://gitlab.com/CalcProgrammer1/OpenRGB/-/raw/master/Controllers/CorsairPeripheralV2Controller/CorsairPeripheralV2Controller.cpp
- HeadsetControl Bragi PR: https://github.com/Sapd/HeadsetControl/pull/570
- padctl: https://github.com/BANANASJIM/padctl/pull/521 · https://raw.githubusercontent.com/BANANASJIM/padctl/feat/scuf-envision-pro-v2/devices/scuf/envision-pro-v2.toml · besseddrest/my-padctl@120b4635 `devices/scuf-envision-pro-v2.toml` (https://github.com/besseddrest/my-padctl/blob/main/devices/scuf-envision-pro-v2.toml)
- Scuf2Switch: https://github.com/MichaelRColton/Scuf2Switch/blob/main/docs/protocol.md · https://github.com/MichaelRColton/Scuf2Switch/blob/main/include/scuf_report.h
- B3Mac: https://raw.githubusercontent.com/B3Mac/ScufEnvisionPro_macOS/main/docs/PROTOCOL.md · https://github.com/B3Mac/ScufEnvisionPro_macOS/blob/main/docs/PROTOCOL.md · https://raw.githubusercontent.com/B3Mac/ScufEnvisionPro_macOS/main/docs/capture-2026-10-19.txt · https://raw.githubusercontent.com/B3Mac/ScufEnvisionPro_macOS/main/Sources/ScufBridge/ControllerService.swift · https://github.com/B3Mac/ScufEnvisionPro_macOS/blob/main/Sources/ScufBridge/ControllerService.swift · https://raw.githubusercontent.com/B3Mac/ScufEnvisionPro_macOS/main/Sources/ScufBridge/VirtualGamepad.swift · https://raw.githubusercontent.com/B3Mac/ScufEnvisionPro_macOS/main/Sources/ScufCore/VirtualPadReport.swift · https://github.com/B3Mac/ScufEnvisionPro_macOS/blob/main/scripts/capture.swift
- kem200: https://raw.githubusercontent.com/kem200/ScufControllerMac/HEAD/README.md · https://raw.githubusercontent.com/kem200/ScufControllerMac/HEAD/docs/protocol.md
- Scufpad: https://raw.githubusercontent.com/ChaseDRedmon/Scufpad/HEAD/tests/fixtures/envision-v2-usb.json · https://github.com/ChaseDRedmon/Scufpad/blob/main/crates/scufpad/src/discovery.rs · https://raw.githubusercontent.com/Athae1218/Scufpad/master/README.md · https://github.com/Athae1218/Scufpad/blob/main/src/Scufpad/Discovery/DeviceDiscovery.cs
- Dead or empty: https://github.com/Tealdragon204/scuf-envision-pro-V2-Linux (404) · https://linux-hardware.org/?id=usb:1b1c-3a08 (404)
- SDL_GameControllerDB: https://github.com/mdqinc/SDL_GameControllerDB/issues/925 · https://github.com/mdqinc/SDL_GameControllerDB/pull/759 · https://raw.githubusercontent.com/mdqinc/SDL_GameControllerDB/master/gamecontrollerdb.txt
- Windows driver listings: https://treexy.com/products/driver-fusion/database/human-interface-devices/scuf/envision-controller/ · https://treexy.com/products/driver-fusion/database/system/scuf/envision-controller/ · https://treexy.com/products/driver-fusion/database/id/usb/vid_1b1c/pid_3a08/
- SCUF and Corsair docs: https://www.scufgaming.com/us/en/gaming/products/pc/envision/ · https://customercare.scufgaming.com/api/v2/help_center/en-us/articles/23530811859085.json · https://customercare.scufgaming.com/hc/en-us/articles/30393776726157-How-to-Troubleshoot-Firmware-Issues-on-Envision-Pro · https://help.corsair.com/hc/en-us/articles/20234992914957-Envision-Controller-iCUE-Overview
- FCC: https://fccid.io/2AAFM-SG601-05 · https://fccid.io/2AAFM-SG601-05/Internal-Photos/Internal-Photos-6532760 · https://fccid.io/2AAFM-SG601-05/User-Manual/Users-Manual-2-6532754 · https://fccid.io/2AAFM-SG601-02 · https://fccid.io/2AAFM · https://fccid.io/2AGLM

**macOS HID, virtual HID, SDL and Steam**
- Apple IOHIDFamily source (tag 2238.100.59): https://github.com/apple-oss-distributions/IOHIDFamily/blob/IOHIDFamily-2238.100.59/IOLib/IOHIDDeviceClass.m · https://github.com/apple-oss-distributions/IOHIDFamily/blob/IOHIDFamily-2238.100.59/IOHIDFamily/IOHIDLibUserClient.cpp · https://github.com/apple-oss-distributions/IOHIDFamily/blob/IOHIDFamily-2238.100.59/IOHIDFamily/IOHIDUserDevice.cpp
- Apple CoreHID docs: https://developer.apple.com/documentation/corehid/communicatingwithhiddevices · https://developer.apple.com/documentation/corehid/hiddevicemanager/devicematchingcriteria · https://developer.apple.com/documentation/corehid/hiddeviceclient/seizedevice()
- Apple developer forums: https://developer.apple.com/forums/thread/764540 · https://developer.apple.com/forums/thread/820708 · https://developer.apple.com/forums/thread/845599 · https://developer.apple.com/forums/thread/843327 · https://developer.apple.com/forums/thread/820676
- OpenJoystickDriver: https://github.com/xsyetopz/OpenJoystickDriver · https://github.com/xsyetopz/OpenJoystickDriver/issues/33 · https://github.com/xsyetopz/OpenJoystickDriver/wiki/Controller-Records · https://github.com/xsyetopz/OpenJoystickDriver/wiki/Writing-Controller-Mods · https://github.com/xsyetopz/OpenJoystickDriver/wiki/Building-from-Source · https://github.com/xsyetopz/OpenJoystickDriver/wiki/Permissions-and-Security · https://github.com/xsyetopz/OpenJoystickDriver/wiki/Playing-Games
- SDL: https://raw.githubusercontent.com/libsdl-org/SDL/main/src/joystick/darwin/SDL_iokitjoystick.c · https://raw.githubusercontent.com/libsdl-org/SDL/main/src/joystick/apple/SDL_mfijoystick.m · https://raw.githubusercontent.com/libsdl-org/SDL/main/src/joystick/hidapi/SDL_hidapi_xboxone.c · https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapijoystick.c · https://raw.githubusercontent.com/libsdl-org/SDL/main/src/joystick/SDL_joystick.c · https://github.com/libsdl-org/SDL/issues/16473
- Virtual Xbox identity and Steam de-duplication: https://github.com/LizardByte/libvirtualhid/pull/208 · https://github.com/LizardByte/libvirtualhid/blob/master/src/platform/macos/macos_xbox_transport.hpp · https://github.com/ZeldaWWHDRecomp/ZeldaWWHDRecomp/pull/348
- Local observations on the target Mac (no URL): `ioreg -r -c IOHIDDevice`, `ioreg -p IOUSB`, `hidutil list`, `systemextensionsctl`, all run 2026-11-08.