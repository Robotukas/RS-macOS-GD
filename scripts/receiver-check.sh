#!/bin/zsh
# T0 check (receiver takeover plan §8.5, §10.2 PC/L1/L3): who drives the Corsair/SCUF receiver, per USB interface.
# Read-only. Queries ioreg by registry name (vhid-check convention) as a plist and parses it with python3 -I.
# Usage: scripts/receiver-check.sh [--expect-if3 <child name>]
# Exit: 0 receiver present (and --expect-if3 satisfied); 1 --expect-if3 mismatch; 2 receiver not present; 64 bad usage.
set -euo pipefail
EXPECT=""
case "${1:-}" in
  "") ;;
  --expect-if3) [[ -n "${2:-}" ]] || { print -u2 "usage: $0 [--expect-if3 <name>]"; exit 64 }; EXPECT="$2" ;;
  *) print -u2 "usage: $0 [--expect-if3 <name>]"; exit 64 ;;
esac

exec python3 -I - "$EXPECT" <<'PY'
import os, plistlib, subprocess, sys, time

NAME = "SCUF Envision Pro Wireless USB Receiver V2"
EXPECT = sys.argv[1]
FIXTURE = os.environ.get("RECEIVER_CHECK_FIXTURE", "")

def snap():
    t = time.monotonic()
    if FIXTURE:  # offline parser test only: a saved `ioreg -a` plist
        out = open(FIXTURE, "rb").read()
    else:
        out = subprocess.run(["ioreg", "-a", "-r", "-w0", "-l", "-n", NAME], capture_output=True).stdout
    roots = plistlib.loads(out) if out.strip() else []
    return roots[0] if roots else None, t

def kids(n): return n.get("IORegistryEntryChildren", [])
def nm(n): return n.get("IORegistryEntryName", "?")
def cl(n): return n.get("IOObjectClass", "?")
def ds(n): return n.get("DebugState") if isinstance(n.get("DebugState"), dict) else {}
def is_client(n): return cl(n).endswith("UserClient") or cl(n).endswith("InterfaceClient")

def interfaces(root):
    d = {}
    for k in kids(root):
        if cl(k) == "IOUSBHostInterface" and "bInterfaceNumber" in k:
            d[int(k["bInterfaceNumber"])] = k
    return d

def hid_chain(iface):
    """IOUSBHostInterface -> IOHIDDevice -> IOHIDInterface -> event service, found by class, not position."""
    for dev in kids(iface):
        if "InputReportCount" in ds(dev) or dev.get("PrimaryUsagePage") is not None:
            for hi in kids(dev):
                if cl(hi) == "IOHIDInterface":
                    return dev, hi
            return dev, None
    return None, None

root, t0 = snap()
if root is None:
    print("receiver not present")
    sys.exit(2)
pid = int(root.get("idProduct", 0))
state = {14856: "linked", 14857: "idle"}.get(pid, "unexpected")
print(f"receiver: idProduct={pid} ({state}) vendor={root.get('idVendor')}")
if1 = interfaces(root)
children = {}
rows = []
d3 = None
for n in range(5):
    it = if1.get(n)
    if it is None:
        print(f"if{n}: absent"); children[n] = "absent"; continue
    drv = [k for k in kids(it) if not is_client(k)]
    cli = sorted({nm(k).split("@")[0] for k in kids(it) if is_client(k)})
    dnames = ",".join(f"{nm(k)}({cl(k)})" if nm(k) != cl(k) else nm(k) for k in drv) or "none"
    line = f"if{n}: bInterfaceNumber={it['bInterfaceNumber']} driver={dnames}"
    if cli: line += f" clients={','.join(cli)}"
    print(line)
    dev, hi = hid_chain(it)
    if dev is None:
        children[n] = "none"
        if n in (3, 4): print("    no IOHIDDevice attached")
        continue
    ch = [k for k in kids(hi) if not is_client(k)] if hi else []
    c = ch[0] if ch else None
    cname = nm(c) if c else "none"
    children[n] = cname
    print(f"    hid: page={dev.get('PrimaryUsagePage')} usage={dev.get('PrimaryUsage')} "
          f"IOHIDDevice={dev.get('IOUserClass', cl(dev))} score={dev.get('IOProbeScore')}")
    if c:
        pidk = [k for k in c if "PID" in k.upper() and "UserServer" in k]
        pidv = c[pidk[0]] if pidk else "n/a(not in registry)"
        print(f"    child: {cname} IOUserClass={c.get('IOUserClass', '-')} IOProbeScore={c.get('IOProbeScore')} "
              f"server={c.get('IOUserServerName', '-')} pid={pidv}")
    else:
        print("    child: none on IOHIDInterface")
    if n in (3, 4):
        d = ds(hi) if hi else {}
        print(f"    IOHIDInterface DebugState: ReportAvailableCalls={d.get('ReportAvailableCalls')} "
              f"CreatedBuffers={d.get('CreatedBuffers')} ReleasedBuffers={d.get('ReleasedBuffers')}")
        print(f"    IOHIDDevice InputReportCount={ds(dev).get('InputReportCount')} "
              f"DeviceOpenedByEventSystem={(hi or {}).get('DeviceOpenedByEventSystem', 'n/a')}")
    if n == 3:
        rows = [k for k in kids(dev) if cl(k) == "IOHIDLibUserClient"]
        d3 = dev

# seize state (IOHIDLibUserClient DebugState.ClientSeized, children of the interface-3 IOHIDDevice)
if d3 is not None:
    if rows:
        parts = []
        for k in rows:
            s = ds(k)
            parts.append(f"{k.get('IOUserClientCreator', '?')}:seized={s.get('ClientSeized', 'n/a')},opened={s.get('ClientOpened', 'n/a')}")
        print("if3 user clients: " + "; ".join(parts))
        print("seize state: " + ("SEIZED" if any(ds(k).get("ClientSeized") in (True, "Yes") for k in rows) else "no client seized"))
    else:
        print("if3 user clients: none")
        print("seize state: no client seized (no IOHIDLibUserClient)")
else:
    print("seize state: not exposed")

# rate on interface 3: InputReportCount twice, 2 s apart
rate = "n/a"
if d3 is None:
    print("if3 rate: n/a (no IOHIDDevice on interface 3)")
if d3 is not None:
    c0 = ds(d3).get("InputReportCount")
    time.sleep(2)
    root2, t1 = snap()
    c1 = None
    if root2 is not None and 3 in interfaces(root2):
        dev2, _ = hid_chain(interfaces(root2)[3])
        c1 = ds(dev2).get("InputReportCount") if dev2 else None
    if isinstance(c0, int) and isinstance(c1, int) and t1 > t0:
        rate = f"{(c1 - c0) / (t1 - t0):.0f}"
        print(f"if3 rate: {rate} reports/s ({c1 - c0} reports in {t1 - t0:.2f}s; expect 940-970 when the controller is awake)")
    else:
        print("if3 rate: n/a (InputReportCount missing or receiver changed during sampling)")

# volume-key switch-off: the receiver's Consumer service (page 0x0C). Read-only get; this script never sets anything.
if not FIXTURE:
    import re
    try:
        r = subprocess.run(["hidutil", "property", "--matching", '{"VendorID":0x1b1c,"ProductID":0x3a08,"PrimaryUsagePage":12}',
                            "--get", "UserKeyMapping"], capture_output=True, text=True, timeout=10)
        rows = re.split(r"(?m)^(?=[0-9a-fA-F]+\s+UserKeyMapping\b)", r.stdout)
        found = []
        for row in rows:
            m = re.match(r"([0-9a-fA-F]+)\s+UserKeyMapping\s*(.*)", row, re.S)
            if m:
                v = " ".join(m.group(2).split())
                found.append((m.group(1), "none" if v.replace(" ", "") in ("", "()", "(null)") else v))
        if r.returncode != 0 or not found:
            print("if4 UserKeyMapping: n/a (service not found)")
        elif len(found) == 1:
            print(f"if4 UserKeyMapping: {found[0][1]}")
        else:
            print("if4 UserKeyMapping: " + "; ".join(f"{i}={v}" for i, v in found))
    except Exception as e:
        print(f"if4 UserKeyMapping: n/a ({e})")

print(f"if3-child={children.get(3, 'absent')} if4-child={children.get(4, 'absent')}")
if EXPECT:
    ok = children.get(3) == EXPECT and children.get(4) == "AppleUserHIDEventDriver"
    print(f"expect: if3={EXPECT} if4=AppleUserHIDEventDriver -> {'OK' if ok else 'MISMATCH'}")
    sys.exit(0 if ok else 1)
PY
