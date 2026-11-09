#!/bin/zsh
# Build GDHub.app + embedded dext (signed, development), verify, install to /Applications, launch.
# Usage: scripts/build-xcode.sh [--no-install | --no-open] [--same-build] [--release] [--engine-install]
#   --same-build: reuse the current number in Xcode/build-number (app-only change; the embedded dext keeps
#   its version, so no driver replacement is triggered). Combine as e.g. `--same-build --no-open`.
#   --release: build and install the Release configuration (-O, no GDHub.debug.dylib) for play sessions; Debug is the
#   default. Combine with --same-build so the installed driver (same version) is not replaced.
#   --engine-install: after installing, install and start the background engine LaunchAgent (scripts/engine-agent.sh);
#   the one-time switch to engine mode. With the agent already installed, every install refreshes and restarts it.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEXT_ID=com.interlinked.gdhub.VirtualHID; UDID=00006031-001851E126E1001C; NUMFILE=Xcode/build-number
installed=$(systemextensionsctl list 2>/dev/null | sed -nE "s/.*${DEXT_ID//./\\.} \([^/]*\/([0-9]+)\).*/\1/p" | sort -n | tail -1)
last=$(cat "$NUMFILE" 2>/dev/null || echo 1); installed=${installed:-0}
SAME=0; CONFIG=Debug; ENGINE_INSTALL=0; ARGS=()
for a in "$@"; do
  if [[ $a == --same-build ]]; then SAME=1
  elif [[ $a == --release ]]; then CONFIG=Release
  elif [[ $a == --engine-install ]]; then ENGINE_INSTALL=1
  else ARGS+=("$a"); fi
done
set -- "${ARGS[@]}"
if (( SAME )); then BUILD=$(( installed > last ? installed : last )); else BUILD=$(( (installed > last ? installed : last) + 1 )); fi
AGENT=~/Library/LaunchAgents/com.interlinked.gdhub.engine.plist
if [[ -f $AGENT ]] && (( ! SAME )); then
  echo "dext build would change while the background engine is installed:"
  echo "run scripts/engine-agent.sh uninstall first (or pass --same-build)"; exit 2
fi
(( BUILD <= 9999 )) || { echo "build number $BUILD > 9999 is not a valid dext CFBundleVersion"; exit 1; }
print -r -- $BUILD > "$NUMFILE"
mkdir -p .xcodebuild
/opt/homebrew/bin/xcodegen generate --spec project.yml --quiet
if ! xcodebuild -project GDHub.xcodeproj -scheme GDHub -configuration $CONFIG -derivedDataPath .xcodebuild \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration CURRENT_PROJECT_VERSION=$BUILD build \
     > .xcodebuild/last-build.log 2>&1; then grep -E "error:|No profiles" .xcodebuild/last-build.log | head -20; exit 1; fi
APP=.xcodebuild/Build/Products/$CONFIG/GDHub.app
DEXT=$APP/Contents/Library/SystemExtensions/$DEXT_ID.dext
[[ -d $DEXT ]] || { echo "dext not embedded at $DEXT"; exit 1; }
codesign --verify --strict --deep "$APP"
# need <bundle> <profile path> <keys…>: key in signature AND profile; this Mac's UDID in the profile.
# If the dext profile lacks this Mac, amfid rejects the dext at launch with -413 "No matching profile found"
# (kernelmanagerd: "Exec format error"). That happens when Xcode generated the DriverKit team profile before it
# registered this Mac. Fix: delete the cached DriverKit profile and rebuild so Xcode regenerates it:
#   rm ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/<DriverKit profile uuid>.provisionprofile
need() {
  local b=$1 p=$2; shift 2
  local sig=$(codesign -d --entitlements :- "$b" 2>/dev/null) prof=$(security cms -D -i "$p" 2>/dev/null)
  for k in "$@"; do
    [[ $sig == *"<key>$k</key>"* ]]  || { echo "MISSING in signature of $b: $k"; exit 1; }
    [[ $prof == *"<key>$k</key>"* ]] || { echo "MISSING in profile of $b: $k"; exit 1; }
  done
  [[ $prof == *$UDID* ]] || { echo "this Mac ($UDID) is not in the profile of $b: $(print -r -- "$prof" | plutil -extract Name raw -o - - 2>/dev/null). Delete the cached copy under ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles and rebuild."; exit 1; }
}
need "$DEXT" "$DEXT/embedded.provisionprofile" com.apple.developer.driverkit \
     com.apple.developer.driverkit.family.hid.device com.apple.developer.driverkit.allow-any-userclient-access \
     com.apple.developer.driverkit.transport.hid
# Receiver tap personality checks (takeover plan 3.6, T4). plutil prints an integer as <integer> and a string as <string>,
# so a match key that came out as a string (it would then never match the kernel's integer property) is caught here.
P="$DEXT/Info.plist"
for k in VendorID ProductID PrimaryUsagePage PrimaryUsage IOProbeScore; do
  plutil -extract "IOKitPersonalities.GDHubReceiverTap.$k" xml1 -o - "$P" 2>/dev/null | grep -q '<integer>' \
    || { echo "tap $k is not an integer"; exit 2; }
done
for p in GDHubVirtualHID GDHubReceiverTap; do
  plutil -extract "IOKitPersonalities.$p.IOUserServerOneProcess" xml1 -o - "$P" 2>/dev/null | grep -q '<true/>' \
    || { echo "$p lacks IOUserServerOneProcess"; exit 2; }
done
for k in IOMatchCategory Transport; do
  plutil -extract "IOKitPersonalities.GDHubReceiverTap.$k" xml1 -o - "$P" >/dev/null 2>&1 \
    && { echo "tap personality has a $k key (it must compete in the default category and match without Transport)"; exit 2; }
done
[[ $(plutil -extract IOKitPersonalities.GDHubReceiverTap.IOProviderClass raw -o - "$P" 2>/dev/null) == IOHIDInterface ]] \
  || { echo "tap IOProviderClass != IOHIDInterface"; exit 2; }
need "$APP" "$APP/Contents/embedded.provisionprofile" com.apple.developer.system-extension.install \
     com.apple.developer.team-identifier
# The dext's own rules (GDHubVirtualHIDUserClient::callerIsGDHub) check the VALUES, and the engine runs this same binary.
T=$(mktemp -t gdhub-ent); codesign -d --entitlements :- "$APP" > $T 2>/dev/null
[[ $(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' $T 2>/dev/null) == 79XF6HYX8A.com.interlinked.gdhub ]] \
  || { echo "app signature: com.apple.application-identifier != 79XF6HYX8A.com.interlinked.gdhub"; rm -f $T; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' $T 2>/dev/null) == 79XF6HYX8A ]] \
  || { echo "app signature: com.apple.developer.team-identifier != 79XF6HYX8A"; rm -f $T; exit 1; }
rm -f $T
ENGINE_PLIST=$APP/Contents/Resources/com.interlinked.gdhub.engine.plist
[[ -f $ENGINE_PLIST ]] && plutil -lint "$ENGINE_PLIST" >/dev/null || { echo "engine plist missing or invalid in $APP"; exit 1; }
[[ $(plutil -extract CFBundleVersion raw "$DEXT/Info.plist") == $BUILD ]] || { echo "dext version mismatch"; exit 1; }
[[ $(plutil -extract CFBundlePackageType raw "$DEXT/Info.plist" 2>/dev/null) == DEXT ]] || { echo "dext CFBundlePackageType != DEXT (sysextd would reject it)"; exit 1; }
# T5: the translator in the dext must be compiled WITHOUT fused multiply-adds (the Swift pipeline it must equal does not fuse
# either; clang's arm64 default is -ffp-contract=on). The generated project must carry -ffp-contract=off both on the dext's
# copy of Shared/GDHubXlate.c and in the dext target's OTHER_CFLAGS, and no fast-math flag may be set; any compile of that file
# in this build's log must show the flag. The self-test in the dext covers the golden vectors on the finished binary.
plutil -convert json -o - GDHub.xcodeproj/project.pbxproj | python3 -I -c '
import json, sys
p = json.load(sys.stdin)["objects"]
def objs(kind): return {k: v for k, v in p.items() if v.get("isa") == kind}
dext = [v for v in objs("PBXNativeTarget").values() if v.get("name") == "GDHubVirtualHID"]
if len(dext) != 1: sys.exit("dext target not found in the project")
t = dext[0]
perfile = False
for ph in t["buildPhases"]:
    o = p[ph]
    if o.get("isa") != "PBXSourcesBuildPhase": continue
    for f in o["files"]:
        bf = p[f]; ref = p.get(bf.get("fileRef", ""), {})
        if ref.get("path") == "GDHubXlate.c" and "-ffp-contract=off" in bf.get("settings", {}).get("COMPILER_FLAGS", ""): perfile = True
if not perfile: sys.exit("GDHubXlate.c in the dext target has no -ffp-contract=off compiler flag")
for c in p[t["buildConfigurationList"]]["buildConfigurations"]:
    bs = p[c]["buildSettings"]; flags = bs.get("OTHER_CFLAGS", [])
    flags = flags if isinstance(flags, list) else [flags]
    if "-ffp-contract=off" not in flags: sys.exit("dext target %s: OTHER_CFLAGS lacks -ffp-contract=off" % p[c]["name"])
    if any("fast-math" in f or "ffp-contract=fast" in f for f in flags): sys.exit("dext target %s: fast-math flag set" % p[c]["name"])
' || { echo "dext build flags: the translator would not be bit-identical to the Swift pipeline"; exit 2; }
if grep -E '/clang .* -c .*Shared/GDHubXlate\.c' .xcodebuild/last-build.log | grep -F driverkit | grep -vqF -e 'ffp-contract\=off' -e 'ffp-contract=off'; then
  echo "a compile of Shared/GDHubXlate.c for the dext in .xcodebuild/last-build.log lacks -ffp-contract=off"; exit 2
fi
echo "built build $BUILD ($CONFIG)"
[[ ${1:-} == --no-install ]] && exit 0
# The engine runs under the same process name, and a running engine would keep executing the old inode: boot it out first.
[[ -f $AGENT ]] && scripts/engine-agent.sh bootout_wait
pkill -x GDHub 2>/dev/null && sleep 1 || true          # only the GUI is left to match
rm -rf /Applications/GDHub.app && ditto "$APP" /Applications/GDHub.app
echo "installed /Applications/GDHub.app (build $BUILD, $CONFIG)"
if [[ -f $AGENT ]] || (( ENGINE_INSTALL )); then
  scripts/engine-agent.sh install                      # refreshes the plist, bootout_wait, bootstrap_retry, wait_connected
  scripts/engine-agent.sh status || { echo "engine not connected: /usr/bin/log show --last 1m --predicate 'subsystem == \"com.interlinked.gdhub\" AND category == \"engine\"'"; exit 1; }
fi
[[ ${1:-} == --no-open ]] || open /Applications/GDHub.app
