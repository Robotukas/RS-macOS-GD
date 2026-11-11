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
ECHO_FIXTURE = os.path.join(ROOT, "Tests", "GDHubTests", "Fixtures", "echo-survey-s2.json")

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

    def __init__(self, step_id, controls, superseded=False):
        self.step_id, self.controls, self.entries, self.superseded = step_id, controls, [(0, frame())], superseded

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
                "attempts": [{"superseded": self.superseded, "verdict": {"verdict": "recorded"}, "receiver": recs}]}


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

    def details(self, res):
        return " ".join(c["detail"] for c in res["gate"]["checks"] if not c["ok"])

    def test_the_six_keys_alone_in_the_factory_profile_pass_the_gate(self):
        res = self.survey([alone(k) for k in TABLE])
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        self.assertEqual(res["edges"], {"total": 36, "sameReport": 36, "alreadyOn": 0, "other": 0, "withInput": 0, "shared": 0})
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
        rp = res["replay"]
        self.assertEqual((rp["wrong"], rp["ghosts"], rp["ambiguous"], rp["unconfirmedClean"]), (0, 0, 0, 0))
        code, out, _ = run_tool(run_file(self.tmp.name, [alone(k) for k in TABLE], "again.json"))
        self.assertEqual(code, 0)
        self.assertIn("GATE: PASS", out)
        self.assertIn("Replay of the v3 rule: 42 reports × 64 masks: wrong 0, ghosts 0, ambiguous 0, unconfirmed clean 0 (shared 0, with-item 0)", out)
        self.assertNotIn("W = ", out, "the window and the grace are gone")

    def test_an_echo_off_by_a_report_fails_the_gate_and_names_the_step_and_attempt(self):
        for kw in ({"press_lag": 1}, {"press_lag": 4}, {"press_lag": -1}, {"release_lag": 1}, {"release_lag": -1}):
            res = self.survey([alone("sax_left", **kw)])
            self.assertFalse(res["gate"]["pass"], kw)
            self.assertIn("every key edge changes exactly its echo in its own report, or the echo was already on for 8 reports",
                          self.failed(res), kw)
            self.assertIn("alone-sax_left (attempt 0)", self.details(res), kw)
        res = self.survey([alone("sax_left", press_lag=1)])
        self.assertEqual(res["worst"]["pressLag"], 1, "the lag is measured and reported")
        res = self.survey([alone("sax_left", press_lag=-1)])
        self.assertEqual(res["worst"]["lead"], 1)
        res = self.survey([alone("sax_left", release_lag=3)])
        self.assertEqual(res["worst"]["releaseLag"], 3)
        res = self.survey([alone("sax_left", press_lag=1)])
        self.assertGreater(res["replay"]["unconfirmedClean"], 0, "the replay reports the clean unconfirmed press")
        self.assertIn("an unconfirmed press that is clean (only that key changed, nothing else on the pad)", self.failed(res))
        code, out, _ = run_tool(run_file(self.tmp.name, [alone("sax_left", press_lag=1)]))
        self.assertEqual(code, 1)
        self.assertIn("GATE: FAIL", out)

    def test_an_echo_that_was_already_on_for_8_reports_passes_and_for_fewer_fails(self):
        measure = alone("sax_left")                                   # the echo of SAX left in this state: A

        def held(a_on_at):
            s = Step("a-held-sax-left", ["a", "sax_left"])
            s.at(a_on_at, buttons=1)                                  # A held by the owner, then SAX left twice with A on
            for n in (200, 400):
                s.at(n, extra=1 << 4, buttons=1).at(n + 100, extra=0, buttons=1)
            return s.at(600, extra=0, buttons=0)
        ok = self.survey([measure, held(100)])
        self.assertTrue(ok["gate"]["pass"], self.failed(ok))
        self.assertEqual(ok["edges"]["alreadyOn"], 4, "two presses and two releases, A on throughout")
        close = self.survey([measure, held(195)])
        self.assertFalse(close["gate"]["pass"])
        self.assertIn("a-held-sax-left (attempt 0)", self.details(close))
        edge = Step("a-held-sax-left", ["a", "sax_left"])
        edge.at(100, buttons=1).at(200, extra=1 << 4, buttons=1).at(210, extra=0, buttons=1).at(215, extra=0, buttons=0)
        self.assertFalse(self.survey([measure, edge])["gate"]["pass"], "A let go 5 reports after the release is too short")

    def test_a_release_is_read_backwards(self):
        s = Step("outer-right-outer-left", ["paddle_outer_right", "paddle_outer_left"])
        s.at(100, extra=1, hat=2)                              # outer right: right
        s.at(200, extra=1 | 8, hat=8)                          # outer left added: the hat cancels to none
        s.at(300, extra=1, hat=2)                              # outer left let go: right is back (it took away left)
        s.at(400, extra=0, hat=8)
        res = self.survey([alone("paddle_outer_left"), s])
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        verdicts = [e["verdict"] for e in res["steps"][-1]["edges"]]
        self.assertEqual(verdicts, ["exact", "exact", "exact", "exact"])
        self.assertEqual(res["steps"][-1]["edges"][2]["changed"], ["D-pad left"], "a cancel counts as the opposite direction")

    def test_sax_pressed_5_reports_apart_both_echoes_at_zero_none_across(self):
        s = Step("together-sax", ["sax_left", "sax_right"])
        s.at(100, extra=1 << 5, buttons=2)                     # SAX right (B)
        s.at(105, extra=(1 << 5) | (1 << 4), buttons=3)        # SAX left (A) five reports later
        s.at(200, extra=1 << 4, buttons=1)                     # SAX right let go
        s.at(210, extra=0, buttons=0)
        res = self.survey([s])
        step = res["steps"][0]
        by_key = {p["key"]: p for p in step["presses"]}
        self.assertEqual([(e["item"], e["pressLag"]) for e in by_key["sax_left"]["echo"]], [("A", 0)])
        self.assertEqual([(e["item"], e["pressLag"]) for e in by_key["sax_right"]["echo"]], [("B", 0)])
        self.assertEqual(res["worst"], {"pressLag": 0, "releaseLag": 0, "lead": 0})
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        self.assertEqual(res["edges"]["sameReport"], 4)

    def test_an_outer_pair_one_report_apart_has_no_lead(self):
        s = Step("together-outer", ["paddle_outer_left", "paddle_outer_right"])
        s.at(100, extra=8, hat=6).at(101, extra=9, hat=8).at(300, extra=8, hat=6).at(301, extra=0, hat=8)
        res = self.survey([s])
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        by_key = {p["key"]: p for p in res["steps"][0]["presses"]}
        self.assertEqual([(e["item"], e["pressLag"]) for e in by_key["paddle_outer_right"]["echo"]], [("D-pad right", 0)],
                         "the cancel at report 101 is outer right's own echo, not an echo that came early")
        self.assertEqual(res["worst"]["lead"], 0)

    def test_two_keys_in_one_report_are_shared_and_the_replay_lists_the_unconfirmed_presses(self):
        s = Step("together-outer", ["paddle_outer_left", "paddle_outer_right"])
        s.at(100, extra=9, hat=8).at(300, extra=0, hat=8)
        res = self.survey([s])
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        self.assertEqual((res["edges"]["shared"], res["edges"]["total"]), (2, 0))
        self.assertEqual([p["shared"] for p in res["steps"][0]["presses"]], [True, True])
        self.assertEqual(res["steps"][0]["presses"][0]["echo"], [], "never attributed")
        rp = res["replay"]
        self.assertEqual((rp["wrong"], rp["ghosts"], rp["unconfirmedClean"]), (0, 0, 0))
        self.assertEqual(rp["unconfirmedShared"], 32, "the 32 masks with exactly one of bits 0 and 3 cannot read the press")
        self.assertEqual(rp["unconfirmedWithItem"], 0)
        self.assertEqual(rp["wrongExcused"], 32, "one report per unreadable press, on the axis the press could not be read on")

    def test_an_opposite_direction_with_other_inputs_in_the_press_report_is_listed_with_item(self):
        # paddle outer right pressed in the same report as D-pad left (the hat cancels to none) and X and Y: the controller
        # reports no direction, so the stored echo is neither seen nor agreed with; the report is not clean.
        s = Step("outer-right-dpad-left", ["paddle_outer_right", "dpad_left"])
        s.at(100, extra=1, hat=8, buttons=0b1100).at(200, extra=0, hat=6, buttons=0b1100).at(300, extra=0, hat=8, buttons=0)
        res = self.survey([alone("paddle_outer_right"), s])
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        self.assertEqual(res["edges"]["withInput"], 1)
        rp = res["replay"]
        self.assertGreater(rp["unconfirmedWithItem"], 0)
        self.assertEqual(rp["unconfirmedClean"], 0)
        self.assertEqual((rp["wrong"], rp["wrongExcused"]), (0, 32), "pinned: the narrowed excuse keeps exactly these 32")

    def test_a_neighbour_touched_in_an_alone_step_is_reported_and_left_out_of_the_table(self):
        s = alone("paddle_outer_right")
        s.press("paddle_inner_right", 1500)
        res = self.survey([s])
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        self.assertEqual(res["touched"], [{"key": "paddle_inner_right", "count": 1, "stepId": "alone-paddle_outer_right", "attempt": 0}])
        self.assertEqual(res["echoByProfile"]["0"], {"paddle_outer_right": [{"echo": ["D-pad right"], "presses": 3}]})
        code, out, _ = run_tool(run_file(self.tmp.name, [s]))
        self.assertEqual(code, 0)
        self.assertIn("touched Paddle inner right 1 time (attempt 0 of alone-paddle_outer_right)", out)

    def test_a_bit_outside_the_six_in_an_alone_step_fails(self):
        s = alone("sax_left")
        s.at(900, extra=(1 << 4) | (1 << 8), buttons=1).at(950, extra=0)
        res = self.survey([s])
        self.assertFalse(res["gate"]["pass"])
        self.assertIn("outside the six keys' table bits", self.details(res))

    def test_a_key_whose_bit_differs_from_the_table_fails_the_gate_and_names_the_bit(self):
        s = Step("alone-paddle_outer_right", ["paddle_outer_right"])
        for i in range(3):
            n = 100 + 400 * i
            s.at(n, extra=1 << 4, hat=2).at(n + 100, extra=0, hat=8)
        res = self.survey([s])
        self.assertFalse(res["gate"]["pass"])
        bad = [c for c in res["gate"]["checks"] if not c["ok"]][0]
        self.assertIn("saw extra bits [4], the table says 0", bad["detail"])
        self.assertIn("alone-paddle_outer_right (attempt 0)", bad["detail"])
        self.assertEqual(res["steps"][0]["presses"][0]["echo"][0]["item"], "D-pad right", "the lags are still measured on the bit seen")

    def test_two_keys_down_show_the_hat_and_the_return_of_the_held_keys_direction_but_judge_nothing(self):
        s = Step("outer-right-outer-left", ["paddle_outer_right", "paddle_outer_left"])
        s.at(100, extra=1, hat=2)                               # outer right held: right
        for i, back in enumerate((3, 1)):
            n = 200 + 200 * i
            s.at(n, extra=1 | 8, hat=6)                         # outer left pressed: the hat shows left, right is gone
            s.at(n + 100, extra=1, hat=8)                       # let go: left is gone at once, right is not back yet
            s.at(n + 100 + back, extra=1, hat=2)                # ... then right is back `back` reports later
        s.at(700, extra=0, hat=8)
        res = self.survey([s])
        step = res["steps"][0]
        self.assertEqual([x["lag"] for x in step["reemergence"]], [3, 1])
        self.assertTrue(all(x["echoDropped"] for x in step["reemergence"]))
        self.assertEqual(step["hatByKeysDown"]["paddle_outer_left+paddle_outer_right"], [6])
        self.assertEqual(step["hatByKeysDown"]["paddle_outer_right"], [2, 8])
        self.assertNotIn("G", res)
        self.assertFalse([c for c in res["gate"]["checks"] if "direction comes back" in c["check"] or "return" in c["check"]],
                         "there is no gate line for the return of the held key's direction")
        # a return as late as 9 reports is still only reported
        s2 = Step("outer-right-outer-left", ["paddle_outer_right", "paddle_outer_left"])
        s2.at(100, extra=1, hat=2).at(200, extra=1 | 8, hat=6).at(300, extra=1, hat=8).at(309, extra=1, hat=2).at(500, extra=0, hat=8)
        res2 = self.survey([s2])
        self.assertEqual(res2["steps"][0]["reemergence"][0]["lag"], 9)

    def test_the_hat_is_judged_by_the_replay_not_by_a_real_direction_check(self):
        def block(hat_when_up_pressed):
            s = Step("outer-right-dpad-up", ["paddle_outer_right", "dpad_up"])
            s.at(100, extra=1, hat=2)
            for n in (200, 400):
                s.at(n, extra=1, hat=hat_when_up_pressed).at(n + 100, extra=1, hat=2)
            return s.at(600, extra=0, hat=8)
        for hat in (1, 0, 2):                                      # up+right, last press wins, the hat never changes
            res = self.survey([alone("paddle_outer_right"), block(hat)])
            self.assertTrue(res["gate"]["pass"], (hat, self.failed(res)))
            self.assertEqual((res["replay"]["wrong"], res["replay"]["ghosts"]), (0, 0), hat)
        self.assertNotIn("realDirection", self.survey([block(1)])["steps"][0])
        held = Step("up-held-paddle_inner_right", ["dpad_up", "paddle_inner_right"])
        held.at(100, hat=0).at(200, extra=2, hat=8)        # the paddle adds down: up and down cancel, no direction
        held.at(300, extra=2, hat=4).at(400, extra=0, hat=8)
        res = self.survey([alone("paddle_inner_right"), held])
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        self.assertEqual((res["replay"]["wrong"], res["replay"]["ghosts"], res["replay"]["ambiguous"]), (0, 0, 0))
        self.assertGreater(res["replay"]["recovered"], 0, "the rule gives the real up back")

    def test_profile_edge_during_a_hold_is_reported_only(self):
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
        never = self.survey([block(None)])
        self.assertIsNone(never["steps"][0]["profileEdges"][0]["change"])
        slow = self.survey([block(5)])
        self.assertEqual(slow["steps"][0]["profileEdges"][0]["change"]["lag"], 5)
        for res in (quick, never, slow):
            self.assertNotIn("profileEdge", res["worst"])
            self.assertNotIn("after a Profile edge", " ".join(c["check"] for c in res["gate"]["checks"]))

    def test_profiles_and_the_echo_of_each_key_per_profile(self):
        steps = [alone("paddle_outer_right")]
        other = Step("profile-1-paddle_outer_right", ["paddle_outer_right"])
        for i in range(3):
            other.press("paddle_outer_right", 100 + 400 * i, echo={"buttons": 1 << 3})   # Y in the next profile
        steps.append(other)
        res = self.survey(steps)
        self.assertEqual(res["echoByProfile"]["0"]["paddle_outer_right"][0]["echo"], ["D-pad right"])
        self.assertEqual(res["echoByProfile"]["1"]["paddle_outer_right"][0]["echo"], ["Y"])
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        # the same key with two different echoes inside one state fails
        mixed = alone("paddle_outer_right")
        mixed.press("paddle_outer_right", 1800, echo={"buttons": 1 << 3})
        bad = self.survey([mixed])
        self.assertIn("each key's echo is one receiver button or one D-pad direction, the same in every press of a state", self.failed(bad))

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
        self.assertIn("no echo on a stick, a trigger, Start, a G key or Profile", self.failed(res))
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
        for key in ("echoByProfile", "worst", "replay", "gate", "row11", "edges", "steps", "touched"):
            self.assertIn(key, data)
        for gone in ("W", "G"):
            self.assertNotIn(gone, data)
        self.assertEqual(data["gate"]["pass"], True)
        self.assertEqual(data["replay"]["reports"], 42)

    def attempts_file(self, step_id, controls, attempts):
        path = os.path.join(self.tmp.name, "attempts-%d.json" % len(os.listdir(self.tmp.name)))
        with open(path, "w") as f:
            json.dump({"steps": [{"stepId": step_id, "kind": "record", "controls": controls, "attempts": attempts}]}, f)
        return path

    def test_every_attempt_is_read_and_a_superseded_one_with_a_lag_fails_the_gate_and_is_named(self):
        good = alone("sax_left").to_json()["attempts"][0]
        old = alone("sax_left", press_lag=5).to_json()["attempts"][0]
        old["superseded"] = True
        path = self.attempts_file("alone-sax_left", ["sax_left"], [old, good])
        loaded = tool.load_run(path)
        self.assertEqual([(s["attempt"], s["superseded"]) for s in loaded], [(0, True), (1, False)])
        res = tool.survey(loaded)
        self.assertFalse(res["gate"]["pass"])
        self.assertIn("alone-sax_left (attempt 0)", self.details(res))
        self.assertNotIn("attempt 1", self.details(res))
        code, out, _ = run_tool(path)
        self.assertEqual(code, 1)
        self.assertIn("attempt 0 (superseded)", out)

    def test_a_superseded_attempt_that_touched_a_neighbour_passes_with_touched_reported(self):
        good = alone("sax_left").to_json()["attempts"][0]
        slip = alone("sax_right").to_json()["attempts"][0]            # the owner pressed SAX right in SAX left's step
        slip["superseded"] = True
        path = self.attempts_file("alone-sax_left", ["sax_left"], [slip, good])
        res = tool.survey(tool.load_run(path))
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        self.assertEqual([(t["key"], t["count"], t["attempt"]) for t in res["touched"]], [("sax_right", 3, 0)])
        self.assertEqual(res["echoByProfile"]["0"]["sax_left"], [{"echo": ["A"], "presses": 3}], "the slip is not SAX left's presses")
        # the same slip in the final attempt means the key was never pressed: that fails
        final = self.attempts_file("alone-sax_left", ["sax_left"], [good, dict(slip, superseded=False)])
        self.assertFalse(tool.survey(tool.load_run(final))["gate"]["pass"])

    def test_the_committed_fixture_is_read_like_a_run_report(self):
        res = tool.survey(tool.load_run(ECHO_FIXTURE))
        self.assertTrue(res["gate"]["pass"], self.failed(res))
        self.assertEqual(res["edges"]["total"], 654)
        self.assertEqual((res["edges"]["sameReport"], res["edges"]["alreadyOn"], res["edges"]["other"]), (634, 20, 0))
        rp = res["replay"]
        self.assertEqual((rp["reports"], rp["wrong"], rp["ghosts"], rp["ambiguous"], rp["unconfirmedClean"]), (789, 0, 0, 0, 0))
        self.assertEqual((rp["unconfirmedShared"], rp["unconfirmedWithItem"], rp["other"]), (0, 0, 0))
        code, out, _ = run_tool(ECHO_FIXTURE)
        self.assertEqual(code, 0)
        self.assertIn("Replay of the v3 rule: 789 reports × 64 masks: wrong 0, ghosts 0, ambiguous 0, unconfirmed clean 0", out)
        self.assertEqual(res["row11"]["probeDirection"], "D-pad up")
        self.assertTrue(res["row11"]["picksOk"])


class RealCaptureTest(unittest.TestCase):
    def test_the_button_walk_has_16_edges_all_in_the_same_report_and_the_table_bits(self):
        res = tool.survey(tool.capture_steps(CAPTURE))
        self.assertEqual((res["edges"]["total"], res["edges"]["sameReport"], res["edges"]["other"]), (16, 16, 0),
                         "8 paddle and SAX presses, 16 edges, bit and echo together")
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
        self.assertEqual((res["edges"]["total"], res["edges"]["sameReport"]), (12, 12))
        self.assertTrue(res["gate"]["pass"])
        code, out, _ = run_tool(SURVEY_FIXTURE)
        self.assertEqual(code, 0)
        self.assertIn("SAX left", out)


if __name__ == "__main__":
    unittest.main()
