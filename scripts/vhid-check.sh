#!/bin/zsh
# H1 check (design §7.2): sysext state, root service, our virtual pad's HID properties, bound event drivers.
# Every ioreg query matches by registry name (= IOUserClass): `ioreg -c IOUserService` / `-c AppleUserHIDDevice`
# print nothing on macOS 27, and a whole-registry grep would pick up Razer's pad.
# Usage: scripts/vhid-check.sh
section() { print -- "\n== $1"; }
PROPS='^\s*\+-o|^\s*"(IOUserClass|VendorID|ProductID|VersionNumber|Transport|Product|SerialNumber|LocationID|PrimaryUsagePage|PrimaryUsage|MaxInputReportSize|MaxOutputReportSize|HIDVirtualDevice|IOCFPlugInTypes)" ='

section "system extension"
systemextensionsctl list 2>/dev/null | grep -i gdhub || echo "(not listed)"
section "dext process"
pgrep -fl gdhub.VirtualHID || echo "(not running)"
section "root service (GDHubVirtualHID)"
ioreg -rw0 -l -n GDHubVirtualHID -d1 | grep -E '^\s*\+-o|^\s*"IOUserServerName" =' || echo "(root not in registry)"

section "pad properties (GDHubVirtualPad)"
ioreg -rw0 -l -n GDHubVirtualPad -d1 | grep -E "$PROPS" || echo "(no pad in registry)"
section "pad count (expected 1 when published)"
ioreg -rw0 -n GDHubVirtualPad -d1 | grep -c '+-o GDHubVirtualPad'

section "bound event driver, our pad only"
ioreg -rw0 -n GDHubVirtualPad -d3 | grep -E 'IOHIDInterface|AppleGCHIDUserEventDriver|AppleUserHIDEventDriver|GameController' || echo "(none)"
ioreg -rw0 -l -n GDHubVirtualPad -d3 | grep -E '"GameControllerSupport"|"GCIOMatchVirtual"|"GameControllerEligible"|"GCSyntheticDevice"' || echo "(no GameControllerSupport key)"

section "cross-check by class and IDs (VendorID 1118; ProductID 2835 = 0B13, 736 = 02E0)"
ioreg -rw0 -l -c IOUserHIDDevice | grep -E '"VendorID" = 1118|"ProductID" = (2835|736)\b' || echo "(none)"

section "hidutil gamepads"
hidutil list --matching '{"PrimaryUsagePage":1,"PrimaryUsage":5}' 2>/dev/null || echo "(hidutil failed)"

section "GameController adoption hint"
if ioreg -rw0 -n GDHubVirtualPad -d3 | grep -q AppleGCHIDUserEventDriver; then
  echo "AppleGCHIDUserEventDriver is bound under our pad: GameController adopted it."
  echo "Confirm with: scuf-envision/tools/gcprobe --watch   (and System Settings > Game Controllers)"
elif ioreg -rw0 -n GDHubVirtualPad -d3 | grep -q AppleUserHIDEventDriver; then
  echo "Only AppleUserHIDEventDriver is bound: GameController did NOT adopt the pad (design §8.1 row 14)."
else
  echo "No event driver under our pad (not published, or still attaching)."
fi
