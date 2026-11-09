import contextlib
import copy
import importlib.util
import io
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FIX = os.path.join(ROOT, "Tests", "GDHubTests", "Fixtures", "dev-runs")
ENGINE = os.path.join(FIX, "sample-engine.json")
DRIVER = os.path.join(FIX, "sample-driver.json")

spec = importlib.util.spec_from_file_location("dev_run_compare", os.path.join(HERE, "dev-run-compare.py"))
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


def run(*args):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = tool.main(list(args))
    return code, out.getvalue(), err.getvalue()


def load(path):
    with open(path) as f:
        return json.load(f)


class Temp:
    def __init__(self):
        self.dir = tempfile.TemporaryDirectory()

    def write(self, name, obj):
        p = os.path.join(self.dir.name, name)
        with open(p, "w") as f:
            json.dump(obj, f)
        return p


class DevRunCompareTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Temp()
        self.addCleanup(self.tmp.dir.cleanup)

    def test_single_report_table(self):
        code, out, _ = run(ENGINE)
        self.assertEqual(code, 0)
        for text in ("sample v2", "requested engine, effective inert", "complete       yes",
                     "stepId", "padReports", "lossRatio", "onsetMs", "effectivePath", "lb", "rt", "ls", "inert"):
            self.assertIn(text, out)

    def test_last_non_superseded_attempt_is_used(self):
        rows = tool.rows(load(DRIVER))
        rt = [r for r in rows if r["stepId"] == "rt"][0]
        self.assertEqual(rt["verdict"], "fail")  # the superseded first try was inconclusive
        self.assertEqual(rt["padChanged"], 30)
        rep = load(DRIVER)
        for a in rep["steps"][1]["attempts"]:
            a["superseded"] = True
        rt = [r for r in tool.rows(rep) if r["stepId"] == "rt"][0]
        self.assertEqual(rt["verdict"], "fail")  # all superseded: the last one

    def test_pairing_by_step_id_with_missing_step(self):
        code, out, _ = run(ENGINE, DRIVER)
        cmp = tool.compare(load(ENGINE), load(DRIVER), 0.10, 5.0)
        by = {p["stepId"]: p for p in cmp["pairs"]}
        self.assertEqual(list(by), ["lb", "rt", "ls"])
        self.assertIsNone(by["ls"]["b"])
        self.assertEqual(by["ls"]["marks"], [])
        self.assertIn("pass / —", out)

    def test_pairing_ignores_order(self):
        b = load(DRIVER)
        b["steps"].reverse()
        cmp = tool.compare(load(ENGINE), b, 0.10, 5.0)
        by = {p["stepId"]: p for p in cmp["pairs"]}
        self.assertEqual(by["rt"]["marks"], ["verdict", "lossRatio"])
        self.assertEqual(by["lb"]["marks"], ["onsetMs"])

    def test_exit_codes_and_thresholds(self):
        self.assertEqual(run(ENGINE, DRIVER)[0], 1)
        self.assertEqual(run(ENGINE, ENGINE)[0], 0)
        # verdict is the same everywhere once rt is made to pass: only numbers remain
        b = load(DRIVER)
        b["steps"][1]["attempts"][1]["verdict"] = {"verdict": "pass"}
        p = self.tmp.write("b.json", b)
        self.assertEqual(run(ENGINE, p)[0], 1)  # lossRatio 0.25 and onset 6.5
        self.assertEqual(run(ENGINE, p, "--loss-threshold", "0.3", "--onset-threshold", "7")[0], 0)
        self.assertEqual(run(ENGINE, p, "--loss-threshold", "0.3", "--onset-threshold", "6")[0], 1)
        self.assertEqual(run(ENGINE, p, "--loss-threshold", "0.2", "--onset-threshold", "7")[0], 1)

    def test_missing_step_alone_is_not_a_difference(self):
        a = load(ENGINE)
        b = load(ENGINE)
        b["steps"] = b["steps"][:2]
        b["complete"] = False
        code, out, _ = run(self.tmp.write("a.json", a), self.tmp.write("b.json", b))
        self.assertEqual(code, 0)
        self.assertIn("incomplete", out)

    def test_schema_newer_is_refused(self):
        newer = load(ENGINE)
        newer["schema"] = 2
        p = self.tmp.write("newer.json", newer)
        for args in ((p,), (ENGINE, p), (p, ENGINE)):
            code, out, err = run(*args)
            self.assertEqual(code, 2)
            self.assertIn("newer", err)
            self.assertEqual(out, "")

    def test_unreadable_is_exit_2(self):
        bad = os.path.join(self.tmp.dir.name, "bad.json")
        with open(bad, "w") as f:
            f.write("nope")
        self.assertEqual(run(bad)[0], 2)
        self.assertEqual(run(os.path.join(self.tmp.dir.name, "missing.json"))[0], 2)

    def test_header_mismatch_warnings(self):
        b = load(ENGINE)
        b["header"]["templateSha256"] = "cd" * 32
        b["header"]["mappingHash"] = "ee" * 32
        b["header"]["padIdentity"] = "other"
        b["header"]["xlateCore"] = "swift"
        b["header"]["vpadMaxRateHz"] = 500
        b["effectivePath"] = "shadow"
        code, out, _ = run(ENGINE, self.tmp.write("b.json", b))
        self.assertEqual(code, 0, "warnings alone do not change the exit code")
        for key in tool.HEADER_WARN_KEYS:
            self.assertIn("WARNING: %s differs" % key, out)
        _, same, _ = run(ENGINE, ENGINE)
        self.assertNotIn("WARNING", same)

    def test_json_output(self):
        code, out, _ = run(ENGINE, DRIVER, "--json")
        self.assertEqual(code, 1)
        data = json.loads(out)
        self.assertTrue(data["differs"])
        self.assertEqual([p["stepId"] for p in data["pairs"]], ["lb", "rt", "ls"])
        self.assertEqual([w["field"] for w in data["headerWarnings"]], ["effectivePath"])
        self.assertEqual(data["thresholds"], {"lossRatio": 0.1, "onsetMs": 5.0})

    def test_sparse_report_does_not_crash(self):
        p = self.tmp.write("sparse.json", {"schema": 1, "steps": [{"stepId": "a", "attempts": []}, {"stepId": "b"}]})
        code, out, _ = run(p)
        self.assertEqual(code, 0)
        self.assertIn("NO (incomplete run)", out)
        self.assertEqual(run(p, p)[0], 0)


if __name__ == "__main__":
    unittest.main()
