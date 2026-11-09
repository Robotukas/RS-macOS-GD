# Latency probes

Read-only probes from the controller-latency investigation (docs/plans/latency-plan.md, section 3). None of them
seizes a device or connects to the dext. Build in place; the binaries are git-ignored.

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swiftc -O padlat.swift -o padlat
swiftc -O napwatch.swift -o napwatch
swiftc -O hops.swift -o hops
clang -O2 latprobe.c -o latprobe -framework IOKit -framework CoreFoundation
clang -O2 hidprobe.c -o hidprobe -framework IOKit -framework CoreFoundation
```

## Usage

- `./padlat 20 /abs/path/run.csv` : SCUF report to virtual-pad report latency. While it runs: flick the left stick x10,
  tap A/B x10, pull and release a trigger x5, then circle a stick for 5 s. Prints stick-onset, digital and trigger-edge
  latency (p50/p95/p99/max), cross-correlation lag of continuous motion, and virtual inter-arrival jitter.
- `./napwatch <gdhub-pid> 120` : per-thread priorities (cur/base), frontmost app, whether GDHub windows are on screen.
  Base priority 4 means App Nap; 46 is normal.
- `./latprobe 30 out.csv`, then `python3 -I analyse.py out.csv` : SCUF change to pad report latency, latency of the
  first change after rest, pad inter-arrival.
- `./hidprobe 20` : timestamps both the 02E0 pad and the synthetic 028E copy, to compute the copy's extra delay.
- `./hops` : microbenchmark of `main.async`, queue hops and timer lateness.

Compare `padlat`'s numbers with GDHub's built-in meter (Driver menu "Latency" lines, or
`log stream --predicate 'subsystem == "com.interlinked.gdhub" AND category == "latency"'`; launch GDHub with
`--latency-log` to print the line every 2 s instead of every 10 s).
