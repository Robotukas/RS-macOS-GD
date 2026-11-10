import contextlib
import importlib.util
import io
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CAPTURE = os.path.join(ROOT, "scuf-envision", "captures", "02-button-walk.txt")
SURVEY_FIXTURE = os.path.join(ROOT, "Tests", "GDHubTests", "Fixtures", "dev-runs", "sample-survey.json")

spec = importlib.util.spec_from_file_location("echo_survey", os.path.join(HERE, "echo-survey.py"))
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)

# Factory profile: paddle outer right -> D-pad right, inner right -> down, inner left -> up, outer left -> left,
# SAX left -> A, SAX right -> B. Hat values: up 0, right 2, down 4, left 6, none 8.
TABLE = {"paddle_outer_right": 0, "paddle_inner_right": 1, "paddle_inner_left": 2, "paddle_outer_left": 3, "sax_left": 4, "sax_right": 5}
ECHO = {"paddle_outer_right": ("hat", 2), "paddle_inner_right": ("hat", 4), "paddle_inner_left": ("hat", 0),
        "paddle_outer_left": ("hat", 6), "sax_left": ("button", 0), "sax_right": ("button", 1)}


def frame(extra=0, hat=8, buttons=0, lt=0, rt=0, sticks=(0, 0, 0, 0)):
    b = [6]
    for s in sticks:
        b += [s & 0xFF, (s >> 8) & 0xFF]
    trig = lt | rt << 10 | hat << 20
    b += [trig & 0xFF, (trig >> 8) & 0xFF, (trig >> 16) & 0xFF]
    word = buttons | extra << 19
    b += [word & 0xFF, (word >> 8) & 0xFF, (word >> 16) & 0xFF, (word >> 24) & 0xFF]
    return " ".join("%02x" % x for x in b)


def echo_fields(key):
    kind, v = ECHO[key]
    return {"hat": v} if kind == "hat" else {"buttons": 1 << v}


class Step:
    """A step as the recorder writes it: the baseline report, then every change, each at a report index."""

    def __init__(self, step_id, controls):
        self.step_id, self.controls, self.entries = step_id, controls, [(0, frame())]

    def at(self, n, **fields):
        self.entries.append((n, frame(**fields)))
        return self

    def press(self, key, n, press_lag=0, release_n=None, release_lag=0, hold_n=None, echo=None):
        """One press: the bit at `n`, the echo `press_lag` reports later; let go at `release_n` (default n + 100)."""
        echo = echo_fields(key) if echo is None else echo
        bit = 1 << TABLE[key]
        rel = release_n if release_n is not None else n + 100
        if press_lag < 0:
            self.at(n + press_lag, **echo)
            self.at(n, extra=bit, **echo)
        elif press_lag == 0:
            self.at(n, extra=bit, **echo)
        else:
            self.at(n, extra=bit)
            self.at(n + press_lag, extra=bit, **echo)
        if release_lag < 0:
            self.at(rel + release_lag, extra=bit)
            self.at(rel)
        elif release_lag == 0:
            self.at(rel)
        else:
            self.at(rel, **echo)
            self.at(rel + release_lag)
        return self

    def to_json(self):
        recs = [{"n": n, "t": float(n), "hex": hx} for n, hx in self.entries]
        return {"stepId": self.step_id, "kind": "record", "controls": self.controls,
                "attempts": [{"superseded": False, "verdict": {"verdict": "recorded"}, "receiver": recs}]}


def run_file(tmp, steps, name="run.json"):
    path = os.path.join(tmp, name)
    with open(path, "w") as f:
        json.dump({"schema": 1, "steps": [s.to_json() for s in steps]}, f)
    return path


def alone(key, n0=100, **kw):
    s = Step("alone-%s" % key, [key])
    for i in range(3):
        s.press(key, n0 + i * 400, **kw)
    return s


def run_tool(*args):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = tool.main(list(args))
        except SystemExit as e:
            code = e.code
    return code, out.getvalue(), err.getvalue()


class EchoSurveyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def survey(self, steps):
        return tool.survey(tool.load_run(run_file(self.tmp.name, steps)))

    def failed(self, res):
        return [c["check"] for c in res["gate"]["checks"] if not c["ok"]]

    def test_the_six_keys_alone_in_the_factory_profile_pass_the_gate(self):
        res = self.survey([alone(k) for k in TABLE])
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        self.assertEqual((res["W"], res["G"]), (1, 1), "same-report echoes: the floor of 1")
        self.assertEqual(res["edges"], {"total": 36, "sameReport": 36})
        echo = res["echoByProfile"]["0"]
        self.assertEqual(echo["paddle_outer_right"], [{"echo": ["D-pad right"], "presses": 3}])
        self.assertEqual(echo["paddle_inner_right"], [{"echo": ["D-pad down"], "presses": 3}])
        self.assertEqual(echo["paddle_inner_left"], [{"echo": ["D-pad up"], "presses": 3}])
        self.assertEqual(echo["paddle_outer_left"], [{"echo": ["D-pad left"], "presses": 3}])
        self.assertEqual(echo["sax_left"], [{"echo": ["A"], "presses": 3}])
        self.assertEqual(echo["sax_right"], [{"echo": ["B"], "presses": 3}])
        step = res["steps"][0]
        self.assertEqual(step["bitsSeen"], [0])
        self.assertEqual([p["bitsAtRise"] for p in step["presses"]], [[0], [0], [0]])
        code, out, _ = run_tool(run_file(self.tmp.name, [alone(k) for k in TABLE], "again.json"))
        self.assertEqual(code, 0)
        self.assertIn("GATE: PASS", out)
        self.assertIn("W = 1", out)

    def test_lags_set_w_and_g(self):
        steps = [alone(k) for k in list(TABLE)[1:]]
        steps.append(alone("paddle_outer_right", press_lag=2, release_lag=5))
        res = self.survey(steps)
        self.assertEqual((res["worst"]["pressLag"], res["worst"]["releaseLag"]), (2, 5))
        self.assertEqual((res["W"], res["G"]), (3, 6), "worst lag + 1")
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        self.assertEqual(res["edges"]["sameReport"], 30, "the six presses of the slow key are not same-report")

    def test_a_lag_beyond_the_gate_fails_it(self):
        res = self.survey([alone("sax_left", press_lag=4)])
        self.assertFalse(res["gate"]["pass"])
        self.assertIn("an echo comes at most 3 reports after its bit", self.failed(res))
        res = self.survey([alone("sax_left", release_lag=8)])
        self.assertIn("an echo goes at most 7 reports after the key's release", self.failed(res))
        res = self.survey([alone("sax_left", release_lag=7)])
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        self.assertEqual(res["G"], 8)
        code, out, _ = run_tool(run_file(self.tmp.name, [alone("sax_left", press_lag=4)]))
        self.assertEqual(code, 1)
        self.assertIn("GATE: FAIL", out)

    def test_a_lead_of_one_passes_and_a_lead_of_two_fails(self):
        res = self.survey([alone("sax_left", press_lag=-1)])
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        self.assertEqual(res["worst"]["lead"], 1)
        self.assertEqual(res["W"], 1, "a lead does not widen the window")
        res = self.survey([alone("sax_left", press_lag=-2)])
        self.assertIn("an echo comes at most 1 report before its bit", self.failed(res))

    def test_a_key_whose_bit_differs_from_the_table_fails_the_gate_and_names_the_bit(self):
        s = Step("alone-paddle_outer_right", ["paddle_outer_right"])
        for i in range(3):
            n = 100 + 400 * i
            s.at(n, extra=1 << 4, hat=2).at(n + 100, extra=0, hat=8)
        res = self.survey([s])
        self.assertFalse(res["gate"]["pass"])
        bad = [c for c in res["gate"]["checks"] if not c["ok"]][0]
        self.assertIn("saw extra bits [4], the table says 0", bad["detail"])
        self.assertEqual(res["steps"][0]["presses"][0]["echo"][0]["item"], "D-pad right", "the lags are still measured on the bit seen")

    def test_two_keys_down_show_the_hat_and_the_return_of_the_held_keys_direction(self):
        s = Step("outer-right-outer-left", ["paddle_outer_right", "paddle_outer_left"])
        s.at(100, extra=1, hat=2)                               # outer right held: right
        for i, back in enumerate((3, 1)):
            n = 200 + 200 * i
            s.at(n, extra=1 | 8, hat=6)                         # outer left pressed: the hat shows left, right is gone
            s.at(n + 100, extra=1, hat=6)                       # let go: the hat still shows left
            s.at(n + 100 + back, extra=1, hat=2)                # ... then right is back `back` reports later
        s.at(700, extra=0, hat=8)
        res = self.survey([s])
        step = res["steps"][0]
        self.assertEqual([x["lag"] for x in step["reemergence"]], [3, 1])
        self.assertTrue(all(x["echoDropped"] for x in step["reemergence"]))
        self.assertEqual(res["worst"]["reemergence"], 3)
        self.assertEqual(res["G"], 4)
        self.assertEqual(step["hatByKeysDown"]["paddle_outer_left+paddle_outer_right"], [6])
        self.assertEqual(step["hatByKeysDown"]["paddle_outer_right"], [2, 6])
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        # a return later than the gate allows
        s2 = Step("outer-right-outer-left", ["paddle_outer_right", "paddle_outer_left"])
        s2.at(100, extra=1, hat=2).at(200, extra=1 | 8, hat=6).at(300, extra=1, hat=6).at(309, extra=1, hat=2).at(500, extra=0, hat=8)
        self.assertIn("the remaining key's direction comes back at most 7 reports after the release", self.failed(self.survey([s2])))

    def test_a_real_direction_the_hat_drops_stops_the_gate(self):
        def block(hat_when_up_pressed):
            s = Step("outer-right-dpad-up", ["paddle_outer_right", "dpad_up"])
            s.at(100, extra=1, hat=2)
            for n in (200, 400):
                s.at(n, extra=1, hat=hat_when_up_pressed).at(n + 100, extra=1, hat=2)
            return s.at(600, extra=0, hat=8)
        ok = self.survey([block(1)])                       # up+right: both shown
        self.assertEqual(ok["steps"][0]["realDirection"]["ok"], True)
        self.assertTrue(ok["gate"]["pass"], self.failed(ok))
        last = self.survey([block(0)])                     # last press wins: up alone, right dropped: still a real up
        self.assertEqual(last["steps"][0]["realDirection"]["ok"], True)
        lost = self.survey([block(2)])                     # the hat never changes: the real up is not shown
        self.assertEqual(lost["steps"][0]["realDirection"]["ok"], False)
        self.assertIn("the hat never drops a real direction while a paddle is held", self.failed(lost))

        held = Step("up-held-paddle_inner_right", ["dpad_up", "paddle_inner_right"])
        held.at(100, hat=0).at(200, extra=2, hat=0)        # opposite echo (down) cannot show next to up: the hat keeps up
        held.at(300, extra=2, hat=4).at(400, extra=0, hat=8)
        res = self.survey([held])
        self.assertEqual(res["steps"][0]["realDirection"]["ok"], False, "D-pad up dropped while the key was down")

    def test_profile_edge_during_a_hold(self):
        def block(change_after):
            s = Step("profile-block-1", ["paddle_outer_right", "profile"])
            s.at(100, extra=1, hat=2)
            s.at(200, extra=1, hat=2, buttons=1 << 16)          # Profile pressed
            if change_after is not None:
                s.at(200 + change_after, extra=1, hat=4, buttons=1 << 16)      # the echo changes (right -> down)
            s.at(300, extra=1, hat=4 if change_after is not None else 2)        # Profile let go
            s.at(400, extra=0, hat=8)
            return s
        quick = self.survey([block(2)])
        edge = quick["steps"][0]["profileEdges"][0]
        self.assertEqual((edge["edge"], edge["change"]["lag"]), ("pressed", 2))
        self.assertEqual(edge["change"]["rose"], ["D-pad down"])
        self.assertEqual(edge["change"]["fell"], ["D-pad right"])
        self.assertEqual(quick["worst"]["profileEdge"], 2)
        self.assertEqual(quick["W"], 3)
        self.assertTrue(quick["gate"]["pass"], self.failed(quick))
        never = self.survey([block(None)])
        self.assertIsNone(never["steps"][0]["profileEdges"][0]["change"])
        self.assertTrue(never["gate"]["pass"], self.failed(never))
        slow = self.survey([block(5)])
        self.assertIn("after a Profile edge during a hold the echo changes within 3 reports or not until release", self.failed(slow))

    def test_profiles_and_the_echo_of_each_key_per_profile(self):
        steps = [alone("paddle_outer_right")]
        other = Step("profile-1-paddle_outer_right", ["paddle_outer_right"])
        for i in range(3):
            other.press("paddle_outer_right", 100 + 400 * i, echo={"buttons": 1 << 3})   # Y in the next profile
        steps.append(other)
        res = self.survey(steps)
        self.assertEqual(res["echoByProfile"]["0"]["paddle_outer_right"][0]["echo"], ["D-pad right"])
        self.assertEqual(res["echoByProfile"]["1"]["paddle_outer_right"][0]["echo"], ["Y"])

    def test_row_11_probe_direction_and_picks(self):
        res = self.survey([alone(k) for k in TABLE])
        self.assertEqual(res["row11"]["probeDirection"], "D-pad up", "up unless it is outer right's echo")
        self.assertTrue(res["row11"]["picksOk"])
        up = Step("alone-paddle_outer_right", ["paddle_outer_right"])
        for i in range(3):
            up.press("paddle_outer_right", 100 + 400 * i, echo={"hat": 0})
        self.assertEqual(self.survey([up])["row11"]["probeDirection"], "D-pad right")
        clash = Step("alone-sax_left", ["sax_left"])
        for i in range(3):
            clash.press("sax_left", 100 + 400 * i, echo={"buttons": 1 << 6})             # View
        r = self.survey([clash])["row11"]
        self.assertEqual(r["picksInsideAnEcho"], ["View"])
        self.assertFalse(r["picksOk"])

    def test_analog_movement_a_stick_and_the_cap_are_reported(self):
        s = alone("sax_left")
        s.at(900, lt=800)                                                                 # an analog field moves
        s.at(950, lt=0)
        res = self.survey([s])
        self.assertTrue(res["steps"][0]["analogMoved"])
        self.assertEqual(res["steps"][0]["analog"]["lt"], 800)
        stick = alone("sax_left")
        stick.at(900, sticks=(9000, 0, 0, 0))
        self.assertTrue(self.survey([stick])["steps"][0]["stickMoved"])
        self.assertIn("no echo on a stick", " ".join(self.failed(self.survey([stick]))), "a stick moving in a key-alone step stops the gate")
        self.assertFalse(self.survey([alone("sax_left")])["steps"][0]["stickMoved"])
        capped = Step("alone-sax_left", ["sax_left"])
        capped.press("sax_left", 100)
        path = run_file(self.tmp.name, [capped])
        with open(path) as f:
            data = json.load(f)
        data["steps"][0]["attempts"][0]["receiverDropped"] = 12
        with open(path, "w") as f:
            json.dump(data, f)
        res = tool.survey(tool.load_run(path))
        self.assertIn("no step lost reports to the cap", self.failed(res))

    def test_unusable_input_exits_with_2(self):
        bad = os.path.join(self.tmp.name, "bad.json")
        with open(bad, "w") as f:
            f.write("{ not json")
        self.assertEqual(run_tool(bad)[0], 2)
        self.assertIn("cannot read", run_tool(bad)[2])
        empty = os.path.join(self.tmp.name, "empty.json")
        with open(empty, "w") as f:
            json.dump({"steps": [{"stepId": "a", "attempts": [{"verdict": {"verdict": "pass"}}]}]}, f)
        code, _, err = run_tool(empty)
        self.assertEqual(code, 2)
        self.assertIn("no step has a `receiver` list", err)
        self.assertEqual(run_tool(os.path.join(self.tmp.name, "missing.json"))[0], 2)
        wrong = os.path.join(self.tmp.name, "wrong.json")
        with open(wrong, "w") as f:
            json.dump({"steps": [{"stepId": "a", "attempts": [{"receiver": [{"n": 1, "t": 0, "hex": "06 00"}]}]}]}, f)
        self.assertEqual(run_tool(wrong)[0], 2)

    def test_json_output_has_the_s2_result_parts(self):
        code, out, _ = run_tool("--json", run_file(self.tmp.name, [alone(k) for k in TABLE]))
        self.assertEqual(code, 0)
        data = json.loads(out)
        for key in ("echoByProfile", "worst", "W", "G", "gate", "row11", "edges", "steps"):
            self.assertIn(key, data)
        self.assertEqual(data["gate"]["pass"], True)

    def test_the_last_attempt_that_is_not_superseded_is_read(self):
        good = alone("sax_left").to_json()
        old = alone("sax_left", press_lag=5).to_json()["attempts"][0]
        old["superseded"] = True
        good["attempts"].insert(0, old)
        path = os.path.join(self.tmp.name, "two.json")
        with open(path, "w") as f:
            json.dump({"steps": [good]}, f)
        self.assertTrue(tool.survey(tool.load_run(path))["gate"]["pass"])


class RealCaptureTest(unittest.TestCase):
    def test_the_button_walk_has_16_edges_all_in_the_same_report_and_the_table_bits(self):
        res = tool.survey(tool.capture_steps(CAPTURE))
        self.assertEqual(res["edges"], {"total": 16, "sameReport": 16}, "8 paddle and SAX presses, 16 edges, bit and echo together")
        step = res["steps"][0]
        self.assertEqual(step["bitsSeen"], [0, 1, 2, 3, 4, 5])
        for p in step["presses"]:
            self.assertEqual(p["bitsAtRise"], [tool.KEY_MASK[p["key"]].bit_length() - 1], p["key"])
        echo = res["echoByProfile"]["0"]
        self.assertEqual(echo["paddle_outer_right"][0]["echo"], ["D-pad right"])
        self.assertEqual(echo["paddle_outer_left"][0]["echo"], ["D-pad left"])
        self.assertEqual(echo["paddle_inner_right"][0]["echo"], ["D-pad down"])
        self.assertEqual(echo["paddle_inner_left"][0]["echo"], ["D-pad up"])
        self.assertEqual(echo["sax_left"][0], {"echo": ["A"], "presses": 2})
        self.assertEqual(echo["sax_right"][0], {"echo": ["B"], "presses": 2})
        self.assertEqual((res["worst"]["pressLag"], res["worst"]["releaseLag"], res["worst"]["lead"]), (0, 0, 0))
        self.assertEqual((res["W"], res["G"]), (1, 1))
        self.assertTrue(res["gate"]["pass"])
        code, out, _ = run_tool("--capture", CAPTURE)
        self.assertEqual(code, 0)
        self.assertIn("Key edges: 16, of which the echo changed in the same report: 16", out)

    def test_report_indexes_follow_the_identical_before_counts(self):
        frames = tool.capture_steps(CAPTURE)[0]["frames"]
        self.assertEqual(frames[0].n, 0)
        self.assertEqual(frames[1].n, 6552, "the first change comes after 6551 identical reports")
        self.assertEqual(len(frames), 87)


class AppWrittenReportTest(unittest.TestCase):
    """The report the app's own encoder writes (Tests/GDHubTests/DevRunReportFixtureTests.swift) reads back here."""

    def test_the_fixture_written_by_the_swift_encoder_is_read(self):
        res = tool.survey(tool.load_run(SURVEY_FIXTURE))
        self.assertEqual([s["stepId"] for s in res["steps"]], ["alone-sax_left", "alone-paddle_outer_right"])
        self.assertEqual(res["echoByProfile"]["0"]["sax_left"], [{"echo": ["A"], "presses": 3}])
        self.assertEqual(res["echoByProfile"]["0"]["paddle_outer_right"], [{"echo": ["D-pad right"], "presses": 3}])
        self.assertEqual(res["edges"], {"total": 12, "sameReport": 12})
        self.assertTrue(res["gate"]["pass"])
        code, out, _ = run_tool(SURVEY_FIXTURE)
        self.assertEqual(code, 0)
        self.assertIn("SAX left", out)


if __name__ == "__main__":
    unittest.main()
