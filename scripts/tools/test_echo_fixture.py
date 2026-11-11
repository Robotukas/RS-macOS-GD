import contextlib
import importlib.util
import io
import json
import os
import re
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
COMMITTED = os.path.join(ROOT, "Tests", "GDHubTests", "Fixtures", "echo-survey-s2.json")

spec = importlib.util.spec_from_file_location("echo_fixture", os.path.join(HERE, "echo-fixture.py"))
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
ER = tool.rule

REST = "06 00 00 00 00 00 00 00 00 00 00 80 00 00 00 00"
RIGHT_AND_OR = "06 00 00 00 00 00 00 00 00 00 00 20 00 00 08 00"       # hat right (2), extra bit 0


def run_report(steps):
    return {"schema": 1, "complete": True, "header": {"mapping": {"secret": "PRIVATE-MAPPING"}, "builds": ["PRIVATE-BUILD"]},
            "notes": ["PRIVATE-NOTE"], "pathEvents": [{"t": 1, "what": "PRIVATE-PATH"}], "t0Ns": 123456789, "steps": steps}


def step(step_id, controls, attempts):
    return {"stepId": step_id, "index": 1, "kind": "record", "controls": controls, "expected": {"x": "PRIVATE-EXPECTED"}, "attempts": attempts}


def attempt(rec, superseded=False):
    return {"superseded": superseded, "verdict": {"verdict": "recorded"}, "metrics": {"m": 1}, "raw": ["PRIVATE-RAW"],
            "startedNs": 5, "receiver": [{"n": n, "t": -12.5 + n, "hex": h} for n, h in rec]}


def run(*args):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = tool.main(list(args))
    return code, out.getvalue(), err.getvalue()


class EchoFixtureTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def write(self, name, obj):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w") as f:
            json.dump(obj, f)
        return path

    def sample(self):
        return run_report([
            step("alone-paddle_outer_right", ["paddle_outer_right"],
                 [attempt([(10, REST), (20, RIGHT_AND_OR), (30, REST)], superseded=True), attempt([(5, REST), (50, RIGHT_AND_OR), (60, REST)])]),
            step("rest", [], [{"verdict": {"verdict": "pass"}}]),                       # an attempt with no receiver list: left out
        ])

    def test_it_keeps_only_the_listed_keys_and_nothing_private(self):
        out = os.path.join(self.tmp.name, "out.json")
        code, text, _ = run(self.write("run.json", self.sample()), "--out", out)
        self.assertEqual(code, 0)
        self.assertIn("2 attempts, 6 reports, 9 hide sets", text)
        with open(out) as f:
            raw = f.read()
        data = json.loads(raw)
        self.assertEqual(sorted(data), ["about", "attempts", "hideSets", "schema", "storedItems"])
        self.assertEqual(data["storedItems"], [12, 13, 11, 14, 1, 2])
        self.assertEqual(data["hideSets"], [0, 0x3F, 0x3D, 1, 2, 4, 8, 16, 32])
        for a in data["attempts"]:
            self.assertEqual(sorted(a), ["controls", "receiver", "stepId", "superseded", "words"])
            for r in a["receiver"]:
                self.assertEqual(sorted(r), ["hex", "n"])
        self.assertEqual([a["superseded"] for a in data["attempts"]], [True, False])
        self.assertEqual([r["n"] for r in data["attempts"][1]["receiver"]], [5, 50, 60])
        for word in ("PRIVATE", "header", "notes", "pathEvents", "t0Ns", "12.5", "verdict", "metrics", "startedNs"):
            self.assertNotIn(word, raw)

    def test_it_writes_the_oracle_words_for_nine_hide_sets(self):
        out = os.path.join(self.tmp.name, "out.json")
        run(self.write("run.json", self.sample()), "--out", out)
        with open(out) as f:
            data = json.load(f)
        a = data["attempts"][1]
        self.assertEqual(sorted(a["words"], key=int), [str(h) for h in sorted(ER.HIDE_SETS)])
        frames = [ER.decode(r["hex"]) for r in a["receiver"]]
        for h in ER.HIDE_SETS:
            self.assertEqual(len(a["words"][str(h)]), 3)
            self.assertEqual(a["words"][str(h)], ER.run_words(frames, h))
        self.assertEqual(a["words"]["0"], [0, 0, 0], "no hidden key: every report passes")
        self.assertEqual(a["words"]["1"][0], 0, "no key held yet")
        self.assertTrue(a["words"]["1"][1] & ER.W_APPLIED)
        self.assertEqual(a["words"]["2"][1], 0, "hide set 2 (paddle inner right) does not hide outer right")

    def test_it_refuses_an_entry_that_is_not_a_16_byte_report_0x06(self):
        for bad in ("06 00 00", REST.replace("06", "05", 1), REST + " 00", "zz"):
            rep = run_report([step("s", ["sax_left"], [attempt([(1, REST), (2, bad)])])])
            code, _, err = run(self.write("bad.json", rep), "--out", os.path.join(self.tmp.name, "never.json"))
            self.assertEqual(code, 2, bad)
            self.assertIn("not a 16-byte report 0x06", err)
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "never.json")))

    def test_unusable_input_exits_with_2(self):
        path = os.path.join(self.tmp.name, "junk.json")
        with open(path, "w") as f:
            f.write("{ not json")
        self.assertEqual(run(path, "--out", os.path.join(self.tmp.name, "o.json"))[0], 2)
        self.assertEqual(run(self.write("none.json", run_report([step("s", [], [{"verdict": {}}])])), "--out", os.path.join(self.tmp.name, "o.json"))[0], 2)
        self.assertEqual(run(os.path.join(self.tmp.name, "missing.json"))[0], 2)

    def test_the_committed_fixture_is_what_the_tool_writes_and_holds_nothing_private(self):
        with open(COMMITTED) as f:
            text = f.read()
        data = json.loads(text)
        again = tool.dump(tool.build([{k: a[k] for k in ("stepId", "controls", "superseded", "receiver")} for a in data["attempts"]]))
        self.assertEqual(again, text, "regenerating from the fixture's own reports gives the same bytes")
        self.assertEqual(sum(len(a["receiver"]) for a in data["attempts"]), 789)
        self.assertLess(len(text.encode("utf-8")), 150000)
        for pattern in (r"/Users", r"/private", r"@", r"nterlinked", r"serial", r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-", r"\.local", r"Library"):
            self.assertIsNone(re.search(pattern, text), pattern)
        for a in data["attempts"]:
            for r in a["receiver"]:
                self.assertRegex(r["hex"], r"^06( [0-9a-f]{2}){15}$")
                self.assertEqual(sorted(r), ["hex", "n"])


if __name__ == "__main__":
    unittest.main()
