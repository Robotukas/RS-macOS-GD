#!/bin/zsh
# H1 check (design §7.2): sysext state, root service, our virtual pad's HID properties, bound event drivers.
# Every ioreg query matches by registry name (= IOUserClass): `ioreg -c IOUserService` / `-c AppleUserHIDDevice`
# print nothing on macOS 27, and a whole-registry grep would pick up Razer's pad.
# Usage: scripts/vhid-check.sh   (exit 1 when a pad exists whose registry parent is not GDHubVirtualHID, i.e. before T3)
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

# T3: the root owns the pad. Its registry parent must be GDHubVirtualHID; under GDHubVirtualHIDUserClient is the build 17
# layout (the pad is then created and removed with the user client).
section "pad parent (T3: GDHubVirtualHID)"
PARENT=$(ioreg -rw0 -n GDHubVirtualHID -d5 2>/dev/null | awk '/\+-o /{ i=index($0,"+-o"); n=$0; sub(/.*\+-o /,"",n); sub(/[ <].*/,"",n); name[i]=n; for (j in name) if (j>i) delete name[j]; if (n=="GDHubVirtualPad") { for (j=i-2;j>=1;j-=2) if (name[j]!="") { print name[j]; exit } } }')
STATUS=0
if [[ -z $PARENT ]]; then echo "(no pad under the root)"
elif [[ $PARENT == GDHubVirtualHID ]]; then echo "PASS: GDHubVirtualPad is a child of GDHubVirtualHID"
else echo "FAIL: GDHubVirtualPad's parent is $PARENT, expected GDHubVirtualHID (build 17 layout?)"; STATUS=1; fi

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
exit $STATUS
