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
# need <bundle> <profile path> <keys…>: key in signature AND profile; this Mac in profile.
# Xcode's "DriverKit Team Provisioning Profile" lists devices as a 40-hex id (not the 0000xxxx-… UDID), so for
# a dext (DEXT_PROFILE=1) the device check only requires a non-empty ProvisionedDevices list; the app profile
# must contain this Mac's UDID verbatim. Real proof for the dext is activation (phase D1).
need() {
  local b=$1 p=$2; shift 2
  local sig=$(codesign -d --entitlements :- "$b" 2>/dev/null) prof=$(security cms -D -i "$p" 2>/dev/null)
  for k in "$@"; do
    [[ $sig == *"<key>$k</key>"* ]]  || { echo "MISSING in signature of $b: $k"; exit 1; }
    [[ $prof == *"<key>$k</key>"* ]] || { echo "MISSING in profile of $b: $k"; exit 1; }
  done
  if [[ ${DEXT_PROFILE:-0} == 1 ]]; then
    local n=$(print -r -- "$prof" | plutil -extract ProvisionedDevices raw -o - - 2>/dev/null)
    [[ ${n:-0} -ge 1 ]] || { echo "profile of $b has no ProvisionedDevices"; exit 1; }
    [[ $prof == *$UDID* ]] || echo "note: $b profile lists devices by hashed id, UDID $UDID not verbatim (verified at activation)"
  else
    [[ $prof == *$UDID* ]] || { echo "this Mac is not in the profile of $b"; exit 1; }
  fi
}
DEXT_PROFILE=1 need "$DEXT" "$DEXT/embedded.provisionprofile" com.apple.developer.driverkit \
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
