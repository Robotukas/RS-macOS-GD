#!/bin/zsh
# Stream GDHub dext / sysextd / kernelmanagerd / kernel logs (the probe dext's process is included). Add "--load" to
# include amfid and syspolicyd (load/signature failures).
# Usage: scripts/dext-log.sh [--load]
# T0 probe (docs/plans/receiver-takeover-plan.md §8.5, removed in T0.5):
#   scripts/dext-log.sh --probe [--load]   stream only the probe: its process, every "GDHubProbe:" line, and any line from
#                                          sysextd, kernelmanagerd, the kernel, ReportCrash, … that mentions TapProbe
#   scripts/dext-log.sh --probe-last [DURATION]   same filter from the log store, newest 10m by default (log show --info --debug)
PRED='process == "com.interlinked.gdhub.VirtualHID" OR process == "com.interlinked.gdhub.TapProbe" OR process == "sysextd" OR process == "kernelmanagerd" OR (sender == "kernel" AND (eventMessage CONTAINS "DK:" OR eventMessage CONTAINS[c] "gdhub")) OR subsystem == "com.interlinked.gdhub"'
PROBE_PRED='process == "com.interlinked.gdhub.TapProbe" OR eventMessage CONTAINS "GDHubProbe:" OR eventMessage CONTAINS[c] "TapProbe"'
MODE=stream; LAST=10m; PROBE=0; LOAD=0
while (( $# )); do
  case $1 in
    --load) LOAD=1 ;;
    --probe) PROBE=1 ;;
    --probe-last) PROBE=1; MODE=show; if [[ -n ${2:-} && $2 != --* ]]; then LAST=$2; shift; fi ;;
    *) echo "usage: scripts/dext-log.sh [--load] | --probe [--load] | --probe-last [DURATION] [--load]"; exit 64 ;;
  esac
  shift
done
(( PROBE )) && PRED=$PROBE_PRED
(( LOAD )) && PRED="$PRED OR process == \"amfid\" OR process == \"syspolicyd\""
if [[ $MODE == show ]]; then
  exec /usr/bin/log show --style compact --info --debug --last "$LAST" --predicate "$PRED"
fi
exec /usr/bin/log stream --style compact --level debug --predicate "$PRED"
