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


def lat_step(step_id, kind, p50, p99, n=10, unmatched=0):
    values = {"lat.n": n, "lat.unmatched": unmatched}
    if p50 is not None:
        values.update({"lat.p50Ms": p50, "lat.p95Ms": p99, "lat.p99Ms": p99, "lat.maxMs": p99})
    return {"index": 0, "stepId": step_id, "kind": kind, "controls": [step_id],
            "attempts": [{"verdict": {"verdict": "pass"}, "metrics": {"padReports": 20, "padChanged": 20, "values": values}}]}


def lat_report(path, steps):
    return {"schema": 1, "complete": True, "requestedPath": path, "effectivePath": path, "header": {"templateId": "t8-latency"}, "steps": steps}


class LatencyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Temp()
        self.addCleanup(self.tmp.dir.cleanup)
        # App (A) and Driver (B): digital p50 0.40 -> 0.15 (tap-a, tap-b), stick onset 0.50 -> 0.20 (flick n=10, circle n=1)
        self.a = lat_report("engine", [
            lat_step("flick-left", "stick", 0.50, 0.90), lat_step("tap-a", "digital", 0.42, 0.80),
            lat_step("tap-b", "digital", 0.38, 0.70), lat_step("circle-left", "stick", 0.90, 0.90, n=1)])
        self.b = lat_report("driver", [
            lat_step("flick-left", "stick", 0.20, 0.35), lat_step("tap-a", "digital", 0.16, 0.30),
            lat_step("tap-b", "digital", 0.14, 0.28), lat_step("circle-left", "stick", 0.25, 0.25, n=1)])

    def paths(self, a=None, b=None):
        return self.tmp.write("a.json", a or self.a), self.tmp.write("b.json", b or self.b)

    def test_rows_carry_latency_values(self):
        r = tool.rows(self.a)[1]
        self.assertEqual((r["latN"], r["latP50"], r["latP99"], r["latUnmatched"]), (10, 0.42, 0.8, 0))
        none = tool.rows(lat_report("engine", [lat_step("x", "digital", None, None, n=0, unmatched=3)]))[0]
        self.assertEqual((none["latN"], none["latP50"], none["latUnmatched"]), (0, None, 3))
        # a report without the keys (older or a rest step) has none
        self.assertIsNone(tool.rows(load(ENGINE))[0]["latP50"])

    def test_single_table_gets_latency_columns_only_when_present(self):
        a, _ = self.paths()
        _, out, _ = run(a)
        for text in ("lat.n", "lat.p50Ms", "lat.p99Ms", "lat.unmatched", "0.42"):
            self.assertIn(text, out)
        _, plain, _ = run(ENGINE)
        self.assertNotIn("lat.p50Ms", plain)

    def test_side_by_side_columns_and_marks(self):
        a, b = self.paths()
        code, out, _ = run(a, b)
        self.assertEqual(code, 1)
        self.assertIn("lat.p50Ms A", out)
        self.assertIn("lat.p99Ms A", out)
        self.assertIn("-0.260", out)       # tap-a: 0.16 - 0.42
        cmp = tool.compare(self.a, self.b, 0.10, 5.0)
        by = {p["stepId"]: p for p in cmp["pairs"]}
        self.assertAlmostEqual(by["tap-a"]["latP50Delta"], -0.26)
        self.assertAlmostEqual(by["tap-a"]["latP99Delta"], -0.50)
        self.assertEqual(by["tap-a"]["marks"], ["lat.p50Ms"])
        self.assertIn("lat.p50Ms", out.split("Side by side")[1])
        # without latency in the data the side-by-side keeps its old columns
        _, plain, _ = run(ENGINE, DRIVER)
        self.assertNotIn("lat.p50Ms A", plain)

    def test_mark_threshold_is_a_tenth_of_a_millisecond(self):
        small = lat_report("driver", [lat_step("tap-a", "digital", 0.42 + 0.1, 0.8)])
        big = lat_report("driver", [lat_step("tap-a", "digital", 0.42 + 0.11, 0.8)])
        a = lat_report("engine", [lat_step("tap-a", "digital", 0.42, 0.8)])
        self.assertEqual(tool.compare(a, small, 0.10, 5.0)["pairs"][0]["marks"], [])
        self.assertEqual(tool.compare(a, big, 0.10, 5.0)["pairs"][0]["marks"], ["lat.p50Ms"])
        pa, pb = self.tmp.write("a.json", a), self.tmp.write("b.json", small)
        self.assertEqual(run(pa, pb)[0], 0)
        self.assertEqual(run(pa, pb, "--latency-threshold", "0.05")[0], 1)
        # a higher p99 alone is shown, not marked
        worse99 = lat_report("driver", [lat_step("tap-a", "digital", 0.42, 5.0)])
        self.assertEqual(tool.compare(a, worse99, 0.10, 5.0)["pairs"][0]["marks"], [])

    def test_gate_summary_line(self):
        a, b = self.paths()
        _, out, _ = run(a, b)
        last = out.strip().splitlines()[-1]
        # digital: tap-a/tap-b are 10 each, tie, so the mean of 0.38 and 0.42 = 0.400 (A), 0.14 and 0.16 = 0.150 (B).
        # stick: flick (n=10) outweighs circle (n=1): A 0.500, B 0.200.
        self.assertEqual(last, "Latency gate: digital p50 A 0.400 ms / B 0.150 ms (Δ -0.250 ms), "
                               "stick onset p50 A 0.500 ms / B 0.200 ms (Δ -0.300 ms)")
        cmp = tool.compare(self.a, self.b, 0.10, 5.0)
        self.assertAlmostEqual(cmp["gate"]["digital"]["delta"], -0.25)
        self.assertEqual(cmp["gate"]["stick"]["steps"], 2)

    def test_no_gate_line_unless_both_carry_latency(self):
        a, _ = self.paths()
        for args in ((a, ENGINE), (ENGINE, a), (ENGINE, DRIVER)):
            _, out, _ = run(*args)
            self.assertNotIn("Latency gate", out)
        self.assertIsNone(tool.compare(load(ENGINE), load(DRIVER), 0.10, 5.0)["gate"])

    def test_gate_with_one_kind_missing_shows_dashes(self):
        a = lat_report("engine", [lat_step("tap-a", "digital", 0.4, 0.8)])
        b = lat_report("driver", [lat_step("tap-a", "digital", 0.1, 0.2)])
        pa, pb = self.tmp.write("a.json", a), self.tmp.write("b.json", b)
        _, out, _ = run(pa, pb)
        last = out.strip().splitlines()[-1]
        self.assertEqual(last, "Latency gate: digital p50 A 0.400 ms / B 0.100 ms (Δ -0.300 ms), "
                               "stick onset p50 A — ms / B — ms (Δ — ms)")

    def test_unanswered_only_steps_do_not_crash(self):
        a = lat_report("engine", [lat_step("tap-a", "digital", None, None, n=0, unmatched=4)])
        pa = self.tmp.write("a.json", a)
        code, out, _ = run(pa, pa)
        self.assertEqual(code, 0)
        self.assertIn("lat.unmatched", out)
        self.assertNotIn("Latency gate", out)

    def test_json_output_has_gate(self):
        a, b = self.paths()
        _, out, _ = run(a, b, "--json")
        data = json.loads(out)
        self.assertAlmostEqual(data["gate"]["stick"]["delta"], -0.3)
        self.assertEqual(data["latencyThresholdMs"], 0.1)
        self.assertEqual(data["thresholds"], {"lossRatio": 0.1, "onsetMs": 5.0})

    def test_weighted_median(self):
        wm = tool.weighted_median
        self.assertIsNone(wm([]))
        self.assertEqual(wm([(3, 1)]), 3)
        self.assertEqual(wm([(1, 1), (2, 1), (9, 1)]), 2)
        self.assertEqual(wm([(1, 1), (3, 1)]), 2)
        self.assertEqual(wm([(0.9, 1), (0.5, 10)]), 0.5)


def vol_step(step_id, expect, verdict, reason=None, keys=2, vol=0, mute=0, device=0, start=0.5, end=0.5,
             start_muted=False, end_muted=False):
    v = {"verdict": verdict}
    if reason:
        v["reason"] = reason
    return {"index": 0, "stepId": step_id, "kind": "digital", "controls": [step_id],
            "attempts": [{"verdict": v, "metrics": {"padReports": 4, "padChanged": 4},
                          "volume": {"expect": expect, "verdict": v, "consumerReports": keys * 2, "keyReports": keys,
                                     "volumeEvents": vol, "muteEvents": mute, "deviceEvents": device,
                                     "startScalar": start, "endScalar": end, "startMuted": start_muted, "endMuted": end_muted,
                                     "hasVolume": True, "hasMute": True}}]}


class VolumeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Temp()
        self.addCleanup(self.tmp.dir.cleanup)
        self.a = lat_report("engine", [
            vol_step("g3-rb", "unchanged", "pass"),
            vol_step("g4-mute-on", "changes", "pass", keys=1, mute=1, end_muted=True),
            vol_step("g2-nothing", "unchanged", "inconclusive", "the volume was already at its lowest", start=0.0, end=0.0)])
        self.b = lat_report("driver", [
            vol_step("g3-rb", "unchanged", "fail", "the Mac's volume changed", vol=1, end=0.4375),
            vol_step("g4-mute-on", "changes", "pass", keys=1, mute=1, end_muted=True),
            vol_step("g2-nothing", "unchanged", "inconclusive", "the volume was already at its lowest", start=0.0, end=0.0)])

    def test_rows_carry_the_volume_values(self):
        rows = tool.rows(self.a)
        v = rows[1]["volume"]
        self.assertEqual((v["expect"], v["verdict"], v["keyReports"], v["muteEvents"], v["endMuted"]), ("changes", "pass", 1, 1, True))
        self.assertEqual((rows[0]["volume"]["startScalar"], rows[0]["volume"]["endScalar"]), (0.5, 0.5))
        self.assertEqual(rows[2]["volume"]["reason"], "the volume was already at its lowest")
        # a step without expect.volume has none
        self.assertIsNone(tool.rows(load(ENGINE))[0]["volume"])

    def test_inconclusive_reads_as_cannot_judge_never_pass_or_fail(self):
        rows = tool.rows(self.a)
        self.assertEqual(tool.volume_word(rows[2]["volume"]), "cannot judge")
        self.assertEqual(tool.volume_word(rows[0]["volume"]), "pass")
        self.assertEqual(tool.volume_word(None), tool.DASH)
        text = tool.volume_text(rows[2]["volume"])
        self.assertIn("unchanged: cannot judge", text)
        self.assertIn("[the volume was already at its lowest]", text)
        self.assertIn("keys 2, vol 0, mute 0, 0% unmuted -> 0% unmuted", text)
        self.assertEqual(tool.volume_text(rows[1]["volume"]),
                         "changes: pass (keys 1, vol 0, mute 1, 50% unmuted -> 50% muted)")

    def test_single_table_gets_a_volume_column_only_when_present(self):
        a = self.tmp.write("a.json", self.a)
        _, out, _ = run(a)
        self.assertIn("volume", out.splitlines()[[i for i, l in enumerate(out.splitlines()) if l.startswith("#")][0]])
        self.assertIn("unchanged: pass", out)
        self.assertIn("cannot judge", out)
        _, plain, _ = run(ENGINE)
        header = [l for l in plain.splitlines() if l.startswith("#")][0]
        self.assertNotIn("volume", header)

    def test_side_by_side_shows_both_words_and_marks_a_volume_difference(self):
        a, b = self.tmp.write("a.json", self.a), self.tmp.write("b.json", self.b)
        code, out, _ = run(a, b)
        self.assertEqual(code, 1)
        side = out.split("Side by side")[1]
        self.assertIn("volume A/B", side)
        self.assertIn("pass / fail", side)
        self.assertIn("cannot judge / cannot judge", side)
        by = {p["stepId"]: p for p in tool.compare(self.a, self.b, 0.10, 5.0)["pairs"]}
        self.assertEqual(by["g3-rb"]["marks"], ["verdict", "volume"])
        self.assertEqual(by["g4-mute-on"]["marks"], [])
        self.assertEqual(by["g2-nothing"]["marks"], [], "cannot judge on both sides is not a difference")
        # without volume data the old columns stay
        _, plain, _ = run(ENGINE, DRIVER)
        self.assertNotIn("volume A/B", plain)

    def test_identical_volume_runs_exit_zero_and_json_has_the_rows(self):
        a = self.tmp.write("a.json", self.a)
        self.assertEqual(run(a, a)[0], 0)
        _, out, _ = run(a, a, "--json")
        data = json.loads(out)
        self.assertEqual(data["a"]["rows"][0]["volume"]["verdict"], "pass")

    def test_sparse_volume_object_does_not_crash(self):
        rep = lat_report("engine", [{"stepId": "x", "attempts": [{"volume": {}}, ]}, {"stepId": "y", "attempts": [{"volume": "no"}]}])
        p = self.tmp.write("sparse.json", rep)
        code, out, _ = run(p, p)
        self.assertEqual(code, 0)
        self.assertEqual(tool.rows(rep)[1]["volume"], None)
        self.assertEqual(tool.volume_word(tool.rows(rep)[0]["volume"]), tool.DASH)


def echo_step(step_id, item, verdict="pass", reason="", counters=None, expected=None, hiding=None, kind="digital"):
    attempt = {"verdict": {"verdict": verdict, **({"reason": reason} if reason else {})}, "metrics": {"padReports": 10, "padChanged": 4, "values": counters or {}}}
    if item is not None:
        attempt["echoItem"] = item
    if hiding is not None:
        attempt["hiding"] = hiding
    step = {"index": 0, "stepId": step_id, "kind": kind, "controls": [step_id], "attempts": [attempt]}
    if expected is not None:
        step["expected"] = expected
    return step


def hiding(conclusive, line="", presses=()):
    return {"conclusive": conclusive, "line": line, "presses": list(presses)}


class RemapStep2Tests(unittest.TestCase):
    """The keys of remap step 2: echoItem, hiding, the pad triggers in `expected`, the filter's counters."""

    def setUp(self):
        self.tmp = Temp()
        self.addCleanup(self.tmp.dir.cleanup)

    def report(self, path, steps):
        return lat_report(path, steps)

    def test_the_same_echo_per_key_on_both_paths_is_no_difference(self):
        steps = lambda: [echo_step("paddle_outer_left", "D-pad left"), echo_step("sax_left", "A")]
        a, b = self.tmp.write("a.json", self.report("engine", steps())), self.tmp.write("b.json", self.report("driver", steps()))
        code, out, _ = run(a, b)
        self.assertEqual(code, 0, out)
        side = out.split("Side by side")[1]
        self.assertIn("echo A/B", side)
        self.assertIn("D-pad left / D-pad left", side)
        self.assertIn("A / A", side)
        self.assertIn("No marked differences.", out)

    def test_a_different_echo_for_the_same_key_fails_the_comparison_and_names_both(self):
        a = self.report("engine", [echo_step("paddle_inner_right", "D-pad down"), echo_step("sax_left", "A")])
        b = self.report("driver", [echo_step("paddle_inner_right", "D-pad up"), echo_step("sax_left", "A")])
        pa, pb = self.tmp.write("a.json", a), self.tmp.write("b.json", b)
        code, out, _ = run(pa, pb)
        self.assertEqual(code, 1)
        side = out.split("Side by side")[1]
        self.assertIn("D-pad down / D-pad up", side)
        by = {p["stepId"]: p for p in tool.compare(a, b, 0.10, 5.0)["pairs"]}
        self.assertEqual(by["paddle_inner_right"]["marks"], ["echo"])
        self.assertEqual(by["sax_left"]["marks"], [])
        self.assertTrue(tool.compare(a, b, 0.10, 5.0)["differs"])

    def test_an_echo_that_only_one_pass_has_is_a_difference_and_none_on_both_is_not(self):
        a = self.report("engine", [echo_step("sax_right", "B"), echo_step("paddle_outer_right", None)])
        b = self.report("driver", [echo_step("sax_right", None, "inconclusive", "cannot judge: the controller sent no button for this key"),
                                   echo_step("paddle_outer_right", None)])
        by = {p["stepId"]: p for p in tool.compare(a, b, 0.10, 5.0)["pairs"]}
        self.assertEqual(by["sax_right"]["marks"], ["verdict", "echo"])
        self.assertEqual(by["paddle_outer_right"]["marks"], [])

    def test_the_tables_get_an_echo_column_only_when_a_step_has_an_echo(self):
        with_echo = self.tmp.write("e.json", self.report("engine", [echo_step("sax_left", "A")]))
        header = [l for l in run(with_echo)[1].splitlines() if l.startswith("#")][0]
        self.assertIn("echo", header)
        self.assertNotIn("hiding", header)
        header = [l for l in run(ENGINE)[1].splitlines() if l.startswith("#")][0]
        self.assertNotIn("echo", header)
        self.assertNotIn("hiding", header)

    def test_hiding_is_read_into_a_word_and_a_conclusive_flag_that_differs_is_marked(self):
        line = "controller's own button hidden: cannot judge: the controller's current profile sends A for this key"
        conclusive = hiding(True, "controller's own button hidden: pass (D-pad right seen on the receiver, never on the pad)",
                            [{"result": "hidden"}] * 9 + [{"result": "cannot judge"}])
        rows = tool.rows(self.report("engine", [echo_step("outer-right", None, hiding=conclusive),
                                                echo_step("a-held-sax-left", None, hiding=hiding(False, line, [{"result": "cannot judge"}] * 2)),
                                                echo_step("rest", None)]))
        self.assertEqual(tool.hiding_word(rows[0]["hiding"]), "conclusive (9 of 10 presses)")
        self.assertEqual(tool.hiding_word(rows[1]["hiding"]), "cannot judge: the controller's current profile sends A for this key")
        self.assertEqual(tool.hiding_word(rows[2]["hiding"]), tool.DASH)
        a = self.report("engine", [echo_step("outer-right", None, hiding=conclusive)])
        b = self.report("driver", [echo_step("outer-right", None, hiding=hiding(False, "controller's own button hidden: not exercised (the controller sent no D-pad right during the hold)", [{"result": "not exercised"}]))])
        pa, pb = self.tmp.write("a.json", a), self.tmp.write("b.json", b)
        code, out, _ = run(pa, pb)
        self.assertEqual(code, 1)
        self.assertEqual(tool.compare(a, b, 0.10, 5.0)["pairs"][0]["marks"], ["hiding"])
        self.assertIn("hiding A/B", out)
        self.assertIn("not exercised (the controller sent no D-pad right during the hold)", out)
        # both not conclusive (the same way) is not a difference
        self.assertEqual(tool.compare(b, b, 0.10, 5.0)["pairs"][0]["marks"], [])

    def test_expected_pad_triggers_are_shown(self):
        self.assertEqual(tool.expected_text({"buttons": [], "guide": False, "lt": True}), "LT, RT still")
        self.assertEqual(tool.expected_text({"buttons": ["A"], "hat": "N", "guide": False}), "A, hat N")
        self.assertEqual(tool.expected_text({"buttons": [], "guide": False, "lt": True, "rt": True}), "LT, RT")
        self.assertEqual(tool.expected_text({"buttons": [], "guide": False}), tool.DASH)
        self.assertEqual(tool.expected_text(None), tool.DASH)
        rep = self.report("engine", [echo_step("lt", None, expected={"buttons": [], "guide": False, "rt": True}, kind="trigger")])
        header = [l for l in run(self.tmp.write("t.json", rep))[1].splitlines() if l.startswith("#")][0]
        self.assertIn("expected", header)
        self.assertIn("RT, LT still", run(self.tmp.write("t.json", rep))[1])

    def test_the_filters_counters_become_one_change_over_the_step(self):
        vals = {"echo.hiddenFramesBefore": 100, "echo.hiddenFramesAfter": 340, "echo.recoveredFramesBefore": 0, "echo.recoveredFramesAfter": 12,
                "echo.otherBefore": 1, "echo.otherAfter": 1, "echo.unconfirmedBefore": 0, "echo.unconfirmedAfter": 0,
                "echo.validBefore": 1, "echo.validAfter": 1}
        self.assertEqual(tool.echo_counters(vals), "hidden +240, recovered +12, other +0, unconfirmed +0")
        self.assertIsNone(tool.echo_counters({}))
        self.assertIsNone(tool.echo_counters({"echo.hiddenFramesBefore": 1}), "a half pair is not a change")
        rep = self.report("engine", [echo_step("x", None, counters=vals), echo_step("y", None)])
        out = run(self.tmp.write("c.json", rep))[1]
        self.assertIn("echo counters", out)
        self.assertIn("hidden +240, recovered +12", out)

    def test_sparse_new_keys_do_not_crash(self):
        rep = self.report("engine", [{"stepId": "x", "attempts": [{"echoItem": 7, "hiding": "no", "verdict": "x"}]},
                                     {"stepId": "y", "expected": "no", "attempts": [{"hiding": {"presses": "no"}}]}])
        rows = tool.rows(rep)
        self.assertIsNone(rows[0]["echoItem"])
        self.assertIsNone(rows[0]["hiding"])
        self.assertEqual(rows[1]["expected"], tool.DASH)
        self.assertEqual(tool.hiding_word(rows[1]["hiding"]), "not conclusive")
        p = self.tmp.write("s.json", rep)
        self.assertEqual(run(p, p)[0], 0)

    def test_the_old_fixtures_still_compare_the_same_way(self):
        code, out, _ = run(ENGINE, DRIVER)
        self.assertEqual(code, 1)
        self.assertNotIn("echo A/B", out)
        self.assertNotIn("hiding A/B", out)


if __name__ == "__main__":
    unittest.main()
