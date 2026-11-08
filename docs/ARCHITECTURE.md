# GDHub — macOS hub for gaming peripherals

Goal: a user-space macOS app (no kernel extension) that understands peripherals macOS ignores and exposes them properly. First device: SCUF Envision Pro over its Slipstream wireless receiver. Later: mouse, keyboard, headset modules behind the same device abstraction.

## Build and run
Swift Package, SwiftUI, macOS 14+. `swift build` / `swift run GDHub` from the repo root. No Xcode project yet; `swift run` is fine for development (the app must call `NSApplication.shared.setActivationPolicy(.regular)` and activate itself so a window appears).

## Layers
```
Sources/GDHub/
  App.swift                      @main SwiftUI app, window with sidebar (devices) + detail
  HID/HIDMonitor.swift           IOHIDManager wrapper. Matches VID/PID list, opens devices,
                                 delivers input reports + connect/disconnect on the main actor.
  Devices/DeviceModule.swift     protocol every device type implements (id, match rules,
                                 parse(report) -> events, state object, view)
  Devices/EnvisionPro/
    EnvisionProReport.swift      pure parser: 16-byte report 0x06 -> GamepadFrame
                                 (see docs/protocol/envision-pro-receiver.md)
    EnvisionProDevice.swift      ObservableObject: latest frame, connected/asleep state,
                                 raw event log, mapping + learn session
  Mapping/
    ControlLayout.swift          Codable model of Resources/envision-pro-layout.json
    ControlMapping.swift         control id -> Binding (button index | axis+sign | hat dir
                                 | trigger field | extraBit), Codable
    MappingStore.swift           load/save JSON in ~/Library/Application Support/GDHub/
  UI/
    ControllerView.swift         front/back image with hotspot overlay; hotspots light up
                                 from the live frame via the mapping; sticks show a dot,
                                 triggers a fill bar, unmapped hotspots drawn dashed
    LearnPanel.swift             guided learn: walks controls in `order`; for the current
                                 control it waits for the next input change, assigns it,
                                 advances. Click any hotspot to re-learn just that one.
    InputMonitorView.swift       live list of raw changes (button n down/up, hat, axes,
                                 extra bits) so unknown inputs are visible even unmapped
  Resources/
    envision-pro-front.png / -back.png   clean product photos (no badges)
    envision-pro-layout.json             hotspots, normalised to each image
```

## Frame model
`GamepadFrame { x, y, z, rz: Int16; lt, rt: UInt16 (0..1023); hat: UInt8 (8 = none); buttons: UInt32 (19 bits); extra: UInt16 (13 bits) }` plus `Equatable` and a `diff(from:)` producing `[InputEvent]`.

## Learn algorithm
Baseline = last frame when the step starts. Activity = frame differs from baseline beyond noise (|axis delta| > 4000, trigger delta > 80, any bit change). Collect frames until the state returns to baseline for 0.5 s or 8 s pass. Then:
- button kind: the first button bit that went high -> `.button(index)`; also record extra bits seen -> stored as `physicalBits` on the mapping (diagnostic).
- D-pad controls: hat value seen -> `.hat(direction)`.
- trigger kind: the analogue field (lt or rt) whose peak delta was largest -> `.trigger(field)`.
- stick kind: two sub-steps "push right" then "push down"; each picks the int16 axis with the largest |delta| and its sign -> `.axis(field, sign)` for horizontal and vertical; the stick's click is learned as a separate button control (l3/r3).
Persist after each assignment. The guided order is `order` in the layout (1..33, the same numbers as docs/layout/*.png).

## Non-goals for this slice
No virtual gamepad output yet, no vendor-channel commands, no mouse/keyboard/headset. Keep those as empty extension points (`DeviceModule` protocol, `HIDMonitor` matching list).
