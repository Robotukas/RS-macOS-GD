# GDHub DriverKit virtual HID extension: design

*File: `docs/plans/driverkit-dext-design.md` · Written 2026-11-08 · Status: design, ready for phase D0 · Trigger: "lets make apple drivers first"*

This document turns P7 of `docs/plans/output-layer-plan.md` into a buildable design and moves it ahead of P1–P6. It does not need the mapping engine: the first pad is fed by a passthrough mapper built on the learned `ControlMapping`.

**Sources.** *local* means checked on this Mac (macOS 27.0.1, Mac15,9 M3 Max, Xcode 27.1, DriverKit SDK 27.0). Everything else cites the five research reports (sdk-api, gc-matching, sdl-descriptors, xcode-project, prior-art) or the sources they quote. SDK paths are shortened:
- `D/` = `DriverKit.platform/…/DriverKit.framework/Headers/`
- `H/` = `…/HIDDriverKit.framework/Headers/`

**What this changes in the output-layer plan**
- **The primary pad uses the 16-byte compact `xbox-bt16` report, published as 045E:02E0 (`xbox-bt16-02e0`) or 045E:0B13 (`xbox-bt16`).** M1 tests both and prefers 02E0 if both work (§4.1, §7.3). `x360-usb` drops to last fallback. P7d expected Razer's pad to favour x360-usb, but GameController never adopts a third-party DriverKit 028E pad (gc-matching §4/§6). No single 028E report is also correct in both SDL 2.32 and SDL ≥ 3.4.12 (sdl-descriptors (d)).
- **The app never carries `driverkit.userclient-access`.** The dext uses `allow-any-userclient-access` (development) and checks the caller's Team ID itself.
- **Paths change.** `Driver/GDHubVirtualHID/` becomes `Dext/GDHubVirtualHID/`. `Output/VirtualPad/DextClient.swift` becomes `Output/VirtualHID/DextClient.swift`, because the pad, keyboard and pointer share it.
- **Default product string for Xbox identities is "Xbox Wireless Controller".** P7b had "SCUF Envision Pro"; that becomes a cosmetic test after first light.

---

## 1. Goals, non-goals, constraints

**Goals**
- **G1 One data-driven dext.** A single DriverKit extension, `com.interlinked.gdhub.VirtualHID`, is embedded in `/Applications/GDHub.app`. It publishes **one virtual HID gamepad**. The app sends the pad's identity at runtime: VID, PID, version, Transport, strings, LocationID, report descriptor and neutral reports. Changing identity needs no dext rebuild (plan decision 3).
- **G2 Exactly one controller in every host.** The pad must appear once in each of:
  - System Settings › Game Controllers and `GCController`
  - Steam (SDL3 3.4.0-1576)
  - Shadow PC (SDL2 2.24.2, statically linked)
  - GeForce NOW (SDL2 2.32.10, plus the GameController "Forge" path)
- **G3 Host output reaches the app.** Output reports (rumble) are delivered asynchronously.
- **G4 Later slots.** The same dext later publishes an NKRO keyboard (slot 1) and a relative pointer (slot 2) as **separate** HID devices. A composite gamepad + mouse is classified as GCMouse (prior-art §4).
- **G5 Failure is safe.**
  - App crash or quit: the devices disappear. (T3: the pad belongs to the root, so this is no longer automatic. The user client's `Stop` asks the root to destroy the pad, and the registry hands back any pad that is still registered when the owner is released. §3.9.)
  - App hang: neutral reports after 2 s.
  - A second app instance cannot publish.

**Non-goals (this design)**
- Developer ID, notarization, distribution, CoreHID, Apple entitlement requests.
- SIP off, `systemextensionsctl developer on`.
- Rumble to the physical SCUF (P7e). That needs a capture of receiver output report 0x09, and OpenLinkHub is GPL-3, so its code cannot be used.
- The mapping engine (P3/P4). The dext path uses `PassthroughPadMapper` until then.
- More than one pad.
- Testing on x86_64. It is built but not tested.

**Constraints**

| Item | Value | Reason / evidence |
|---|---|---|
| Account / team | Paid personal ADP, team `79XF6HYX8A`, certificate "Apple Development: Robertas Suminskas (P2B3MZTPX8)" (OU 79XF6HYX8A, expires 2027-11-08) | *local*, xcode-project §1 |
| Signing | Automatic, development-only capabilities, no Apple request: DriverKit (development), Family HID Device (development), Allow Any UserClient (development), Transport HID (development, fallback only), System Extension | Xcode 27.1 `DVTPortalCachedPortalCapabilities.json`: `isPublic:true, editable:true, developmentOnly:true` (xcode-project §3). DTS: "available on all paid developer accounts without any special approval" (forum 809202) |
| Devices | Development builds run only on registered Macs. This Mac's provisioning UDID is `00006031-001851E126E1001C` | xcode-project §1 |
| SIP | ON. No `systemextensionsctl developer`, `reset` or `uninstall`. Replacement works by bumping `CFBundleVersion` | DTS forum 804191 ("The old disable SIP process is no longer necessary"), 773002 |
| Install location | The app must run from `/Applications/GDHub.app`. Anywhere else gives `OSSystemExtensionErrorDomain` 3 (`unsupportedParentBundleLocation`) | Apple "Installing System Extensions and Drivers" |
| App deployment target | macOS 14.0 (unchanged, `Package.swift` `.v14`) | existing |
| **Dext deployment target** | **`DRIVERKIT_DEPLOYMENT_TARGET = 23.0`**, so `OSMinimumDriverKitVersion` is 23.0 | DriverKit 23 corresponds to macOS 14, matching the app's minimum. The SDK accepts 21.0–25.6 and 27.0; minimum 21.0, recommended 23.0 (`SDKSettings.plist`). All `IOUserHIDDevice`/`IOHIDDevice` APIs are `introduced=19.0`. An unsigned build with 23.0 was verified. **Never `latest_driverkit`** (the template default): it resolves to 27.0, which refuses macOS < 27 and changes silently with Xcode. Fallback: 22.0, which Karabiner 8.6.0 uses for Xcode 27 |
| Architectures | Default `ARCHS` (`arm64 x86_64`). **No arm64e** | *local* `lipo -archs`: Razer's dext is `arm64` only and Corsair's is `x86_64 arm64`, and both load here. Apple's `XboxGamepad.dext` is arm64e because it is a platform binary. Forum 813880: POSIX 8 errors went away after removing arm64e |
| Licences | Karabiner (Unlicense) may be copied. libvirtualhid client code and OJD ≤ 0.6.0-alpha.1 are MIT and may be borrowed. **Never** OJD ≥ alpha.2 (PolyForm-NC) or OpenLinkHub (GPL-3) | prior-art §1 |
| Bundle IDs | App `com.interlinked.gdhub`. Dext `com.interlinked.gdhub.VirtualHID`, and the `.dext` folder name must equal it | procon2 README; xcode-project verified output path |

---

## 2. Repository layout

`project.yml` stays at the repo root, because that is the layout xcodegen 2.46.0 + Xcode 27.1 verified (BUILD SUCCEEDED). App-shell files go in `Xcode/App/` and dext sources in `Dext/GDHubVirtualHID/`. SwiftPM ignores both folders, so `swift build`, `swift test` and `scripts/bundle.sh` keep working unchanged.

Statuses: **NEW** = new file, **MOD** = modified, **GEN** = generated by `xcodegen` from `project.yml` (committed, never hand-edited), **IGN** = gitignored. The last column is the phase that creates the file.

| Path | Status | Purpose | Phase |
|---|---|---|---|
| `project.yml` | NEW | XcodeGen spec. Single source of truth for the Xcode project, both Info.plists and both entitlements files (§6.1) | D0 |
| `GDHub.xcodeproj/` | GEN, IGN | Generated project (`*.xcodeproj` is already in `.gitignore`) | D0 |
| `.gitignore` | MOD | Add `.xcodebuild/` and `Xcode/build-number` | D0 |
| `Package.swift` | MOD (T3) | SwiftPM build and tests. T3 adds the C target `GDHubDextCore` (`Dext/GDHubVirtualHID/Core`), the same files the dext compiles | T3 |
| `scripts/bundle.sh` | unchanged | SwiftPM dev loop. The app it builds has no dext; the Driver menu then shows "Not bundled" | — |
| `scripts/build-xcode.sh` | NEW | xcodegen → signed xcodebuild → signature and profile checks → install to `/Applications` → launch (§6.2) | D0 |
| `scripts/dext-log.sh` | NEW | `log stream` with the dext/sysextd/kernel predicate (§6.5) | D0 |
| `scripts/vhid-check.sh` | NEW | H1 check: sysext state, root service, our HID devices and their properties, bound event drivers (§7.2) | D3 |
| `Xcode/App/BundleModule+Xcode.swift` | NEW | `extension Bundle { static var module: Bundle { .main } }`. Xcode only, because `Bundle.module` is used in `ControlLayout.swift:255` and `ControllerView.swift:11` | D0 |
| `Xcode/App/Info.plist` | GEN | App Info.plist | D0 |
| `Xcode/App/GDHub.entitlements` | GEN | `com.apple.developer.system-extension.install` | D0 |
| `Xcode/build-number` | NEW, IGN | Build counter (1…9999) used for `CURRENT_PROJECT_VERSION` | D0 |
| `Dext/GDHubVirtualHID/Info.plist` | GEN | Dext Info.plist with the IOKit personality (§3.2) | D0 |
| `Dext/GDHubVirtualHID/GDHubVirtualHID.entitlements` | GEN | Dext entitlements (§3.3) | D0 |
| `Dext/GDHubVirtualHID/GDHubProtocol.h` | NEW | Wire contract shared with Swift: selectors, slots, spec layout, async argument layout, limits. Plain C `#define`s (§3.5–3.6) | D0 (full in D2) |
| `Dext/GDHubVirtualHID/GDHubInternal.h` | NEW | Dext-only: Team ID, timings, `GDLog`, bridge function declarations between classes, spec helpers | D0 |
| `Dext/GDHubVirtualHID/GDHubVirtualHID.iig` / `.cpp` | NEW | Root `IOService` on `IOUserResources`: `Start`/`RegisterService`, `NewUserClient`, single-owner claim | D0 (root), D2 (client) |
| `Dext/GDHubVirtualHID/GDHubVirtualHIDUserClient.iig` / `.cpp` | NEW | User client: dispatch table, Team check, spec store, report buffers, watchdog, output delivery | D2, D3, D5 |
| `Dext/GDHubVirtualHID/Core/GDHubDextCore.h`, `GDHubRegistryCore.c`, `GDHubStatsCore.c` | NEW | DriverKit-free C core, compiled into the dext and into the SwiftPM target `GDHubDextCore`: the registry state machine, the `hop`/`hr` meter, CRC-32 and the GDHubStatus2 packer (§3.13) | T3 |
| `Dext/GDHubVirtualHID/GDHubRegistry.cpp` | NEW | Typed wrappers over the core (IOLock and OSObject retain/release as its operations), `GDH_SYNC` violation sink, status2 builder | T3 |
| `Tests/GDHubTests/DextCoreRegistryTests.swift`, `DextCoreMeterTests.swift`, `DextClientCapabilityTests.swift` | NEW | Registry transitions with retain counting and concurrency, meter/CRC/status2, capability negotiation against fake dexts | T3 |
| `Dext/GDHubVirtualHID/GDHubSpec.cpp` | NEW | Spec validation, device-description dictionary, descriptor copy, report-length lookup, neutral iteration | D3 |
| `Dext/GDHubVirtualHID/GDHubVirtualPad.iig` / `.cpp` | NEW | Slot 0 `IOUserHIDDevice` | D3, D5 |
| `Dext/GDHubVirtualHID/GDHubVirtualKeyboard.iig` / `.cpp` | NEW | Slot 1 (copy of the pad class) | D8 |
| `Dext/GDHubVirtualHID/GDHubVirtualPointer.iig` / `.cpp` | NEW | Slot 2 (copy of the pad class) | D8 |
| `Sources/GDHub/Output/VirtualHID/DextProtocol.swift` | NEW | Swift mirror of `GDHubProtocol.h`, `DeviceSpec` encoder, `DextError` | D2, D3 |
| `Sources/GDHub/Output/VirtualHID/DextClient.swift` | NEW | Service matching, `IOServiceOpen`, calls, async output port, reconnect | D2 |
| `Sources/GDHub/Output/VirtualHID/DriverManager.swift` | NEW | `OSSystemExtensionRequest` flow, install/connection/pad UI state | D1, D2 |
| `Sources/GDHub/Output/VirtualHID/HIDReportSizer.swift` | NEW | Minimal HID descriptor parser giving report IDs and byte lengths per type (feeds the spec and the tests) | D3 |
| `Sources/GDHub/Output/VirtualPad/PadState.swift` | NEW | `PadState`, `PadButtons` (XInput convention) | D3 |
| `Sources/GDHub/Output/VirtualPad/PadDescriptors.swift` | NEW | Descriptor hex strings and `[UInt8](hex:)` | D3, D6 |
| `Sources/GDHub/Output/VirtualPad/PadReportBuilders.swift` | NEW | Pure builders: `xboxBT16` (also used by `xbox-bt16-02e0`), `xboxBT17Gapped`, `xboxPR208`, `gip20`, `x360` | D3, D6 |
| `Sources/GDHub/Output/VirtualPad/PadIdentity.swift` | NEW | Identity catalogue (data) → `DeviceSpec` | D3, D6 |
| `Sources/GDHub/Output/VirtualPad/PassthroughPadMapper.swift` | NEW | `GamepadFrame` + `ControlMapping` → `PadState` | D4 |
| `Sources/GDHub/Output/VirtualPad/VirtualPadSink.swift` | NEW | Send-on-change, deadbands, 250 Hz cap, heartbeat, neutral, identity switch, test pattern | D3, D4 |
| `Sources/GDHub/Output/VirtualPad/RumbleDecoder.swift` | NEW | Output report → `RumbleCommand` | D5 |
| `Sources/GDHub/UI/DriverCommands.swift` | NEW | `CommandMenu("Driver")` with status lines and actions | D1–D6 |
| `Sources/GDHub/UI/VirtualControllerPanel.swift` | NEW | Designed panel, built only after the mockup is approved | D7 |
| `Sources/GDHub/App.swift` | MOD | Owns `vhidQueue`, `DextClient`, `VirtualPadSink`, `DriverManager`; Driver menu; lifecycle notifications | D1, D4 |
| `Sources/GDHub/Devices/EnvisionPro/EnvisionProDevice.swift` | MOD | `onFrame` and `onStatusChange` hooks | D4 |
| `Tests/GDHubTests/HIDReportSizerTests.swift` | NEW | Descriptor lengths and report sizes (§7.1) | D3 |
| `Tests/GDHubTests/PadReportBuilderTests.swift` | NEW | Byte vectors (§7.1) | D3, D6 |
| `Tests/GDHubTests/DextProtocolTests.swift` | NEW | Parses `GDHubProtocol.h` text and compares every `#define` with Swift; spec encoding offsets | D2, D3 |
| `Tests/GDHubTests/PassthroughPadMapperTests.swift` | NEW | Mapper | D4 |
| `Tests/GDHubTests/VirtualPadSinkTests.swift` | NEW | Rate cap, coalescing, deadband, heartbeat, neutral (fake transport and clock) | D4 |
| `Tests/GDHubTests/RumbleDecoderTests.swift` | NEW | Decoder | D5 |
| `scuf-envision/tools/gcprobe.swift` | MOD | Add `--watch`: print `extendedGamepad` value changes | D3 |
| `docs/research/host-identity-matrix.md` | NEW | M1 results (02E0 vs 0B13), then H1–H7 results per identity and host | D3, D6 |
| `docs/mockups/virtual-controller-panel.html` | NEW | Mockup, attached in chat for mobile review before D7 code | D7 |

---

## 3. Dext design

### 3.1 Topology (copy of the proven Razer / Corsair / Karabiner shape)

Registry names as ioreg prints them (`<name> <class …>`):
```
IOUserResources
 └─ GDHubVirtualHID <class IOUserService>                  root; IOUserServerName = com.interlinked.gdhub.VirtualHID
     ├─ GDHubVirtualHIDUserClient <class IOUserUserClient>   one per IOServiceOpen(type 0)
     │   ├─ GDHubVirtualKeyboard <class AppleUserHIDDevice>    slot 1 (D8; moves to the root with the pad in T11)
     │   └─ GDHubVirtualPointer <class AppleUserHIDDevice>     slot 2 (D8; moves to the root with the pad in T11)
     └─ GDHubVirtualPad <class AppleUserHIDDevice>             slot 0, created by the ROOT (T3: CreatePad, called by the user client's createDevice)
         └─ IOHIDInterface ─ AppleGCHIDUserEventDriver (expected for 0B13 / 02E0) | AppleUserHIDEventDriver
```
- **T3: the root is the provider of the pad** (before T3, the user client was the provider of every HID child). Keyboard and pointer still hang under the client until D8/T11.
- **What that changes.** A child of the user client was terminated by the kernel with its client (Karabiner and Razer in ioreg; sdk-api §2). The pad no longer is. G5 now holds because the user client's `Stop` calls `root->DestroyPad`, and because `GDHubReleaseOwner` returns any pad still registered for that owner, so no pad outlives its owner (§3.9). The root's own `Stop` terminates a registered pad too.
- **The pad is found through the registry, not through its provider.** The user client takes a +1 copy of the pad for the duration of each call (§3.13).
- **The ioreg registry name of every dext object is its `IOUserClass`.** On this Mac Razer shows as `RazerVirtualHIDDevice <class IOUserService>` → `VirtualDriverClient <class IOUserUserClient>` → `VirtualControllerDriverKit <class AppleUserHIDDevice>` → `IOHIDInterface` → `AppleUserHIDEventDriver <class AppleUserHIDEventService>` (*local*).
- **In ioreg, find these objects by name (`-n`), never by class (`-c`).** On macOS 27.0.1, `ioreg -rc IOUserService`, `ioreg -rc IOUserUserClient` and `ioreg -rc AppleUserHIDDevice` print nothing, although Razer's root, client and three pads exist. `ioreg -rw0 -n VirtualControllerDriverKit -d3` does print the pad, its interface and its event driver. `-c IOUserHIDDevice` and `-c IOHIDDevice` also list them (*local*). Every shell check in this document uses `-n` (§6.3, §6.5, §7.2).
- **The IOKit API is not affected.** `IOServiceGetMatchingServices` finds Razer's root with `IOServiceMatching("IOUserService")` + `IOUserServerName`, and its pad with `IOServiceMatching("AppleUserHIDDevice")` + VendorID/ProductID (*local* Swift probe). `DextClient` (§5.2) and the duplicate check (§5.4) therefore keep class matching.

### 3.2 Info.plist personality (exact; generated from `project.yml` §6.1)

Expected `plutil -p Dext/GDHubVirtualHID/Info.plist` (after build-setting expansion in the built product):
```
"IOKitPersonalities" => {
  "GDHubVirtualHID" => {
    "CFBundleIdentifier"       => "com.interlinked.gdhub.VirtualHID"
    "CFBundleIdentifierKernel" => "com.apple.kpi.iokit"
    "IOClass"                  => "IOUserService"
    "IOMatchCategory"          => "com.interlinked.gdhub.VirtualHID"
    "IOProviderClass"          => "IOUserResources"
    "IOResourceMatch"          => "IOKit"
    "IOUserClass"              => "GDHubVirtualHID"
    "IOUserServerName"         => "com.interlinked.gdhub.VirtualHID"
    "GDHubPadProperties" => { "IOClass" => "AppleUserHIDDevice", "IOUserClass" => "GDHubVirtualPad" }   // T3: root level (was inside UserClientProperties)
    "UserClientProperties" => {
      "IOClass"     => "IOUserUserClient"
      "IOUserClass" => "GDHubVirtualHIDUserClient"
      // D8 adds (T11 moves them to the root level like the pad):
      "GDHubKeyboardProperties" => { "IOClass" => "AppleUserHIDDevice", "IOUserClass" => "GDHubVirtualKeyboard" }
      "GDHubPointerProperties"  => { "IOClass" => "AppleUserHIDDevice", "IOUserClass" => "GDHubVirtualPointer" }
    }
    "IOUserServerOneProcess"   => true          // T4
  }
  "GDHubReceiverTap" => {                       // T4: all five match keys are integers; no IOMatchCategory, no Transport
    "CFBundleIdentifier" => "com.interlinked.gdhub.VirtualHID", "CFBundleIdentifierKernel" => "com.apple.kpi.iokit"
    "IOClass" => "IOUserService", "IOProviderClass" => "IOHIDInterface", "IOUserClass" => "GDHubReceiverTap"
    "IOUserServerName" => "com.interlinked.gdhub.VirtualHID", "IOUserServerOneProcess" => true
    "VendorID" => 6940, "ProductID" => 14856, "PrimaryUsagePage" => 65368, "PrimaryUsage" => 1, "IOProbeScore" => 1000
  }
}
"OSBundleUsageDescription" => "Publishes GDHub's virtual game controller, keyboard and pointer."
"OSMinimumDriverKitVersion" => "23.0"            // derived from DRIVERKIT_DEPLOYMENT_TARGET
"CFBundlePackageType" => "DEXT"                  // from $(PRODUCT_BUNDLE_PACKAGE_TYPE); xcodegen omits it otherwise (§6.1)
"CFBundleVersion" => "<build number>"            // 1…9999, kext version format
```
- **`CFBundlePackageType` must be `DEXT`.** sysextd's `DriverExtensionCategoryDelegate` rejects anything else: its strings include ``%{public}s: package type not `DEXT` `` followed by `extension failed to validate! uninstalling...`. kernelmanagerd has `has invalid or missing package type`. Razer, Corsair and all 22 dexts in `/System/Library/DriverExtensions` carry `DEXT` (*local*). `build-xcode.sh` gates on it (§6.2).
- **`IOMatchCategory` is kept.** It is right for `IOUserResources` providers; Razer, Corsair and Apple's template all set it. The forum 814101 advice against it applies to hardware matching.
- **`UserClientProperties` is a naming convention, not an SDK constant.** `NewUserClient` passes it to `Create()` (sdk-api §2). The same holds for `GDHubPadProperties`, which `CreatePad` passes to `Create()` as the root's own property (the Karabiner pattern: `Create(this, "VirtualHIDKeyboard")` on the root service). That the root can create the pad this way is assumption A15 of the takeover plan; the live check is that `ioreg -rw0 -n GDHubVirtualHID -d3` shows `GDHubVirtualPad` directly under the root.
- **Do not add `IOUserClientEntitlements` to the user client dict.** Razer's has none.

### 3.3 Entitlements (exact)

**Dext** (`Dext/GDHubVirtualHID/GDHubVirtualHID.entitlements`):

| Key | Value | Portal capability | Development-only? |
|---|---|---|---|
| `com.apple.developer.driverkit` | `true` | DriverKit (development) (`DRIVERKIT_PUBLIC`, `alwaysEnableForSupportedProductTypes`) | yes |
| `com.apple.developer.driverkit.family.hid.device` | `true` | DriverKit Family HID Device (development) | yes |
| `com.apple.developer.driverkit.allow-any-userclient-access` | `true` | DriverKit Allow Any UserClient (development) | yes |
| `com.apple.developer.driverkit.transport.hid` | `true` | DriverKit Transport HID (development). **From T4 it is required**: the receiver tap opens an `IOHIDInterface`. The development profile for this App ID lists it (checked by `build-xcode.sh`) | yes |

- **Never put these in the dext:** `com.apple.developer.hid.virtual.device` ("should never be included in a DEXT", forum 843327), `com.apple.developer.driverkit.family.hid.virtual.device` (defunct), `com.apple.developer.driverkit.userclient-access` (restricted).
- **Why `family.hid.device`:** DTS says AppleUserHIDDevice needs it, and "Including any other HID entitlement is unnecessary" (843327). Razer ships with `transport.hid` and no `family.hid.device`. `transport.hid` is therefore the documented fallback (§8).

**App** (`Xcode/App/GDHub.entitlements`):
- `com.apple.developer.system-extension.install = true`. This is public and not development-only.
- Xcode adds `com.apple.application-identifier = 79XF6HYX8A.com.interlinked.gdhub` and `com.apple.developer.team-identifier = 79XF6HYX8A` from the profile. AMFI on macOS 26+ expects them (OJD `Host.entitlements` note), and the dext's caller check reads them (§3.11).
- Debug builds also get `get-task-allow`.
- The app is **not sandboxed** and has no `userclient-access`. A missing grant would break signing ("the entitlement.plist doesn't match the profile", forum 804191).

### 3.4 Classes (exact `.iig`)

All three `.iig` files and the iig/C++ rules below come from the sdk-api `iigtest`, which compiled with `-Wall` and linked for `arm64-apple-driverkit23.0`.

**iig and C++ rules**
- RPC methods (no `LOCALONLY`) are implemented as `IMPL(Class, Method)`, and super is called as `Method(args, SUPERDISPATCH)`.
- `LOCALONLY` methods are plain overrides that call `super::`.
- Instance variables: `ivars` is allocated with `IONewZero` in `init()` and freed with `IOSafeDeleteNULL` in `free()`.
- There are no C++ exceptions and no RTTI. Use `OSDynamicCast` / `OSRequiredCast`.
- Ownership: names containing "Get" return +0; everything else returns +1.

`GDHubVirtualHID.iig`
```cpp
#ifndef GDHubVirtualHID_h
#define GDHubVirtualHID_h
#include <Availability.h>
#include <DriverKit/IOService.iig>
class IOUserClient;
class GDHubVirtualHID : public IOService {
public:
    virtual bool init() override;
    virtual void free() override;
    virtual kern_return_t Start(IOService * provider) override;   // Start(SUPERDISPATCH) then RegisterService()
    virtual kern_return_t Stop(IOService * provider) override;
    virtual kern_return_t NewUserClient(uint32_t type, IOUserClient ** userClient) override;
    // T3. RPC (no LOCAL, no LOCALONLY): runs on the root's default queue. Called by the owning user client (rank 1 -> 2).
    // `ownerGen` is the generation GDHubClaimOwner returned; a stale one is refused with kIOReturnNotPermitted.
    virtual kern_return_t CreatePad(uint64_t ownerGen);
    virtual kern_return_t DestroyPad(uint64_t ownerGen);
};
#endif
```

`GDHubVirtualHIDUserClient.iig`
```cpp
#ifndef GDHubVirtualHIDUserClient_h
#define GDHubVirtualHIDUserClient_h
#include <Availability.h>
#include <DriverKit/IOUserClient.iig>
#include <DriverKit/IOTimerDispatchSource.iig>
class GDHubVirtualHIDUserClient : public IOUserClient {
public:
    virtual bool init() override;
    virtual void free() override;
    virtual kern_return_t Start(IOService * provider) override;
    virtual kern_return_t Stop(IOService * provider) override;
    virtual kern_return_t ExternalMethod(uint64_t selector, IOUserClientMethodArguments * arguments,
                                         const IOUserClientMethodDispatch * dispatch,
                                         OSObject * target, void * reference) override;
    // Watchdog: runs on the default queue, which is also the ExternalMethod queue (no named EM queue is created).
    virtual void WatchdogFired(OSAction * action TARGET, uint64_t time) TYPE(IOTimerDispatchSource::TimerOccurred);
};
#endif
```

`GDHubVirtualPad.iig` (keyboard and pointer are identical apart from the class name)
```cpp
#ifndef GDHubVirtualPad_h
#define GDHubVirtualPad_h
#include <Availability.h>
#include <DriverKit/IOService.iig>
#include <HIDDriverKit/IOUserHIDDevice.iig>
class GDHubVirtualPad : public IOUserHIDDevice {
public:
    virtual bool init() override;
    virtual void free() override;
    // Do NOT override Start (Apple doc / Karabiner). Registration comes from "RegisterService" in the description.
    virtual bool handleStart(IOService * provider) override;
    virtual kern_return_t Stop(IOService * provider) override;
    virtual OSDictionary * newDeviceDescription(void) override;
    virtual OSData * newReportDescriptor(void) override;
    virtual kern_return_t setReport(IOMemoryDescriptor * report, IOHIDReportType reportType, IOOptionBits options,
                                    uint32_t completionTimeout, OSAction * action) override;
    virtual kern_return_t getReport(IOMemoryDescriptor * report, IOHIDReportType reportType, IOOptionBits options,
                                    uint32_t completionTimeout, OSAction * action) override;
    // T3. RPCs (no LOCALONLY): dispatched onto this device's default queue (rank 4); the only callers of handleReport.
    // `source` is a GDHUB_PADSRC_* value, checked on the pad's own queue against the registry's padSource word.
    // `tSrc` is the caller's mach_absolute_time() just before the call (0 = none); it feeds the `hop` histogram.
    // `report` is a fixed-length buffer (its length was set once); `length` is its valid length.
    virtual kern_return_t submitInput(uint32_t source, uint64_t tSrc, IOMemoryDescriptor * report, uint32_t length);
    // Posts every neutral report of the spec from the pad's own prefilled, fixed-length buffers.
    virtual kern_return_t postNeutralFrom(uint32_t source, uint32_t reason);
};
#endif
```
(`postReport(IOMemoryDescriptor *)` of D3 is gone: `submitInput` replaces it.)

`GDHubInternal.h` (plain header). Its bridge functions avoid passing raw pointers through iig. Static functions can reach `ivars`, which sdk-api `sCreatePad` verified.
```cpp
#pragma once
#include <DriverKit/DriverKit.h>
#include <HIDDriverKit/HIDDriverKit.h>
#include <os/log.h>
#include <string.h>
#include "GDHubProtocol.h"
#define GDHUB_TEAM_ID               "79XF6HYX8A"
#define GDHUB_APP_ID                GDHUB_TEAM_ID ".com.interlinked.gdhub"
#define GDHUB_WATCHDOG_PERIOD_MS    250
#define GDHUB_WATCHDOG_TIMEOUT_MS   2000
#ifndef GDHUB_DEXT_BUILD
#define GDHUB_DEXT_BUILD 0          // set by GCC_PREPROCESSOR_DEFINITIONS = GDHUB_DEXT_BUILD=$(CURRENT_PROJECT_VERSION)
#endif
#define GDLog(fmt, ...) os_log(OS_LOG_DEFAULT, "GDHub: " fmt, ##__VA_ARGS__)
class GDHubVirtualHID; class GDHubVirtualHIDUserClient;
bool     GDHubRootClaim(GDHubVirtualHID * root, GDHubVirtualHIDUserClient * uc);     // single authorized owner
void     GDHubRootRelease(GDHubVirtualHID * root, GDHubVirtualHIDUserClient * uc);
// T3: GDHubRootClaim/Release, GDHubUCCopySpec and the (never implemented) GDHubUCDeliverOutput are gone. The registry
// replaces them: GDHubClaimOwner/GDHubReleaseOwner, GDHubCopyPadSpec, GDHubCopyPad/GDHubCopyRoot/GDHubCopyOwner (+1),
// GDH_SYNC(callerRank, targetRank, targetQueue, what), GDHubSpecFindInput, GDHubSpecCRC32 (full list: GDHubInternal.h).
kern_return_t  GDHubSpecValidate(const uint8_t * p, size_t len);                       // §3.6 rules
uint32_t       GDHubSpecU32(OSData * spec, uint32_t off);
uint16_t       GDHubSpecU16(OSData * spec, uint32_t off);
uint8_t        GDHubSpecU8(OSData * spec, uint32_t off);
OSDictionary * GDHubSpecCreateDescription(OSData * spec);                               // +1
OSData *       GDHubSpecCreateDescriptor(OSData * spec);                                // +1
bool           GDHubSpecIsDeclaredInput(OSData * spec, const uint8_t * report, uint32_t len);
uint32_t       GDHubSpecInputCount(OSData * spec);
uint32_t       GDHubSpecSendLength(OSData * spec, uint32_t index);                     // sendLength, or lengthInclID when 0
const uint8_t* GDHubSpecNeutral(OSData * spec, uint32_t index, uint32_t * length);
```

**Root (`GDHubVirtualHID.cpp`)**
- **ivars (T3):** `{ IODispatchQueue * queue; }`, a retained copy of the root's own default queue, used by `GDH_SYNC` at call sites. The claim lock and the `owner` pointer moved into the registry.
- **Start (T3):**
  ```cpp
  kr = Start(provider, SUPERDISPATCH); if (kr) return kr;
  CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->queue);
  gdhr_set_identity(reg, mach_absolute_time(), GDHUB_DEXT_BUILD, getpid());   // instanceNonce, build, pid
  gdhr_register_root(reg, this);                       // replaces a stale root of an earlier instance in this process
  kr = RegisterService(); if (kr) { gdhr_unregister_root(reg, this); return kr; }
  GDLog("root start build %u pid=%d", GDHUB_DEXT_BUILD, getpid());     // the U5 grep matches the prefix "GDHub: root start build N"
  ```
  The registry is created by whichever object runs first; nothing may assume the root started first (T0.3: services of one dext start in any order after a relaunch).
- **Stop (T3):** `gdhr_pad_take(reg, 0)` and, if a pad is still registered, `Terminate(0)` on it; `gdhr_unregister_root(reg, this)` (ignores a stale root); then `Stop(SUPERDISPATCH)`.
- **`CreatePad(ownerGen)` (root queue):** `gdhr_pad_begin_create` (STAGED to CREATING, generation checked), then `Create(this, "GDHubPadProperties", &child)`, which blocks while the kernel starts the pad on the pad's queue. Success only if the pad registered itself in `handleStart` (`gdhr_pad_is`). Otherwise the slot is emptied, a pad that exists is terminated, `createFails++`.
- **`DestroyPad(ownerGen)` (root queue):** `gdhr_pad_take(reg, ownerGen)`: `padSource = NONE`, the registry pointer cleared, then `Terminate(0)` and release. A destroy without a pad succeeds as a no-op; a stale generation is refused.
- **NewUserClient:**
  ```cpp
  if (type != GDHUB_USERCLIENT_TYPE) return kIOReturnBadArgument;
  IOService * c = nullptr; kr = Create(this, "UserClientProperties", &c); if (kr) return kr;
  *userClient = OSDynamicCast(IOUserClient, c);
  if (!*userClient) { c->release(); return kIOReturnError; }
  return kIOReturnSuccess;
  ```
- **`GDHubClaimOwner`:** under the registry lock, grant ownership if there is no owner or it is this client, retain the client, and return the owner generation (> 0); 0 means another client owns the dext. **`GDHubReleaseOwner`:** clear the owner if it is this client; if that client's pad is still registered, the core takes it in the same critical section and the wrapper terminates it.

**User client ivars**
```cpp
struct GDHubVirtualHIDUserClient_IVars {
    GDHubVirtualHID * root;                         // provider (retained by DriverKit until Stop), not retained here
    bool authorized, protocolOK, ownsRoot, neutralised, stopped;
    bool padCreated;                                // T3: this client created the pad and has not destroyed it
    uint64_t ownerGen;                              // T3: generation GDHubClaimOwner returned
    IOLock * lock;                                  // guards outputAction, outputSeq/Count/Drops
    OSData * spec[GDHUB_SLOT_COUNT];                // retained; this client's copy, used on the UC queue only
    IOBufferMemoryDescriptor * inBuf[GDHUB_MAX_INPUT_REPORTS];   // T3: one per input-table entry, length set once (SetLength is a kernel RPC)
    void * inAddr[GDHUB_MAX_INPUT_REPORTS]; uint32_t inLen[GDHUB_MAX_INPUT_REPORTS];
    OSAction * outputAction;                        // retained completion from registerOutput
    uint64_t outputSeq, outputCount, outputDrops, postCount, watchdogFires;
    IODispatchQueue * queue; IOTimerDispatchSource * timer; OSAction * timerAction;
    uint64_t lastActivity, periodTicks, timeoutTicks;
};
```

**Device ivars (T3, pad):** `{ OSData * spec /*+1*/; IODispatchQueue * queue /*retained copy*/; IOBufferMemoryDescriptor * neutral[4] /*prefilled, length set once*/; uint32_t neutralLen[4], neutralCount; bool stopping; gdh_meter meter; }`. The pad no longer holds its provider or the user client. (Keyboard and pointer keep `{ uc, spec }` until D8/T11.)

**Device methods**
- **`handleStart(provider)`:**
  ```cpp
  if (!OSDynamicCast(GDHubVirtualHID, provider)) return false;           // T3: the provider is the root
  ivars->spec = GDHubCopyPadSpec(); if (!ivars->spec) return false;      // staged in the registry; only while the slot is CREATING
  CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->queue);
  buildNeutrals(ivars);                                                  // one prefilled fixed-length buffer per input-table entry
  gdh_meter_init(&ivars->meter, tb.numer, tb.denom, 10000);
  if (!super::handleStart(provider)) return false;                       // super calls newDeviceDescription / newReportDescriptor
  return gdhr_pad_started(reg, this) == GDHR_OK;                         // register last: CREATING to LIVE, padSource = UC
  ```
- **`Stop`:** `ivars->stopping = true; gdhr_pad_stopped(reg, this);` (a no-op if `DestroyPad` already took the pad) `; return Stop(provider, SUPERDISPATCH);`. `free()` releases spec, queue and buffers again, which is safe after a failed start.
- **`newDeviceDescription`** returns `GDHubSpecCreateDescription(ivars->spec)`. **`newReportDescriptor`** returns `GDHubSpecCreateDescriptor(ivars->spec)`.
- **`submitInput(source, tSrc, report, length)`** (pad queue):
  ```cpp
  tPin = mach_absolute_time();
  if (ivars->stopping || bad length)          { ucRejected++; return NotReady / BadArgument; }
  if (source != registry padSource)           { ucRejected++; return NotReady (no pad) / Busy (another source); }   // authoritative check
  kr = handleReport(tPin, report, length, kIOHIDReportTypeInput, 0);
  tPout = mach_absolute_time();               // hop = tPin - tSrc (if tSrc), hr = tPout - tPin; counters; one log line per 10 s window
  ```
- **`postNeutralFrom(source, reason)`** (pad queue): the same source check, then `handleReport` for each prefilled neutral buffer, in spec order. Returns the last error or success.

### 3.5 External method table (`GDHubProtocol.h`, version 1)

- Call with `IOServiceOpen(service, mach_task_self_, GDHUB_USERCLIENT_TYPE = 0, &connect)`.
- Every selector passes through `super::ExternalMethod(selector, args, &sMethods[selector], this, nullptr)`, so the SDK checks argument counts and sizes.
- Columns `C S sIn sOut` in the table are the dispatch-table checks:
  - `C` = `checkCompletionExists` (1 = required, 0 = must be absent)
  - `S` = `checkScalarInputCount`
  - `sIn` = `checkStructureInputSize` (`VAR` = `kIOUserClientVariableStructureSize` = 0xffffffff)
  - `sOut` = `checkScalarOutputCount`
  - `checkStructureOutputSize` is 0 for every selector except 11 (`VAR`).

| # | Name | Scalars in | Struct in | Scalars out | C S sIn sOut | Dext behaviour | Error returns |
|---|---|---|---|---|---|---|---|
| 0 | `hello` | `[protocolVersion, appBuild]` | — | `[protocolVersion, dextBuild, capabilities]` | 0 2 0 3 | First call: Team ID check (§3.11) → claim the ownership in the registry → `protocolOK = (in[0] == 1)`. Always fills the outputs when authorized. `capabilities` = `CAP_PAD`, plus `CAP_ROOT_PAD` (0x100) from T3 | `kIOReturnNotPermitted` 0xE00002E2 (not our team), `kIOReturnExclusiveAccess` 0xE00002C5 (another client owns the dext) |
| 1 | `createDevice` | — | spec, 257…1536 B (§3.6) | — | 0 0 VAR 0 | Copy the struct (or map `structureInputDescriptor`), validate, build one fixed-length buffer per input-table entry, stage the spec in the registry, then `root->CreatePad(ownerGen)` (T3; before T3: `Create(this, kSlotKey[slot], &child)` on the user client) | `BadArgument` 0xE00002C2 (spec invalid), `Busy` 0xE00002D5 (slot in use), `Unsupported` 0xE00002C7 (slot not built yet: keyboard and pointer before D8) |
| 2 | `destroyDevice` | `[slot]` | — | — | 0 1 0 0 | `root->DestroyPad(ownerGen)` (T3; before: `device->Terminate(0)`), then release the client's spec and buffers. Success if the slot is empty | `BadArgument` |
| 3 | `postReport` | `[slot]` | one input report, 1…64 B, ID byte first when the descriptor uses IDs | — | 0 1 VAR 0 | `(id, len)` must match an input-table entry, with `len` = that entry's send length (§3.6). Copy into the entry's fixed-length buffer (T3: no `SetLength` per post), `pad->submitInput(UC, tCall, buffer, len)` on a +1 pad from the registry. Then `postCount++`, `lastActivity = now`, `neutralised = false` | `NotReady` 0xE00002D8 (no device), `BadArgument` (length or ID not declared) |
| 4 | `postNeutral` | `[slot]` | — | — | 0 1 0 0 | `pad->postNeutralFrom(UC, reason)`: every neutral report of the slot, in spec order | `NotReady` |
| 5 | `heartbeat` | — | — | — | 0 0 0 0 | `lastActivity = now` | — |
| 6 | `registerOutput` | — | — | — | 1 0 0 0 | Retain `args->completion` (it is retained only during the call; `IOUserClient.iig:96-98`). Replaces any earlier one. Returns at once | — |
| 7 | `getStatus` | — | — | `[deviceMask, postCount, watchdogFires, outputCount, outputDrops]` | 0 0 0 5 | Counters, for the UI and the rate check | — |
| 8 | `devTerminate` | — | — | — | 0 0 0 0 | DEBUG-only (`GDHUB_DEV_TERMINATE`). T3 order: `DestroyPad`, then `Terminate(0)` on the root | `NotReady` |
| 9 | `setForwarding` (T3; COUNT needs `CAP_TAP`, T4) | `[state, flags, argMs]` | — | `[appliedState, tapPresent, padSource, lastError]` | 0 3 0 4 | INERT (0) or COUNT (1), `flags == 0` (`gdh_fwd_validate`). Anything else: `kIOReturnUnsupported`. The state is stored in the registry and the tap is poked with `DispatchAsync` onto its own queue; the reply does not wait for the interface to open or close, so `appliedState` is what had been applied so far (status2 shows the result) | `Unsupported` |
| 10 | reserved (T5, mapping blob) | — | — | — | VAR on every column | Answers `kIOReturnUnsupported` | `Unsupported` |
| 11 | `getStatus2` (T3, `CAP_ROOT_PAD`) | — | — | — | 0 0 0 0 `sOut=VAR` | Structure output `GDHubStatus2` (276 bytes from T4, maximum 512): identity, counters, the last 10 s window of `hop` and `hr`, the topology probe, and the tap fields (T4). Returns `min(size, caller's maximum)` bytes. A reader that knows an older layout uses the fields that fit | `BadArgument` (maximum below 8 bytes) |

- **Gate.** `ExternalMethod` first rejects `selector >= GDHUB_SEL_COUNT` (12 from T3; 9 in build 17) with `BadArgument`. For any selector except 0 it then returns `NotPermitted` unless `authorized`, and `Unsupported` unless `protocolOK`.
- **Table layout.** Write `sMethods[]` positionally, in selector order, with a comment per row. C++ does not allow `[n] =` designators.
- **Inline size.** Struct inputs above the inline limit (≈ 4 KB, unverified) arrive as `structureInputDescriptor` with `structureInput == NULL`. Both forms are handled (Karabiner `createIOMemoryDescriptor`; prior-art lesson 4). Our maximum is 1536 B.

**T3 additions to the protocol (additive; `GDHUB_PROTOCOL_VERSION` stays 1).**
- `GDHUB_SPEC_VERSION 1`: the spec validator checks this value at spec offset 4 instead of the protocol version. Both are 1, so the bytes did not change.
- T4 adds `GDHUB_CAP_TAP (1u << 9)` (absent in a `GDHUB_TAP_DECLINE` build), `GDHUB_FWD_COUNT 1` and the tap fields of status2 (offsets 172-275, appended; byte 171 stays reserved).
- `GDHUB_CAP_ROOT_PAD (1u << 8)`, `GDHUB_SEL_SET_FORWARDING 9`, `GDHUB_SEL_GET_STATUS2 11`, `GDHUB_SEL_COUNT 12`, `GDHUB_FWD_INERT 0`, `GDHUB_PADSRC_NONE/UC/TAP`, and the `GDHUB_ST2_*` offsets of `GDHubStatus2`.
- **The additive rule** (written into the header): selectors are only added, each new one behind a capability bit; blobs carry their own versions; `GDHubStatus2` only grows by appending fields, and a reader uses `min(size field, bytes received)`.
- **Compatibility.** An old app never calls 9 or 11 and ignores the new capability bit. A new app calls 9 and 11 only when `hello` reported `CAP_ROOT_PAD`; build 17 answers any selector above 8 with `BadArgument`, and the app would not send them.

`GDHubProtocol.h` (complete as of D2; `DextProtocolTests` checks every number against Swift; the T3 additions above are in the file, not repeated here):
```c
#ifndef GDHubProtocol_h
#define GDHubProtocol_h
// Wire contract GDHub.app <-> GDHubVirtualHID.dext. Little-endian. Swift mirror: Output/VirtualHID/DextProtocol.swift
#define GDHUB_PROTOCOL_VERSION          1
#define GDHUB_USERCLIENT_TYPE           0
#define GDHUB_SEL_HELLO                 0
#define GDHUB_SEL_CREATE_DEVICE         1
#define GDHUB_SEL_DESTROY_DEVICE        2
#define GDHUB_SEL_POST_REPORT           3
#define GDHUB_SEL_POST_NEUTRAL          4
#define GDHUB_SEL_HEARTBEAT             5
#define GDHUB_SEL_REGISTER_OUTPUT       6
#define GDHUB_SEL_GET_STATUS            7
#define GDHUB_SEL_COUNT                 8
#define GDHUB_SLOT_PAD                  0
#define GDHUB_SLOT_KEYBOARD             1
#define GDHUB_SLOT_POINTER              2
#define GDHUB_SLOT_COUNT                3
#define GDHUB_CAP_PAD                   1      // hello out[2] bits: 1 << slot
#define GDHUB_CAP_KEYBOARD              2
#define GDHUB_CAP_POINTER               4
#define GDHUB_MAX_DESCRIPTOR            1024
#define GDHUB_MAX_REPORT                64
#define GDHUB_MAX_INPUT_REPORTS         4
#define GDHUB_MAX_NEUTRAL               256
#define GDHUB_SPEC_MAGIC                0x53484447u   /* bytes 'G' 'D' 'H' 'S' */
#define GDHUB_SPEC_HEADER_SIZE          256
#define GDHUB_SPEC_OFF_MAGIC            0      /* u32 */
#define GDHUB_SPEC_OFF_VERSION          4      /* u16 = GDHUB_PROTOCOL_VERSION */
#define GDHUB_SPEC_OFF_HEADER_SIZE      6      /* u16 = 256 */
#define GDHUB_SPEC_OFF_SLOT             8      /* u8 */
#define GDHUB_SPEC_OFF_FLAGS            9      /* u8 */
#define GDHUB_SPEC_OFF_INPUT_COUNT      10     /* u8, 1..4 */
#define GDHUB_SPEC_OFF_VENDOR           12     /* u32 each from here */
#define GDHUB_SPEC_OFF_PRODUCT          16
#define GDHUB_SPEC_OFF_VERSION_NUMBER   20
#define GDHUB_SPEC_OFF_COUNTRY          24
#define GDHUB_SPEC_OFF_LOCATION         28     /* 0 = omit */
#define GDHUB_SPEC_OFF_INTERVAL_US      32
#define GDHUB_SPEC_OFF_USAGE_PAGE       36
#define GDHUB_SPEC_OFF_USAGE            40
#define GDHUB_SPEC_OFF_DESC_LEN         44     /* u16 */
#define GDHUB_SPEC_OFF_NEUTRAL_LEN      46     /* u16 */
#define GDHUB_SPEC_OFF_INPUT_TABLE      48     /* 4 x { u8 reportID (0 = no IDs), u8 sendLength (0 = lengthInclID), u16 lengthInclID } */
#define GDHUB_SPEC_OFF_TRANSPORT        64
#define GDHUB_SPEC_LEN_TRANSPORT        32
#define GDHUB_SPEC_OFF_MANUFACTURER     96
#define GDHUB_SPEC_LEN_MANUFACTURER     32
#define GDHUB_SPEC_OFF_PRODUCT_NAME     128
#define GDHUB_SPEC_LEN_PRODUCT_NAME     64
#define GDHUB_SPEC_OFF_SERIAL           192
#define GDHUB_SPEC_LEN_SERIAL           32
/* 224..255 reserved, zero. Then: descriptor (DESC_LEN bytes), then one neutral report per input-table entry. */
#define GDHUB_SPEC_FLAG_HID_DEFAULT_BEHAVIOR 1  /* sets "HIDDefaultBehavior" = true (keyboard/pointer) */
/* Async output (registerOutput): args[0] = slot | type<<8 | reportID<<16 | length<<24 | truncated<<40,
   args[1..8] = payload, 8 bytes per word little-endian (max 64), args[9] = sequence. */
#define GDHUB_OUTPUT_ARG_COUNT          10
#endif
```

### 3.6 Spec validation (`GDHubSpecValidate`; the Swift encoder enforces the same rules)

The spec is valid only if all of the following hold:
1. `len ≥ 256`.
2. The magic is correct, `version == 1` and `headerSize == 256`.
3. `slot < 3`.
4. `1 ≤ inputCount ≤ 4` and `1 ≤ descLen ≤ 1024`.
5. `len == 256 + descLen + neutralLen`.
6. Every input-table `lengthInclID` is 1…64. Every `sendLength` is 0, or satisfies `lengthInclID ≤ sendLength ≤ max(lengthInclID over the table)`. That maximum is the device's `MaxInputReportSize`, because the table lists every input report the descriptor declares (§5.3).
7. If any reportID is 0, then `inputCount == 1`. Rule 6 then forces `sendLength` to be 0 or equal to `lengthInclID`.
8. `neutralLen` equals the sum of the table's **send lengths** (`send(i) = sendLength ? sendLength : lengthInclID`), and is ≤ 256. Neutral report `i` is `send(i)` bytes long.
9. Every neutral report with a non-zero ID starts with that ID.
10. Every string field ends in a NUL in its last byte, and Transport is non-empty.

SDL 2.24/2.32 builds the device path from Transport and gets an empty path without it (sdl-descriptors (a)), which is why Transport is required.

**`sendLength`** exists only for `xbox-pr208` (§4.5). That identity reproduces libvirtualhid PR #208, which declared report 0x01 as 17 bytes and sent it zero-padded to the 25-byte `MaxInputReportSize`. Every other identity leaves it 0.

**`GDHubSpecIsDeclaredInput`**
- If the descriptor has no report IDs (`table[0].id == 0`), it requires `len == send(0)`.
- Otherwise it requires `report[0] == table[i].id` and `len == send(i)` for some `i`.
- `GDHubSpecSendLength(spec, i)` returns `send(i)`. `postNeutral` and the watchdog post each neutral report at that length.

IOHIDFamily drops short reports without logging anything (macgip), which is why the dext enforces this. A report longer than its declared length but within `MaxInputReportSize` is accepted, and only the declared fields are read. PR #208's end-to-end test (GameController and Steam) relied on this with an `IOHIDUserDevice`. It is untested for a dext device, which is why only `xbox-pr208` uses it.

**`GDHubSpecCreateDescription`**
- Build with `OSDictionary::withCapacity(16)` and the SDK helpers `OSDictionarySetValue`, `OSDictionarySetUInt64Value` and `OSDictionarySetStringValue` (`D/OSCollections.h:163-177`).
- Set these keys:
  - `"RegisterService" = kOSBooleanTrue`. This is the registration method; do not override `Start` (Karabiner DEVELOPMENT.md, procon2).
  - `VendorID`, `ProductID`, `VersionNumber`, `CountryCode`, `ReportInterval` (µs), `PrimaryUsagePage`, `PrimaryUsage`.
  - `LocationID`, only if non-zero.
  - `Transport`, `Manufacturer`, `Product` and `SerialNumber`, as strings; skip empty optional strings.
  - `"HIDDefaultBehavior" = kOSBooleanTrue`, only when flag bit 0 is set.
- **Never set** `HIDVirtualDevice`, `Built-In`, `GameControllerEligible`, `GCSyntheticDevice`, `Privileged` or `IOServiceDEXTEntitlements`. GameController's probe rejects `GameControllerEligible == false` and `GCSyntheticDevice == true` (gc-matching §4). `Privileged` is in IOHIDFamily's restricted list.

### 3.7 Report injection path

```
VirtualPadSink (vhidQueue) ── IOConnectCallMethod(sel 3, [slot], bytes) ──► GDHubVirtualHIDUserClient::ExternalMethod
  (UC default queue, rank 1) validate (id,len) ─► entry = GDHubSpecFindInput ─► memcpy into inBuf[entry] (fixed length, set at createDevice)
  ─► pad = GDHubCopyPad() (+1) ─► GDH_SYNC(UC→PAD) ─► tCall = mach_absolute_time()
  ─► pad->submitInput(UC, tCall, inBuf[entry], len)   iig RPC, synchronous, runs on the pad's default queue (rank 4)
  ─► tPin; source check against the registry's padSource; handleReport(tPin, md, len, kIOHIDReportTypeInput, 0); tPout
  ─► AppleUserHIDDevice ─► IOHIDInterface ─► hosts          pad->release()
```
- **One buffer per input-table entry** (T3; before: one per slot). Each is created with its capacity equal to the entry's send length and `SetLength(sendLength)` once, at `createDevice`. `SetLength` is a kernel RPC (`IOBufferMemoryDescriptor.iig:92-93`), so it is never called per post. Reuse is safe because the RPC is synchronous and the user client's queue is the only writer. Karabiner creates and releases a descriptor per post, which shows `handleReport` is finished with it on return. That `handleReport` accepts a buffer whose length was set once is assumption A16 of the takeover plan (live check: reports reach the host, `postErrors` stays 0).
- **Neutral reports** come from buffers the pad builds once in `handleStart` (one per input-table entry, prefilled from the spec), so the watchdog and `postNeutral` copy nothing.
- **Timestamps** are `mach_absolute_time()` taken at the pad's entry (`tPin`), as before.
- **`hop` and `hr`.** `hop` = `tPin - tCall` (the cost of the user client to pad hop, whatever it is: in-process or through the kernel; A19). `hr` = the duration of `handleReport`. Both are in 62-bucket histograms (edges at 1, 2, 3, 5, 8, 12, 18 and 25 µs so that a p50 of a few µs is readable, then 39 × 25 µs, 10 × 100 µs, edges at 3, 5, 10 and 20 ms, one overflow) in 10 s windows, with an exact mean, written on the pad's queue. The last completed window is in `GDHubStatus2` (the engine's meter line shows it) and the dext logs one line per window (§3.12).
- **Why a cross-queue RPC.** This is Karabiner's proven pattern. It removes the open question of calling `handleReport` from the user client's queue (sdk-api uncertainty).

### 3.8 Output report path (rumble) back to the app

```
host IOHIDDeviceSetReport(Output, id 3, 9 B) ─► AppleUserHIDDevice ─► GDHubVirtualPad::setReport (pad queue)
  report->CreateMapping(0,0,0,0,0,&map); bytes = map->GetAddress(); n = map->GetLength()
  ─► owner = GDHubCopyOwner() (+1 from the registry; T3: not through a pointer kept in the pad) ─► GDHubUCDeliverOutput(owner, slot, reportType, options & 0xFF, bytes, n)
        lock; action = outputAction (retain); args[9] = ++outputSeq; outputCount++ or outputDrops++; unlock
        uc->AsyncCompletion(action, kIOReturnSuccess, args, GDHUB_OUTPUT_ARG_COUNT); action->release()
  ─► if (action) CompleteReport(action, kIOReturnSuccess, n);  return kIOReturnSuccess;   // ANY report ID, even with no app
getReport: if (action) CompleteReport(action, kIOReturnUnsupported, 0); return kIOReturnUnsupported;
```
- **T3 status.** `GDHubUCDeliverOutput` itself is still D5 work and does not exist. The pad already looks the owner up through the registry in `setReport` (+1, released after use) and counts `outputsSeen` / `outputsNoOwner` in `GDHubStatus2`; delivery is the only part still missing, and `setReport` still completes with success.
- **The buffer includes the report-ID byte first.** macgip tests `bytes[0] == kRumbleReportID`. The dext forwards the raw bytes and also the ID from `options & 0xFF` (`H/IOHIDDevice.iig:94-96`), and the decoder accepts both forms.
- **`CompleteReport` is called whenever `action != nullptr`, with the same status the method returns.** procon2 and macgip both do this; Karabiner never does.
- **The completion is retained once and reused.** The app arms it once per connection; this is the NullDriver sample's stored-callback pattern. Fallback if callbacks stop after the first: re-arm after each callback (§8).

### 3.9 Teardown rules

1. **Client goes away** (`IOServiceClose`, app quit, crash or `kill -9`):
   - The kernel terminates the `IOUserUserClient`. Its `Stop` runs on the client's queue:
     - `ivars->stopped = true` (the watchdog stops acting)
     - **T3:** if the client owns the root: `root->DestroyPad(ownerGen)` (GDH_SYNC UC→ROOT). On the root's queue: `padSource = NONE`, registry pointer cleared, `Terminate(0)` on the pad. If that call fails, the client takes the pad out of the registry itself and terminates it.
     - `GDHubReleaseOwner(this)`. Inside one critical section the registry clears the owner and, if that owner's pad is somehow still registered, hands it back to be terminated. **No pad outlives its owner.**
     - release the client's specs and input buffers, then (under the lock) the `outputAction`
     - `timer->Cancel(^{ Stop(SUPERDISPATCH) })`
   - **T3 (plan 6.3): neutral before destroy.** `destroyPad` (used by `destroyDevice`, `Stop` and `devTerminate`) first calls `pad->postNeutralFrom(UC, …)` and ignores the result, then `DestroyPad`. Nothing waits in between. This adds one more synchronous UC→pad call to `Stop`, so a wedged pad queue now also delays the client's `Stop`.
   - **Before T3** the pad was a child of the client, so the kernel terminated it with the client. Now its provider is the root, so the client must ask. The pad's own `Stop` then runs on the pad's queue: it sets `stopping` (every later submission returns `NotReady`), calls `gdhr_pad_stopped` (a no-op after `DestroyPad`) and releases its spec, queue and buffers.
   - DriverKit has no `ClientClose` override, so the client's `Stop` is the "ClientClose" hook (`D/IOUserClient.iig` has none).
   - **New dependency:** G5 now needs the client's queue to run `Stop`. A wedged client queue would leave the pad in place (the 30 s orphan timer of the takeover plan arrives in T7).
2. **`destroyDevice`** calls `root->DestroyPad`, which calls `Terminate(0)`. That is asynchronous and calls `Stop` later (`IOService.iig:324-326`); the registry slot is free at once. The app waits **300 ms** before creating the next identity, so hosts never see two pads. A late `Stop` of the old pad cannot disturb a new one: it compares the pad pointer.
3. **`free()`** of the user client: `IOLockFree`, release `timer`, `timerAction`, `queue`, specs and buffers, then `IOSafeDeleteNULL(ivars, …)`.
4. **Driver update:** `DriverManager` destroys every device and closes the connection **before** it submits a replacement activation (§5.1). Whether replacement completes in place while a client is open is untested.
5. **Root `Stop`** (and `devTerminate`) also terminate a pad that is still registered. T4 `devTerminate` order: set `terminating` in the registry, destroy the pad, `Terminate(0)` on the tap (its `Stop` closes the interface), then `Terminate(0)` on the root. With `IOUserServerOneProcess` the old process survives a replacement unless every service of it ends (T0), so the tap must go too; the `terminating` flag makes a tap that the kernel re-matches in the meantime decline its Start, so nothing is left to keep the process alive. Root `Stop` also terminates the tap (belt and braces).

### 3.10 Watchdog (neutral report)

- **Setup in `Start`:**
  - `mach_timebase_info(&tb)` (`D/IOLib.h:174`)
  - `periodTicks = 250 ms → ticks` and `timeoutTicks = 2000 ms → ticks`
  - `CopyDispatchQueue(kIOServiceDefaultQueueName, &queue)`
  - `IOTimerDispatchSource::Create(queue, &timer)`
  - `CreateActionWatchdogFired(0, &timerAction)` (generated by iig from the `TYPE(...)` method)
  - `timer->SetHandler(timerAction)`
  - `timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, now + periodTicks, periodTicks / 10)`
- **`WatchdogFired`:** if the client has a pad, `!neutralised`, `lastActivity != 0` and `now - lastActivity > timeoutTicks`, then:
  - `pad->postNeutralFrom(UC, WATCHDOG)` on a +1 pad from the registry (T3 unchanged in timing: 250 ms tick, 2 s timeout)
  - set `neutralised = true` and `watchdogFires++`
  - log `"GDHub: watchdog …"`
  - re-arm `WakeAtTime` in every case.
- **The app keeps it fed.** The app sends `heartbeat` every 500 ms while any device is published. `send-on-change` therefore never trips the watchdog while an input is simply held (plan §7b).
- **Recovery.** The next `postReport` clears `neutralised`.
- **No locking needed.** The timer and `ExternalMethod` share the default queue, so they are serialized.

### 3.11 Team ID check and single owner

On the first `hello`:
```cpp
static bool callerIsGDHub(GDHubVirtualHIDUserClient * self) {
    OSDictionary * e = nullptr;
    if (self->CopyClientEntitlements(&e) != kIOReturnSuccess || !e) return false;   // IOUserClient.iig:264-271
    const char * team = OSDictionaryGetStringValue(e, "com.apple.developer.team-identifier");   // (the shipped code compares OSStrings by length and bytes)
    const char * app  = OSDictionaryGetStringValue(e, "com.apple.application-identifier");
    bool ok = team && strcmp(team, GDHUB_TEAM_ID) == 0 && (!app || strcmp(app, GDHUB_APP_ID) == 0);
    e->release();
    return ok;
}
```
- **Why the dext checks.** `allow-any-userclient-access` makes the kernel accept any caller. DTS: the dext "can always say 'nah'" (774297). A same-team caller is **not** allowed automatically on macOS: forum 806493 shows `0xe00002e2` "UC failed userclient-access check".
- **What is rejected.** `scripts/bundle.sh` builds and any unprovisioned binary fail the check, because they lack `team-identifier`.
- **Single owner.** `hello` then calls `GDHubClaimOwner` (T3: the registry holds the owner, retained, and returns a generation; `CreatePad` and `DestroyPad` carry that generation, so a stale client can neither create nor destroy). A second authorized GDHub, for example one started from `.xcodebuild/…/GDHub.app`, gets `kIOReturnExclusiveAccess` and cannot publish a second pad.

### 3.12 Logging

- DriverKit has no `os_log_create`. Use `os_log(OS_LOG_DEFAULT, "GDHub: …")` with `%{public}s` for strings.
- The dext process runs as `_driverkit`, with the process name = bundle ID (xcode-project §7).
- Log at least these events:
  - root start (with build)
  - client start/stop
  - hello result
  - create/destroy (`slot`, `vid:pid`)
  - spec rejection reason
  - watchdog fire
  - T3: one `pad meter` line per completed 10 s window with posts (`hop` and `hr` p50/p99/max/mean in µs; at most 192 characters by the generic estimator, about 144 in practice); the root start line carries the process id
  - T3: `sync inline (first at this site)` once per GDH_SYNC call site, and the topology probe lines `topo <where>: rootq=… ucq=… padq=… onq root/uc/pad=…` (root, user client and pad Start, first ExternalMethod, first submitInput; each once)
  - first output report per slot
- **Never log per report.**
- **Dext log lines are live-only** (`log stream` shows them as `kernel () GDHub…`; `log show` does not keep them) **and are cut at about 256 characters**: every line stays under 250.

---

### 3.13 Registry, queues and the call-order invariant (T3)

**Registry** (`Core/GDHubRegistryCore.c`, wrapped by `GDHubRegistry.cpp`). One process-global struct, zero-initialised, with a single lock (`IOLock` in the dext, a pthread mutex in the tests) that is installed by compare-and-swap on first use; whichever object runs first creates it, and nothing assumes the root started first.

| Field | Guard | Meaning |
|---|---|---|
| `root` | lock | retained; a different root replaces (and releases) a stale one, a stale `unregister` is ignored |
| `owner`, `ownerGen` | lock | retained owner client; generation > 0 while owned, 0 otherwise |
| `padState`, `pad`, `padSpec`, `padSpecCrc`, `padGen` | lock | slot state machine NONE → STAGED → CREATING → LIVE; `pad` retained (LIVE only), `padSpec` retained (STAGED..LIVE), `padGen` = generation that staged it |
| `padSource`, `desiredState` | atomic | who may post (NONE/UC; TAP in T4+); INERT |
| `counters[]`, `nonce`, `build`, `pid` | atomic | relaxed counters; identity |

**Rules.** The lock protects pointer fields and nothing else. Inside it the only call out is `retain` (an atomic increment). Every release happens after the unlock. Accessors return +1 copies, taken under the lock; this is safe because the registry's own reference keeps the object alive until the pointer is cleared under that same lock. No RPC can run under the lock, because the lock is private to the core and the core cannot name a GDHub class. Atomics are the compiler builtins `__atomic_*`: the core is plain C, the SDK's `atomic` and `stdatomic.h` live under `usr/include/c++/v1` (C++ only), and the builtins need neither. Locks are `IOLock` (`IOLib.h:381-427`); the SDK has no `os/lock.h` (`os_unfair_lock`) and no `pthread.h` (`usr/include/os/` holds only `atomic.h`, `availability.h`, `base.h`, `log.h`, `overflow.h`).

**Transitions.** `stage` (user client; owner generation checked; slot must be NONE, else Busy) → `begin_create` (root) → `started` (the pad, last thing in `handleStart`; refused unless CREATING) → `take` (destroy: `padSource = NONE`, then the pointer is cleared; a stale generation is refused; any state returns to NONE) or `stopped` (the pad stopped by itself: only if it is still the registered pad). `release_owner` takes the owner's pad in the same critical section.

**Queues: documented, measured on build 18, and still open.**
- *Documented:* every IOService gets its own default queue (`IOService.iig:171-175, 195-203`). `ExternalMethod` runs on a queue named `IOUserClientQueueExternalMethod` if one was set, else on "the default queue for the IOUserClient object" (`IOUserClient.iig:183-189, 203-209`). A queue runs one block at a time, and `OnQueue()` is true on the queue we run on and on any queue that invoked a second one (`IODispatchQueue.iig:99-105`). No header says that a service created with `Create` shares its creator's queue.
- *Generated code:* it names queues only in the class description (the user client declares `IOUserClientQueueExternalMethod`, the root and pad none: `GDHubVirtualHIDUserClient.iig.cpp:40-41, 70-71`). The choice of queue happens in the DriverKit runtime library, which is not in the SDK as source.
- *Measured (build 18):* inside the user client's `ExternalMethod`, `rootQueue->OnQueue()` was TRUE for both `CreatePad` and `DestroyPad`, and both calls completed at once. At the `postNeutralFrom` call of the same `destroyDevice` no violation was logged, which is consistent with the pad's queue not being on the stack (or with its queue pointer being null, which the probe will show).
- *Resolved on build 19 (takeover plan, "T3 results"):* root, user client and pad each have their own default queue; `ExternalMethod` runs on the **root's** queue (the provider's), the user client's own queue only runs the watchdog timer, and a call from the root's queue to `CreatePad`/`DestroyPad` is an inline nested call. The text below is kept as it was written before that measurement; where it says "user client queue" for external methods, read "root queue". The tap (T4) has its own queue as well.
- *So either* the user client uses the root's default queue object, *or* its methods are invoked nested inside the root's queue, *or* something else. The documents cannot tell these apart. The next build logs one `topo …` line at each Start and at the first `ExternalMethod` and `submitInput`, and puts three equality flags and two `OnQueue()` bytes into status2 (`topology`, `probeExt`, `probePad`). Until that is read, nothing in this section may be taken as fact beyond the list above.

| Object | Rank | Methods that run "on its queue" (documented) |
|---|---|---|
| user client | 1 | `ExternalMethod` (selectors 0-11), `WatchdogFired`, `Stop` |
| root | 2 | `Start`, `Stop`, `NewUserClient`, `CreatePad`, `DestroyPad` |
| tap | 3 | `Start`, `Stop`, `SetPowerState`, `TapTick` (50 ms), `ReportAvailable`, the `GDHubTapApply` pokes (T4, §3.14) |
| pad | 4 | `handleStart`, `Stop`, `submitInput`, `postNeutralFrom`, `setReport`, `getReport`, the only calls of `handleReport` |

**What does not depend on the topology.**
- The registry is lock- and atomics-based and assumes nothing about queues.
- The fields that the user client's `ExternalMethod`, watchdog and `Stop` all touch (`padCreated`, `neutralised`, `stopped`, `lastActivity`, `postCount`, `watchdogFires`) are accessed atomically, and the pad's `stopping` flag too, so one queue or several are both correct. `spec[]` and the input buffers are touched only by `ExternalMethod` and `Stop` (never by the watchdog).
- The pad's meter has one writer: `submitInput`, called only by the one user client, whose calls are sequential on whatever queue it runs.

**Call-order invariant.** The only synchronous cross-object calls are UC → root (`CreatePad`, `DestroyPad`) and UC → pad (`submitInput`, `postNeutralFrom`). Calls go only toward a higher rank. The pad calls no GDHub object (it reads the registry and calls the kernel). The root calls no GDHub object synchronously either: `Terminate(0)` on a pad is a kernel call that returns before the pad's `Stop` runs. `GDHubUCDeliverOutput` (D5) will take only the client's leaf lock and use `AsyncCompletion`. With these four call sites no wait cycle is expressible whatever the queue topology: a cycle needs something that holds the target queue while waiting on the user client, and no code does.

**`GDH_SYNC(callerRank, targetRank, targetQueue, what)`** wraps all four call sites, in every build.
- *Compile time:* `callerRank < targetRank` is a `static_assert`. That is the only rank check, and it makes a run-time rank violation impossible: `syncViolations` stays in the status2 layout (offset 56) and reads 0 by construction.
- *Run time:* if the target's queue is already on this thread's queue stack (`OnQueue()`), the call is an inline nested call, not a cycle, because the thread already owns that queue. It is counted in `syncInline` (status2 offset 160) and logged once per call site. This is the situation build 18 found for `CreatePad` and `DestroyPad`, which it had wrongly called violations.

**Failure paths.** Every path leaves the registry consistent:
- the client builds its input buffers before staging anything, and releases them if staging or `CreatePad` fails (`unstage` is idempotent);
- `CreatePad` that fails empties the slot and terminates a pad that exists but never registered, or registered and then failed a later start step. If Create returns before the pad's `Start` (IOService.iig:299-315 does not say which comes first), the root logs `CreatePad: Create returned before the pad started`, counts `createEarly`, and returns success without terminating anything; the user client's `createDevice` then reports failure and empties the slot, because the engine treats a NotReady post as a lost device (it does not wait: `IOSleep` would block a queue that may be the root's own). Build 18 measured `pad start` before `createDevice … created`, so this case does not occur on this OS. A slot stuck in CREATING is emptied by `destroyDevice`, by the client's `Stop` (`release_owner`) and by the root's `Stop`, and a pad that registers afterwards is refused by `gdhr_pad_started`. A `createDevice` that reports failure, whatever state the pad reached (even LIVE), always leaves the slot empty;
- a second `createDevice` is Busy at the client (`padCreated`) and again at the registry (slot not NONE); a stale client record (the pad stopped behind its back) is dropped;
- a destroy without a create, or a destroy by a stale generation, changes nothing;
- the pad starts only while the root is creating it, so no other path can start a pad;
- a late `Stop` of an old pad cannot clear a newer pad;
- an early `Stop` (root, pad) is safe: unregister/stopped compare pointers and ignore strangers.

### 3.14 The receiver tap (T4)

`GDHubReceiverTap` is a plain `IOService` that matches interface 3's `IOHIDInterface` only (vendor 6940, product 14856 = 3A08, page 65368, usage 1; `IOProbeScore 1000`, about 8200 in total against Apple's 1201) and runs in the root's process (`IOUserServerOneProcess` on both personalities). It does **nothing per frame unless an owner asked for COUNT in this process**, and in T4 it translates and posts nothing. Plan sections 3.2, 4.5, 6.1, 6.4, 6.5 are the specification; this section is what the code does.

**States and transitions** (all applied on the tap's own queue).

| From | To | Trigger | What happens |
|---|---|---|---|
| (process start) | INERT | any relaunch | `desiredState` is zero in a new process. The tap attaches, the interface is **not** opened |
| INERT | COUNT | owner's `setForwarding(COUNT)` (root queue stores the state **only if the caller is the current owner**, under the registry lock, and pokes) or the tap's timer | pool of 8 × 64 B buffers created once, each `AddReportToPool`, then `Open(this, 0, action)`. On error: `openFailures++`, `lastError`, retry no sooner than 500 ms later, log rate-limited |
| COUNT | INERT | `setForwarding(INERT)`, or the owner went away (user client `Stop` resets the state inside the registry's critical section and pokes), or tap `Stop` | `Close(this, 0)`, `opened = 0` (even if `Close` fails: counted in `closeFailures`, the next Open is still attempted), the whole pool released, published to status2 |
| COUNT | COUNT (paused) | `SetPowerState(Off)` | `powered = 0`; frames are counted as `framesIgnored` (the buffer is still re-added). `On` resumes. The interface is not closed: the receiver re-enumerates on wake and a new tap instance starts |
| (new instance) | INERT or COUNT | Start | `gdhr_register_tap` reads `desiredState` in the same critical section. Normally INERT; after a re-enumeration inside the same process it finds COUNT still asked for |
| any | gone | `Stop` | order: `stopping` (atomic) → `Close` → `gdhr_unregister_tap` → timer cancel → `Stop(SUPERDISPATCH)` from the cancel handler |

**The exact condition under which `Open` is called** (`gdh_tap_decide`, `Core/GDHubRegistryCore.c`, called from `GDHubTapApply`, the only caller): `desiredState == COUNT` (only selector 9 sets it, owner loss clears it, a new process starts at INERT) **and** the tap is not stopping **and** `powered` **and** the interface is not already open **and** the retry time has passed. A unit test enumerates all 64 input combinations: exactly one opens.

**Control path.** Selector 9 runs on the root's queue: it stores `desiredState` (atomic) and calls `GDHubPokeTap`, which takes +1 copies of the tap and its queue from the registry and `DispatchAsync`es (`IODispatchQueue.iig:132-133`, never waits) a block that runs `GDHubTapApply` on the tap's queue and releases the tap. The tap's timer runs the same function as a backstop for a lost poke and drives the Open retry. It is adaptive: 50 ms while desired != applied, an Open retry is pending or the dext is terminating, otherwise 1 s (no more than one wakeup per second when INERT and settled). status2 tells the paths apart: `pokesRun` counts pokes that ran on the tap's queue and `tickApplies` counts the Open/Close attempts the timer made.

**Waits-for graph, with the tap.** Root queue → pad queue (`submitInput`, `postNeutralFrom`) and root queue → registry lock (leaf). Tap queue → kernel (`Open`, `Close`, `AddReportToPool`, `Create` of buffers) and registry lock (leaf). Nothing calls the tap synchronously (pokes are asynchronous; the kernel's `Start`, `Stop`, `SetPowerState` and `ReportAvailable` are kernel callbacks onto its queue; `GDHubTapReadMeter` reads a seqlock and enters no queue). The tap calls no GDHub object. The tap node has no outgoing edge to any GDHub queue and no incoming synchronous edge, so it can lie on no cycle.

**Pool and report path.** Strategy B of the T0 probe: 8 buffers, each re-added after its report. `poolMiss` counts reports that arrived in a kernel buffer or in a buffer of a dropped pool. The bookkeeping (`gdh_pool_*`, in the core) runs before the `opened` check, so ownership is right whatever the state. **On Close the whole pool is released** and a fresh one is built at the next Open (`reopens` counts these): nobody knows whether the kernel keeps its pool across a Close, and a late report that carries an old buffer then matches nothing and is never dereferenced. Nothing is mapped or copied in T4 (only the report ID, the length and the timestamp are read), so there is no per-frame allocation. The kernel-to-driver delay (`now - timestamp`) feeds the meter core's second histogram; one `tap meter` line per 10 s window, never per frame.

**Lifetime.** An `OSAction` retains its target until it is cancelled or freed (`OSAction.iig:69-70`), and the tap holds its two actions, so the tap, its queue, timer, pool and a reference on the `IOHIDInterface` would never be freed. `Stop` therefore, after `Close`, cancels `reportAction` and `timerAction` in the timer's cancel handler (`OSAction::Cancel`, `OSAction.iig:100-105`: afterwards the action can only be freed), then calls the super `Stop`, releases the pool and the provider. `tap free #N` is logged in `free()` and counted (`tapFrees`): `tapStarts == tapFrees + live instances`. Close precedes Cancel. The user client keeps `timerAction` in the same way and probably leaks the same way; `client free` is logged so a count of `client start` against `client free` measures it.

**Self-terminate.** devTerminate and root `Stop` reach only the registered tap. When `terminating` is set, every tap's timer calls `Terminate(0)` on itself once and stops re-arming, so an older instance or a second receiver's tap cannot keep the shared process alive. `IOService.iig:317-326` documents `Terminate` for objects made with `Create()`; the header does not forbid it for a matched service. If it fails the tap logs the code and stays; the process then needs the controller switched off or a reboot. If `devTerminate`'s own `Terminate(0)` of the root fails, the flag is cleared again so taps can attach in a process that did not end.

**"Restart driver (dev)" (m5).** The menu item ends the process through `devTerminate` and the root is not re-matched afterwards (it matches `IOUserResources` once). While the tap personality is installed, the next 3A08 enumeration can start a process that contains only a tap and no root, so `devTerminate` is unreachable and the tap cannot be ended. **Reboot after "Restart driver (dev)"** (or use the upgrade procedure, which replaces the dext). Possible alternative, not implemented: make the tap decline its `Start` when no root has registered within N seconds, which lets Apple's driver take the interface but makes a controller that attaches during a slow root start (the T0 relaunch showed either order) lose its tap until the next enumeration.

**Never breaks the engine path.** The tap takes only the `IOHIDInterface`. The engine reads the `IOHIDDevice`, which is untouched. If a user-space client has seized the device, `Open` fails; the tap counts it, retries every 500 ms from the timer and never spins.

**Rollback lever.** A `GDHUB_TAP_DECLINE=1` build makes the tap's `Start` log, undo the super `Start` and return an error, so Apple's driver attaches to interface 3; it also drops `CAP_TAP`.

**Engine side (`TapSupervisor`).** `inputPath = count` sends COUNT after hello; every other value sends INERT; the value is polled once a second. The dext's `instanceNonce` of the instance on which COUNT was accepted is remembered. A different nonce at a later hello or status2 (relaunch or replacement) **trips** the supervisor: no re-arm for the rest of this engine run, because a crash in the COUNT path would otherwise become a crash loop at the reconnect back-off. The trip clears when the stored `inputPath` value changes (any change of the stored text, e.g. `engine` and then `count`, or `Count`; an identical rewrite cannot be seen) or the engine restarts. A re-enumeration inside the same dext process keeps the nonce and needs no engine action. Selector-11 calls from the supervisor: none while INERT and settled; 1 per second while armed; 10 per second for at most 5 s after the controller interface comes up, and only if the dext has a tap (it logs `tap: not present 5 s after the controller interface came up` and stops).

**Tests** (off-device): `DextCoreTapTests`, `InputPathTests`, `TapSupervisorTests`, `DextTapSourceTests`, and the capability tests in `DextClientCapabilityTests`.

---

## 4. Pad identity and descriptors

### 4.1 What decides adoption (gc-matching, sdl-descriptors; all *local* or source-cited)

**Kernel (GameController)**
- `AppleGameControllerPersonality.kext` matches `IOHIDInterface` on **VendorID + ProductID only**: probe score 1000, and VID +5000 / PID +1000 gives **7000**, which beats `AppleUserHIDEventDriver` at 1201.
- `AppleGCHIDUserEventDriver::probe` accepts a non-Apple DriverKit device **only** when the personality has `GCIOMatchVirtual = true`.
- Exactly 14 VID:PIDs have it:
  - ps5: 054C:0CE6, 054C:0DF2
  - ps4: 054C:09CC, 054C:05C4
  - switch: 057E:2009
  - xbox: 045E:02FD, **02E0**, 0B20, **0B13**, 0B23, 0B02, 0B05, 0B22, 0B3C
- **What does not matter:** Transport, VersionNumber, Built-In and PrimaryUsage are never read.
- **What is rejected:** `PrimaryUsagePage == 0x84`, `GameControllerEligible == false`, `GCSyntheticDevice == true`.
- **Every other path refuses our bundle ID.** For a DriverKit device the MFi merger and the dynamic database path require a `CFBundleIdentifier` beginning `com.apple.`.
- **Proof on this Mac:** Razer's 028E pad is bound to `AppleUserHIDEventDriver` with `GameControllerSupport = False`.

**SDL (HIDAPI on IOHIDManager, non-exclusive open)**
- The first top-level collection must be GD GamePad (1/5).
- SDL2 2.24.2 and 2.32 pick Bluetooth parsing for 045E Xbox pads **by PID** (`SDL_IsJoystickBluetoothXboxOne`). 0B13 and 02E0 are always BT, so they always get report 0x01.
- SDL3 3.4 picks BT parsing by `Transport` beginning with `"Bluetooth"`. Otherwise it uses the wired GIP parser (report 0x20).
- A **16-byte** report 0x01 uses the compact button order. **> 16 bytes** uses the gapped order.
- Guide comes from report 0x02 in the 16-byte mode.
- Rumble is output report 0x03, 9 bytes: `03 0F LT RT L R FF 00 EB`.

**GameController and button order: what PR #208 shows and what it does not.** libvirtualhid PR #208 (merge `dd0ff885`, 2026-10-30, `src/platform/macos/macos_xbox_transport.hpp`) is the only end-to-end GameController result for a virtual Xbox pad. Its proven setup is **not** `xbox-bt16`:
- Report 0x01 is **declared as 17 bytes**: Btn1-15 contiguous, 1 pad bit, then Consumer Record (0x0C:0xB2) and 7 pad bits.
- It is **sent as 25 bytes**, zero-padded to the broker's fixed input size.
- It sits in a dual descriptor with the GIP collection, so `MaxInputReportSize` is 25.
- The device is an `IOHIDUserDevice`. The broker requests Transport `Bluetooth`, but the code comment says the device reports `Virtual`.
- PID 0B13 for the series profile, 0B20 for the one profile.

What it shows:
- GameController reads the compact order: A, B, X, Y, LB, RB, View, Menu, then LS and RS.
- Guide and Share never reach GameController.
- The PR's gapped test put gapped bits under a **contiguous** Btn1-15 descriptor and got "X arrives as Y". That result fits decoding by usage number **and** decoding by bit position, so it does not tell us which one GameController uses.

What it does not show: a 16-byte report 0x01, a BLE Transport, or a DriverKit device.
- **0B13 with a 16-byte report is a combination no real pad produces.** SDL's notes in `SDL_hidapi_xboxone.c` (2.24.2, 2.32.x, 3.4.x) say the 16-byte report with a separate Guide report comes from the original Xbox One S on firmware 3.1.1221. The Series X on firmware 5.5.2641 sends 17 bytes. GameController may therefore not handle 0B13 at 16 bytes.
- **045E:02E0 (`USB_PRODUCT_XBOX_ONE_S_REV1_BLUETOOTH`) is the PID that firmware uses natively.** Its own personality, "Xbox Wireless Controller 0x2e0 IOService", has `GCIOMatchVirtual = true` and category `xbox` (*local*).
- **Every SDL takes the same path for 02E0 as for 0B13.** 02E0 is in `SDL_IsJoystickBluetoothXboxOne` in 2.24.2, 2.32.x and 3.4.x, so all of them use the 16-byte compact parser. SDL 2.32 and 3.x also treat 02E0 as an Xbox One without Share (`SDL_IsJoystickXboxSeriesX` is false), which matches a report that has no Share bit.
- **Hence `xbox-bt16-02e0` (§4.2), tested next to `xbox-bt16` at M1 (§7.3).**

Fallback order when GameController fails (§8.1 row 15):
- **Pad appears in GameController but its buttons are shifted.** GameController decodes by bit position, so `xbox-bt17-remap` cannot help. Try `xbox-bt16-02e0`, then `xbox-pr208`.
- **Pad does not appear in GameController at all.** Try `xbox-bt16-02e0`, then `xbox-bt17-remap`, then `xbox-pr208`.

### 4.2 Identity catalogue (`PadIdentity.swift`, data only)

| id | Role | VID:PID | VersionNumber | Transport | Manufacturer / Product | Serial | LocationID | ReportInterval | Descriptor | Input reports (ID:bytes incl. ID) | Output |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `xbox-bt16-02e0` | **Primary, preferred** (M1 tests it next to `xbox-bt16`; the default identity) | 045E:02E0 (1118:736) | 0x0513 (1299) | `"Bluetooth Low Energy"` | `"Microsoft"` / `"Xbox Wireless Controller"` | `"GDHub-1"` | 0x47444801 (1195657217) | 4000 µs | §4.3, 285 B | 0x01:16, 0x02:2 | 0x03:9 |
| `xbox-bt16` | **Primary** (M1 candidate; use if only 0B13 works) | 045E:0B13 (1118:2835) | 0x0513 | `"Bluetooth Low Energy"` | same | same | same | 4000 | §4.3, 285 B | 0x01:16, 0x02:2 | 0x03:9 |
| `xbox-bt17-remap` | Fallback 1 (only when the pad does not appear in GameController at all; §8.1 row 15) | 045E:0B13 | 0x0513 | `"Bluetooth Low Energy"` | same | same | same | 4000 | §4.4, 315 B | 0x01:17 | 0x03:9 |
| `xbox-dual-usb` | Fallback 2 (BLE transport causes trouble, or SDL3 gets no input) | 045E:0B13 | 0x0513 | `"USB"` | same | same | same | 4000 | §4.5, 312 B | 0x01:16, 0x02:2, 0x20:25 | 0x03:9, 0x09:13 |
| `xbox-pr208` | Fallback 2b (GameController still fails; GameController and SDL3 hosts only, **wrong in SDL2**) | 045E:0B13 | 0x0513 | `"Virtual"` | same | same | same | 4000 | §4.5, 310 B | 0x01:17 **sent as 25**, 0x20:25 | 0x03:9, 0x09:13 |
| `x360-usb` | Fallback 3 (SDL2-only hosts; never GameController) | 045E:028E (1118:654) | 0x0114 (276) | `"USB"` | `"Microsoft"` / `"Xbox 360 Controller"` | same | same | 4000 | §4.6, 122 B | 0x00:20 (no IDs) | 0x00:4 |

Common to every pad identity:
- PrimaryUsagePage 1 and PrimaryUsage 5.
- CountryCode 0, flags 0.
- No `HIDVirtualDevice` key. DriverKit never sets it (gc-matching §6).

Rules that never change (plan decision 4):
- Never 028E with version 0 or 1, which are Steam's virtual-pad markers.
- Never the name "GamePad-N". thrustmacos saw no input in native GFN with that name.
- Never publish while another device with the identity's VID:PID exists (§5.4 duplicate check). OJD's GameControllerCompatible profile uses 0B13, and duplicate VID:PIDs break rumble (OJD wiki). `xbox-bt16-02e0` avoids that clash.
- VersionNumber stays 0x0513 for every Xbox identity. GameController never reads it (§4.1), and SDL's Xbox One driver only logs it.

**`PadIdentity.spec()` builds the `DeviceSpec`:**
- `inputReports` comes from `HIDReportSizer(descriptor)`.
- `sendLengths` comes from the identity. It is `[0x01: 25]` for `xbox-pr208` and empty for every other identity.
- `neutralReports` is `builder.reports(for: .neutral)`, ordered like `inputReports`, each at its send length.
- **Nothing in the dext is identity-specific.**

**Users can override strings.** `UserDefaults` `vhid.pad.productOverride` replaces the product string (cosmetic test only).

### 4.3 Primary: `xbox-bt16` / `xbox-bt16-02e0` descriptor (285 bytes; verified with a HID size parser: input 0x01 = 16 B, 0x02 = 2 B, output 0x03 = 9 B)

`xbox-bt16-02e0` uses this descriptor, the `xboxBT16` builder and these neutral reports unchanged. Only ProductID differs: 736 (0x02E0) instead of 2835 (0x0B13).

```
05 01 09 05 A1 01            // GD, Game Pad, Collection(Application)
85 01                        //  Report ID 1
09 01 A1 00 09 30 09 31 15 00 27 FF FF 00 00 95 02 75 10 81 02 C0   // X,Y   bytes 1-4
09 01 A1 00 09 33 09 34 15 00 27 FF FF 00 00 95 02 75 10 81 02 C0   // Rx,Ry bytes 5-8
05 01 09 32 15 00 26 FF 03 95 01 75 0A 81 02 15 00 25 00 75 06 95 01 81 03 // LT 10b + pad (9-10)
05 01 09 35 15 00 26 FF 03 95 01 75 0A 81 02 15 00 25 00 75 06 95 01 81 03 // RT 10b + pad (11-12)
05 01 09 39 15 01 25 08 35 00 46 3B 01 66 14 00 75 04 95 01 81 42          // hat, 0 = null (13 lo)
75 04 95 01 15 00 25 00 35 00 45 00 65 00 81 03                            // nibble pad (13 hi)
05 09 19 01 29 0A 15 00 25 01 75 01 95 0A 81 02   // Btn1-10: A B X Y LB RB View Menu | LS RS (14-15)
15 00 25 00 75 01 95 06 81 03                     // pad -> 16 bytes
05 0C 0A 23 02 85 02 15 00 25 01 95 01 75 01 81 02 15 00 25 00 75 07 95 01 81 03 // 0x02: AC Home = Xbox
05 0F 09 21 85 03 A1 02                           // 0x03 OUTPUT rumble
 09 97 15 00 25 01 75 04 95 01 91 02 15 00 25 00 75 04 95 01 91 03 // enable nibble
 09 70 15 00 25 64 75 08 95 04 91 02              // LT RT L R magnitude 0-100
 09 50 66 01 10 55 0E 15 00 26 FF 00 75 08 95 01 91 02 // duration
 09 A7 15 00 26 FF 00 75 08 95 01 91 02           // start delay
 65 00 55 00 09 7C 15 00 26 FF 00 75 08 95 01 91 02 C0 // loop count
C0
```

**Report 0x01 layout (builder `xboxBT16`).** `PadState` uses XInput conventions: y up = +1, sticks −1…1, triggers 0…1.

| Byte | Content | From `PadState` |
|---|---|---|
| 0 | 0x01 | — |
| 1-2 | LX u16 LE, centre 0x8000 | `u16(lx)` where `u16(v) = UInt16(((clamp(v,-1,1)+1) * 32767.5).rounded(.toNearestOrAwayFromZero))` |
| 3-4 | LY u16, 0 = up | `u16(-ly)` |
| 5-6 / 7-8 | RX / RY | `u16(rx)`, `u16(-ry)` |
| 9-10 / 11-12 | LT / RT 10-bit LE | `UInt16((clamp(t,0,1) * 1023).rounded(.toNearestOrAwayFromZero))` |
| 13 | hat: 0 none, 1 N, 2 NE, 3 E, 4 SE, 5 S, 6 SW, 7 W, 8 NW; high nibble 0 | Opposite directions cancel (up+down → neither) |
| 14 | A 0x01, B 0x02, X 0x04, Y 0x08, LB 0x10, RB 0x20, View 0x40, Menu 0x80 | |
| 15 | LS 0x01, RS 0x02 | |

- **Report 0x02:** `02, guide ? 0x01 : 0x00`.
- **Neutral reports:** `01 00 80 00 80 00 80 00 80 00 00 00 00 00 00 00` and `02 00`.

**Expected behaviour and what to verify**

| Where | Expected | Verify |
|---|---|---|
| ioreg (H1) | `GDHubVirtualPad <class AppleUserHIDDevice>`, VendorID 1118, ProductID 2835 (736 for `-02e0`), VersionNumber 1299, Transport "Bluetooth Low Energy", SerialNumber "GDHub-1", LocationID 1195657217, MaxInputReportSize 16, MaxOutputReportSize 9, **no** `HIDVirtualDevice`. Child `IOHIDInterface` bound to **`AppleGCHIDUserEventDriver`**. Device `IOCFPlugInTypes` contains `7DDEECA8…`. That entry alone does not prove adoption: Razer's non-adopted pad here also lists `7DDEECA8…` → `IOHIDLib.plugin` (*local*). The bound driver is the proof | `scripts/vhid-check.sh` (§7.2) |
| System Settings › Game Controllers (H2) | The pane appears and lists "Xbox Wireless Controller" | Visual check |
| GameController | `extendedGamepad != nil`, category Xbox. A, B, X, Y, LB, RB, View, Menu, LS and RS correct. Guide and Share are not visible to GameController (PR #208) | `scuf-envision/tools/gcprobe --watch` |
| Steam (SDL3 3.4) (H3) | HIDAPI Xbox One driver, `is_bluetooth` (Transport prefix) → 0x01 parser, 16 B → compact. Guide from 0x02. Rumble via 0x03 | Controller test screen. `controller.txt`: one "device opened", and no second MFi copy. An MFi copy shows as 045e:02e0, 045e:0b13 or 05ac:0004; with `xbox-bt16-02e0` the HIDAPI pad is 045e:02e0 too, so count the controllers rather than match the PID |
| Shadow (SDL2 2.24.2) (H5) | HIDAPI Xbox One, BT by PID, compact 16 B | Alt+Cmd+O lists one pad. `joy.cpl` in the VM shows every input. Watch for the 2.24 MFi + HIDAPI duplicate race (SDL #11002) |
| GeForce NOW (SDL2 2.32.10 + Forge) (H4) | HIDAPI BT by PID, or GameController when Forge is on. Both decode compact | `geronimo.log`: "Opened controller named …" once, no "Skipping (SDL\|Forge) gamepad" |
| Rumble (H7) | Hosts write `03 0F LT RT L R FF 00 EB` | App log `rumble …` (D5) |

### 4.4 Fallback 1: `xbox-bt17-remap` (315 bytes; input 0x01 = 17 B, output 0x03 = 9 B; no report 0x02)

This is §4.3 with everything from `05 09 19 01 …` through the end of the report 0x02 block replaced by:
```
05 09 15 00 25 01 75 01 95 02 19 01 29 02 81 02 95 01 81 03 95 02 19 03 29 04 81 02
95 01 81 03 95 02 19 05 29 06 81 02 95 02 81 03 95 02 19 07 29 08 81 02
95 01 09 0B 81 02 95 02 19 09 29 0A 81 02 95 01 81 03
05 0C 0A B2 00 95 01 81 02 95 07 81 03
```
- **Builder `xboxBT17Gapped`:**
  - bytes 0-13 as in §4.3
  - byte 14: A 0x01, B 0x02, X 0x08, Y 0x10, LB 0x40, RB 0x80
  - byte 15: View 0x04, Menu 0x08, Guide 0x10, LS 0x20, RS 0x40
  - byte 16: Share 0x01
- **Neutral report:** `01 00 80 00 80 00 80 00 80 00 00 00 00 00 00 00 00`.
- **Where it works.** SDL reads the gapped bits correctly, because > 16 B selects the gapped parser. GameController works only if it decodes buttons by HID usage number rather than by bit position. That is unknown: PR #208's gapped test cannot tell the two apart (§4.1).
- **When to use it.** Only when the pad does not appear in GameController at all with `xbox-bt16-02e0` (§8.1 row 15). If GameController lists the pad but its buttons are shifted, GameController decodes by position, and this remap cannot help. In that case go to `xbox-bt16-02e0`, then `xbox-pr208` (§4.5).
- **PR #208's exact setup is `xbox-pr208`, not a variant of this descriptor.** PR #208 declares Btn1-15 contiguously (Guide = Btn11 at byte 15 bit 2), then 1 pad bit, then the Consumer Record bit at byte 16 bit 0 and 7 pad bits. It sends the report as 25 bytes. Pick it per host (identity switching at host launch, plan P5).

### 4.5 Fallback 2: `xbox-dual-usb` (312 bytes) and Fallback 2b: `xbox-pr208` (310 bytes)

Both identities add libvirtualhid's GIP vendor collection (report 0x20 in, 0x09 out) and share the GIP builder below.

**`xbox-dual-usb`**

- **Descriptor:** §4.3 followed by libvirtualhid's MIT GIP vendor collection:
  ```
  06 00 FF 09 01 A1 01 15 00 26 FF 00 75 08 85 20 95 18 81 02 85 09 95 0C 91 02 C0
  ```
- **Reports:**
  - input: 0x01:16, 0x02:2, 0x20:25
  - output: 0x03:9, 0x09:13
- **Send order:** on every change, send 0x01 (and 0x02 when Guide changed), then 0x20.
- **Which host reads what:**
  - SDL3 with Transport `USB` → wired GIP parser → reads 0x20. This is PR #208's proven Steam path.
  - SDL2 (BT by PID) and GameController read 0x01 and ignore 0x20.

GIP report 0x20 (25 B; libvirtualhid `xbox_gip_transport_input_report`):

| Byte | Value |
|---|---|
| 0 | 0x20 |
| 1, 2 | 0x00 |
| 3 | 0x10 |
| 4 | Menu 0x04, View 0x08, A 0x10, B 0x20, X 0x40, Y 0x80 |
| 5 | Up 0x01, Down 0x02, Left 0x04, Right 0x08, LB 0x10, RB 0x20, LS 0x40, RS 0x80 |
| 6-7 / 8-9 | LT / RT 10-bit LE (same values as BT bytes 9-12) |
| 10-11 / 14-15 | LX / RX int16 LE = `Int16(bitPattern: btU16 ^ 0x8000)` |
| 12-13 / 16-17 | LY / RY int16 LE = `Int16(bitPattern: (0xFFFF - btU16) ^ 0x8000)` (up positive) |
| 18 | Share 0x01 |
| 19 | 0 |
| 20 | 0x07 |
| 21 | 0x20 |
| 22 | 0 |
| 23 | 0x01 |
| 24 | Guide 0x01 |

- **Neutral 0x20:** `20 00 00 10 00 00 00 00 00 00 00 00 FF FF 00 00 FF FF 00 00 07 20 00 01 00`.
- **Output 0x09 (13 B) rumble:** when `r[0] == 0x09 && r[3] == 0x09`, it is equivalent to `[0x03] + r[5..<13]`.

**`xbox-pr208` (310 bytes; input 0x01 = 17 B declared and 25 B sent, 0x20 = 25 B; output 0x03 = 9 B, 0x09 = 13 B; `MaxInputReportSize` 25)**

This is a byte-for-byte copy of libvirtualhid's `xbox_gip_report_descriptor()` from PR #208, which is MIT client code (§1). It is `make_xbox_bluetooth_report_descriptor(false)` (283 B) followed by the same 27-byte GIP collection that `xbox-dual-usb` uses. The bytes were extracted from the PR sources and compared byte for byte, and the size parser confirms the lengths above.
```
05 01 09 05 A1 01            // GD, Game Pad, Collection(Application)
85 01                        //  Report ID 1
09 01 A1 00 09 30 09 31 15 00 27 FF FF 00 00 95 02 75 10 81 02 C0   // X,Y   bytes 1-4
09 01 A1 00 09 33 09 34 15 00 27 FF FF 00 00 95 02 75 10 81 02 C0   // Rx,Ry bytes 5-8
05 01 09 32 15 00 26 FF 03 95 01 75 0A 81 02 15 00 25 00 75 06 95 01 81 03 // LT 10b + pad (9-10)
05 01 09 35 15 00 26 FF 03 95 01 75 0A 81 02 15 00 25 00 75 06 95 01 81 03 // RT 10b + pad (11-12)
05 01 09 39 15 01 25 08 35 00 46 3B 01 66 14 00 75 04 95 01 81 42          // hat, 0 = null (13 lo)
75 04 95 01 15 00 25 00 35 00 45 00 65 00 81 03                            // nibble pad (13 hi)
05 09 19 01 29 0F 15 00 25 01 75 01 95 0F 81 02   // Btn1-15 contiguous (14 b0 … 15 b6)
15 00 25 00 75 01 95 01 81 03                     // 1 pad bit (15 b7)
05 0C 0A B2 00 15 00 25 01 95 01 75 01 81 02      // Consumer Record = Share (16 b0)
15 00 25 00 75 07 95 01 81 03                     // 7 pad bits -> declared 17 bytes
05 0F 09 21 85 03 A1 02                           // 0x03 OUTPUT rumble (identical to §4.3)
 09 97 15 00 25 01 75 04 95 01 91 02 15 00 25 00 75 04 95 01 91 03
 09 70 15 00 25 64 75 08 95 04 91 02
 09 50 66 01 10 55 0E 15 00 26 FF 00 75 08 95 01 91 02
 09 A7 15 00 26 FF 00 75 08 95 01 91 02
 65 00 55 00 09 7C 15 00 26 FF 00 75 08 95 01 91 02 C0
C0
06 00 FF 09 01 A1 01 15 00 26 FF 00 75 08 85 20 95 18 81 02 85 09 95 0C 91 02 C0 // GIP collection (as xbox-dual-usb)
```
- **Identity.** 045E:0B13, VersionNumber 0x0513, Transport `"Virtual"`. `Virtual` is what PR #208's `IOHIDUserDevice` reported, per its code comment. The other strings are as in §4.2. `sendLengths = [0x01: 25]`, so the input table is `01 19 11 00 20 00 19 00`.
- **Report 0x01, 25 B (builder `xboxPR208`, after libvirtualhid's `xbox_bluetooth_transport_input_report`):**

  | Byte | Content |
  |---|---|
  | 0-13 | As §4.3: ID, sticks, triggers, hat |
  | 14 | A 0x01, B 0x02, X 0x04, Y 0x08, LB 0x10, RB 0x20, View 0x40, Menu 0x80 (compact, as §4.3) |
  | 15 | LS 0x01, RS 0x02, Guide 0x04 (Btn11) |
  | 16 | Share 0x01 (Consumer Record) |
  | 17-24 | 0. This is padding beyond the declared 17 bytes; IOHIDFamily reads only the declared fields |
- **Report 0x20:** the GIP builder above, unchanged.
- **Send order.** On every change, send 0x01, then 0x20. This is the PR's client order.
- **Neutral reports:** `01 00 80 00 80 00 80 00 80` followed by 16 × `00` (25 B), then the 0x20 neutral above.
- **Which host reads what:**
  - **GameController** reads 0x01. This is PR #208's proven path. Guide and Share stay invisible to GameController.
  - **SDL3 / Steam.** Transport `Virtual` is neither `USB` nor a `Bluetooth` prefix, so `bus_type` is unknown and `is_bluetooth` is false (`SDL_hidapi_mac_hid.c`). SDL3 therefore uses the wired GIP parser on 0x20, which is PR #208's proven Steam path.
  - **SDL2 2.24.2 / 2.32 (Shadow, the GFN SDL path) is wrong.** 0B13 is Bluetooth by PID, so SDL2 parses 0x01. The report arrives as 25 B, and anything over 16 B selects the gapped parser, so the compact bits are misread. Never pick `xbox-pr208` for an SDL2 host.
- **Remaining differences from PR #208:**
  - Our pad is an `AppleUserHIDDevice` from a dext, not an `IOHIDUserDevice`.
  - The dext also sets LocationID, CountryCode, ReportInterval and PrimaryUsagePage/PrimaryUsage.

### 4.6 Fallback 3: `x360-usb` (122 bytes; input 20 B and output 4 B, no report IDs; 360Controller `xbox360hid.h` layout)

```
05 01 09 05 A1 01 75 08 95 02 81 01               // bytes0-1 const (send 00 14)
05 09 15 00 25 01 75 01 95 04 19 0C 29 0F 81 02   // byte2 b0-3 Dpad = Btn12-15
95 04 09 09 09 0A 09 07 09 08 81 02               // b4-7 Start9 Back10 LS7 RS8
95 03 09 05 09 06 09 0B 81 02 95 01 81 01         // byte3 LB5 RB6 Guide11, pad
95 04 19 01 29 04 81 02                           // b4-7 A B X Y = Btn1-4
05 01 15 00 26 FF 00 75 08 95 02 09 32 09 35 81 02 // LT=Z RT=Rz
16 00 80 26 FF 7F 75 10 95 04 09 30 09 31 09 33 09 34 81 02 // X Y Rx Ry (Y up=-32768)
75 08 95 06 81 01                                 // bytes14-19 const
06 00 FF 09 01 15 00 26 FF 00 75 08 95 04 91 02 C0 // out: 00 04 big small
```

**Builder `x360`:**

| Byte | Content |
|---|---|
| 0-1 | `00 14` |
| 2 | Up 0x01, Down 0x02, Left 0x04, Right 0x08, Menu/Start 0x10, View/Back 0x20, LS 0x40, RS 0x80 |
| 3 | LB 0x01, RB 0x02, Guide 0x04, A 0x10, B 0x20, X 0x40, Y 0x80 |
| 4-5 | LT, RT, 8-bit |
| 6-13 | LX, LY, RX, RY int16 LE: `Int16((clamp(v)*32767).rounded())` with **LY = −ly and RY = −ry** (HID convention: up is negative) |
| 14-19 | 0 |

- **Neutral:** `00 14` followed by 18 × `00`.
- **Rumble output:** `00 04 big small`.
- **Where it works.** It is correct in SDL 2.24 (HIDAPI 360 driver). In SDL 2.32 IOKit it works, but as "Steam Virtual Gamepad" with no Guide. **It is wrong in SDL ≥ 3.4.12** (Y inverted, LT only on the upper half of its travel), and GameController never sees it.

### 4.7 Keyboard and pointer (D8; draft descriptors, parser-checked)

- **Keyboard (slot 1)**
  - Identity: 1209:4744, version 0x0100, Transport "USB", "GDHub" / "GDHub Virtual Keyboard", serial "GDHub-K1", **CountryCode 32 (UK/ISO)**, flags `HID_DEFAULT_BEHAVIOR`.
  - Descriptor (90 B): input 0x01 = 31 B, 0x02 = 3 B; output 0x01 = 2 B (LEDs, accepted and ignored):
    ```
    05 01 09 06 A1 01 85 01 05 07 19 E0 29 E7 15 00 25 01 75 01 95 08 81 02 95 01 75 08 81 01
    05 07 19 00 29 DF 15 00 25 01 75 01 95 E0 81 02 05 08 19 01 29 05 95 05 75 01 91 02 95 01 75 03 91 01 C0
    05 0C 09 01 A1 01 85 02 15 00 26 FF 03 19 00 2A FF 03 75 10 95 01 81 00 C0
    ```
  - Usage Maximum stays ≤ 255. Karabiner saw ioreg CPU problems at 2048.
- **Pointer (slot 2)**
  - Identity: 1209:4745, "GDHub Virtual Pointer", serial "GDHub-P1", flags `HID_DEFAULT_BEHAVIOR`.
  - Descriptor (75 B): input 0x01 = 8 B (8 buttons, X/Y int16 relative, wheel, AC Pan):
    ```
    05 01 09 02 A1 01 85 01 09 01 A1 00 05 09 19 01 29 08 15 00 25 01 75 01 95 08 81 02
    05 01 09 30 09 31 16 01 80 26 FF 7F 75 10 95 02 81 06 09 38 15 81 25 7F 75 08 95 01 81 06
    05 0C 0A 38 02 15 81 25 7F 75 08 95 01 81 06 C0 C0
    ```
- **Neutral reports:** all zeros after the ID. The watchdog therefore releases stuck keys and buttons.

---

## 5. App side (Swift)

### 5.1 `DriverManager` (`@MainActor final class DriverManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate`)

**Inputs it reads**
- `dextID = "com.interlinked.gdhub.VirtualHID"`
- `embeddedDextURL = Bundle.main.bundleURL/Contents/Library/SystemExtensions/<dextID>.dext`
- `embeddedBuild = Bundle(url: embeddedDextURL)?.infoDictionary["CFBundleVersion"] as? String`

**Launch sequence (`start()`)**
1. If `embeddedBuild == nil`, set `.notBundled`. This is the SwiftPM build.
2. Else if `!Bundle.main.bundlePath.hasPrefix("/Applications/")`, set `.wrongLocation(path)`.
3. Else submit `OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier:queue: .main)` (macOS 12+).
4. **Always** call `vhidQueue.async { dext.start() }`. The client simply waits for the service, and this makes the rejection test possible from the SwiftPM build.

**`request(_:foundProperties:)`**
- `enabled = props.filter { $0.isEnabled && !$0.isUninstalling }`.
  - An entry with `bundleVersion == embeddedBuild` → `.active(build)`.
  - Otherwise, if `enabled` is non-empty → `.updating(from, to)` and `installOrUpdate()`. This is automatic: the user just installed a newer build.
  - Otherwise, if any entry `isAwaitingUserApproval` → `.needsApproval`.
  - Otherwise → `.notInstalled`.
- While in `.needsApproval`, poll the properties again every 3 s.

**`installOrUpdate()`**
1. Run `vhidQueue.sync { sink.shutdown(); dext.stop() }`. This destroys the devices and closes the connection first.
2. `OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: dextID, queue: .main)`, set the delegate, `OSSystemExtensionManager.shared.submitRequest`.
3. Set `.activating`.

**Delegate callbacks.** All are `nonisolated` and run `MainActor.assumeIsolated { … }`, since they arrive on `.main`.

| Callback | Result |
|---|---|
| `actionForReplacingExtension` | `.replace` (logs `bundleVersion` old → new) |
| `requestNeedsUserApproval` | `.needsApproval` |
| `didFinishWithResult .completed` | Query properties again → `.active`, and `vhidQueue.async { dext.start() }` |
| `didFinishWithResult .willCompleteAfterReboot` | `.rebootRequired` |
| `didFailWithError` | `.failed(code, message)` using the table below |

**`uninstall()`:** the same shutdown, then `deactivationRequest`, then `.uninstalling`. The other uninstall path is dragging the app to the Trash **in Finder**. `systemextensionsctl uninstall` needs SIP off.

**OSSystemExtensionErrorDomain messages**

| Code | Name | Message shown |
|---|---|---|
| 1 | unknown | — |
| 2 | missingEntitlement | "App lacks System Extension entitlement" |
| 3 | unsupportedParentBundleLocation | "Run from /Applications" |
| 4 | extensionNotFound | "Dext not embedded" |
| 5 | extensionMissingIdentifier | — |
| 6 | duplicateExtensionIdentifer | — |
| 7 | unknownExtensionCategory | "Dext not recognised (CFBundlePackageType must be DEXT)" |
| 8 | codeSignatureInvalid | "Signature/profile mismatch" |
| 9 | validationFailed | "Validation failed (entitlements vs profile, or CFBundlePackageType)" |
| 10 | forbiddenBySystemPolicy | — |
| 11 | requestCanceled | — |
| 12 | requestSuperseded | — |
| 13 | authorizationRequired | — |

**UI states (Driver menu in D1–D6, panel in D7)**

| State | Text | Actions |
|---|---|---|
| `.checking` | Checking driver… | — |
| `.notBundled` | Driver not bundled (SwiftPM build): run `scripts/build-xcode.sh` | — |
| `.wrongLocation(path)` | Run GDHub from /Applications to install the driver | Reveal in Finder |
| `.notInstalled` | Driver not installed | **Install Driver** |
| `.activating` / `.updating(a,b)` | Installing… / Updating driver a → b… | — |
| `.needsApproval` | Allow "GDHub Virtual HID" in System Settings › General › Login Items & Extensions › Driver Extensions | **Open System Settings**: `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`; fall back to opening System Settings |
| `.active(build)` | Driver active (build N) | Uninstall Driver |
| `.rebootRequired` | Restart the Mac to finish installing the driver | — |
| `.uninstalling` | Removing driver… | — |
| `.failed(code,msg)` | Driver error code: msg | Retry |

**Connection states** (from `DextClient`):

| State | Text |
|---|---|
| `stopped` | — |
| `waitingForService` | Waiting for driver |
| `connected(dextBuild)` | Connected (driver build N) |
| `rejected(0xE00002E2)` | Driver refused this app: not signed by team 79XF6HYX8A |
| `exclusive(0xE00002C5)` | Another GDHub is connected |
| `protocolMismatch(dext)` | Driver protocol vD, app v1: update the driver |
| `failed(kr)` | — |

**Pad states:** `off`, `publishing(identity)`, `published(identity)`, `blockedDuplicate(desc)`, `error(kr)`. The menu also shows the post rate and the last rumble.

### 5.2 `DextClient` (all methods run on `vhidQueue`; enforce with `dispatchPrecondition(condition: .onQueue(queue))`)

```swift
final class DextClient: PadTransport {
    enum State: Equatable { case stopped, waitingForService, connected(dextBuild: UInt64), rejected(kern_return_t),
                            exclusive, protocolMismatch(dext: UInt64), failed(kern_return_t) }
    struct OutputReport { let slot: UInt8, type: UInt8, reportID: UInt8; let bytes: [UInt8]; let sequence: UInt64 }
    var onState: ((State) -> Void)?          // called on queue; AppModel hops to main
    var onOutput: ((OutputReport) -> Void)?  // called on queue
    init(queue: DispatchQueue)
    func start(); func stop()
    func createDevice(_ spec: DeviceSpec) -> kern_return_t
    func destroyDevice(slot: UInt8) -> kern_return_t
    func post(slot: UInt8, report: [UInt8]) -> kern_return_t
    func postNeutral(slot: UInt8) -> kern_return_t
    func heartbeat() -> kern_return_t
    func status() -> (mask: UInt64, posts: UInt64, watchdogFires: UInt64, outputs: UInt64, drops: UInt64)?
}
```

**Matching.** `IOServiceMatching("IOUserService")` with `kIOPropertyMatchKey: ["IOUserServerName": dextID, "IOUserClass": "GDHubVirtualHID"]` (T3 added the class: from T4 the receiver tap is a second service of this dext with the same server name, and `hello` must go to the root; build 17's root carries the same `IOUserClass` property, so the new match finds it). `DextClient.matchingProperties` exposes the dictionary and `DextProtocolTests` pins it. Build a new dictionary for each call, because `IOServiceAddMatchingNotification` consumes it.

**`start()`**
1. `port = IONotificationPortCreate(kIOMainPortDefault)`, then `IONotificationPortSetDispatchQueue(port, queue)`.
2. Add `kIOFirstMatchNotification` and `kIOTerminatedNotification` notifications. Pass `Unmanaged.passUnretained(self)` as the refcon; the client lives for the whole app.
3. Drain both iterators at once. This arms them and handles a service that already exists.
4. Set the state to `waitingForService`.

**On match**
1. `IOServiceOpen(service, mach_task_self_, 0, &connect)`.
2. `hello`:
   ```swift
   var inp: [UInt64] = [1, appBuild]; var out = [UInt64](repeating: 0, count: 3); var n: UInt32 = 3
   IOConnectCallScalarMethod(connect, 0, &inp, 2, &out, &n)
   ```
3. Map the result to a state:
   - `0xE00002E2` → `.rejected` (close)
   - `0xE00002C5` → `.exclusive` (close)
   - `out[0] != 1` → `.protocolMismatch(out[0])`
   - otherwise keep `capabilities = out[2]`, `registerOutput()`, then `.connected(dextBuild: out[1])`

**On terminate.** `IOServiceClose(connect)` (if open), then `.waitingForService`. When the service comes back, for example after a dext replacement, the same match path reconnects. The sink re-creates its device on `.connected`.

**Calls**
- **`createDevice`:** `IOConnectCallStructMethod(connect, 1, bytes, bytes.count, nil, nil)`.
- **`post`:**
  ```swift
  var s: [UInt64] = [UInt64(slot)]
  report.withUnsafeBytes { IOConnectCallMethod(connect, 3, &s, 1, $0.baseAddress, $0.count, nil, nil, nil, nil) }
  ```
- **`destroyDevice` / `postNeutral`:** `IOConnectCallScalarMethod` with `[slot]`. **`heartbeat`:** no arguments. **`status`:** 5 outputs.
- **T3, behind `capabilities & CAP_ROOT_PAD`:** `status2()` (selector 11, 512-byte structure output, decoded by offset; short and long replies both decode) and `setForwardingInert()` (selector 9, `[0, 0, 0]` in, 4 scalars out). Without the bit they send nothing: `status2()` is nil and `setForwardingInert()` returns `krUnsupported`. The engine's meter line appends the dext's `hop`/`hr` from `status2()` once a window has closed. `status()` and the T3 calls go through one `callRaw` seam, which the capability tests replace with a fake dext.

**`registerOutput()`**
```swift
private static let outputCallback: IOAsyncCallback = { refcon, result, args, numArgs in
    guard let refcon, let args, result == kIOReturnSuccess else { return }
    let words = (0..<Int(numArgs)).map { UInt64(UInt(bitPattern: args[$0])) }
    Unmanaged<DextClient>.fromOpaque(refcon).takeUnretainedValue().handleOutput(words)
}
var ref = [io_user_reference_t](repeating: 0, count: Int(kOSAsyncRef64Count))      // 8
ref[Int(kIOAsyncCalloutFuncIndex)]   = io_user_reference_t(UInt(bitPattern: unsafeBitCast(Self.outputCallback, to: Int.self)))
ref[Int(kIOAsyncCalloutRefconIndex)] = io_user_reference_t(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
IOConnectCallAsyncScalarMethod(connect, 6, IONotificationPortGetMachPort(port), &ref, UInt32(kOSAsyncRef64Count), nil, 0, nil, nil)
```
The xcode-project research typechecked this code shape against the macOS 27 SDK with a macOS 14 target.

**`handleOutput`**
- `w[0]` holds `slot = w0 & 0xFF`, `type = (w0>>8) & 0xFF`, `id = (w0>>16) & 0xFF`, `len = (w0>>24) & 0xFF` (≤ 64).
- The bytes are taken little-endian from `w[1…8]`. The sequence number is `w[9]`.
- If the sequence number jumps by more than 1, log the drop.

**`PadTransport`** is the protocol `VirtualPadSink` depends on: `createDevice`, `destroyDevice`, `post`, `postNeutral`, `heartbeat`. Tests use a fake.

### 5.3 `DeviceSpec` encoder (`DextProtocol.swift`)

```swift
struct DeviceSpec: Equatable {
    var slot: DextProtocol.Slot; var flags: UInt8 = 0
    var vendorID, productID, versionNumber: UInt32
    var countryCode: UInt32 = 0, locationID: UInt32 = 0, reportIntervalUs: UInt32 = 4000
    var primaryUsagePage: UInt32 = 1, primaryUsage: UInt32 = 5
    var transport: String, manufacturer: String, product: String, serialNumber: String
    var descriptor: [UInt8]
    var sendLengths: [UInt8: Int] = [:]            // reportID → padded send length; only xbox-pr208 ([0x01: 25])
    var neutralReports: [[UInt8]]                  // one per HIDReportSizer input report, same order, each at its send length
    func encoded() throws -> [UInt8]               // 256-byte header + descriptor + neutral blob; enforces §3.6
}
```
- The header writes little-endian `UInt32` and `UInt16` at the `DextProtocol.Offset` constants.
- Strings are UTF-8 and must be shorter than their field (one NUL byte at least). Anything longer throws.
- The input table is `(id, sendLengths[id] ?? 0, lengthInclID)` from `HIDReportSizer.inputs(descriptor)`.
- It throws if a `sendLengths` key is not an input report ID, or if a send length is outside `lengthInclID…max(lengthInclID)` (§3.6 rule 6).
- It throws if a neutral report's length is not its send length.

**`HIDReportSizer`** is a minimal parser:
- It reads short items. It handles Report Size (0x74), Report Count (0x94), Report ID (0x84), Push/Pop (0xA4/0xB4), and Input/Output/Feature (0x80/0x90/0xB0). It skips long items (0xFE).
- For each (type, id) it sums `size × count` bits, in first-seen order.
- Length = bits / 8, plus 1 when id ≠ 0.
- It throws if any report's bit total is not a multiple of 8.

### 5.4 `VirtualPadSink` (queue-confined to `vhidQueue`; `@unchecked Sendable`)

```swift
struct PadButtons: OptionSet { a, b, x, y, lb, rb, view, menu, ls, rs, guide, share, dpadUp, dpadDown, dpadLeft, dpadRight }
struct PadState: Equatable { var buttons: PadButtons = []; var lx = 0.0, ly = 0.0, rx = 0.0, ry = 0.0, lt = 0.0, rt = 0.0
                             static let neutral = PadState() }        // y up = +1
final class VirtualPadSink {
    struct Config { var maxRateHz = 250.0; var axisDeadband = 0.002; var triggerDeadband = 0.002; var heartbeatMs = 500 }
    init(queue: DispatchQueue, transport: PadTransport, clock: @escaping () -> UInt64 /* ns */, scheduler: SinkScheduler, config: Config)
    nonisolated func submit(frame: GamepadFrame, mapping: ControlMapping)  // queue.async { submit(state: mapper(frame, mapping)) }
    func submit(state: PadState); func neutral(); func setEnabled(_ on: Bool, identity: PadIdentity)
    func transportConnected(); func transportLost(); func shutdown(); func runTestPattern()
    var onPadState: ((PadPublishState) -> Void)?
}
```

**Algorithm**
1. **Disabled or not published:** return.
2. **Deadband snap:** `|axis| < axisDeadband → 0` and `trigger < triggerDeadband → 0`.
3. **Unchanged test.** The state counts as unchanged if buttons are equal, every `|Δaxis| < axisDeadband` and every `|Δtrigger| < triggerDeadband` against `lastSentState`. If unchanged, return. Because of the snap, returning to rest always differs and is always sent.
4. **Rate cap** (plan §7b: send only on change, default 250 Hz, configurable down to 125 Hz):
   - `pending = state`
   - if `now ≥ lastPostAt + 1e9/maxRateHz` → `flush()`
   - else, if no flush is armed, arm one-shot `scheduler.after(lastPostAt + interval)` → `flush()`. The final state always goes out.
5. **`flush()`**
   - `reports = builder.reports(for: pending)` gives `[reportID: bytes]`.
   - For each report ID in the identity's input order: if `bytes != lastSentBytes[id]`, call `transport.post(slot: 0, report: bytes)`.
   - `lastSentState = pending`, `lastPostAt = now`.
   - If a post fails with `NotReady` or `NotPermitted`, mark the pad unpublished and re-create it once after 1 s.
6. **Heartbeat.** A repeating `DispatchSourceTimer` (500 ms) calls `transport.heartbeat()` while the pad is published.
7. **`neutral()`:** `transport.postNeutral(slot: 0)`, then `lastSentState = .neutral` and `lastSentBytes = neutral`.
8. **`setEnabled(true, id)`**
   - **Duplicate check.** Use `IOServiceGetMatchingServices` with `IOServiceMatching("IOHIDDevice")` and property match `VendorID` / `ProductID`. If a device has `SerialNumber != "GDHub-1"`, set `.blockedDuplicate`.
   - Otherwise `createDevice(identity.spec())`, then `neutral()`.
   - **Identity switch:** destroy, wait 300 ms, create.
9. **Persistence.** `UserDefaults` keys `vhid.pad.enabled` (default false) and `vhid.pad.identity`. The latter defaults to `"xbox-bt16-02e0"`. If M1 (§7.3) passes only with `xbox-bt16`, change the default constant to `"xbox-bt16"`.
10. **`runTestPattern()`** (D3) feeds 100 Hz states for 8 s:
    - A, B, X, Y, LB, RB, View, Menu, LS, RS, Guide, 300 ms each
    - D-pad N, E, S, W
    - LT ramp, then RT ramp
    - left-stick circle, then right-stick circle
    - neutral
    
    While the pattern runs, frames from the SCUF are ignored.

### 5.5 `PassthroughPadMapper` (until the P3 engine replaces it)

`static func padState(_ f: GamepadFrame, _ m: ControlMapping) -> PadState`, using the learned mapping (factory profile in `ControlMapping.default`):

| PadState | Source |
|---|---|
| a, b, x, y, lb, rb, view, menu | `m.isActive("a" … "menu", f)` |
| ls, rs | `"l3"`, `"r3"` |
| guide | `"start"` (centre button 11) |
| share | none (button 17 "profile" stays unbound, plan §3.5) |
| dpadUp/Right/Down/Left | `"dpad_up" / "dpad_right" / "dpad_down" / "dpad_left"`. `isActive` already counts diagonals. Paddles reach the D-pad through the factory echo |
| lx, ly | `m.stickPosition("left_stick", f)` → `(x, -y)` (the mapping's y grows downward) |
| rx, ry | `"right_stick"`, same conversion |
| lt, rt | `m.triggerValue("lt"/"rt", f) ?? 0` |

### 5.6 Hooks

**`EnvisionProDevice.swift` (MOD)**
- `var onFrame: ((GamepadFrame, ControlMapping) -> Void)?`. In `handle(...)` after `hasFrame = true`, call `onFrame?(new, mapping)`.
- `var onStatusChange: ((Status) -> Void)?`. Fire it from `status`'s `didSet` when the value changed.

**`App.swift` `AppModel` (MOD)**
- **Owned objects:**
  - `let vhidQueue = DispatchQueue(label: "com.interlinked.gdhub.vhid", qos: .userInteractive)`
  - `dext = DextClient(queue: vhidQueue)`
  - `padSink = VirtualPadSink(queue: vhidQueue, transport: dext, …)`
  - `driver = DriverManager(dext: dext, sink: padSink)`
- **Wiring:**
  - `envision.onFrame = { [padSink] f, m in padSink.submit(frame: f, mapping: m) }`
  - `envision.onStatusChange = { [padSink] s in if s != .active { padSink.neutral() } }`. This covers asleep, receiver idle and disconnected.
  - `dext.onState`: hop to main, `driver.connection = s`, and on `.connected` call `padSink.transportConnected()`.
  - `dext.onOutput`: `RumbleDecoder`, then `driver.lastRumble` and the log.
- **Notifications:**
  - `NSApplication.willTerminateNotification` → `vhidQueue.sync { padSink.shutdown(); dext.stop() }`
  - `NSWorkspace.willSleepNotification` → `padSink.neutral()`
- **Startup:** `driver.start()`. Add `CommandMenu("Driver") { DriverCommands(driver: model.driver) }`, following the existing `LayoutCommands` pattern.
- **Cost:** the main actor already handles the 1 kHz reports. The hook adds one `async` hop per frame. When P1 moves `HIDMonitor` to `hidQueue`, `onFrame` moves there unchanged.

### 5.7 `RumbleDecoder`

**Result type:** `RumbleCommand { left, right, leftTrigger, rightTrigger: Double (0…1); durationMs: Int? }`.

| Input | Decoding |
|---|---|
| Report ID 3 (9 B, starting with 0x03) or 8 B without the ID | `[enable, LT, RT, L, R, duration, delay, loop]`. Magnitudes 0…100 → /100. `durationMs = duration × 10` |
| Report ID 9 (13 B, `r[3] == 0x09`) | Decode `[0x03] + r[5..<13]` as above |
| x360 (ID 0, 4 B `00 04 big small`) | `left = big/255`, `right = small/255` |

D5 shows the result. P7e routes it to SCUF output report 0x09.

---

## 6. Build and install

### 6.1 `project.yml` (repo root; verified shape, adapted paths)

```yaml
name: GDHub
options: {bundleIdPrefix: com.interlinked, deploymentTarget: {macOS: "14.0"}, createIntermediateGroups: true}
settings:
  base: {DEVELOPMENT_TEAM: 79XF6HYX8A, CODE_SIGN_STYLE: Automatic, MARKETING_VERSION: "0.1.0", CURRENT_PROJECT_VERSION: "1"}
targets:
  GDHub:
    type: application
    platform: macOS
    scheme: {}
    sources: [Sources/GDHub, Xcode/App/BundleModule+Xcode.swift]
    dependencies: [{target: GDHubVirtualHID}]          # embedded in Contents/Library/SystemExtensions
    info:
      path: Xcode/App/Info.plist
      properties: {CFBundleDisplayName: GDHub, CFBundleShortVersionString: $(MARKETING_VERSION),
                   CFBundleVersion: $(CURRENT_PROJECT_VERSION), LSMinimumSystemVersion: "14.0",
                   NSPrincipalClass: NSApplication, NSHighResolutionCapable: true,
                   NSSystemExtensionUsageDescription: "GDHub installs a driver that publishes its virtual controller, keyboard and pointer."}
    entitlements: {path: Xcode/App/GDHub.entitlements, properties: {com.apple.developer.system-extension.install: true}}
    settings:
      base: {PRODUCT_BUNDLE_IDENTIFIER: com.interlinked.gdhub, PRODUCT_NAME: GDHub, SWIFT_VERSION: "5.0",
             ENABLE_HARDENED_RUNTIME: YES, CODE_SIGN_IDENTITY: "Apple Development"}
  GDHubVirtualHID:
    type: driver-extension
    platform: macOS                                      # xcodegen has no DriverKit platform; SDKROOT does it
    sources: [Dext/GDHubVirtualHID]
    dependencies: [{sdk: DriverKit.framework}, {sdk: HIDDriverKit.framework}]
    info:
      path: Dext/GDHubVirtualHID/Info.plist
      properties:
        CFBundlePackageType: $(PRODUCT_BUNDLE_PACKAGE_TYPE)   # = DEXT; xcodegen omits it for driver-extension (see below)
        CFBundleDisplayName: GDHub Virtual HID
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        OSBundleUsageDescription: Publishes GDHub's virtual game controller, keyboard and pointer.
        IOKitPersonalities:
          GDHubVirtualHID:
            CFBundleIdentifier: $(PRODUCT_BUNDLE_IDENTIFIER)
            CFBundleIdentifierKernel: com.apple.kpi.iokit
            IOClass: IOUserService
            IOMatchCategory: $(PRODUCT_BUNDLE_IDENTIFIER)
            IOProviderClass: IOUserResources
            IOResourceMatch: IOKit
            IOUserClass: GDHubVirtualHID
            IOUserServerName: $(PRODUCT_BUNDLE_IDENTIFIER)
            GDHubPadProperties: {IOClass: AppleUserHIDDevice, IOUserClass: GDHubVirtualPad}   # T3: root level
            # D8/T11: GDHubKeyboardProperties / GDHubPointerProperties move up the same way
            UserClientProperties:
              IOClass: IOUserUserClient
              IOUserClass: GDHubVirtualHIDUserClient
            IOUserServerOneProcess: true                          # T4
          GDHubReceiverTap:                                       # T4 (see §3.14 and project.yml for the full keys)
            IOProviderClass: IOHIDInterface
            IOUserClass: GDHubReceiverTap
            IOUserServerOneProcess: true
            VendorID: 6940
            ProductID: 14856
            PrimaryUsagePage: 65368
            PrimaryUsage: 1
            IOProbeScore: 1000
    entitlements:
      path: Dext/GDHubVirtualHID/GDHubVirtualHID.entitlements
      properties: {com.apple.developer.driverkit: true, com.apple.developer.driverkit.family.hid.device: true,
                   com.apple.developer.driverkit.allow-any-userclient-access: true}
    settings:
      base: {PRODUCT_BUNDLE_IDENTIFIER: com.interlinked.gdhub.VirtualHID, PRODUCT_NAME: $(PRODUCT_BUNDLE_IDENTIFIER),
             SDKROOT: driverkit, SUPPORTED_PLATFORMS: driverkit, DRIVERKIT_DEPLOYMENT_TARGET: "23.0",
             CLANG_CXX_LANGUAGE_STANDARD: gnu++20,
             GCC_PREPROCESSOR_DEFINITIONS: ["$(inherited)", "GDHUB_DEXT_BUILD=$(CURRENT_PROJECT_VERSION)"],
             ENABLE_HARDENED_RUNTIME: YES, CODE_SIGN_IDENTITY: "Apple Development"}
```
- **The Xcode app compiles the sources directly.** `Package.swift` has only an `executableTarget`, so the app target compiles `Sources/GDHub` itself. Resources are copied flat into `Contents/Resources`, which the `Bundle.module` shim serves.
- **The default Info.plist values are overridden on purpose.** xcodegen's default plist hard-codes `CFBundleShortVersionString` 1.0. That is why both version keys are set explicitly; this was verified.
- **`CFBundlePackageType` is set explicitly on the dext.**
  - xcodegen 2.46.0's generated plist has no package type for a `driver-extension` target. The earlier unsigned proto build of this target had no `CFBundlePackageType`, while the app still got `APPL` (*local*). Xcode does set `PRODUCT_BUNDLE_PACKAGE_TYPE = DEXT` for this product type, but the generated plist never references it.
  - Without the key, sysextd fails validation (§3.2), and that happens only after a build that passes every `codesign` and `need` check.
  - With the line above, an xcodegen 2.46.0 + Xcode 27.1 build (`CODE_SIGNING_ALLOWED=NO`) produced `CFBundlePackageType = DEXT` (*local*).
  - Karabiner's dext plist uses the same `$(PRODUCT_BUNDLE_PACKAGE_TYPE)`. macgip, a development-signed xcodegen dext that loaded with SIP on, uses the literal `DEXT`. Either works.
- **Do not add arm64e.** Do not set `OTHER_CODE_SIGN_FLAGS`.

### 6.2 `scripts/build-xcode.sh` (exact behaviour)

```zsh
#!/bin/zsh
# Build GDHub.app + embedded dext (signed, development), verify, install to /Applications, launch.
# Usage: scripts/build-xcode.sh [--no-install | --no-open]
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEXT_ID=com.interlinked.gdhub.VirtualHID; UDID=00006031-001851E126E1001C; NUMFILE=Xcode/build-number
installed=$(systemextensionsctl list 2>/dev/null | sed -nE "s/.*${DEXT_ID//./\\.} \([^/]*\/([0-9]+)\).*/\1/p" | sort -n | tail -1)
last=$(cat "$NUMFILE" 2>/dev/null || echo 1); installed=${installed:-0}
BUILD=$(( (installed > last ? installed : last) + 1 ))
(( BUILD <= 9999 )) || { echo "build number $BUILD > 9999 is not a valid dext CFBundleVersion"; exit 1; }
print -r -- $BUILD > "$NUMFILE"
mkdir -p .xcodebuild
/opt/homebrew/bin/xcodegen generate --spec project.yml --quiet
if ! xcodebuild -project GDHub.xcodeproj -scheme GDHub -configuration Debug -derivedDataPath .xcodebuild \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration CURRENT_PROJECT_VERSION=$BUILD build \
     > .xcodebuild/last-build.log 2>&1; then grep -E "error:|No profiles" .xcodebuild/last-build.log | head -20; exit 1; fi
APP=.xcodebuild/Build/Products/Debug/GDHub.app
DEXT=$APP/Contents/Library/SystemExtensions/$DEXT_ID.dext
[[ -d $DEXT ]] || { echo "dext not embedded at $DEXT"; exit 1; }
codesign --verify --strict --deep "$APP"
need() { # need <bundle> <profile path> <keys…>: key in signature AND profile; this Mac in profile
  local b=$1 p=$2; shift 2
  local sig=$(codesign -d --entitlements :- "$b" 2>/dev/null) prof=$(security cms -D -i "$p" 2>/dev/null)
  for k in "$@"; do
    [[ $sig == *"<key>$k</key>"* ]]  || { echo "MISSING in signature of $b: $k"; exit 1; }
    [[ $prof == *"<key>$k</key>"* ]] || { echo "MISSING in profile of $b: $k"; exit 1; }
  done
  [[ $prof == *$UDID* ]] || { echo "this Mac is not in the profile of $b"; exit 1; }
}
need "$DEXT" "$DEXT/embedded.provisionprofile" com.apple.developer.driverkit \
     com.apple.developer.driverkit.family.hid.device com.apple.developer.driverkit.allow-any-userclient-access
need "$APP" "$APP/Contents/embedded.provisionprofile" com.apple.developer.system-extension.install \
     com.apple.developer.team-identifier
[[ $(plutil -extract CFBundleVersion raw "$DEXT/Info.plist") == $BUILD ]] || { echo "dext version mismatch"; exit 1; }
[[ $(plutil -extract CFBundlePackageType raw "$DEXT/Info.plist" 2>/dev/null) == DEXT ]] || { echo "dext CFBundlePackageType != DEXT (sysextd would reject it)"; exit 1; }
echo "built build $BUILD"
[[ ${1:-} == --no-install ]] && exit 0
pkill -x GDHub 2>/dev/null && sleep 1 || true
rm -rf /Applications/GDHub.app && ditto "$APP" /Applications/GDHub.app
echo "installed /Applications/GDHub.app (build $BUILD)"
[[ ${1:-} == --no-open ]] || open /Applications/GDHub.app
```
- **Dext layout.** A dext is a shallow bundle: `embedded.provisionprofile` sits at its root, as in Razer's (*local*).
- **Package type.** `codesign --verify` and `need` cannot see a missing `CFBundlePackageType`. The `plutil` gate stops the build before install, instead of sysextd rejecting it at activation (§3.2, §8.1 row 28).
- **Version numbers.** The kext version format means a build number over 9999, or a timestamp, fails activation (forum 780345).
- **Before relaunching**, leave layout edit mode (Layout › Cancel editing), as the GDHub testing process requires.

### 6.3 First install, step by step

1. **Prepare.** Xcode › Settings › Accounts must show the team 79XF6HYX8A account. Make sure no other GDHub is running.
2. **Build and install.** Run `scripts/build-xcode.sh`. The first run creates the App IDs, registers the Mac, and creates the profiles "Mac App Development" and "DriverKit App Development". Check that both `need` lines and the `CFBundlePackageType` gate pass.
3. **Install the driver.** GDHub opens from `/Applications`. Choose Driver › **Install Driver**, and the state becomes "Needs approval".
4. **Approve.** In System Settings › General › Login Items & Extensions › **Driver Extensions**, switch **GDHub Virtual HID** on. Authenticate if asked.
5. **Verify.**
   - The Driver menu shows "Driver active (build N)" and then "Connected (driver build N)".
   - `systemextensionsctl list` shows `*	*	79XF6HYX8A	com.interlinked.gdhub.VirtualHID (0.1.0/N)	GDHub Virtual HID	[activated enabled]`.
   - `ioreg -rw0 -l -n GDHubVirtualHID -d1 | grep -E '^\s*"IOUserServerName" = "com.interlinked.gdhub.VirtualHID"'` matches. Match by name (`-n`): `ioreg -c IOUserService` prints nothing on macOS 27 (§3.1).
   - `pgrep -lf com.interlinked.gdhub.VirtualHID` shows the dext process.

### 6.4 Developer-portal steps (only if automatic signing fails; Account Holder role, which an individual account has)

1. **App ID for the app.** Identifiers › + › App IDs › App › Explicit `com.interlinked.gdhub`. Capability: **System Extension**.
2. **App ID for the dext.** Identifiers › + › Explicit `com.interlinked.gdhub.VirtualHID`. Capabilities:
   - **DriverKit (development)**
   - **DriverKit Family HID Device (development)**
   - **DriverKit Allow Any UserClient (development)**
   - optionally **DriverKit Transport HID (development)**
3. **Device.** Devices: make sure Provisioning UDID `00006031-001851E126E1001C` (macOS) is registered.
4. **Dext profile.** Profiles › + › Development › **DriverKit App Development** › `com.interlinked.gdhub.VirtualHID` › certificate P2B3MZTPX8 › this Mac. Name it "GDHub VirtualHID Dev".
5. **App profile.** Profiles › + › **macOS App Development** › `com.interlinked.gdhub` › same certificate and Mac. Name it "GDHub App Dev".
6. **Install the profiles.** Double-click both downloads, or copy them to `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.
7. **Switch to manual signing.** In `project.yml` set `CODE_SIGN_STYLE: Manual` and `PROVISIONING_PROFILE_SPECIFIER` to "GDHub App Dev" / "GDHub VirtualHID Dev". Run step 2 of §6.3 again.
8. **If a capability was added later**, delete the cached profiles in that folder; they are "not precious" (forum 809202).

### 6.5 Logs and state

- **Dext and system logs:** `scripts/dext-log.sh` runs
  ```
  log stream --style compact --level debug --predicate 'process == "com.interlinked.gdhub.VirtualHID" OR process == "sysextd" OR process == "kernelmanagerd" OR (sender == "kernel" AND (eventMessage CONTAINS "DK:" OR eventMessage CONTAINS[c] "gdhub")) OR subsystem == "com.interlinked.gdhub"'
  ```
  The app logs through `Logger(subsystem: "com.interlinked.gdhub", category: "vhid")`.
- **Load failures:** add `process == "amfid" OR process == "syspolicyd"`. Or use `sudo log collect --last 10m` (DTS preference).
- **Crashes:** `/Library/Logs/DiagnosticReports/com.interlinked.gdhub.VirtualHID*.ips`.
- **State** (ioreg by registry name, §3.1):
  - `systemextensionsctl list`
  - `ioreg -rw0 -n GDHubVirtualHID -d6`: tree of root → user client → devices → interfaces → event drivers
  - `ioreg -rw0 -l -n GDHubVirtualHID -d1`: root properties
  - `ioreg -rw0 -l -n GDHubVirtualPad -d1`: pad properties
  - `hidutil list --matching '{"PrimaryUsagePage":1,"PrimaryUsage":5}'`

### 6.6 Update and uninstall

- **Update.** Run `scripts/build-xcode.sh` again. The app sees the installed build (N) is older than the bundled one (N+1) and calls `installOrUpdate()`, which closes the client and submits activation. The result is `.replace`, then `.completed`, then reconnect.
  - Check that the Driver menu shows `Connected (driver build N+1)`; the build number comes from `hello`.
  - If it still shows N, the old dext process is still running. Reboot: Karabiner reports that replacing a dext does not restart its process.
  - The old version shows "terminated waiting to uninstall on reboot" until the next restart.
  - If `sysextd` wedges after many versions, reboot.
- **Uninstall.** Use Driver › Uninstall Driver (`deactivationRequest`), or drag `/Applications/GDHub.app` to the Trash **in Finder**.
  - `systemextensionsctl uninstall` / `reset` need SIP off. Do not use them.
  - `rm -rf` of the app in the build script deliberately does **not** uninstall the dext. Check this once with `systemextensionsctl list` after the first scripted reinstall.

---

## 7. Test plan

### 7.1 Unit tests (`swift test`, existing XCTest target)

**`HIDReportSizerTests`**

| Descriptor | Length | Inputs | Outputs |
|---|---|---|---|
| bt16 | 285 | `[(1,16),(2,2)]` | `[(3,9)]` |
| bt17 | 315 | `[(1,17)]` | `[(3,9)]` |
| dual | 312 | `[(1,16),(2,2),(0x20,25)]` | `[(3,9),(9,13)]` |
| pr208 | 310 | `[(1,17),(0x20,25)]` | `[(3,9),(9,13)]` |
| x360 | 122 | `[(0,20)]` | `[(0,4)]` |
| keyboard | 90 | `[(1,31),(2,3)]` | `[(1,2)]` |
| pointer | 75 | `[(1,8)]` | — |

**`PadReportBuilderTests`**
- **bt16 neutral:** `01 00 80 00 80 00 80 00 80 00 00 00 00 00 00 00` and `02 00`.
- **bt16 buttons:** A → byte14 0x01. Y → 0x08. Menu → 0x80. LS → byte15 0x01. Guide → `02 01`.
- **bt16 axes:**
  - lx −1 → `00 00`, lx +1 → `FF FF`
  - ly +1 (up) → bytes 3-4 `00 00`
  - lt 1 → `FF 03`, rt 0.5 → `00 02`
- **bt16 hat:** up+right → byte13 0x02. Left → 0x07. Up+down → 0x00.
- **bt17:** X → byte14 0x08, LB → 0x40, View → byte15 0x04, Guide → 0x10, RS → 0x40, Share → byte16 0x01.
- **GIP:** neutral is §4.5's 25 bytes. A → byte4 0x10. Up → byte5 0x01.
- **pr208 0x01:** 25 bytes long. Neutral is `01 00 80 00 80 00 80 00 80` + 16 × `00`. X → byte14 0x04, Menu → 0x80, LS → byte15 0x01, Guide → byte15 0x04, Share → byte16 0x01. Bytes 17-24 are always 0. Bytes 0-14 equal the bt16 builder's for the same state.
- **bt16-02e0:** the identity's reports are byte-identical to bt16 for the same state.
- **x360:**
  - neutral is `00 14` + 18 zeros
  - A → byte3 0x10, Guide → byte3 0x04, Menu → byte2 0x10
  - ly +1 → bytes 8-9 `01 80`
  - lt 1 → byte4 0xFF

**`DextProtocolTests`**
- Read `Dext/GDHubVirtualHID/GDHubProtocol.h`, located relative to `#filePath`. Parse every `#define GDHUB_<NAME> <number>`. Assert each one equals the Swift constant of the same name in a name→value table in the test.
- Encode the `xbox-bt16` spec and assert:
  - total length 256 + 285 + 18
  - bytes `47 44 48 53` at offset 0
  - VendorID `5E 04 00 00` at offset 12
  - Transport string plus NUL at offset 64
  - input table `01 00 10 00 02 00 02 00` at offset 48
- Encode the `xbox-bt16-02e0` spec: ProductID `E0 02 00 00` at offset 16, and every other byte equal to `xbox-bt16` except ProductID.
- Encode the `xbox-pr208` spec and assert:
  - total length 256 + 310 + 50
  - input table `01 19 11 00 20 00 19 00` at offset 48
  - Transport `56 69 72 74 75 61 6C 00` ("Virtual") at offset 64
- A send length below the declared length, or above the largest input report, throws. So does a neutral report whose length is not its send length.
- An overlong product string throws.

**T3 tests**
- `DextProtocolTests` (extended): every new `#define` (including `(1u << 8)` forms and the `GDHUB_ST2_*` offsets) against its Swift constant; selector numbers never move; capability bits additive; the matching dictionary names `IOUserClass`; `GDHubPadProperties` sits at root level in `project.yml`.
- `DextCoreRegistryTests`: every registry transition, stale and duplicate calls, reference counts of every fake object (no leak, no retain after the last release, no release under the lock), a concurrent pad-cycling/copying test, concurrent root register/unregister, one claim winner among eight, one surviving lock among sixteen racing `ensure` calls.
- `DextCoreMeterTests`: bucket edges, percentiles, window closing, timebase, a seqlock test with concurrent readers, CRC-32 against the check value and against `gdx_crc32`, `GDHubStatus2` packed in C and decoded in Swift (full, short, long, newer-version buffers).
- `DextSourceRulesTests`: source guards. Every cross-object call sits behind a `GDH_SYNC` toward a higher rank (exactly four call sites); the registry core cannot name DriverKit or a GDHub class; every `GDLog` format stays under 250 characters even with 10-digit conversions; the posting hot paths contain no allocation, `SetLength` or logging except the once-per-window meter line.
- `DextClientCapabilityTests`: a new app against a build-17 dext sends neither selector 9 nor 11 and keeps `getStatus`; a new app against a T3 dext reads status2 and sets INERT.

**`PassthroughPadMapperTests`** (`ControlMapping.default`)
- button 1 → A; button 11 → guide; hat 0 → dpadUp; hat 1 → up + right
- x = 32767 → lx ≈ 1; y = 32767 (down) → ly ≈ −1
- lt 1023 → 1.0
- paddle frame (extra bit 0 + hat 2) → dpadRight

**`VirtualPadSinkTests`** (fake transport, manual clock and scheduler)
- The same state twice gives 1 post.
- 1000 distinct states over 1 s give ≤ 251 posts, and the last state is posted.
- ±0.001 stick noise gives 0 posts.
- Return to rest is always posted.
- `neutral()` calls `postNeutral` once.
- The heartbeat fires every 500 ms only while the pad is published.
- An identity switch gives destroy, a 300 ms gap, then create.

**`RumbleDecoderTests`**
- `03 0F 10 20 30 40 FF 00 EB` → lt 0.16, rt 0.32, left 0.48, right 0.64, durationMs 2550.
- The 8-byte form without the ID gives the same result.
- GIP 0x09 normalisation.
- x360 `00 04 80 FF`.

### 7.2 Manual checks

**`scripts/vhid-check.sh` (H1)** prints the following. Every ioreg query matches by registry name (= `IOUserClass`), because `ioreg -c IOUserService` / `-c AppleUserHIDDevice` print nothing on macOS 27 (§3.1). This also scopes each check to our objects: Razer's 045E:028E pad, when on, already shows `AppleUserHIDEventDriver` elsewhere in the registry.
- `systemextensionsctl list | grep gdhub`
- root: `ioreg -rw0 -l -n GDHubVirtualHID -d1 | grep -E '^\s*"IOUserServerName" ='`
- pad properties: `ioreg -rw0 -l -n GDHubVirtualPad -d1 | grep -E '^\s*\+-o|^\s*"(IOUserClass|VendorID|ProductID|VersionNumber|Transport|Product|SerialNumber|LocationID|PrimaryUsagePage|PrimaryUsage|MaxInputReportSize|MaxOutputReportSize|HIDVirtualDevice|IOCFPlugInTypes)" ='`
- pad count: `ioreg -rw0 -n GDHubVirtualPad -d1 | grep -c '+-o GDHubVirtualPad'` (expected 1)
- bound event driver, our pad only: `ioreg -rw0 -n GDHubVirtualPad -d3 | grep -E 'AppleGCHIDUserEventDriver|AppleUserHIDEventDriver'`, and `ioreg -rw0 -l -n GDHubVirtualPad -d3 | grep -E '"GameControllerSupport"'`
- cross-check by class and IDs: `ioreg -rw0 -l -c IOUserHIDDevice | grep -E '"VendorID" = 1118|"ProductID" = (2835|736)'`. `-c IOUserHIDDevice` works where `-c AppleUserHIDDevice` does not.
- `hidutil list --matching '{"PrimaryUsagePage":1,"PrimaryUsage":5}'`

**Preconditions for every host test (H3–H7)**
- **Razer's virtual controller is off** (Synapse, or Driver Extensions). It publishes 045E:028E "Xbox 360 Controller" (v0x0114, Transport USB) and 1532:27DB, and SDL hosts can list those as controllers.
- OJD is not publishing a pad.
- ShadowUSB is not forwarding the receiver.
- GDHub is the receiver owner (state "Connected").

**H1–H7** follow output-layer plan §4, with these expected values:

| # | Check | Expected for `xbox-bt16` |
|---|---|---|
| H1 | ioreg | Exactly one GDHub pad, with the values in §4.3 |
| H2 | `scuf-envision/tools/gcprobe` (build it with `swiftc -O scuf-envision/tools/gcprobe.swift -o scuf-envision/tools/gcprobe`) | 1 controller, `extended=true`. `--watch` shows each face button, bumper, View/Menu, stick click, triggers and sticks |
| H3 | Steam | Controller test: every input, rumble test; `controller.txt` as in §4.3 |
| H4 | GFN | `geronimo.log` as in §4.3; a game responds |
| H5 | Shadow | Alt+Cmd+O lists one pad; `joy.cpl` in the VM shows every input |
| H6 | Duplicates | Repeat H3–H5 with Steam open and closed, and with Razer's pad on (to record the interference) |
| H7 | Rumble | One game per host. The app log shows a decoded `RumbleCommand`; `getStatus` shows `outputDrops == 0` |

**Failure behaviour (D4)**

| Action | Expected |
|---|---|
| `kill -9 $(pgrep -x GDHub)` | Pad gone from ioreg within 1 s: `ioreg -rw0 -n GDHubVirtualPad -d1` prints nothing |
| `kill -STOP` while RT is held | Within 2.5 s gcprobe shows RT 0 and `watchdogFires` +1 |
| `kill -CONT` | Pad follows the SCUF again |
| Run `.build/GDHub.app` (bundle.sh) alone | Connection "Driver refused this app (0xe00002e2)", no pad |
| Second authorized instance (`.xcodebuild/Build/Products/Debug/GDHub.app/Contents/MacOS/GDHub &`) | "Another GDHub is connected" |
| Controller switched off | Pad stays, reports neutral |

### 7.3 Milestone M1 "first light" (end of D3)

Run M1 twice, once with `xbox-bt16-02e0` and once with `xbox-bt16` (Identity switch: destroy, 300 ms gap, create). With **Send Test Pattern** running, all of these must hold:
1. `vhid-check.sh` shows the H1 values in §4.3, with ProductID 736 or 2835. `ioreg -rw0 -n GDHubVirtualPad -d3 | grep -E 'AppleGCHIDUserEventDriver|AppleUserHIDEventDriver'` shows **`AppleGCHIDUserEventDriver`** under **our** pad's `IOHIDInterface`. A whole-registry grep does not count: Razer's pad already shows `AppleUserHIDEventDriver`.
2. **System Settings › Game Controllers** shows the controller.
3. `gcprobe --watch` prints A, B, X, Y, LB, RB, View, Menu, LS, RS in that order, then the D-pad, the trigger ramps and the stick circles.
4. Switching the pad off removes it from ioreg (`ioreg -rw0 -n GDHubVirtualPad -d1` prints nothing) and from System Settings.

**Outcome:**
- If both identities pass, keep `xbox-bt16-02e0` as the default.
- If only `xbox-bt16` passes, make it the default (§5.4).
- If neither passes step 2 or 3, follow §8.1 row 15 and pull `xbox-bt17-remap` / `xbox-pr208` forward from D6.

Record every result in `docs/research/host-identity-matrix.md`.

---

## 8. Risks and fallbacks

### 8.1 Symptom → check → action

| # | Symptom | Check | Action |
|---|---|---|---|
| 1 | xcodebuild: "No profiles for 'com.interlinked.gdhub.VirtualHID' were found" | Build uses `-allowProvisioningUpdates`; Xcode account signed in | Add the flags. If it persists, open `GDHub.xcodeproj` once (Signing & Capabilities › Try Again) or follow the portal steps (§6.4) |
| 2 | `need` fails: key missing in the **profile** | `security cms -D -i …/embedded.provisionprofile` | Enable the "(development)" capability on the App ID, delete the cached profiles, rebuild |
| 3 | Activation error 3 | App path | Install with `build-xcode.sh`. Never activate from `.xcodebuild/` |
| 4 | Error 8 or 9 (signature or validation) | First rule out row 28 (`CFBundlePackageType`). Then compare `codesign -d --entitlements :-` with the profile `Entitlements` | Remove extra keys. If `get-task-allow` is the difference, set `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` on the dext target |
| 5 | Error 2 or 4 | App entitlements; `Contents/Library/SystemExtensions/com.interlinked.gdhub.VirtualHID.dext` present (folder name = bundle ID) | Fix `project.yml` |
| 6 | Stuck at `.needsApproval` | Driver Extensions toggle | Turn on "GDHub Virtual HID" |
| 7 | `.willCompleteAfterReboot`, or `hello` still reports the old build after an update | — | Reboot (Karabiner: replacing a dext does not restart its process) |
| 8 | Active but no `GDHubVirtualHID` in ioreg / dext crashes | `ioreg -rw0 -n GDHubVirtualHID -d1`. Never `-c IOUserService`, which prints nothing here even on success (§3.1). Then dext-log, `.ips`, `amfid` | `EXC_CRASH (Code Signature Invalid)` means the dext claims an entitlement it is not allowed (Karabiner): remove it. "disallowing arm64 platform driverkit binary" or POSIX 8: try adding `arm64e` (we default to arm64, which loads for Razer and Corsair here) |
| 9 | `IOServiceOpen` → 0xE00002E2; kernel log "UC failed userclient-access check" | `codesign -d --entitlements :- <dext>` contains `allow-any-userclient-access` | Fix signing. Last resort: request a team `userclient-access` grant (forum 849054), or procon2's no-user-client channel (vendor feature report 0x7F) |
| 10 | `hello` → 0xE00002E2 (our own check) | `codesign -d --entitlements :- /Applications/GDHub.app` shows `com.apple.developer.team-identifier = 79XF6HYX8A` | Run the Xcode build, not `bundle.sh` |
| 11 | `hello` → 0xE00002C5 | `pgrep -lf GDHub` | Quit the other instance |
| 12 | `createDevice` OK but no pad in ioreg, or it vanishes | `ioreg -rw0 -n GDHubVirtualPad -d1`, not `-c AppleUserHIDDevice` (§3.1). Then dext-log: handleStart / spec / description | If the "RegisterService" key is not honoured: override `Start` as `IMPL`, call `Start(provider, SUPERDISPATCH)`, then `RegisterService()` (JoyCon2Mac, sdk-api iigtest pattern) |
| 13 | Kernel mentions `IOServiceDEXTEntitlements` / `family.hid.device` | Dext signature and profile | Ensure `family.hid.device`. Add `transport.hid` (development); Razer ships with it |
| 14 | Pad's interface bound to `AppleUserHIDEventDriver` with `GameControllerSupport = No`, and no `AppleGCHIDUserEventDriver` | `ioreg -rw0 -l -n GDHubVirtualPad -d3`, scoped to our pad: VendorID 1118 / ProductID 2835 or 736. PrimaryUsagePage ≠ 0x84. No `GameControllerEligible` / `GCSyntheticDevice` keys | Fix the spec. **Transport and VersionNumber do not matter for adoption** |
| 15 | Adopted (`AppleGCHIDUserEventDriver`), but System Settings / gcprobe shows no controller, no input or wrong buttons | `gcprobe --watch` with the test pattern. Decide which case applies (§4.1) | **(a) The pad is listed in GameController but its buttons are shifted** (for example X arrives as Y, View/Menu lost): GameController decodes by bit position, so skip `xbox-bt17-remap`. Try `xbox-bt16-02e0` (if not yet tried), then `xbox-pr208` (§4.5). **(b) The pad does not appear in GameController at all, or shows no input:** try `xbox-bt16-02e0`, then `xbox-bt17-remap` (§4.4), then `xbox-pr208`. `xbox-pr208` is wrong in SDL2, so pick it per host. Keep VersionNumber 0x0513 |
| 16 | `getReport` / `setReport` hangs or timeouts in a host, or GameController drops the pad | dext-log | Answer `getReport(Feature)` with a zero buffer of the requested length plus success. Ensure `CompleteReport` whenever `action != nullptr` |
| 17 | Steam: no input, or "device opened" missing | `controller.txt`; Transport string | SDL3 needs a `Bluetooth…` prefix for the 0x01 parser. If BLE Transport causes side effects or no input, use `xbox-dual-usb` |
| 18 | Steam (or another SDL host) shows two controllers (one MFi, bus 05 / 045e:02e0 / 05ac:0004) | H6 | Record it. Possibly GameController's Synthetic Device Manager or an SDL MFi duplicate. Try a Steam restart. For a Steam-only profile, `x360-usb` is not GameController-adopted |
| 19 | SDL buttons scrambled (X↔Y, View/Menu lost) | `MaxInputReportSize`; the identity in use | SDL used the gapped parser because report 0x01 arrived as > 16 B. Use `xbox-bt16-02e0` / `xbox-bt16`, or `xbox-bt17-remap` for SDL. `xbox-pr208` always does this in SDL2 (it sends 25 B), so never use it for SDL2 hosts |
| 20 | Shadow: no pad, or two pads | Alt+Cmd+O; SDL #11002 race | Restart Shadow after the pad exists. Record in the matrix. Fallback `x360-usb` for Shadow only (SDL 2.24 correct) |
| 21 | GFN: "Skipping SDL gamepad" or "Skipping Forge gamepad" | `geronimo.log` | Note the Forge flag. Forge is GameController-only, so keep a GameController-adopted identity. Try `xbox-dual-usb` |
| 22 | ioreg looks fine but hosts see no movement | `postCount` rising? Report length vs sizer | Short or wrong-length reports are dropped silently (macgip). The dext already rejects undeclared lengths: check the app log for `BadArgument` |
| 23 | Rumble never reaches the app | `MaxOutputReportSize` > 0; `getStatus` outputCount/outputDrops | If only the first callback arrives, re-arm `registerOutput` after every callback (app flag `rearmEachCallback`) |
| 24 | Phantom pads | `hidutil list` | Disable Razer's virtual driver. Refuse to publish while another device with the identity's VID:PID exists (OJD uses 0B13; `xbox-bt16-02e0` avoids it) |
| 25 | Stuck input after an app hang | `watchdogFires` | Watchdog sends neutral after 2 s. A crash removes the device |
| 26 | Dext stops loading around 2027-11-08 (certificate expiry) | Keychain | Renew the certificate, rebuild, re-activate |
| 27 | Dext logs invisible | `--level debug`; process filter | Rely on `ioreg`, `getStatus` and the app log |
| 28 | Activation fails after a clean build (`OSSystemExtensionErrorDomain` 7 `unknownExtensionCategory` or 9 `validationFailed`; the exact code is untested). sysextd logs ``package type not `DEXT` `` then `extension failed to validate! uninstalling...`, or kernelmanagerd logs `has invalid or missing package type` | `plutil -extract CFBundlePackageType raw /Applications/GDHub.app/Contents/Library/SystemExtensions/com.interlinked.gdhub.VirtualHID.dext/Info.plist` must print `DEXT` | Add `CFBundlePackageType: $(PRODUCT_BUNDLE_PACKAGE_TYPE)` (or `DEXT`) to the dext `info.properties` in `project.yml` (§6.1). The `build-xcode.sh` gate (§6.2) should already have stopped this build |
| 29 | `vhid-check.sh` / §6.3 checks print nothing although the Driver menu says active and connected | Which ioreg filter is used | `ioreg -c IOUserService` / `-c IOUserUserClient` / `-c AppleUserHIDDevice` print nothing on macOS 27.0.1 even for Razer's working dext. Use `-n GDHubVirtualHID` / `-n GDHubVirtualPad` (§3.1) |

**Seen in D1 (2026-11-08).** Activation reached `[activated enabled]`, but the dext never launched: `amfid` logged `-413 "No matching profile found"` and `kernelmanagerd` `NSPOSIXErrorDomain 8 "Exec format error"`. Cause: Xcode generated the "DriverKit Team Provisioning Profile" *before* it registered this Mac, so `ProvisionedDevices` held only a previously registered device, while the Mac profile (generated after registration) had the Mac. Fix that worked: delete the cached DriverKit profile from `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` and rebuild with `-allowProvisioningUpdates`; Xcode regenerated it with the Mac's UDID and the dext launched. `scripts/build-xcode.sh` now refuses a dext profile that lacks this Mac's UDID. `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` was *not* needed.

### 8.2 Defaults chosen where research was uncertain

| Question | Default | Fallback |
|---|---|---|
| Register the HID device | `"RegisterService" = true` in the description; `Start` not overridden | `Start` IMPL + `RegisterService()` (#12) |
| Queue for `handleReport` | RPC `postReport` on the device queue (Karabiner) | — |
| Pass identity to the child | One class per slot. The child reads `spec[slot]` through `GDHubUCCopySpec` in `handleStart` (no custom keys in the `Create` dict) | — |
| `CompleteReport` | Call when `action != nullptr`, with the returned status | — |
| Timestamp | `mach_absolute_time()` | — |
| Large struct | Handle `structureInput` and `structureInputDescriptor` | — |
| HID entitlement | `family.hid.device` | add `transport.hid` |
| Automatic provisioning | `-allowProvisioningUpdates -allowProvisioningDeviceRegistration` | §6.4 manual |
| `get-task-allow` in dext | Xcode default | `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` |
| Replace with an open client | Close client and destroy devices first; verify with `hello` build | Reboot |
| `AsyncCompletion` reuse | Arm once per connection | Re-arm per callback |
| Architectures | arm64 x86_64 | + arm64e |
| DriverKit target | 23.0 | 22.0 |
| GameController and a 16-byte report | `xbox-bt16-02e0` and `xbox-bt16`, both tested at M1; prefer 02E0 | §8.1 row 15. Shifted buttons → `xbox-bt16-02e0` → `xbox-pr208`. Absent → `xbox-bt16-02e0` → `xbox-bt17-remap` → `xbox-pr208` |
| Report longer than declared | Only `xbox-pr208` (`sendLength` 25 for a 17-byte 0x01) | — |
| BLE Transport side effects | `"Bluetooth Low Energy"` | `xbox-dual-usb` |
| Pad `HIDDefaultBehavior` | Absent | `""` (procon2), only if GameController classification is wrong |
| Product string | "Xbox Wireless Controller" | "SCUF Envision Pro" (cosmetic test after M1) |
| `setReport` buffer includes the ID | Forward raw bytes plus the ID | Decoder accepts both |

---

## 9. Implementation phases

These phases run **before** output-layer P1–P6. P7a, b, d and e are covered here, and D8 covers P7c.

**Model and effort (user rule; set them explicitly on every subagent)**
- Swift and scripts: sonnet/medium.
- Dext C++ and the threading in `VirtualPadSink` / `DextClient`: sonnet/high.
- `xcodegen`, `xcodebuild`, `swift build`, `swift test` and log greps: haiku/low.
- opus/high only for a dext bug that sonnet cannot fix.
- No multi-agent fan-out.

**Progress.** Each phase updates the Savvy progress bar, and the `## Phases` ledger if one is added to this file.

| Phase | Scope | Files touched | Model | Done when |
|---|---|---|---|---|
| **D0** Project and signing | XcodeGen project; root-only dext; `NewUserClient` returns `kIOReturnUnsupported` | `project.yml`, `.gitignore`, `Xcode/App/BundleModule+Xcode.swift`, GEN plists and entitlements, `Dext/GDHubVirtualHID/{GDHubProtocol.h, GDHubInternal.h, GDHubVirtualHID.iig, GDHubVirtualHID.cpp}`, `scripts/build-xcode.sh`, `scripts/dext-log.sh` | sonnet/medium; dext sonnet/high | `scripts/build-xcode.sh` passes every `need` check and the `CFBundlePackageType == DEXT` gate, and installs. `/Applications/GDHub.app` launches and shows the controller images (shim works). `swift build`, `swift test` and `scripts/bundle.sh` still work. If signing fails, finish §6.4 first |
| **D1** Activation | `DriverManager` (install state only); Driver menu | `Output/VirtualHID/DriverManager.swift`, `UI/DriverCommands.swift`, `App.swift` | sonnet/medium | Install, then Needs approval, then the user approves, then "Driver active (build N)". `systemextensionsctl list` shows `[activated enabled]`. `ioreg -rw0 -l -n GDHubVirtualHID -d1` shows the root with `"IOUserServerName" = "com.interlinked.gdhub.VirtualHID"` (by name, not `-c`; §3.1). `pgrep` shows the dext. Rebuild N+1: the app auto-updates and `systemextensionsctl` lists N+1 enabled |
| **D2** User client and protocol | User client with `hello`, `heartbeat`, `registerOutput` (stores only), `getStatus`; Team check; root claim; watchdog timer; `DextClient`; protocol mirror | `GDHubVirtualHIDUserClient.iig/.cpp`, `GDHubVirtualHID.cpp`, `GDHubProtocol.h`, `GDHubInternal.h`, `Output/VirtualHID/{DextProtocol.swift, DextClient.swift}`, `DriverManager.swift`, `DriverCommands.swift`, `Tests/GDHubTests/DextProtocolTests.swift` | dext sonnet/high; Swift sonnet/medium | Menu shows "Connected (driver build N)". dext-log shows `GDHub: hello`. `bundle.sh` app shows "refused (0xe00002e2)". A second authorized instance shows "Another GDHub is connected". `swift test` green |
| **D3** Pad and first light | `createDevice`, `destroyDevice`, `postReport`, `postNeutral`; watchdog neutral; pad class; spec helpers including `sendLength` (§3.6), so later identities need no dext change; `xbox-bt16-02e0` and `xbox-bt16` identities, builder and sizer; minimal sink (publish toggle and test pattern) | `GDHubVirtualPad.iig/.cpp`, `GDHubSpec.cpp`, `GDHubVirtualHIDUserClient.cpp`, `project.yml` (no change expected), `Output/VirtualHID/HIDReportSizer.swift`, `Output/VirtualPad/{PadState, PadDescriptors, PadReportBuilders, PadIdentity, VirtualPadSink}.swift`, `DextProtocol.swift` (`DeviceSpec`), `DriverCommands.swift`, `scripts/vhid-check.sh`, `scuf-envision/tools/gcprobe.swift`, `Tests/GDHubTests/{HIDReportSizerTests, PadReportBuilderTests, DextProtocolTests}.swift`, `docs/research/host-identity-matrix.md` (M1 results) | sonnet/high | **M1 (§7.3)** passes for at least one of `xbox-bt16-02e0` / `xbox-bt16`, and the default identity is set from the result. `swift test` green |
| **D4** Live passthrough | Mapper; full sink (deadband, 250 Hz cap, trailing flush, heartbeat, neutral, sleep/terminate, reconnect, duplicate guard); device hooks | `Output/VirtualPad/{PassthroughPadMapper, VirtualPadSink}.swift`, `Devices/EnvisionPro/EnvisionProDevice.swift`, `App.swift`, `Tests/GDHubTests/{PassthroughPadMapperTests, VirtualPadSinkTests}.swift` | sonnet/high | The SCUF drives every control in `gcprobe --watch`. Over 10 s of continuous stick circling, the `getStatus` postCount delta is ≤ 2510; at rest it is ≈ 0. Every §7.2 failure-behaviour row passes |
| **D5** Output path | `setReport`/`getReport` forwarding with `CompleteReport`; `GDHubUCDeliverOutput`; async decode; `RumbleDecoder`; menu line | `GDHubVirtualPad.cpp`, `GDHubVirtualHIDUserClient.cpp`, `DextClient.swift`, `Output/VirtualPad/RumbleDecoder.swift`, `DriverManager.swift`, `DriverCommands.swift`, `Tests/GDHubTests/RumbleDecoderTests.swift` | dext sonnet/high; Swift sonnet/medium | Steam's rumble test logs a `RumbleCommand` in the app; `outputDrops == 0` while connected |
| **D6** Host identity matrix | Fallback identities and builders (`xbox-bt17-remap`, `xbox-dual-usb`, `xbox-pr208`, `x360-usb`; pulled into D3 if M1 fails, §7.3); Identity submenu; run H1–H7 per host; use fallbacks only when §8.1 symptoms appear | `Output/VirtualPad/{PadIdentity, PadReportBuilders, PadDescriptors}.swift`, `DriverCommands.swift`, `Tests/GDHubTests/PadReportBuilderTests.swift`, `docs/research/host-identity-matrix.md` | sonnet/medium (tests haiku/low); user runs the hosts | The matrix has H1–H7 for Steam, Shadow and GFN with the chosen identity per host. Exactly one controller per host, every input, rumble in one game each |
| **D7** Virtual controller panel | Mockup first, then the approved UI | `docs/mockups/virtual-controller-panel.html` (attach in chat, wait for approval), `UI/VirtualControllerPanel.swift`, `App.swift` | sonnet/medium | User approves the mockup. The panel shows install, connection and pad state, identity, post rate and last rumble, with the actions in §5.1, and matches the mockup |
| **D8** Keyboard and pointer | Slots 1 and 2 | `Dext/GDHubVirtualHID/{GDHubVirtualKeyboard, GDHubVirtualPointer}.iig/.cpp`, `GDHubVirtualHIDUserClient.cpp` (`postBytes` switch, capabilities), `project.yml` (two plist dicts), `Output/VirtualHID/{KeyboardIdentity, PointerIdentity}.swift` (§4.7), tests | sonnet/high | `hidutil list` shows 1209:4744 (CountryCode 32) and 1209:4745. A Debug test types "gdhub" into TextEdit and moves the pointer 200 px. `kill -STOP` while a key is held releases it within 2.5 s. With GFN Direct mouse input on, the keys reach a game (P7 verify) |

**Out of scope here, next.** P7e physical rumble: capture the SCUF if3 output report 0x09 format, then route `RumbleCommand` to it. Engine-driven `PadState` (P3/P4) replaces `PassthroughPadMapper` without changing the sink.
