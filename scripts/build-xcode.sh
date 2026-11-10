#!/bin/zsh
# Build GDHub.app + embedded dext (signed, development), verify, install to /Applications, launch.
# Usage: scripts/build-xcode.sh [--no-install | --no-open] [--same-build] [--release] [--engine-install]
#        scripts/build-xcode.sh --check
#        scripts/build-xcode.sh --seed-source-hash <build> <commit>
#   --same-build: reuse the current number in Xcode/build-number (app-only change; the embedded dext keeps
#   its version, so no driver replacement is triggered). Combine as e.g. `--same-build --no-open`.
#   The build guard refuses it unless the driver sources are the ones the activated build was built from:
#   Xcode/dext-source.hash ("<build> <sha256>") must exist, carry the reused number and the hash of the tracked files
#   under Dext/ and Shared/ plus the GDHubVirtualHID target block of project.yml, and the reused number must be the
#   `activated enabled` build in `systemextensionsctl list`. Two different driver binaries never share a build number.
#   --release: build and install the Release configuration (-O, no GDHub.debug.dylib) for play sessions; Debug is the
#   default. Combine with --same-build so the installed driver (same version) is not replaced.
#   --engine-install: after installing, install and start the background engine LaunchAgent (scripts/engine-agent.sh);
#   the one-time switch to engine mode. With the agent already installed, every install refreshes and restarts it.
#   --check: compile only. Release configuration into a scratch .xcodebuild-check with the current number, run the same
#   checks as a real build, delete the built app, install nothing, write neither Xcode/build-number nor the hash file,
#   and do not mind a running engine agent. Use it to see that driver code compiles before the one replacement.
#   --seed-source-hash <build> <commit>: write Xcode/dext-source.hash (and Xcode/build-number) = <build> and the hash of
#   the current driver sources, but only when those sources equal <commit>'s (git diff of Dext/ and Shared/, the same
#   GDHubVirtualHID block of project.yml, no untracked file there). Used once to record what build 24 was built from.
# Xcode/build-number and Xcode/dext-source.hash are written only after a build and its checks succeeded.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEXT_ID=com.interlinked.gdhub.VirtualHID; UDID=00006031-001851E126E1001C; NUMFILE=Xcode/build-number; HASHFILE=Xcode/dext-source.hash
XCODEGEN=$(command -v xcodegen 2>/dev/null || echo /opt/homebrew/bin/xcodegen)

# The hash of what the driver is built from: every tracked file under Dext/ and Shared/ (sorted by path, path, size and
# bytes) and the GDHubVirtualHID target block of project.yml. Prints the hex digest. Refuses (exit 3) when an untracked
# file sits under Dext/ or Shared/: it would be compiled into the driver without being part of the hash.
# `source_hash block` prints the block alone (the seeding check compares it with the one at a commit).
source_hash() {
  python3 -I - "$@" <<'PY'
import hashlib, subprocess, sys

def git(*a):
    return subprocess.run(["git", *a], check=True, capture_output=True).stdout

def block(text):
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if l.rstrip() == "  GDHubVirtualHID:"), None)
    if start is None:
        sys.exit("project.yml has no GDHubVirtualHID target block")
    out = [lines[start]]
    for l in lines[start + 1:]:
        body = l.lstrip(" ")
        if body and not body.startswith("#") and len(l) - len(body) <= 2:
            break
        out.append(l)
    while out and not out[-1].strip():
        out.pop()
    return "\n".join(out) + "\n"

mode = sys.argv[1] if len(sys.argv) > 1 else "hash"
if mode == "block-at":
    sys.stdout.write(block(git("show", sys.argv[2] + ":project.yml").decode()))
    sys.exit(0)
if mode == "block":
    sys.stdout.write(block(open("project.yml").read()))
    sys.exit(0)
others = [p for p in git("ls-files", "--others", "--exclude-standard", "-z", "--", "Dext", "Shared").split(b"\0") if p]
if others:
    sys.stderr.write("untracked files under Dext/ or Shared/ (they would be built into the driver without being in its hash):\n")
    for p in sorted(others):
        sys.stderr.write("  " + p.decode(errors="replace") + "\n")
    sys.exit(3)
h = hashlib.sha256()
for path in sorted(p for p in git("ls-files", "-z", "--", "Dext", "Shared").split(b"\0") if p):
    try:
        data = open(path, "rb").read()
        h.update(b"F %s %d\n" % (path, len(data)) + data + b"\n")
    except FileNotFoundError:
        h.update(b"F %s missing\n" % path)
h.update(b"P\n" + block(open("project.yml").read()).encode())
print(h.hexdigest())
PY
}

# The build `systemextensionsctl list` shows as `activated enabled` for the driver (the enabled entry, not the highest one).
enabled_build() {
  systemextensionsctl list 2>/dev/null | grep -F "$DEXT_ID" | grep -F "activated enabled" \
    | sed -nE 's/.*\([^/]*\/([0-9]+)\).*/\1/p' | sort -n | tail -1 || true
}

if [[ ${1:-} == --seed-source-hash ]]; then
  [[ $# -eq 3 && $2 == <-> ]] || { echo "usage: scripts/build-xcode.sh --seed-source-hash <build> <commit>"; exit 2; }
  SEED_BUILD=$2; SEED_COMMIT=$3
  git rev-parse --verify --quiet "$SEED_COMMIT^{commit}" >/dev/null || { echo "seeding: $SEED_COMMIT is not a commit"; exit 2; }
  git diff --quiet "$SEED_COMMIT" -- Dext Shared \
    || { echo "seeding refused: Dext/ or Shared/ differ from $SEED_COMMIT, so they are not the sources of build $SEED_BUILD"; exit 2; }
  [[ -z $(git status --porcelain -- Dext Shared) ]] \
    || { echo "seeding refused: git status shows changes under Dext/ or Shared/"; exit 2; }
  [[ $(source_hash block-at "$SEED_COMMIT") == $(source_hash block) ]] \
    || { echo "seeding refused: the GDHubVirtualHID block of project.yml differs from $SEED_COMMIT"; exit 2; }
  H=$(source_hash) || { echo "seeding refused: the source hash could not be made"; exit 2; }
  [[ -f $HASHFILE ]] && echo "replacing $HASHFILE: $(cat $HASHFILE)"
  print -r -- "$SEED_BUILD $H" > $HASHFILE
  print -r -- $SEED_BUILD > $NUMFILE
  echo "seeded $HASHFILE = $SEED_BUILD $H (driver sources equal $SEED_COMMIT); $NUMFILE = $SEED_BUILD"
  exit 0
fi

installed=$(systemextensionsctl list 2>/dev/null | sed -nE "s/.*${DEXT_ID//./\\.} \([^/]*\/([0-9]+)\).*/\1/p" | sort -n | tail -1)
last=$(cat "$NUMFILE" 2>/dev/null || echo 1); installed=${installed:-0}
SAME=0; CONFIG=Debug; ENGINE_INSTALL=0; CHECK=0; ARGS=()
for a in "$@"; do
  if [[ $a == --same-build ]]; then SAME=1
  elif [[ $a == --release ]]; then CONFIG=Release
  elif [[ $a == --engine-install ]]; then ENGINE_INSTALL=1
  elif [[ $a == --check ]]; then CHECK=1
  else ARGS+=("$a"); fi
done
set -- "${ARGS[@]}"
if (( CHECK )); then
  (( SAME || ENGINE_INSTALL )) && { echo "--check stands alone: it installs nothing and uses the current number"; exit 2; }
  CONFIG=Release; ARGS=(--no-install); set -- --no-install
fi
if (( SAME || CHECK )); then BUILD=$(( installed > last ? installed : last )); else BUILD=$(( (installed > last ? installed : last) + 1 )); fi
BUILDDIR=.xcodebuild; (( CHECK )) && BUILDDIR=.xcodebuild-check
LOG=$BUILDDIR/last-build.log
# Test hook for the build guard's own tests (scripts/tools/test_build_guard.py): skips the post-build checks, which need
# a signed build. Never together with an install.
SKIP_VERIFY=${GDHUB_BUILD_TEST_SKIP_VERIFY:-0}
if [[ $SKIP_VERIFY == 1 && ${1:-} != --no-install ]]; then echo "GDHUB_BUILD_TEST_SKIP_VERIFY needs --no-install or --check"; exit 2; fi
AGENT=~/Library/LaunchAgents/com.interlinked.gdhub.engine.plist
if [[ -f $AGENT ]] && (( ! SAME && ! CHECK )); then
  echo "dext build would change while the background engine is installed:"
  echo "run scripts/engine-agent.sh uninstall first (or pass --same-build)"; exit 2
fi
(( BUILD <= 9999 )) || { echo "build number $BUILD > 9999 is not a valid dext CFBundleVersion"; exit 1; }
HASH=$(source_hash) || {
  if (( CHECK )); then HASH=unhashed; else echo "build refused: the driver source hash could not be made"; exit 2; fi
}
if (( SAME )); then
  # The build guard: an app-only build may only embed the driver the activated build was built from.
  [[ -f $HASHFILE ]] || { echo "--same-build refused: $HASHFILE is missing. Seed it once from the commit build $BUILD was built from:"
                          echo "  scripts/build-xcode.sh --seed-source-hash $BUILD <commit>"; exit 2; }
  read -r HASH_BUILD HASH_SEEDED < $HASHFILE || true
  [[ ${HASH_BUILD:-} == $BUILD ]] || { echo "--same-build refused: $HASHFILE is for build ${HASH_BUILD:-?}, but this build would reuse number $BUILD"; exit 2; }
  [[ ${HASH_SEEDED:-} == $HASH ]] || { echo "--same-build refused: the driver sources (Dext/, Shared/, the GDHubVirtualHID block of project.yml) are not the ones build $BUILD was built from."
                                      echo "  recorded ${HASH_SEEDED:-?}"; echo "  now      $HASH"
                                      echo "A driver change needs a new build number (no --same-build) and the replacement steps of the takeover plan."; exit 2; }
  ENABLED=$(enabled_build)
  [[ -n $ENABLED ]] || { echo "--same-build refused: systemextensionsctl list shows no activated enabled build of $DEXT_ID"; exit 2; }
  [[ $ENABLED == $BUILD ]] || { echo "--same-build refused: this build would be $BUILD, the activated enabled driver is build $ENABLED"; exit 2; }
fi
mkdir -p $BUILDDIR
$XCODEGEN generate --spec project.yml --quiet
if ! xcodebuild -project GDHub.xcodeproj -scheme GDHub -configuration $CONFIG -derivedDataPath $BUILDDIR \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration CURRENT_PROJECT_VERSION=$BUILD \
     GDHUB_DEXT_SOURCE_HASH=$HASH build \
     > $LOG 2>&1; then
  grep -E "error:|No profiles" $LOG | head -20
  (( CHECK )) && rm -rf $BUILDDIR/Build/Products/$CONFIG/GDHub.app
  exit 1
fi
APP=$BUILDDIR/Build/Products/$CONFIG/GDHub.app
DEXT=$APP/Contents/Library/SystemExtensions/$DEXT_ID.dext
# The post-build checks (signature, entitlements, profile, personality, plist, floating-point flags).
verify_build() {
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
# The app records what its embedded driver was built from (GDHubDextSourceHash in the app's Info.plist, so the dext's own
# files and signature stay untouched): a rollback archive can be checked against Xcode/dext-source.hash.
[[ $(plutil -extract GDHubDextSourceHash raw "$APP/Contents/Info.plist" 2>/dev/null) == $HASH ]] \
  || { echo "app Info.plist GDHubDextSourceHash does not carry the source hash $HASH"; exit 1; }
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
if grep -E '/clang .* -c .*Shared/GDHubXlate\.c' $LOG | grep -F driverkit | grep -vqF -e 'ffp-contract\=off' -e 'ffp-contract=off'; then
  echo "a compile of Shared/GDHubXlate.c for the dext in $LOG lacks -ffp-contract=off"; exit 2
fi
}
if [[ $SKIP_VERIFY != 1 ]]; then verify_build; fi
# The build number and the source hash are recorded only now, after the build and its checks succeeded (a failed build
# leaves them as they were). A --check build records nothing and deletes the app it built.
if (( CHECK )); then
  rm -rf "$APP"
  echo "check passed: build $BUILD ($CONFIG, scratch $BUILDDIR) compiled and verified; nothing installed, nothing recorded"
  exit 0
fi
print -r -- $BUILD > "$NUMFILE"
print -r -- "$BUILD $HASH" > "$HASHFILE"
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
