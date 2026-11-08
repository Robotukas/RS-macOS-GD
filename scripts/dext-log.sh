#!/bin/zsh
# Stream GDHub dext / sysextd / kernelmanagerd / kernel logs. Add "--load" to include amfid and syspolicyd
# (load/signature failures). Usage: scripts/dext-log.sh [--load]
PRED='process == "com.interlinked.gdhub.VirtualHID" OR process == "sysextd" OR process == "kernelmanagerd" OR (sender == "kernel" AND (eventMessage CONTAINS "DK:" OR eventMessage CONTAINS[c] "gdhub")) OR subsystem == "com.interlinked.gdhub"'
[[ ${1:-} == --load ]] && PRED="$PRED OR process == \"amfid\" OR process == \"syspolicyd\""
exec /usr/bin/log stream --style compact --level debug --predicate "$PRED"
