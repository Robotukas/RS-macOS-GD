#!/usr/bin/env python3
"""Makes the committed fixture of the echo replay from the run report of the echo survey (Developer-mode template
"Paddles and SAX: what the controller adds (survey)", picker row 10):

    python3 scripts/tools/echo-fixture.py RUN.json [--out Tests/GDHubTests/Fixtures/echo-survey-s2.json]

The repository is public, so the fixture keeps controller reports and words only. Per step and attempt that has
receiver reports it keeps `stepId`, `controls`, `superseded` and the receiver list as `{n, hex}` (the report index and
the 16 bytes of report 0x06); nothing else of the run report (no header, mapping, builds, decode table, notes, path
events, timestamps, metrics, verdicts or pad side; no `t`). It refuses any receiver entry that is not a 16-byte report
0x06. It also writes the expected words of the rule (scripts/tools/echo_rule.py) for nine hide sets (none, all six,
row 11's set, each key alone) with the factory stored items, per report, each attempt starting from a fresh state.
The Swift tests (`EchoReplayTests`) and the Python tests replay the rule over the reports and compare.

Exit 0: written. 2: the input cannot be used."""
import argparse
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DEFAULT_OUT = os.path.join(ROOT, "Tests", "GDHubTests", "Fixtures", "echo-survey-s2.json")

spec = importlib.util.spec_from_file_location("echo_rule", os.path.join(HERE, "echo_rule.py"))
rule = importlib.util.module_from_spec(spec)
sys.modules.setdefault("echo_rule", rule)
spec.loader.exec_module(rule)

SCHEMA = 1


class FixtureError(Exception):
    pass


def keep(path):
    """The trimmed attempts of a run report: [{stepId, controls, superseded, receiver: [{n, hex}]}]."""
    try:
        with open(path, "rb") as f:
            data = json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError) as e:
        raise FixtureError("%s: cannot read (%s)" % (path, e))
    if not isinstance(data, dict) or not isinstance(data.get("steps"), list):
        raise FixtureError("%s: not a run report" % path)
    out = []
    for st in data["steps"]:
        for a in st.get("attempts", []):
            rec = a.get("receiver") or []
            if not rec:
                continue
            entries = []
            for r in rec:
                try:
                    hexs = " ".join("%02x" % int(x, 16) for x in str(r["hex"]).split())
                    n = int(r["n"])
                    rule.decode(hexs)                       # 16 bytes, report id 6
                except (KeyError, ValueError, TypeError) as e:
                    raise FixtureError("step %s: a receiver entry is not a 16-byte report 0x06 (%s): %r" % (st.get("stepId"), e, r))
                entries.append({"n": n, "hex": hexs})
            out.append({"stepId": str(st.get("stepId", "")), "controls": [str(c) for c in st.get("controls", [])],
                        "superseded": bool(a.get("superseded")), "receiver": entries})
    if not out:
        raise FixtureError("%s: no step has a `receiver` list; run the echo-survey template (picker row 10)" % path)
    return out


def words_for(attempt, hide):
    frames = [rule.decode(r["hex"]) for r in attempt["receiver"]]
    return rule.run_words(frames, hide)


def build(attempts):
    for a in attempts:
        a["words"] = {str(h): words_for(a, h) for h in rule.HIDE_SETS}
    return {"schema": SCHEMA,
            "about": "Controller reports (report 0x06, n = report index) of the echo survey, and the words of the echo rule "
                     "(scripts/tools/echo_rule.py) per hide set, factory stored items, a fresh state per attempt. Made by "
                     "scripts/tools/echo-fixture.py.",
            "storedItems": rule.FACTORY_CODES, "hideSets": rule.HIDE_SETS, "attempts": attempts}


def dump(obj):
    """Compact JSON, one attempt per line, so the diff of a regenerated fixture is readable."""
    head = {k: v for k, v in obj.items() if k != "attempts"}
    lines = ["{"]
    for k, v in head.items():
        lines.append("%s: %s," % (json.dumps(k), json.dumps(v, separators=(",", ":"))))
    lines.append('"attempts": [')
    rows = []
    for a in obj["attempts"]:
        rows.append(json.dumps(a, separators=(",", ":"), sort_keys=True))
    lines.append(",\n".join(rows))
    lines.append("]")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Make the echo replay fixture from a survey run report.")
    ap.add_argument("run", help="run report written by the echo-survey template")
    ap.add_argument("--out", default=DEFAULT_OUT, help="where to write (default: the committed fixture)")
    args = ap.parse_args(argv)
    try:
        obj = build(keep(args.run))
    except FixtureError as e:
        print("echo-fixture: %s" % e, file=sys.stderr)
        return 2
    text = dump(obj)
    json.loads(text)                                         # the dump must read back
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(text)
    n = sum(len(a["receiver"]) for a in obj["attempts"])
    print("wrote %s: %d attempts, %d reports, %d hide sets, %d bytes" % (
        os.path.basename(args.out), len(obj["attempts"]), n, len(rule.HIDE_SETS), len(text.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
