#!/bin/zsh
# Build GDHub.app + embedded dext (signed, development), verify, install to /Applications, launch.
# Usage: scripts/build-xcode.sh [--no-install | --no-open] [--same-build] [--release] [--engine-install] [--probe [--probe-downgrade]]
#   --same-build: reuse the current number in Xcode/build-number (app-only change; the embedded dext keeps
#   its version, so no driver replacement is triggered). Combine as e.g. `--same-build --no-open`.
#   --release: build and install the Release configuration (-O, no GDHub.debug.dylib) for play sessions; Debug is the
#   default. Combine with --same-build so the installed driver (same version) is not replaced.
#   --engine-install: after installing, install and start the background engine LaunchAgent (scripts/engine-agent.sh);
#   the one-time switch to engine mode. With the agent already installed, every install refreshes and restarts it.
#   --probe (T0 of docs/plans/receiver-takeover-plan.md, removed in T0.5): build with the throwaway probe dext
#   (com.interlinked.gdhub.TapProbe), version from Xcode/probe-build, crash drill from PROBE_CRASH=1. Forces --same-build.
#   While Xcode/probe-build exists the script refuses to run without --probe; --probe refuses to run without the file.
#   --probe-downgrade: allow a probe version that is not greater than the installed one (T0.4).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEXT_ID=com.interlinked.gdhub.VirtualHID; UDID=00006031-001851E126E1001C; NUMFILE=Xcode/build-number
PROBE_ID=com.interlinked.gdhub.TapProbe; PROBEFILE=Xcode/probe-build
installed=$(systemextensionsctl list 2>/dev/null | sed -nE "s/.*${DEXT_ID//./\\.} \([^/]*\/([0-9]+)\).*/\1/p" | sort -n | tail -1)
last=$(cat "$NUMFILE" 2>/dev/null || echo 1); installed=${installed:-0}
SAME=0; CONFIG=Debug; ENGINE_INSTALL=0; PROBE=0; PROBE_DOWN=0; ARGS=()
for a in "$@"; do
  if [[ $a == --same-build ]]; then SAME=1
  elif [[ $a == --release ]]; then CONFIG=Release
  elif [[ $a == --engine-install ]]; then ENGINE_INSTALL=1
  elif [[ $a == --probe ]]; then PROBE=1; SAME=1          # the production dext version must not move during T0
  elif [[ $a == --probe-downgrade ]]; then PROBE_DOWN=1
  else ARGS+=("$a"); fi
done
set -- "${ARGS[@]}"
XB_EXTRA=()
if [[ -f $PROBEFILE ]] && (( ! PROBE )); then
  echo "$PROBEFILE exists (T0 probe in progress): run with --probe, or finish T0.5 and remove the file"; exit 2
fi
if (( PROBE )) && [[ ! -f $PROBEFILE ]]; then echo "--probe needs $PROBEFILE (print 1 > $PROBEFILE)"; exit 2; fi
if (( PROBE_DOWN && ! PROBE )); then echo "--probe-downgrade only goes with --probe"; exit 2; fi
if (( PROBE )); then
  PBUILD=$(cat "$PROBEFILE")
  [[ $PBUILD == <-> ]] && (( PBUILD >= 1 && PBUILD <= 9999 )) || { echo "$PROBEFILE must hold an integer 1..9999 (is: '$PBUILD')"; exit 2; }
  pinstalled=$(systemextensionsctl list 2>/dev/null | sed -nE "s/.*${PROBE_ID//./\\.} \([^/]*\/([0-9]+)\).*/\1/p" | sort -n | tail -1)
  pinstalled=${pinstalled:-0}
  if (( ! PROBE_DOWN && PBUILD <= pinstalled )); then       # checked before the build: sysextd would not take a lower or equal version
    echo "probe build $PBUILD is not greater than the installed probe $pinstalled (pass --probe-downgrade for T0.4)"; exit 2
  fi
  XB_EXTRA=(PROBE_BUILD=$PBUILD PROBE_CRASH=${PROBE_CRASH:-0})
fi
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
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration CURRENT_PROJECT_VERSION=$BUILD "${XB_EXTRA[@]}" build \
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
if (( PROBE )); then
  # T0 probe checks (plan §3.6). The production dext must stay at the installed version, or the next GUI launch replaces it.
  [[ $(plutil -extract CFBundleVersion raw "$DEXT/Info.plist") == $installed ]] \
    || { echo "probe: embedded production dext version != installed ($installed): the next GUI launch would replace the driver"; exit 2; }
  PDEXT=$APP/Contents/Library/SystemExtensions/$PROBE_ID.dext
  [[ -d $PDEXT ]] || { echo "probe dext not embedded at $PDEXT"; exit 1; }
  [[ $(plutil -extract CFBundleVersion raw "$PDEXT/Info.plist") == $PBUILD ]] \
    || { echo "probe dext CFBundleVersion != $PROBEFILE ($PBUILD)"; exit 2; }
  [[ $(plutil -extract CFBundlePackageType raw "$PDEXT/Info.plist" 2>/dev/null) == DEXT ]] || { echo "probe CFBundlePackageType != DEXT"; exit 2; }
  need "$PDEXT" "$PDEXT/embedded.provisionprofile" com.apple.developer.driverkit com.apple.developer.driverkit.transport.hid
  PP="$PDEXT/Info.plist"
  for k in VendorID:6940 ProductID:14856 PrimaryUsagePage:65368 PrimaryUsage:1 IOProbeScore:50; do
    x=$(plutil -extract "IOKitPersonalities.GDHubProbeTap.${k%%:*}" xml1 -o - "$PP" 2>/dev/null) || x=
    [[ $x == *"<integer>${k##*:}</integer>"* ]] || { echo "probe tap ${k%%:*} is not the integer ${k##*:}"; exit 2; }
  done
  for p in GDHubProbeRoot GDHubProbeTap; do
    x=$(plutil -extract "IOKitPersonalities.$p.IOUserServerOneProcess" xml1 -o - "$PP" 2>/dev/null) || x=
    [[ $x == *"<true/>"* ]] || { echo "$p lacks IOUserServerOneProcess"; exit 2; }
  done
  if plutil -extract IOKitPersonalities.GDHubProbeTap.IOMatchCategory raw -o - "$PP" >/dev/null 2>&1; then
    echo "probe tap personality has an IOMatchCategory (it must compete in the default category)"; exit 2
  fi
  if plutil -extract IOKitPersonalities.GDHubProbeTap.Transport raw -o - "$PP" >/dev/null 2>&1; then
    echo "probe tap personality has a Transport key (plan §3.2 leaves it out)"; exit 2
  fi
  echo "probe checks passed: probe build $PBUILD (installed probe $pinstalled), crash=${PROBE_CRASH:-0}, production dext $installed unchanged"
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
