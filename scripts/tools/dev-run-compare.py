#!/usr/bin/env python3 -I
"""Show and compare Developer mode run reports (docs/protocol/developer-mode-files.md).

    dev-run-compare.py A.json            one table
    dev-run-compare.py A.json B.json     both tables, then a side-by-side paired by stepId

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


def rows(report):
    out = []
    for i, step in enumerate(report.get("steps") or []):
        if not isinstance(step, dict):
            continue
        a = final_attempt(step)
        m = a.get("metrics") or {}
        tag, reason = verdict_of(a)
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


def report_table(rs):
    head = ["#", "stepId", "kind", "controls", "verdict", "detail", "padReports", "padChanged", "lossRatio", "onsetMs", "framesSeen", "effectivePath"]
    body = [[r["index"], r["stepId"], r["kind"], ",".join(r["controls"]) or DASH, r["verdict"], r["detail"] or DASH,
             fmt(r["padReports"]), fmt(r["padChanged"]), fmt(r["lossRatio"], 3), fmt(r["onsetMs"], 2),
             fmt(r["framesSeen"]), fmt(r["effectivePath"])] for r in rs]
    return table(head, body) if body else "(no steps)"


def delta(a, b):
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return b - a
    return None


def signed(d, digits):
    return DASH if d is None else ("%+.*f" % (digits, d))


def compare(a, b, loss_threshold, onset_threshold):
    ra, rb = rows(a), rows(b)
    ia, ib = {r["stepId"]: r for r in ra}, {r["stepId"]: r for r in rb}
    order = [r["stepId"] for r in ra] + [r["stepId"] for r in rb if r["stepId"] not in ia]
    pairs = []
    for sid in order:
        x, y = ia.get(sid), ib.get(sid)
        marks = []
        d_loss = d_onset = None
        if x and y:
            if x["verdict"] != y["verdict"]:
                marks.append("verdict")
            d_loss = delta(x["lossRatio"], y["lossRatio"])
            if d_loss is not None and abs(d_loss) > loss_threshold + 1e-12:
                marks.append("lossRatio")
            d_onset = delta(x["onsetMs"], y["onsetMs"])
            if d_onset is not None and abs(d_onset) > onset_threshold + 1e-12:
                marks.append("onsetMs")
        pairs.append({"stepId": sid, "a": x, "b": y, "lossDelta": d_loss, "onsetDelta": d_onset, "marks": marks})
    ha, hb = a.get("header") or {}, b.get("header") or {}
    warnings = []
    for key in HEADER_WARN_KEYS:
        va = a.get(key) if key == "effectivePath" else ha.get(key)
        vb = b.get(key) if key == "effectivePath" else hb.get(key)
        if va != vb:
            warnings.append({"field": key, "a": va, "b": vb})
    differs = any(p["marks"] for p in pairs)
    return {"pairs": pairs, "headerWarnings": warnings, "differs": differs,
            "thresholds": {"lossRatio": loss_threshold, "onsetMs": onset_threshold}}


def side_by_side(cmp):
    head = ["stepId", "verdict A/B", "lossRatio A", "B", "Δ", "onsetMs A", "B", "Δ", "padChanged A/B", "diff"]
    body = []
    for p in cmp["pairs"]:
        x, y = p["a"], p["b"]
        body.append([
            p["stepId"],
            "%s / %s" % (x["verdict"] if x else DASH, y["verdict"] if y else DASH),
            fmt(x["lossRatio"], 3) if x else DASH, fmt(y["lossRatio"], 3) if y else DASH, signed(p["lossDelta"], 3),
            fmt(x["onsetMs"], 2) if x else DASH, fmt(y["onsetMs"], 2) if y else DASH, signed(p["onsetDelta"], 2),
            "%s / %s" % (fmt(x["padChanged"]) if x else DASH, fmt(y["padChanged"]) if y else DASH),
            ("* " + ",".join(p["marks"])) if p["marks"] else "",
        ])
    return table(head, body) if body else "(no steps)"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Show or compare Developer mode run reports.")
    ap.add_argument("a", metavar="A.json")
    ap.add_argument("b", metavar="B.json", nargs="?")
    ap.add_argument("--loss-threshold", type=float, default=0.10, help="mark a lossRatio change larger than this (default 0.10)")
    ap.add_argument("--onset-threshold", type=float, default=5.0, help="mark an onsetMs change larger than this many ms (default 5)")
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

    cmp = compare(ra, rb, args.loss_threshold, args.onset_threshold)
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
        print("Side by side (paired by stepId; * = verdict change, lossRatio Δ > %s, onsetMs Δ > %s ms)" %
              (fmt(args.loss_threshold, 3), fmt(args.onset_threshold, 2)))
        print(side_by_side(cmp))
        n = sum(1 for p in cmp["pairs"] if p["marks"])
        print()
        print("%d of %d steps differ." % (n, len(cmp["pairs"])) if n else "No marked differences.")
    return 1 if cmp["differs"] else 0


if __name__ == "__main__":
    sys.exit(main())
