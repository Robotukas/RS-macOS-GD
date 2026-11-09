import sys
rows = [l.strip().split(',') for l in open(sys.argv[1]) if l.count(',') >= 4]
sc = [(int(r[1]), r[4]) for r in rows if r[0] == 'scuf']
vp = [(int(r[1]), r[4]) for r in rows if r[0] == 'vpad']
def pct(xs, name, unit=1e3):
    if not xs: print(name, "n=0"); return
    s = sorted(xs); n = len(s)
    print("%s: n=%d p50=%.2f p90=%.2f p99=%.2f max=%.2f ms" % (name, n, s[n//2]/unit*1e-3*1e3/1e3, s[n*9//10]/1e6, s[n*99//100]/1e6, s[-1]/1e6) if False else
          "%s: n=%d p50=%.2f p90=%.2f p99=%.2f max=%.2f ms" % (name, n, s[n//2]/1e6, s[n*9//10]/1e6, s[n*99//100]/1e6, s[-1]/1e6))
changes = [sc[i][0] for i in range(1, len(sc)) if sc[i][1] != sc[i-1][1]]
print("scuf reports", len(sc), "content changes", len(changes), "vpad reports", len(vp))
# latency: each scuf change -> first vpad report at or after it (within 50 ms)
import bisect
vts = [t for t, _ in vp]
lat, miss = [], 0
for t in changes:
    j = bisect.bisect_left(vts, t)
    if j < len(vts) and vts[j] - t < 50e6: lat.append(vts[j] - t)
    else: miss += 1
pct(lat, "scuf change -> next vpad report")
print("scuf changes with no vpad report within 50 ms:", miss)
# first change after >=50 ms rest
rest = [changes[i] for i in range(1, len(changes)) if changes[i] - changes[i-1] > 50e6]
lr = []
for t in rest:
    j = bisect.bisect_left(vts, t)
    if j < len(vts) and vts[j] - t < 50e6: lr.append(vts[j] - t)
pct(lr, "first change after >=50 ms rest -> vpad")
pct([b - a for a, b in zip(vts, vts[1:]) if b - a < 50e6], "vpad inter-arrival (in motion)")
