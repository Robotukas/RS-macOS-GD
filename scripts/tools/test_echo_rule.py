import importlib.util
import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FIX = os.path.join(ROOT, "Tests", "GDHubTests", "Fixtures")
FIXTURE = os.path.join(FIX, "echo-survey-s2.json")
V23_FILE = os.path.join(FIX, "echo-v23-table.json")

spec = importlib.util.spec_from_file_location("echo_rule", os.path.join(HERE, "echo_rule.py"))
ER = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ER)

RECOVERED, OTHER, UNCONF, ARMED, APPLIED = ER.W_RECOVERED, ER.W_OTHER, ER.W_UNCONFIRMED, ER.W_ARMED, ER.W_APPLIED


def pads(rows):
    return [ER.fmt(r.pad) for r in rows[1:]]


def hat_rows(rows):
    return [ER.fmt(r.pad).split("hat:")[1] for r in rows[1:]]


def frame(buttons=0, hat=8, extra=0):
    return ER.Frame(buttons, hat, extra, ER.items_of(buttons, hat))


class RuleTest(unittest.TestCase):
    def test_a_fresh_state_is_16_zero_bytes_and_a_report_with_no_hidden_key_held_passes(self):
        e = ER.Echo(0x3F)
        self.assertEqual(e.state_bytes(), bytes(16))
        self.assertEqual(e.step(0b101, 2, 0b1000000), 0, "extra bit 6 is not one of the six")
        self.assertEqual(e.flags, ER.VALID | ER.ARMED)
        self.assertEqual(e.state_bytes(), bytes([5, 0x08, 5, 0x08, 0, 0, 0, 3] + [0] * 8))
        # H = 0: nothing is ever hidden, whatever is held
        z = ER.Echo(0)
        for ex in (0, 1, 0x3F):
            self.assertEqual(z.step(0b1111, 6, ex), 0)

    def test_the_word_and_the_state_of_one_hidden_press(self):
        e = ER.Echo(0x01)
        e.step(0, 8, 0)
        w = e.step(0, 2, 1)                        # paddle outer right: the controller adds D-pad right
        self.assertEqual(w, APPLIED | ARMED | 1 << 16 | 8 << 10, "held key 0, hat none")
        self.assertEqual(e.state_bytes(), bytes([0, 0, 0x00, 0x08, 1, 1, 1, 3, 12, 0, 0, 0, 0, 0, 0, 0]))
        self.assertEqual(ER.apply_word(w, [6] + [0] * 10 + [0x20] + [0, 0, 0, 0]), [6] + [0] * 10 + [0x80] + [0, 0, 0, 0],
                         "the hat nibble becomes 8, nothing else changes")
        self.assertEqual(ER.apply_word(0, list(range(16))), list(range(16)), "a word of 0 gives the bytes unchanged")

    def test_apply_changes_only_buttons_1_to_10_and_the_hat_nibble(self):
        raw = [6, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0x2F, 0xFF, 0xFF, 0xFF, 0xFF]
        word = APPLIED | 0b1010101010 | 3 << 10
        out = ER.apply_word(word, raw)
        self.assertEqual(out[:11], raw[:11])
        self.assertEqual(out[11], 0x3F, "hat nibble 3, low nibble kept")
        self.assertEqual(out[12], 0xAA)
        self.assertEqual(out[13], 0xFE, "bits 0-1 of byte 13 are buttons 9 and 10; the other bits stay")
        self.assertEqual(out[14:], raw[14:])

    def test_items_code_and_changed(self):
        self.assertEqual([ER.code(m) for m in ER.FACTORY], ER.FACTORY_CODES)
        up, right, down, left = (1 << ER.U), (1 << ER.R), (1 << ER.D), (1 << ER.L)
        self.assertEqual(ER.changed(0, right), right)
        self.assertEqual(ER.changed(left, 0), right, "a cancel counts as the opposite direction")
        self.assertEqual(ER.changed(left, right), right, "a straight move from n to p counts as p")
        self.assertEqual(ER.changed(up, 0), down)
        self.assertEqual(ER.changed(0b1, 0b11), 0b10)
        self.assertEqual(ER.changed(right, right), 0)
        self.assertEqual([ER.hat_of(m) for m in (0, up, right, down, left, up | right, up | down, up | left | right)], [8, 0, 2, 4, 6, 1, 8, 0])

    def test_a_hold_that_ends_clears_cur_and_equals_a_fresh_state_for_that_report(self):
        e = ER.Echo(0x01)
        e.step(0, 8, 0)
        e.step(0, 2, 1)
        e.step(0b100, 2, 1)
        self.assertEqual(e.step(0b100, 8, 0), 0)
        fresh = ER.Echo(0x01)
        fresh.step(0b100, 8, 0)
        self.assertEqual(e.state_bytes(), fresh.state_bytes())

    def test_the_stored_items_of_keys_outside_the_hide_mask_are_dropped(self):
        self.assertEqual(ER.Echo(0x01, ER.FACTORY).S, [ER.FACTORY[0], 0, 0, 0, 0, 0])

    def test_scripted_headline_sequences(self):
        # V4: up held, paddle inner right (the controller adds down and reports no direction): up on every report
        rows = ER.simulate(["+up", "+IR", ".", "-IR", "-up"], ["IR"])
        self.assertEqual(hat_rows(rows), ["U", "U", "U", "U", "."])
        self.assertTrue(rows[2].word & RECOVERED)
        # V5: paddle held first, D-pad left pressed twice: left twice
        rows = ER.simulate(["+OR", "+left", "-left", "+left", "-left", "-OR"], ["OR"])
        self.assertEqual(hat_rows(rows), [".", "L", ".", "L", ".", "."])
        # the paddle's own direction never reaches the pad
        rows = ER.simulate(["+OR", ".", "-OR"], ["OR"])
        self.assertEqual(hat_rows(rows), [".", ".", "."])
        # V3: A held, SAX left tapped: A without a break; A let go during the hold stays until the release
        rows = ER.simulate(["+A", "+SL", ".", "-SL"], ["SL"])
        self.assertEqual(pads(rows), ["A+hat:.", "A+hat:.", "A+hat:.", "A+hat:."])
        rows = ER.simulate(["+A", "+SL", "-A", "-SL"], ["SL"])
        self.assertEqual(pads(rows), ["A+hat:.", "A+hat:.", "A+hat:.", "hat:."])
        # V9: outer right hidden, outer left untouched, one after the other: left
        rows = ER.simulate(["+OR", "+OL", ".", "-OL", "-OR"], ["OR"])
        self.assertEqual(hat_rows(rows), [".", "L", "L", ".", "."])
        # V1: every hidden key alone sends only the pick: nothing reaches the pad
        for k, key in enumerate(ER.KEYS):
            rows = ER.simulate(["+" + key, ".", "-" + key], [key])
            self.assertEqual(pads(rows), ["hat:."] * 3, key)
            self.assertFalse(any(r.word & (OTHER | UNCONF) for r in rows), key)

    def test_v8_both_outer_paddles_freeze_the_left_right_axis(self):
        rows = ER.simulate(["+OR +OL", "+up", "-up", "-OR -OL"], ["OR", "OL"])
        self.assertEqual(hat_rows(rows), [".", "U", ".", "."])
        rows = ER.simulate(["+left", "+OR +OL", "-left", "-OR -OL"], ["OR", "OL"])
        self.assertEqual(hat_rows(rows), ["L", "L", "L", "."], "left held from before stays, as it was before the pair went down")

    def test_the_press_is_read_only_when_the_stored_item_was_not_already_on(self):
        # V11: another item at the press (after a Profile press): that item and the stored one are hidden for the hold
        rows = ER.simulate(["+OR", "+right", "-right", "-OR"], ["OR"], E=[ER.bit(3)] + ER.FACTORY[1:])
        self.assertTrue(rows[1].word & OTHER)
        self.assertEqual(pads(rows), ["hat:.", "hat:.", "hat:.", "hat:."], "Y and right are hidden for the hold")
        rows = ER.simulate(["+OR", "-OR", "+OR", "-OR"], ["OR"], E=[ER.bit(3)] + ER.FACTORY[1:])
        self.assertTrue(rows[1].word & OTHER and rows[3].word & OTHER, "read again at every press")
        rows = ER.simulate(["+OR", "-OR", "E=OR:right", "+OR", "-OR"], ["OR"], E=[ER.bit(3)] + ER.FACTORY[1:])
        self.assertTrue(rows[1].word & OTHER and not rows[4].word & OTHER, "the next hold with the stored item: no OTHER")
        # V12: A held, SAX left + X at the press: X passes at once
        rows = ER.simulate(["+A", "+SL +X", "-X", "-A -SL"], ["SL"])
        self.assertEqual(pads(rows), ["A+hat:.", "A+X+hat:.", "A+hat:.", "hat:."])
        # V13: two keys pressed in one report with stored items the report contradicts: UNCONFIRMED
        rows = ER.simulate(["+OR +OL", ".", "-OR -OL"], ["OR"])
        self.assertTrue(rows[1].word & UNCONF)
        self.assertEqual(hat_rows(rows), [".", ".", "."], "covered only, no direction worked out, no ghost")

    def test_v14_a_reset_at_every_report_of_a_hold_never_shows_the_echo(self):
        for n in range(1, 5):
            reps = ["+OR"] + ["."] * 4 + ["-OR"]
            reps[n] = reps[n] + " reset"
            rows = ER.simulate(reps, ["OR"])
            self.assertEqual(hat_rows(rows), ["."] * 6, n)
            self.assertFalse(rows[n + 1].word & ARMED, "ARMED is clear until a report with no hidden key held")

    def test_v20_a_repeated_report_gives_the_same_state_and_word_except_bits_25_26(self):
        mask = ~(OTHER | UNCONF)
        for H in (0x3F, 0x01, 0x09, 0x3D):
            for (buttons, hat, extra) in [(0, 8, 0), (0, 2, 1), (0b100, 2, 1), (0b100, 8, 0), (3, 6, 0b1001), (0, 8, 0b1001)]:
                e = ER.Echo(H)
                e.step(0, 8, 0)
                w1 = e.step(buttons, hat, extra)
                s1 = e.state_bytes()
                w2 = e.step(buttons, hat, extra)
                self.assertEqual(e.state_bytes(), s1)
                self.assertEqual(w1 & mask, w2 & mask)
                self.assertFalse(w2 & (OTHER | UNCONF))

    def test_the_random_walk_has_no_ghost_under_the_factory_set_and_keeps_its_guarantees(self):
        total = 0
        for H in (0x3F, 0x3D, 0x01, 0x09, 0x10):
            for seed in range(3):
                ghosts, reports, bad_repeat, bad_fresh = ER.walk(seed, 15000, H, resets=bool(seed % 2))
                self.assertEqual(ghosts["factory"], 0, (H, seed))
                self.assertEqual((bad_repeat, bad_fresh), (0, 0), (H, seed))
                total += reports["factory"]
        self.assertGreater(total, 100000)


class V22SlipsTest(unittest.TestCase):
    """Timing slips, synthetic and never measured (S2 saw none): the limits the plan's text pins."""

    def run_frames(self, H, frames):
        e = ER.Echo(H)
        out = []
        for f in frames:
            w = e.step(f.buttons, f.hat, f.extra)
            out.append((w, ER.fmt(ER.word_pad(w, f.buttons, f.hat)).split("hat:")[1]))
        return out

    def test_a_release_lead_of_one_report_shows_the_opposite_direction_for_one_report(self):
        out = self.run_frames(0x01, [frame(), frame(hat=2, extra=1), frame(hat=2, extra=1), frame(hat=8, extra=1), frame(hat=8, extra=0)])
        self.assertEqual([h for _, h in out], [".", ".", ".", "L", "."])
        self.assertTrue(out[3][0] & RECOVERED)

    def test_a_release_lag_of_one_report_shows_the_echo_for_one_report(self):
        out = self.run_frames(0x01, [frame(), frame(hat=2, extra=1), frame(hat=2, extra=0), frame(hat=8, extra=0)])
        self.assertEqual([h for _, h in out], [".", ".", "R", "."])

    def test_a_press_lag_is_unconfirmed_and_never_a_ghost(self):
        out = self.run_frames(0x01, [frame(), frame(hat=8, extra=1), frame(hat=2, extra=1), frame(hat=2, extra=1), frame(hat=8, extra=0)])
        self.assertTrue(out[1][0] & UNCONF)
        self.assertEqual([h for _, h in out], [".", ".", ".", ".", "."])

    def test_a_press_lead_shows_the_echo_for_the_hold(self):
        out = self.run_frames(0x01, [frame(), frame(hat=2, extra=0), frame(hat=2, extra=1), frame(hat=2, extra=1), frame(hat=8, extra=0)])
        self.assertEqual([h for _, h in out], [".", "R", "R", "R", "."])


class V23Test(unittest.TestCase):
    def test_the_table_equals_the_committed_file(self):
        with open(V23_FILE) as f:
            committed = json.load(f)
        self.assertEqual(committed["axis"], ER.v23_table())
        self.assertEqual(committed["already"], ER.v23_already_table())
        self.assertEqual(len(committed["axis"]), 270)
        self.assertEqual(len(committed["already"]), 44)

    def test_no_case_shows_a_ghost(self):
        for label, axis, hidden, untouched, before, pr, during in ER.v23_cases():
            rows = ER.simulate(ER.v23_script(axis, hidden, untouched, before, pr, during), hidden)
            self.assertFalse(any(r.ghost for r in rows), label)
        for label, key, item, change in ER.v23_already_cases():
            first = "+" + item + (" +" + change[1:] if change[0] == "-" else "")
            last = "-" + item + (" -" + change[1:] if change[0] == "+" else "")
            rows = ER.simulate([first, "+" + key + " " + change, ".", "-" + key, last], (key,))
            self.assertFalse(any(r.ghost for r in rows), label)

    def test_with_no_real_direction_the_table_equals_the_ideal(self):
        t = ER.v23_table()
        for label, axis, hidden, untouched, before, pr, during in ER.v23_cases():
            if (before, pr, during) == ("0", "0", "0"):
                rows = ER.simulate(ER.v23_script(axis, hidden, untouched, before, pr, during), hidden)
                self.assertEqual(t[label], "".join(ER._axis_char(r.ideal, axis) for r in rows[1:]), label)

    def test_written_out_rows(self):
        t = ER.v23_table()
        self.assertEqual(t["h:OL:-:+0+"], "++0++0", "right held, let go in the press report, pressed again: shown at once")
        self.assertEqual(t["h:OL:-:+++"], "+++++0", "the cancel against the hidden left is worked out: right stays")
        self.assertEqual(t["h:OL:-:++-"], "+++0-0", "left pressed during the hold (the key's own item): shown at the release")
        self.assertEqual(t["v:IL+IR:-:+++"], "+++++0", "both of a pair hidden: the axis stays as it was")
        self.assertEqual(t["v:IL+IR:-:0++"], "0000" + "+0", "pressed during the hold of the pair: frozen until the release")


class ExhaustiveSearchTest(unittest.TestCase):
    """V25: no ghost with the echoes S2 measured."""

    def test_no_ghost_from_rest_with_up_to_two_changes_per_report(self):
        for H, depth in ((0x01, 4), (0x09, 4), (0x3F, 3)):
            ghosts, states = ER.exhaustive(depth, 2, H)
            self.assertEqual(ghosts, [], (H, ghosts[:3]))
            self.assertGreater(states, 1000)

    def test_the_search_finds_a_ghost_in_a_filter_that_lets_the_echo_through(self):
        class Leaky(ER.Echo):
            def step(self, buttons, hat, extra):
                super().step(buttons, hat, extra)
                return 0                                   # every report passes unchanged, echoes included

        orig = ER.Echo
        ER.Echo = Leaky
        try:
            ghosts, _ = ER.exhaustive(2, 1, 0x01, stop_at_first=True)
        finally:
            ER.Echo = orig
        self.assertTrue(ghosts)
        self.assertIn("+OR", ghosts[0][0][-1])


class FixtureReplayTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.attempts = ER.load_attempts(FIXTURE)
        cls.frames = [[f for _, f in a[3]] for a in cls.attempts]
        with open(FIXTURE) as f:
            cls.fixture = json.load(f)

    def test_the_fixture_has_the_survey_attempts(self):
        self.assertEqual(len(self.attempts), 54)
        self.assertEqual(sum(len(f) for f in self.frames), 789)
        self.assertEqual(self.fixture["storedItems"], ER.FACTORY_CODES)
        self.assertEqual(self.fixture["hideSets"], ER.HIDE_SETS)

    def test_the_stored_words_equal_the_oracle(self):
        for a, frames in zip(self.fixture["attempts"], self.frames):
            self.assertEqual(sorted(a["words"]), sorted(str(h) for h in ER.HIDE_SETS))
            for h in ER.HIDE_SETS:
                self.assertEqual(a["words"][str(h)], ER.run_words(frames, h), (a["stepId"], h))

    def test_zero_wrong_zero_ghosts_zero_ambiguous_under_all_64_masks(self):
        r = ER.replay_all_masks(self.frames)
        self.assertEqual((r["reports"], r["wrong"], r["wrongExcused"], r["ghosts"], r["ambiguous"]), (789, 0, 0, 0, 0))
        self.assertEqual((r["other"], len(r["unconfirmed"])), (0, 0), "no OTHER and no UNCONFIRMED press in the recording")
        self.assertGreater(r["recovered"], 0)

    def test_no_hidden_key_leaves_every_report_unchanged(self):
        r = ER.replay(self.frames, 0)
        self.assertEqual(r["identityBad"], 0)

    def test_the_opposite_cancels_the_plan_names_come_out_as_the_real_direction(self):
        by_n = {}
        for a in self.attempts:
            e = ER.Echo(0x3F)
            for n, f in a[3]:
                w = e.step(f.buttons, f.hat, f.extra)
                by_n[n] = (ER.fmt(ER.word_pad(w, f.buttons, f.hat)).split("hat:")[1], w)
        for n, hat in ((203344, "U"), (234540, "U"), (260104, "L"), (260415, "L")):
            self.assertEqual(by_n[n][0], hat, n)
            self.assertTrue(by_n[n][1] & RECOVERED, n)

    def test_a_repeated_report_changes_neither_state_nor_cleaned_bytes(self):
        mask = ~(OTHER | UNCONF)
        for frames in self.frames:
            e = ER.Echo(0x3F)
            for f in frames:
                w1 = e.step(f.buttons, f.hat, f.extra)
                s1 = e.state_bytes()
                w2 = e.step(f.buttons, f.hat, f.extra)
                self.assertEqual(e.state_bytes(), s1)
                self.assertEqual(w1 & mask, w2 & mask)

    def test_the_replay_catches_a_broken_rule(self):
        class NoCover(ER.Echo):
            def step(self, buttons, hat, extra):
                super().step(buttons, hat, extra)
                return 0
        orig = ER.Echo
        ER.Echo = NoCover
        try:
            r = ER.replay(self.frames, 0x3F)
        finally:
            ER.Echo = orig
        self.assertGreater(r["ghosts"], 0)
        self.assertGreater(r["wrong"], 0)


class TruthModelTest(unittest.TestCase):
    def test_a_cancel_against_a_held_paddle_is_a_real_opposite_direction(self):
        frames = [frame(), frame(hat=6), frame(hat=8, extra=1), frame(hat=6)]            # left held, outer right pressed: none
        real, amb = ER.truth(frames, ER.FACTORY)
        self.assertEqual(real[2], 1 << ER.L)
        self.assertEqual(amb, [0, 0, 0, 0])

    def test_an_unknown_item_that_disagrees_around_it_is_ambiguous(self):
        frames = [frame(), frame(hat=2, extra=1), frame(hat=8, extra=0)]               # right while outer right is held; off after
        self.assertEqual(ER.truth(frames, ER.FACTORY)[1], [0, 0, 0], "off before and after: the run is off")
        frames = [frame(), frame(hat=2, extra=1), frame(hat=2, extra=1), frame(hat=2, extra=0)]
        real, amb = ER.truth(frames, ER.FACTORY)
        self.assertEqual(amb[1:3], [1 << ER.R, 1 << ER.R], "off before, on after: ambiguous for the whole run")
        self.assertEqual(amb[0] | amb[3], 0)


if __name__ == "__main__":
    unittest.main()
