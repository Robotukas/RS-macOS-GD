#!/bin/zsh
# Manage the GDHub engine LaunchAgent (docs/plans/engine-agent-plan.md §4.3). The engine is the same app binary run as
# `GDHub --engine` by launchd; it owns the virtual pad so the pad keeps up while a fullscreen game owns the screen.
#
# Usage: scripts/engine-agent.sh install|uninstall|restart|status|latency|log|bootout_wait|bootstrap_retry|wait_connected
#   install     copy the plist from /Applications/GDHub.app, bootout (waiting), bootstrap, wait until connected, status
#   uninstall   bootout (waiting) and remove the plist, then release a pinned pad (--release-pad); the GUI is in-app mode from its next launch
#   restart     kickstart -k, then wait until connected
#   status      launchd state; exit 0 only if running, interactive, and the engine's last `connection:` line is connected
#   latency     live stream of the engine's rolling meter line (every 10 s): callback delay of ALL frames + changed-frame
#               latency. Run it while playing; Ctrl-C to stop
#   log         live stream of every engine log line (category engine)
# All log reads use /usr/bin/log: in zsh a bare `log` is a builtin and silently reads nothing.
L=com.interlinked.gdhub.engine
DST=~/Library/LaunchAgents/$L.plist
SRC=/Applications/GDHub.app/Contents/Resources/$L.plist
PROC='/Applications/GDHub.app/Contents/MacOS/GDHub --engine'
U=$(id -u)
T=gui/$U/$L
zmodload zsh/datetime

# Boots the job out and returns only once launchd no longer knows it (bootout itself returns early).
bootout_wait() {
  launchctl bootout $T 2>/dev/null
  local i
  for i in {1..60}; do
    launchctl print $T >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  print -u2 "warning: engine still loaded 6 s after bootout: killing it"
  pkill -9 -f "$PROC"
  for i in {1..10}; do
    launchctl print $T >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  return 1
}

# bootstrap; rc 5 or 37 retries (a bootout may still be finishing); rc 5 with the job loaded counts as loaded.
bootstrap_retry() {
  local n rc err
  for n in 0 1 2 3; do
    err=$(launchctl bootstrap gui/$U $DST 2>&1); rc=$?
    (( rc == 0 )) && return 0
    if (( rc == 5 )) && launchctl print $T >/dev/null 2>&1; then return 0; fi
    (( rc == 5 || rc == 37 )) || { print -u2 "bootstrap failed (rc $rc): $err"; return $rc }
    sleep 0.2
  done
  print -u2 "bootstrap failed after retries (rc $rc): $err"
  return $rc
}

# status [-q]: see the header. -q prints nothing.
status() {
  local quiet=0; [[ ${1:-} == -q ]] && quiet=1
  local out; out=$(launchctl print $T 2>/dev/null) || { (( quiet )) || print "engine: not loaded"; return 1 }
  local state pid spawn last runs
  state=$(print -r -- $out | awk -F' = ' '/^\tstate = /{print $2; exit}')
  pid=$(print -r -- $out | awk -F' = ' '/^\tpid = /{print $2; exit}')
  spawn=$(print -r -- $out | awk -F' = ' '/^\tspawn type = /{print $2; exit}')
  last=$(print -r -- $out | awk -F' = ' '/^\tlast exit code = /{print $2; exit}')
  runs=$(print -r -- $out | awk -F' = ' '/^\truns = /{print $2; exit}')
  local conn=""
  if [[ $state == running && -n $pid ]]; then
    local start
    start=$(date -j -f '%a %b %d %T %Y' "$(ps -o lstart= -p $pid | xargs)" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    if [[ -n $start ]]; then
      conn=$(/usr/bin/log show --style compact --start "$start" --predicate "processID == $pid AND subsystem == \"com.interlinked.gdhub\" AND category == \"engine\" AND eventMessage BEGINSWITH \"connection: \"" 2>/dev/null | tail -1)
    fi
  fi
  if (( ! quiet )); then
    print "state = $state"; print "pid = ${pid:--}"; print "spawn type = ${spawn:--}"
    print "last exit code = ${last:--}"; print "runs = ${runs:--}"
    print "connection: ${conn:-(none logged since the process started)}"
  fi
  [[ $state == running && $spawn == interactive* && $conn == *"connection: connected("* ]]
}

wait_connected() {
  local end=$(( EPOCHREALTIME + 5 ))
  while (( EPOCHREALTIME < end )); do
    status -q && return 0
    sleep 0.5
  done
  status -q
}

case ${1:-} in
  install)
    plutil -lint "$SRC" >/dev/null || { print -u2 "missing or invalid $SRC (install the app first)"; exit 1 }
    mkdir -p ~/Library/LaunchAgents && cp "$SRC" "$DST" || exit 1
    bootout_wait || { print -u2 "could not unload the running engine"; exit 1 }
    bootstrap_retry || exit 1
    wait_connected; rc=$?
    status
    exit $rc ;;
  uninstall)
    bootout_wait; rc=$?
    rm -f "$DST"
    # T7: a pad the driver pinned (LIVE, the engine was killed) is removed now, not after the 30 s orphan timer. The release runs the
    # app binary as a short-lived foreground process (hello, setForwarding(INERT, RELEASE_PAD), exit). Three safeguards, because an
    # older installed app (this is step U1 of the T7 install itself, and of every rollback) does not know the flag and would start a
    # full engine that never returns: (1) it only runs when the binary contains the feature marker that this build's tool carries (read
    # with grep, the app is not executed); (2) it runs in the background with a hard 8 s limit, then it is killed; (3) its output goes
    # to a temp file that is shown, never discarded, and nothing it does can fail the uninstall.
    bin=/Applications/GDHub.app/Contents/MacOS/GDHub
    if [[ -x $bin ]]; then
      if grep -aq 'gdhub-feature:release-pad-v1' "$bin"; then
        out=$(mktemp -t gdhub-release); "$bin" --engine --engine-foreground --release-pad >"$out" 2>&1 &
        rpid=$!
        ( sleep 8; kill -9 $rpid 2>/dev/null ) &
        wd=$!
        wait $rpid 2>/dev/null; rrc=$?
        kill $wd 2>/dev/null; wait $wd 2>/dev/null
        if (( rrc == 137 || rrc == 143 )); then print "release-pad: killed after 8 s (no answer); the driver's 30 s orphan timer removes a pinned pad"
        else tail -3 "$out"; print "release-pad: exit $rrc"; fi
        rm -f "$out"
      else
        print "release-pad: the installed app is older and does not know it; skipped (a pinned pad is removed by the driver after 30 s)"
      fi
    fi
    print "engine agent uninstalled (the /Applications GUI is in in-app mode from its next launch)"
    exit $rc ;;
  restart)
    launchctl kickstart -k $T || exit 1
    wait_connected; rc=$?
    status
    exit $rc ;;
  status) status ;;
  latency)
    print "Engine meter, every 10 s. cb(all frames) = kernel timestamp to HID callback for EVERY report (idle stream included)."
    exec /usr/bin/log stream --style compact --level info --predicate 'process == "GDHub" AND subsystem == "com.interlinked.gdhub" AND category == "engine" AND eventMessage BEGINSWITH "meter: "' ;;
  log)
    exec /usr/bin/log stream --style compact --level info --predicate 'process == "GDHub" AND subsystem == "com.interlinked.gdhub" AND category == "engine"' ;;
  bootout_wait) bootout_wait ;;
  bootstrap_retry) bootstrap_retry ;;
  wait_connected) wait_connected ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
