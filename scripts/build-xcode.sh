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
     com.apple.developer.driverkit.family.hid.device com.apple.developer.driverkit.allow-any-userclient-access
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
