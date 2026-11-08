#!/usr/bin/env python3
"""Decode hidcap log lines of report 0x06 into fields and print an event timeline."""
import sys, re
pat = re.compile(r'^\s*([\d.]+) \[.*?\] id=0x06 len=16(?: \(\+(\d+) identical before\))?: (.*)$')
HAT = {0:"N",1:"NE",2:"E",3:"SE",4:"S",5:"SW",6:"W",7:"NW",8:"null"}
def s16(lo, hi):
    v = lo | (hi << 8); return v - 65536 if v >= 32768 else v
def parse(b):
    f = {}
    f["X"], f["Y"], f["Z"], f["Rz"] = s16(b[1],b[2]), s16(b[3],b[4]), s16(b[5],b[6]), s16(b[7],b[8])
    trig = b[9] | (b[10] << 8) | (b[11] << 16)          # 24 bits: 10 Rx, 10 Ry, 4 hat
    f["LT"] = trig & 0x3ff; f["RT"] = (trig >> 10) & 0x3ff; f["hat"] = (trig >> 20) & 0xf
    btn = b[12] | (b[13] << 8) | (b[14] << 16) | (b[15] << 24)  # 19 buttons + 13 pad bits
    f["buttons"] = btn & 0x7ffff; f["pad"] = btn >> 19
    return f
frames = []
for line in open(sys.argv[1]):
    m = pat.match(line)
    if not m: continue
    t = float(m.group(1)); b = bytes.fromhex(m.group(3).replace(" ", ""))
    frames.append((t, parse(b)))
print(f"{len(frames)} distinct frames")
prev = None
rng = {k: [0, 0] for k in ("X","Y","Z","Rz","LT","RT")}
axis_active = {k: None for k in ("X","Y","Z","Rz","LT","RT")}
events = []
for t, f in frames:
    for k in rng:
        rng[k][0] = min(rng[k][0], f[k]); rng[k][1] = max(rng[k][1], f[k])
        moving = abs(f[k]) > 2000 if k in ("X","Y","Z","Rz") else f[k] > 40
        if moving and axis_active[k] is None: axis_active[k] = t
        if not moving and axis_active[k] is not None:
            if t - axis_active[k] > 0.15: events.append((axis_active[k], f"axis {k} active {axis_active[k]:.2f}-{t:.2f}s"))
            axis_active[k] = None
    if prev:
        ch = f["buttons"] ^ prev["buttons"]
        for i in range(19):
            if ch >> i & 1: events.append((t, f"button {i+1:2d} {'DOWN' if f['buttons']>>i&1 else 'up  '}"))
        if f["hat"] != prev["hat"]: events.append((t, f"hat -> {HAT.get(f['hat'], f['hat'])}"))
        if f["pad"] != prev["pad"]: events.append((t, f"pad bits -> 0x{f['pad']:04x}"))
    prev = f
events.sort()
for t, e in events: print(f"{t:8.3f}  {e}")
print("axis ranges:", {k: tuple(v) for k, v in rng.items()})
print("pad values seen:", sorted({f["pad"] for _, f in frames}))
