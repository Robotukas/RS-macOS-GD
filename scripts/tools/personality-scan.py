#!/usr/bin/env python3
"""T0 scan (receiver takeover plan §8.5, A14): installed driver personalities that could compete for the
Corsair/SCUF receiver (vendor 6940 = 0x1B1C) or sit on IOHIDInterface. Read-only. Run: python3 -I scripts/tools/personality-scan.py"""
import os, plistlib, re

ROOTS = ["/System/Library/Extensions", "/Library/Extensions", "/System/Library/DriverExtensions",
         "/Library/DriverExtensions", "/Library/SystemExtensions"]
VENDOR = 6940
VENDOR_KEYS = {"idvendor", "vendorid", "idvendorarray", "idvendormask", "vendoridmask", "vendor", "vendorids"}
PRODUCT_KEYS = ("idProduct", "ProductID", "idProductArray", "idProductMask", "ProductIDMask")
USAGE_KEYS = ("PrimaryUsagePage", "PrimaryUsage", "DeviceUsagePage", "DeviceUsage", "DeviceUsagePairs")
MATCH_DICTS = ("IOPropertyMatch", "IONameMatch", "IOParentMatch", "IOPathMatch")
ID_FORMS = {"1b1c", "0x1b1c", "6940", "0x1b1c0000"}

def is_vendor(v):
    if isinstance(v, bool): return False
    if isinstance(v, int): return v == VENDOR
    if isinstance(v, str):
        t = v.strip().lower()
        return t in ID_FORMS or bool(re.fullmatch(r"(usb|id)?0?x?0*1b1c(,.*)?", t)) or t.startswith("usb1b1c") or t.startswith("usb,vid1b1c")
    if isinstance(v, (list, tuple)): return any(is_vendor(x) for x in v)
    if isinstance(v, dict): return any(is_vendor(x) for x in v.values())
    return False

def vendor_hits(d, path=""):
    """Yield (keypath, value) for every key under a personality that mentions the Corsair vendor id."""
    for k, v in d.items():
        kp = f"{path}.{k}" if path else k
        if str(k).lower() in VENDOR_KEYS and is_vendor(v):
            yield kp, v
        elif isinstance(v, dict):
            yield from vendor_hits(v, kp)
        elif isinstance(v, (list, tuple)):
            for i, x in enumerate(v):
                if isinstance(x, dict): yield from vendor_hits(x, f"{kp}[{i}]")
                elif str(path).split(".")[-1] in MATCH_DICTS and is_vendor(x): yield kp, x
        elif isinstance(v, str) and path.split(".")[0] in MATCH_DICTS and is_vendor(v):
            yield kp, v

def usage_could_match(d):
    """True unless a usage/product key excludes page 65368 / usage 1 / product 14856 (a missing key means 'any')."""
    pid = d.get("ProductID", d.get("idProduct"))
    if isinstance(pid, int) and pid != 14856: return False
    pairs = d.get("DeviceUsagePairs")
    if isinstance(pairs, list) and pairs:
        return any(isinstance(x, dict) and x.get("DeviceUsagePage") in (None, 65368) and x.get("DeviceUsage") in (None, 1)
                   for x in pairs)
    page = d.get("PrimaryUsagePage", d.get("DeviceUsagePage"))
    use = d.get("PrimaryUsage", d.get("DeviceUsage"))
    if isinstance(page, int) and page != 65368: return False
    if isinstance(use, int) and use != 1: return False
    return True

def find_plists():
    for root in ROOTS:
        if not os.path.isdir(root): continue
        for dp, dn, fn in os.walk(root):
            if "Info.plist" in fn:
                yield root, dp, os.path.join(dp, "Info.plist")

def short(d, keys):
    return " ".join(f"{k}={d[k]!r}" for k in keys if k in d)

def main():
    bundles = personalities = skipped = 0
    seen = set()
    hits, generic = [], []
    for root, dp, ip in find_plists():
        rp = os.path.realpath(ip)
        if rp in seen: continue
        seen.add(rp)
        try:
            with open(ip, "rb") as f: info = plistlib.load(f)
            if not isinstance(info, dict): raise ValueError
        except Exception:
            skipped += 1; continue
        pers = info.get("IOKitPersonalities")
        if not isinstance(pers, dict): continue
        bundles += 1
        bid = info.get("CFBundleIdentifier", "?")
        for name, p in pers.items():
            if not isinstance(p, dict): continue
            personalities += 1
            score = p.get("IOProbeScore", "-")
            prov = p.get("IOProviderClass", "-")
            vh = list(vendor_hits(p))
            base = (dp, bid, name, prov, score)
            if vh:
                hits.append(base + (vh, short(p, PRODUCT_KEYS + USAGE_KEYS),))
            if prov == "IOHIDInterface":
                has_vendor_key = any(str(k).lower() in VENDOR_KEYS for k in p)
                s = score if isinstance(score, (int, float)) else 0
                if not vh and usage_could_match(p) and (not has_vendor_key or is_vendor(next((p[k] for k in p if str(k).lower() in VENDOR_KEYS), None))):
                    skip = {"IOClass", "IOProviderClass", "IOProbeScore", "CFBundleIdentifier", "CFBundleIdentifierKernel", "IOMatchCategory", "IOUserClass", "IOUserServerName", "IOUserServerCDHash"}
                    keys = " ".join(f"{k}={str(p[k])[:90]!r}" for k in sorted(p) if k not in skip)
                    generic.append(base + (keys or "(no other matching keys: generic)", s > 1201))
    print("# personality-scan: installed driver personalities vs Corsair/SCUF receiver (vendor 6940 = 0x1B1C)")
    print(f"bundles with IOKitPersonalities scanned: {bundles}  personalities scanned: {personalities}  "
          f"plists skipped (unreadable/odd): {skipped}")
    print("roots: " + ", ".join(ROOTS))
    print("limit: most system kexts live in the kernel collection and are not on disk; their personalities are NOT covered.")
    print("compare: plan's earlier manual scan = 2,863 personalities, exactly one 6940 entry (USB mass storage 6940:6659)")
    print(f"\n== vendor 6940 hits: {len(hits)}")
    for dp, bid, name, prov, score, vh, extra in sorted(hits, key=lambda x: x[0]):
        print(f"- {dp}\n    bundle={bid} personality={name} IOProviderClass={prov} IOProbeScore={score}")
        print("    vendor keys: " + "; ".join(f"{k}={v!r}" for k, v in vh))
        if extra: print("    other keys: " + extra)
    print(f"\n== generic IOHIDInterface personalities (could match page 65368/usage 1): {len(generic)}")
    for dp, bid, name, prov, score, keys, beats in sorted(generic, key=lambda x: x[0]):
        print(f"- {dp}\n    bundle={bid} personality={name} IOProbeScore={score}{'  (> 1201!)' if beats else ''}\n    keys: {keys}")

main()
