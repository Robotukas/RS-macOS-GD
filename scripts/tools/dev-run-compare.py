#!/usr/bin/env python3 -I
"""Show and compare Developer mode run reports (docs/protocol/developer-mode-files.md).

    dev-run-compare.py A.json            one table
    dev-run-compare.py A.json B.json     both tables, then a side-by-side paired by stepId

When the steps carry per-event latency (values lat.n, lat.p50Ms, lat.p99Ms, lat.unmatched) the tables get latency
columns, a |p50 difference| above --latency-threshold (0.1 ms) is marked, and a last line summarises the T8 gate rows:
the digital and the stick-onset p50 (the n-weighted median of the steps' p50s) of A and B and the difference B - A.

A step with expect.volume carries a `volume` object in its attempt (what the Mac's volume did while the key was pressed):
the tables get a volume column ("unchanged: pass ..."; an inconclusive volume verdict reads "cannot judge", never pass or
fail), and a paired step whose volume verdict differs is marked "volume".

Exit 0: nothing differs. 1: a paired verdict differs or a marked difference exists. 2: a file cannot be used
(unreadable, not a report, or a schema newer than 1).
"""
import argparse
import json
import sys

SUPPORTED_SCHEMA = 1
DASH = "—"
HEADER_WARN_KEYS = ("templateSha256", "mappingHash", "effectivePath", "padIdentity", "xlateCore", "vpadMaxRateHz")


class ReportError(Exception):
    pass


def load(path):
    try:
        with open(path, "rb") as f:
            data = json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError) as e:
        raise ReportError("%s: cannot read (%s)" % (path, e))
    if not isinstance(data, dict):
        raise ReportError("%s: not a run report" % path)
    schema = data.get("schema", SUPPORTED_SCHEMA)
    if not isinstance(schema, int) or isinstance(schema, bool):
        raise ReportError("%s: schema is not a number" % path)
    if schema > SUPPORTED_SCHEMA:
        raise ReportError("%s: schema %d is newer than this tool understands (%d)" % (path, schema, SUPPORTED_SCHEMA))
    if "steps" not in data and "header" not in data:
        raise ReportError("%s: not a run report (no steps, no header)" % path)
    return data


def final_attempt(step):
    """The last attempt that was not superseded; if all were, the last one."""
    attempts = [a for a in (step.get("attempts") or []) if isinstance(a, dict)]
    if not attempts:
        return {}
    live = [a for a in attempts if not a.get("superseded")]
    return (live or attempts)[-1]


def verdict_of(attempt):
    v = attempt.get("verdict")
    if isinstance(v, dict) and v.get("verdict"):
        return str(v["verdict"]), str(v.get("reason") or "")
    return DASH, ""


def num(v):
    """A JSON number, or None (booleans and strings are not numbers here)."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return v


def volume_of(attempt):
    """The attempt's volume object reduced to what the tables show, or None when the step has no volume check."""
    v = attempt.get("volume")
    if not isinstance(v, dict):
        return None
    verdict = v.get("verdict") if isinstance(v.get("verdict"), dict) else {}
    tag = str(verdict.get("verdict") or DASH)
    return {
        "expect": str(v.get("expect") or DASH),
        "verdict": tag,
        "reason": str(verdict.get("reason") or ""),
        "consumerReports": num(v.get("consumerReports")),
        "keyReports": num(v.get("keyReports")),
        "volumeEvents": num(v.get("volumeEvents")),
        "muteEvents": num(v.get("muteEvents")),
        "deviceEvents": num(v.get("deviceEvents")),
        "startScalar": num(v.get("startScalar")),
        "endScalar": num(v.get("endScalar")),
        "startMuted": v.get("startMuted") if isinstance(v.get("startMuted"), bool) else None,
        "endMuted": v.get("endMuted") if isinstance(v.get("endMuted"), bool) else None,
    }


def volume_word(vol):
    """pass / fail stay as they are; inconclusive is "cannot judge"."""
    if vol is None:
        return DASH
    return "cannot judge" if vol["verdict"] == "inconclusive" else vol["verdict"]


def level(scalar, muted):
    parts = []
    if scalar is not None:
        parts.append("%d%%" % round(scalar * 100))
    if muted is not None:
        parts.append("muted" if muted else "unmuted")
    return " ".join(parts) or DASH


def volume_text(vol):
    """One cell: 'unchanged: pass (keys 2, vol 0, mute 0, 50% unmuted -> 50% unmuted)'."""
    if vol is None:
        return DASH
    head = "%s: %s" % (vol["expect"], volume_word(vol))
    counts = "keys %s, vol %s, mute %s" % (fmt(vol["keyReports"]), fmt(vol["volumeEvents"]), fmt(vol["muteEvents"]))
    if vol["deviceEvents"]:
        counts += ", device %s" % fmt(vol["deviceEvents"])
    levels = "%s -> %s" % (level(vol["startScalar"], vol["startMuted"]), level(vol["endScalar"], vol["endMuted"]))
    why = (" [%s]" % vol["reason"]) if vol["reason"] else ""
    return "%s (%s, %s)%s" % (head, counts, levels, why)


def rows(report):
    out = []
    for i, step in enumerate(report.get("steps") or []):
        if not isinstance(step, dict):
            continue
        a = final_attempt(step)
        m = a.get("metrics") or {}
        tag, reason = verdict_of(a)
        vals = m.get("values") if isinstance(m.get("values"), dict) else {}
        out.append({
            "index": step.get("index", i),
            "stepId": step.get("stepId", ""),
            "kind": step.get("kind", ""),
            "controls": step.get("controls") or [],
            "verdict": tag,
            "detail": reason or m.get("detail") or "",
            "padReports": m.get("padReports"),
            "padChanged": m.get("padChanged"),
            "lossRatio": m.get("lossRatio"),
            "onsetMs": m.get("onsetMs"),
            "framesSeen": m.get("framesSeen"),
            "latN": num(vals.get("lat.n")),
            "latP50": num(vals.get("lat.p50Ms")),
            "latP99": num(vals.get("lat.p99Ms")),
            "latUnmatched": num(vals.get("lat.unmatched")),
            "volume": volume_of(a),
            "effectivePath": (a.get("effectivePath") or {}).get("atEnd"),
            "attempts": len(step.get("attempts") or []),
        })
    return out


def short(s, n=8):
    return s[:n] if isinstance(s, str) and s else DASH


def fmt(v, digits=2):
    if v is None:
        return DASH
    if isinstance(v, float):
        return ("%.*f" % (digits, v)).rstrip("0").rstrip(".") if v != int(v) else str(int(v))
    return str(v)


def table(headers, body):
    cells = [headers] + [[str(c) for c in r] for r in body]
    widths = [max(len(r[i]) for r in cells) for i in range(len(headers))]
    lines = []
    for n, r in enumerate(cells):
        lines.append("  ".join(c.ljust(widths[i]) for i, c in enumerate(r)).rstrip())
        if n == 0:
            lines.append("  ".join("-" * w for w in widths))
    return "\n".join(lines)


def header_block(label, report, path):
    h = report.get("header") or {}
    notes = report.get("notes") or []
    lines = [
        "%s: %s" % (label, path),
        "  startedAt      %s" % (report.get("startedAt") or DASH),
        "  path           requested %s, effective %s" % (report.get("requestedPath") or DASH, report.get("effectivePath") or DASH),
        "  template       %s v%s sha256 %s" % (h.get("templateId") or DASH, h.get("templateVersion", DASH), short(h.get("templateSha256"))),
        "  mappingHash    %s" % short(h.get("mappingHash")),
        "  complete       %s" % ("yes" if report.get("complete") else "NO (incomplete run)"),
        "  builds         app %s, engine %s, dext %s" % (h.get("appBuild") or DASH, h.get("engineBuild") or DASH, h.get("dextBuild") or DASH),
        "  pad            %s, xlateCore %s, vpadMaxRateHz %s" % (h.get("padIdentity") or DASH, h.get("xlateCore") or DASH, fmt(h.get("vpadMaxRateHz"))),
        "  notes          %s" % ("; ".join(map(str, notes)) if notes else DASH),
    ]
    return "\n".join(lines)


def has_latency(rs):
    return any(r["latN"] is not None for r in rs)


def report_table(rs):
    head = ["#", "stepId", "kind", "controls", "verdict", "detail", "padReports", "padChanged", "lossRatio", "onsetMs", "framesSeen"]
    lat = has_latency(rs)
    if lat:
        head += ["lat.n", "lat.p50Ms", "lat.p99Ms", "lat.unmatched"]
    vol = any(r["volume"] is not None for r in rs)
    if vol:
        head.append("volume")
    head.append("effectivePath")
    body = []
    for r in rs:
        row = [r["index"], r["stepId"], r["kind"], ",".join(r["controls"]) or DASH, r["verdict"], r["detail"] or DASH,
               fmt(r["padReports"]), fmt(r["padChanged"]), fmt(r["lossRatio"], 3), fmt(r["onsetMs"], 2), fmt(r["framesSeen"])]
        if lat:
            row += [fmt(r["latN"]), fmt(r["latP50"], 3), fmt(r["latP99"], 3), fmt(r["latUnmatched"])]
        if vol:
            row.append(volume_text(r["volume"]))
        row.append(fmt(r["effectivePath"]))
        body.append(row)
    return table(head, body) if body else "(no steps)"


def delta(a, b):
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return b - a
    return None


def signed(d, digits):
    return DASH if d is None else ("%+.*f" % (digits, d))


def weighted_median(pairs):
    """pairs: (value, weight > 0). The value at which half of the weight lies on each side; a tie between two values is their mean."""
    pairs = sorted((v, w) for v, w in pairs if w > 0)
    if not pairs:
        return None
    total = sum(w for _, w in pairs)
    run = 0
    for i, (v, w) in enumerate(pairs):
        run += w
        if abs(run - total / 2) < 1e-9 and i + 1 < len(pairs):
            return (v + pairs[i + 1][0]) / 2
        if run > total / 2:
            return v
    return pairs[-1][0]


GATE_KINDS = (("digital", "digital"), ("stick", "stick onset"))


def gate_summary(ra, rb):
    """The T8 gate rows: per step kind, the n-weighted median of the p50s of the steps both reports have. None unless both carry latency."""
    if not (any(r["latP50"] is not None for r in ra) and any(r["latP50"] is not None for r in rb)):
        return None
    ib = {r["stepId"]: r for r in rb}
    out = {}
    for kind, _label in GATE_KINDS:
        pa, pb = [], []
        for x in ra:
            y = ib.get(x["stepId"])
            if not y or x["kind"] != kind or x["latP50"] is None or y["latP50"] is None:
                continue
            pa.append((x["latP50"], x["latN"] or 1))
            pb.append((y["latP50"], y["latN"] or 1))
        a, b = weighted_median(pa), weighted_median(pb)
        out[kind] = {"a": a, "b": b, "delta": (b - a) if a is not None and b is not None else None, "steps": len(pa)}
    return out


def ms3(v):
    return DASH if v is None else "%.3f" % v


def gate_line(gate):
    parts = []
    for kind, label in GATE_KINDS:
        g = gate[kind]
        parts.append("%s p50 A %s ms / B %s ms (Δ %s ms)" % (label, ms3(g["a"]), ms3(g["b"]), signed(g["delta"], 3)))
    return "Latency gate: " + ", ".join(parts)


def compare(a, b, loss_threshold, onset_threshold, latency_threshold=0.1):
    ra, rb = rows(a), rows(b)
    ia, ib = {r["stepId"]: r for r in ra}, {r["stepId"]: r for r in rb}
    order = [r["stepId"] for r in ra] + [r["stepId"] for r in rb if r["stepId"] not in ia]
    pairs = []
    for sid in order:
        x, y = ia.get(sid), ib.get(sid)
        marks = []
        d_loss = d_onset = d_p50 = d_p99 = None
        if x and y:
            if x["verdict"] != y["verdict"]:
                marks.append("verdict")
            if x["volume"] is not None and y["volume"] is not None and x["volume"]["verdict"] != y["volume"]["verdict"]:
                marks.append("volume")
            d_loss = delta(x["lossRatio"], y["lossRatio"])
            if d_loss is not None and abs(d_loss) > loss_threshold + 1e-12:
                marks.append("lossRatio")
            d_onset = delta(x["onsetMs"], y["onsetMs"])
            if d_onset is not None and abs(d_onset) > onset_threshold + 1e-12:
                marks.append("onsetMs")
            d_p50 = delta(x["latP50"], y["latP50"])
            d_p99 = delta(x["latP99"], y["latP99"])
            if d_p50 is not None and abs(d_p50) > latency_threshold + 1e-12:
                marks.append("lat.p50Ms")
        pairs.append({"stepId": sid, "a": x, "b": y, "lossDelta": d_loss, "onsetDelta": d_onset,
                      "latP50Delta": d_p50, "latP99Delta": d_p99, "marks": marks})
    ha, hb = a.get("header") or {}, b.get("header") or {}
    warnings = []
    for key in HEADER_WARN_KEYS:
        va = a.get(key) if key == "effectivePath" else ha.get(key)
        vb = b.get(key) if key == "effectivePath" else hb.get(key)
        if va != vb:
            warnings.append({"field": key, "a": va, "b": vb})
    differs = any(p["marks"] for p in pairs)
    return {"pairs": pairs, "headerWarnings": warnings, "differs": differs, "gate": gate_summary(ra, rb),
            "thresholds": {"lossRatio": loss_threshold, "onsetMs": onset_threshold},
            "latencyThresholdMs": latency_threshold}


def side_by_side(cmp):
    head = ["stepId", "verdict A/B", "lossRatio A", "B", "Δ", "onsetMs A", "B", "Δ", "padChanged A/B"]
    lat = any((p["a"] and p["a"]["latP50"] is not None) or (p["b"] and p["b"]["latP50"] is not None) for p in cmp["pairs"])
    if lat:
        head += ["lat.p50Ms A", "B", "Δ", "lat.p99Ms A", "B", "Δ"]
    vol = any((p["a"] and p["a"]["volume"]) or (p["b"] and p["b"]["volume"]) for p in cmp["pairs"])
    if vol:
        head.append("volume A/B")
    head.append("diff")
    body = []
    for p in cmp["pairs"]:
        x, y = p["a"], p["b"]
        row = [
            p["stepId"],
            "%s / %s" % (x["verdict"] if x else DASH, y["verdict"] if y else DASH),
            fmt(x["lossRatio"], 3) if x else DASH, fmt(y["lossRatio"], 3) if y else DASH, signed(p["lossDelta"], 3),
            fmt(x["onsetMs"], 2) if x else DASH, fmt(y["onsetMs"], 2) if y else DASH, signed(p["onsetDelta"], 2),
            "%s / %s" % (fmt(x["padChanged"]) if x else DASH, fmt(y["padChanged"]) if y else DASH),
        ]
        if lat:
            row += [fmt(x["latP50"], 3) if x else DASH, fmt(y["latP50"], 3) if y else DASH, signed(p["latP50Delta"], 3),
                    fmt(x["latP99"], 3) if x else DASH, fmt(y["latP99"], 3) if y else DASH, signed(p["latP99Delta"], 3)]
        if vol:
            row.append("%s / %s" % (volume_word(x["volume"]) if x else DASH, volume_word(y["volume"]) if y else DASH))
        row.append(("* " + ",".join(p["marks"])) if p["marks"] else "")
        body.append(row)
    return table(head, body) if body else "(no steps)"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Show or compare Developer mode run reports.")
    ap.add_argument("a", metavar="A.json")
    ap.add_argument("b", metavar="B.json", nargs="?")
    ap.add_argument("--loss-threshold", type=float, default=0.10, help="mark a lossRatio change larger than this (default 0.10)")
    ap.add_argument("--onset-threshold", type=float, default=5.0, help="mark an onsetMs change larger than this many ms (default 5)")
    ap.add_argument("--latency-threshold", type=float, default=0.10, help="mark a lat.p50Ms change larger than this many ms (default 0.1)")
    ap.add_argument("--json", action="store_true", help="print the result as JSON")
    args = ap.parse_args(argv)
    try:
        ra = load(args.a)
        rb = load(args.b) if args.b else None
    except ReportError as e:
        print("error: %s" % e, file=sys.stderr)
        return 2

    if rb is None:
        if args.json:
            print(json.dumps({"a": {"path": args.a, "header": ra.get("header"), "complete": bool(ra.get("complete")), "rows": rows(ra)}}, indent=2))
        else:
            print(header_block("A", ra, args.a))
            print()
            print(report_table(rows(ra)))
        return 0

    cmp = compare(ra, rb, args.loss_threshold, args.onset_threshold, args.latency_threshold)
    if args.json:
        out = dict(cmp)
        out["a"] = {"path": args.a, "complete": bool(ra.get("complete")), "rows": rows(ra)}
        out["b"] = {"path": args.b, "complete": bool(rb.get("complete")), "rows": rows(rb)}
        print(json.dumps(out, indent=2))
    else:
        print(header_block("A", ra, args.a))
        print()
        print(report_table(rows(ra)))
        print()
        print(header_block("B", rb, args.b))
        print()
        print(report_table(rows(rb)))
        print()
        for w in cmp["headerWarnings"]:
            print("WARNING: %s differs: A %s, B %s" % (w["field"], fmt(w["a"]) if w["a"] != "" else DASH, fmt(w["b"]) if w["b"] != "" else DASH))
        for label, rep in (("A", ra), ("B", rb)):
            if not rep.get("complete"):
                print("WARNING: run %s is incomplete; steps it did not reach show %s" % (label, DASH))
        if cmp["headerWarnings"]:
            print()
        print("Side by side (paired by stepId; * = verdict or volume verdict change, lossRatio Δ > %s, onsetMs Δ > %s ms, lat.p50Ms Δ > %s ms)" %
              (fmt(args.loss_threshold, 3), fmt(args.onset_threshold, 2), fmt(args.latency_threshold, 3)))
        print(side_by_side(cmp))
        n = sum(1 for p in cmp["pairs"] if p["marks"])
        print()
        print("%d of %d steps differ." % (n, len(cmp["pairs"])) if n else "No marked differences.")
        if cmp["gate"]:
            print()
            print(gate_line(cmp["gate"]))
    return 1 if cmp["differs"] else 0


if __name__ == "__main__":
    sys.exit(main())
