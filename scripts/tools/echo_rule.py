#!/usr/bin/env python3
"""The echo-hiding rule of remap step 2 (docs/plans/remap-step2-plan.md, "Translators: hiding the echo"), as the Python
oracle. It is the reference of `Sources/GDHub/Mapping/EchoFilter.swift` and, from S5, of the C `gdx_echo_next`.
Standard library only.

It holds
  - the rule itself (`Echo`, with the 16-byte state of the plan and the word it returns) and `apply_word`;
  - the truth model of the plan (`truth`, `compare`) and the replay of the rule over recorded attempts (`replay`);
  - a small controller model (`simulate`) for scripted sequences, the V23 table, the V22 slips (see the tests);
  - the ghost check, the exhaustive search of short sequences (V25) and a random walk.

    python3 scripts/tools/echo_rule.py replay RUN_OR_FIXTURE.json     0 wrong, 0 ghosts under all 64 hide masks
    python3 scripts/tools/echo_rule.py exhaust DEPTH MAXCH HIDE...    e.g.  exhaust 4 2 01 09   (hex hide masks)
    python3 scripts/tools/echo_rule.py v23                            the V23 table as JSON

Items, a 14-bit word: bits 0..9 = receiver buttons 1..10 (A B X Y LB RB View Menu L3 R3), bits 10..13 = D-pad up, right,
down, left. An item code c in 1..14 names bit c - 1; 0 = none. Keys (extra bits 0..5): 0 paddle outer right, 1 inner
right, 2 inner left, 3 outer left, 4 SAX left, 5 SAX right."""
import collections
import itertools
import json
import random
import sys

U, R, D, L = 10, 11, 12, 13
AXES = ((U, D), (R, L))                       # (positive, negative): vertical, then horizontal
HAT_ITEMS = [1, 3, 2, 6, 4, 12, 8, 9] + [0] * 8
ITEMS_HAT = [8, 0, 2, 1, 4, 8, 3, 2, 6, 7, 8, 0, 5, 6, 4, 8]
VALID, ARMED = 1, 2
W_RECOVERED, W_OTHER, W_UNCONFIRMED, W_ARMED, W_APPLIED = 1 << 24, 1 << 25, 1 << 26, 1 << 27, 1 << 31
KEYS = ["OR", "IR", "IL", "OL", "SL", "SR"]
KEY_NAMES = ["paddle outer right", "paddle inner right", "paddle inner left", "paddle outer left", "SAX left", "SAX right"]
ITEM_NAMES = ["A", "B", "X", "Y", "LB", "RB", "View", "Menu", "L3", "R3", "D-pad up", "D-pad right", "D-pad down", "D-pad left"]
# What the controller adds for each key as measured in S2 (and the stored items of the factory bindings), as item bits.
FACTORY = [1 << R, 1 << D, 1 << U, 1 << L, 1 << 0, 1 << 1]
FACTORY_CODES = [12, 13, 11, 14, 1, 2]
# The nine hide sets of the fixture: none, all six, row 11's set (all but paddle inner right), each key alone.
HIDE_SETS = [0x00, 0x3F, 0x3D, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20]


def bit(i):
    return 1 << i


def popcount(x):
    return bin(x).count("1")


def code(mask):
    """Item code of a one-item mask (0 for none)."""
    return mask.bit_length()


def items_of(buttons, hat):
    return (buttons & 0x3FF) | HAT_ITEMS[hat & 15] << 10


def axv(items, p, n):
    return (1 if items >> p & 1 else 0) - (1 if items >> n & 1 else 0)


def hat_of(items):
    return ITEMS_HAT[(items >> 10) & 15]


def pad_items(items):
    """What a pad shows for an item set: the buttons, and the hat with opposites cancelled."""
    return (items & 0x3FF) | HAT_ITEMS[hat_of(items)] << 10


def changed(prev, obs):
    """What one press changed (the plan's `changed`): the buttons that came on, and per axis the direction p when the
    axis went from 0 to p, from n to 0 or straight from n to p (n likewise). A release is read backwards:
    changed(report, report before)."""
    c = obs & ~prev & 0x3FF
    for p, n in AXES:
        v0, v1 = axv(prev, p, n), axv(obs, p, n)
        if (v0, v1) in ((0, 1), (-1, 0), (-1, 1)):
            c |= bit(p)
        elif (v0, v1) in ((0, -1), (1, 0), (1, -1)):
            c |= bit(n)
    return c


def axis_of(s):
    return AXES[0] if s & (bit(U) | bit(D)) else AXES[1]


def on_in(items, s):
    """Item s (one item) is on in a raw report: a button by its bit, a direction when the axis reads s's direction."""
    if s & 0x3FF:
        return bool(items & s)
    p, n = axis_of(s)
    return axv(items, p, n) == (1 if s == bit(p) else -1)


def item_text(mask):
    return "+".join(ITEM_NAMES[i] for i in range(14) if mask >> i & 1) or "-"


def fmt(items):
    s = [ITEM_NAMES[i] for i in range(10) if items >> i & 1]
    h = hat_of(items)
    return "+".join(s + ["hat:" + ("." if h >= 8 else "U UR R DR D DL L UL".split()[h])])


Frame = collections.namedtuple("Frame", "buttons hat extra items")


def decode(hexs):
    """A 16-byte report 0x06 as hex text -> Frame (buttons = the 19 button bits, extra = the 13 extra bits)."""
    raw = [int(x, 16) for x in hexs.split()]
    if len(raw) != 16 or raw[0] != 6:
        raise ValueError("not a 16-byte report 0x06: %s" % hexs)
    word = raw[12] | raw[13] << 8 | raw[14] << 16 | raw[15] << 24
    trig = raw[9] | raw[10] << 8 | raw[11] << 16
    hat = (trig >> 20) & 0xF
    buttons = word & 0x7FFFF
    return Frame(buttons, hat, (word >> 19) & 0x1FFF, items_of(buttons, hat))


def apply_word(word, frame):
    """`gdx_echo_apply` / `EchoFilter.apply`: with bit 31 set, buttons 1..10 (byte 12 and bits 0-1 of byte 13) := word
    bits 0..9 and the hat nibble (high nibble of byte 11) := word bits 10..13. A word of 0 gives the bytes unchanged."""
    out = list(frame)
    if word & W_APPLIED:
        out[12] = word & 0xFF
        out[13] = (out[13] & 0xFC) | ((word >> 8) & 3)
        out[11] = (out[11] & 0x0F) | (((word >> 10) & 0xF) << 4)
    return out


# ---------------------------------------------------------------------------------------------------------- the rule

class Echo:
    """`EchoState` + `EchoParams`: H the hide mask, S the stored item (an item mask) of each key in H, 0 outside it."""

    def __init__(self, H, S=None):
        S = list(FACTORY if S is None else S)
        self.H = H & 0x3F
        self.S = [S[k] if self.H >> k & 1 else 0 for k in range(6)]
        self.reset()

    def reset(self):
        self.est = self.prev = 0
        self.held = self.six = self.known = self.flags = 0
        self.cur = [0] * 6               # the item mask read for each held key (the state stores its code)
        self.press = {}                  # key -> "seen" | "other" | "stored" | "unconfirmed" on the last press report

    def clone(self):
        c = Echo.__new__(Echo)
        c.H, c.S = self.H, self.S
        c.est, c.prev, c.held, c.six, c.known, c.flags = self.est, self.prev, self.held, self.six, self.known, self.flags
        c.cur = list(self.cur)
        c.press = {}
        return c

    def state_bytes(self):
        """The 16 bytes of the plan: est, prev (little endian), held, six, known, flags, cur[6], pad[2]."""
        return bytes([self.est & 0xFF, self.est >> 8, self.prev & 0xFF, self.prev >> 8, self.held, self.six, self.known,
                      self.flags] + [code(c) for c in self.cur] + [0, 0])

    def step(self, buttons, hat, extra):
        obs = items_of(buttons, hat)
        six = extra & 0x3F
        held = six & self.H
        self.press = {}
        if not held:
            if self.held:
                self.cur = [0] * 6
            self.est = self.prev = obs
            self.six, self.held, self.known = six, 0, 0
            self.flags = VALID | ARMED
            return 0
        word = 0
        pressed = held & ~self.held
        if pressed:
            mp = 0
            for j in range(6):
                if (held & ~pressed & self.known) >> j & 1 or pressed >> j & 1:
                    mp |= self.S[j]
            one = (self.flags & VALID) and popcount(six ^ self.six) == 1
            c = changed(self.prev, obs) if one else 0
            for k in range(6):
                if not pressed >> k & 1:
                    continue
                s = self.S[k]
                if not on_in(self.prev, s) and popcount(c) == 1:      # the press shows one item
                    self.cur[k] = c
                    if c == s:
                        self.known |= bit(k)
                        self.press[k] = "seen"
                    else:
                        word |= W_OTHER
                        self.press[k] = "other"
                    continue
                self.cur[k] = s                                       # the stored item stands
                ok = bool(obs & s)
                if not ok and not s & 0x3FF:
                    p, n = axis_of(s)
                    ok = axv(obs, p, n) == axv(self.est | mp, p, n)
                if ok:
                    self.known |= bit(k)
                    self.press[k] = "stored"
                else:
                    word |= W_UNCONFIRMED
                    self.press[k] = "unconfirmed"
        self.known &= held
        M = MI = 0
        for k in range(6):
            if held >> k & 1:
                M |= self.S[k] | self.cur[k]
                if self.known >> k & 1:
                    MI |= self.S[k]
        out = (obs & 0x3FF & ~M) | (self.est & 0x3FF & M)
        for p, n in AXES:
            hp, hn = M >> p & 1, M >> n & 1
            if not hp and not hn:
                out |= obs & (bit(p) | bit(n))
            elif hp and hn:
                out |= self.est & (bit(p) | bit(n))
            else:
                a, b = (p, n) if hp else (n, p)
                out |= self.est & bit(a)
                if obs >> b & 1 or (not obs >> a & 1 and MI >> a & 1):
                    out |= bit(b)
                    if not obs >> b & 1:
                        word |= W_RECOVERED
        self.est, self.prev, self.held, self.six = out, obs, held, six
        self.flags |= VALID
        return (word | W_APPLIED | (W_ARMED if self.flags & ARMED else 0) | held << 16 | ITEMS_HAT[(out >> 10) & 15] << 10
                | (out & 0x3FF))


def word_items(word, buttons, hat):
    """The items a word gives for a report (0 = unchanged)."""
    if word == 0:
        return items_of(buttons, hat)
    return (word & 0x3FF) | HAT_ITEMS[(word >> 10) & 15] << 10


def word_pad(word, buttons, hat):
    return pad_items(word_items(word, buttons, hat))


# ------------------------------------------------------------------------------------------------- the truth model

def truth(frames, E):
    """The plan's truth model over one attempt's frames. E = the echo (an item mask) of each key as measured for the
    state. Returns (real, amb, target): the real items per report, the ambiguous items per report, and the target for a
    hide mask via `target_for`."""
    n = len(frames)
    real, unknown, echoed = [0] * n, [0] * n, [0] * n
    for i, f in enumerate(frames):
        held_all = f.extra & 0x3F
        obs = f.items
        e = 0
        for k in range(6):
            if held_all >> k & 1:
                e |= E[k]
        echoed[i] = e
        r, unk = obs & 0x3FF & ~e, e & 0x3FF
        for p, nn in AXES:
            a = axv(obs, p, nn)
            ep, en = bool(e >> p & 1), bool(e >> nn & 1)
            if not ep and not en:
                if a == 1:
                    r |= bit(p)
                if a == -1:
                    r |= bit(nn)
            elif ep and not en:
                unk |= bit(p)
                if a == 0:
                    r |= bit(nn)
            elif en and not ep:
                unk |= bit(nn)
                if a == 0:
                    r |= bit(p)
            else:
                unk |= bit(p) | bit(nn)
        real[i], unknown[i] = r, unk
    amb = [0] * n
    for item in range(14):
        i = 0
        while i < n:
            if not unknown[i] >> item & 1:
                i += 1
                continue
            j = i
            while j < n and unknown[j] >> item & 1:
                j += 1
            before = (real[i - 1] >> item & 1) if i > 0 else 0
            after = (real[j] >> item & 1) if j < n else None
            for t in range(i, j):
                if after is None or after == before:
                    if before:
                        real[t] |= bit(item)
                else:
                    amb[t] |= bit(item)
            i = j
    return real, amb


def target_for(frames, real, E, H):
    """Target = the real items plus the echoes of held keys outside H."""
    out = []
    for i, f in enumerate(frames):
        t = real[i]
        for k in range(6):
            if (f.extra >> k & 1) and not H >> k & 1:
                t |= E[k]
        out.append(t)
    return out


def compare(out, target, amb):
    """True when the pad shows the target, ambiguous items not compared; a direction axis is compared as +1/0/-1."""
    if (out ^ target) & 0x3FF & ~amb:
        return False
    for p, n in AXES:
        if amb & (bit(p) | bit(n)):
            continue
        if axv(out, p, n) != axv(target, p, n):
            return False
    return True


# ------------------------------------------------------------------------------------------------------------ replay

def load_attempts(path):
    """Attempts of a run report (steps[].attempts[].receiver) or of the committed fixture (attempts[]), as
    (stepId, attemptIndex, superseded, [(n, Frame)])."""
    with open(path, "rb") as f:
        data = json.loads(f.read().decode("utf-8"))
    out = []
    if "attempts" in data and "steps" not in data:
        for i, a in enumerate(data["attempts"]):
            out.append((a["stepId"], i, bool(a.get("superseded")), [(r["n"], decode(r["hex"])) for r in a["receiver"]]))
        return out
    for st in data["steps"]:
        for ai, a in enumerate(st.get("attempts", [])):
            rec = a.get("receiver") or []
            if rec:
                out.append((st["stepId"], ai, bool(a.get("superseded")), [(r["n"], decode(r["hex"])) for r in rec]))
    return out


def run_words(frames, H, S=None):
    """Words of the rule over one attempt's frames, from a fresh state."""
    e = Echo(H, S)
    return [e.step(f.buttons, f.hat, f.extra) for f in frames]


def replay(frames_list, H, S=None, E=None):
    """The rule over attempts (each a list of Frame, a fresh state each) against the truth model for hide mask H, the
    stored items S and the measured echoes E (both default to the factory table). Returns the counts and the list of
    unconfirmed presses as (attempt, report, key, keys changed in that report). A report that differs from the target
    inside a hold in which the rule flagged a press UNCONFIRMED is not counted in `wrong` but in `wrongExcused`: the
    rule said it could not read that press, an accepted limit (a direction opposite to a paddle pressed in the very
    same report; two keys of a pair pressed in one report); the unconfirmed press has its own gate line, and a ghost is
    never excused."""
    S = list(FACTORY if S is None else S)
    E = list(FACTORY if E is None else E)
    res = {"reports": 0, "wrong": 0, "wrongExcused": 0, "ghosts": 0, "ambiguous": 0, "recovered": 0, "other": 0,
           "unconfirmed": [], "wrongAt": [], "ghostAt": [], "identityBad": 0}
    for ai, frames in enumerate(frames_list):
        real, amb = truth(frames, E)
        target = target_for(frames, real, E, H)
        e = Echo(H, S)
        hold = 0
        prev_six = 0
        excused = False
        for i, f in enumerate(frames):
            w = e.step(f.buttons, f.hat, f.extra)
            if not f.extra & H:
                excused = False
            elif w & W_UNCONFIRMED:
                excused = True
            out = word_pad(w, f.buttons, f.hat)
            res["reports"] += 1
            res["ambiguous"] += popcount(amb[i])
            if w & W_RECOVERED:
                res["recovered"] += 1
            if w & W_OTHER:
                res["other"] += 1
            if w & W_UNCONFIRMED:
                for k, how in sorted(e.press.items()):
                    if how == "unconfirmed":
                        res["unconfirmed"].append((ai, i, k, popcount((f.extra ^ prev_six) & 0x3F)))
            if H == 0 and (w != 0 or out != pad_items(f.items)):
                res["identityBad"] += 1
            hold = target[i] if not f.extra & H else hold | target[i]
            if out & ~hold:
                res["ghosts"] += 1
                res["ghostAt"].append((ai, i))
            if not compare(out, target[i], amb[i]):
                if excused:                      # the rule said it could not read this press (its own UNCONFIRMED flag)
                    res["wrongExcused"] += 1
                else:
                    res["wrong"] += 1
                    res["wrongAt"].append((ai, i))
            prev_six = f.extra
    return res


def replay_all_masks(frames_list, S=None, E=None):
    """`replay` under all 64 hide masks, summed."""
    tot = {"reports": 0, "wrong": 0, "wrongExcused": 0, "ghosts": 0, "ambiguous": 0, "recovered": 0, "other": 0, "unconfirmed": []}
    for H in range(64):
        r = replay(frames_list, H, S, E)
        for key in ("wrong", "wrongExcused", "ghosts", "ambiguous", "recovered", "other"):
            tot[key] += r[key]
        tot["reports"] = r["reports"]
        tot["unconfirmed"] += [(H,) + u for u in r["unconfirmed"]]
    return tot


# ------------------------------------------------------------------------------------------ the controller model

ITEM_TOKENS = {"A": bit(0), "B": bit(1), "X": bit(2), "Y": bit(3), "LB": bit(4), "RB": bit(5), "View": bit(6),
               "Menu": bit(7), "L3": bit(8), "R3": bit(9), "up": bit(U), "right": bit(R), "down": bit(D), "left": bit(L)}
KEY_INDEX = {k: i for i, k in enumerate(KEYS)}


def controller(real, keys, E):
    """The report the controller sends: buttons ORed, each axis combined with opposites cancelling."""
    s = real
    for k in range(6):
        if keys >> k & 1:
            s |= E[k]
    return s & 0x3FF, hat_of(s), keys


SimRow = collections.namedtuple("SimRow", "rep real keys raw pad ideal hold word buttons hat extra ghost")


def simulate(reports, hidden, S=None, E=None, keep_resets=False):
    """Scripted sequence through the controller model and the rule. `reports` = strings of tokens: '+A' / '-A' real
    items, '+OR' / '-OR' keys, 'reset' (a full reset of the rule before that report), 'E=OR:Y' (the controller now adds
    Y for that key), '.' nothing. `hidden` = key names in the hide mask. The first report is a rest. The ideal pad
    = real + the echoes of held keys outside the hide mask; ghost = a pad item outside the union of the ideal items since
    the report before the hold began."""
    H = sum(bit(KEY_INDEX[k]) for k in hidden)
    e = Echo(H, FACTORY if S is None else S)
    E = list(FACTORY if E is None else E)
    real = keys = hold = 0
    rows = []
    prev_ideal = 0
    for rep in ["rest"] + list(reports):
        for t in rep.split():
            if t in (".", "rest"):
                continue
            if t == "reset":
                if not keep_resets:
                    e.reset()
                continue
            if t.startswith("E="):
                k, it = t[2:].split(":")
                E[KEY_INDEX[k]] = ITEM_TOKENS[it]
                continue
            on, nm = t[0] == "+", t[1:]
            if nm in KEY_INDEX:
                keys = keys | bit(KEY_INDEX[nm]) if on else keys & ~bit(KEY_INDEX[nm])
            else:
                real = real | ITEM_TOKENS[nm] if on else real & ~ITEM_TOKENS[nm]
        btn, hat, ex = controller(real, keys, E)
        w = e.step(btn, hat, ex)
        pad = word_pad(w, btn, hat)
        ideal_raw = real
        for k in range(6):
            if keys >> k & 1 and not H >> k & 1:
                ideal_raw |= E[k]
        ideal = pad_items(ideal_raw)
        if not keys & H:
            hold = ideal_raw
        elif rows and not rows[-1].keys & H:
            hold = prev_ideal | ideal_raw
        else:
            hold |= ideal_raw
        prev_ideal = ideal_raw
        rows.append(SimRow(rep, real, keys, items_of(btn, hat), pad, ideal, hold, w, btn, hat, ex,
                           bool(keys & H) and bool(pad & ~hold)))
    return rows


# ------------------------------------------------------------------------------------------------- the V23 table

V23_AXES = {"v": ("IL", "IR", U, D), "h": ("OR", "OL", R, L)}      # axis: (key adding p, key adding n, p, n)
DIR_TOKEN = {U: "up", R: "right", D: "down", L: "left"}


def _real_token(axis, v):
    _, _, p, n = V23_AXES[axis]
    return DIR_TOKEN[p if v == "+" else n]


def _axis_char(items, axis):
    _, _, p, n = V23_AXES[axis]
    return {1: "+", 0: "0", -1: "-"}[axv(items, p, n)]


def v23_cases():
    """Every case of V23, as (label, axis, hidden keys, untouched key or None, real before the press, real in the press
    report, real during the hold). Per axis: hidden {+, -, both} x untouched {none, the other one} (not for both),
    real before {+, 0, -}, real in the press report {+, 0, -} (unchanged, let go or pressed) and real during the hold
    {+, 0, -}; + is the direction the first key of the axis adds."""
    cases = []
    for axis in ("v", "h"):
        kp, kn, _, _ = V23_AXES[axis]
        combos = [((kp,), None), ((kp,), kn), ((kn,), None), ((kn,), kp), ((kp, kn), None)]
        for hidden, untouched in combos:
            for before, pr, during in itertools.product("+0-", repeat=3):
                label = "%s:%s:%s:%s%s%s" % (axis, "+".join(hidden), untouched or "-", before, pr, during)
                cases.append((label, axis, hidden, untouched, before, pr, during))
    return cases


def _real_change(axis, old, new):
    toks = []
    if old != new:
        if old != "0":
            toks.append("-" + _real_token(axis, old))
        if new != "0":
            toks.append("+" + _real_token(axis, new))
    return " ".join(toks)


def v23_script(axis, hidden, untouched, before, pr, during):
    """The reports of one case (after the rest): the real direction before | the untouched key | the press (the hidden
    keys together, the real direction as in the press report) | during the hold | the hidden keys let go | all let go."""
    on = " ".join("+" + k for k in hidden)
    off = " ".join("-" + k for k in hidden)
    return [_real_change(axis, "0", before) or ".",
            "+" + untouched if untouched else ".",
            (on + " " + _real_change(axis, before, pr)).strip(),
            _real_change(axis, pr, during) or ".",
            off,
            ((("-" + untouched) if untouched else "") + " " + _real_change(axis, during, "0")).strip()]


def v23_table():
    """label -> the pad's value on the axis ('+', '0', '-') in each report from 'real before' to 'all let go'."""
    table = {}
    for label, axis, hidden, untouched, before, pr, during in v23_cases():
        rows = simulate(v23_script(axis, hidden, untouched, before, pr, during), hidden)
        table[label] = "".join(_axis_char(r.pad, axis) for r in rows[1:])
    return table


def v23_already_cases():
    """The key's own item already on, plus one other change in the press report: per key, the factory item held first,
    then the press report with one other change (a different button pressed, or a direction on the other axis pressed or
    let go)."""
    cases = []
    for k, key in enumerate(KEYS):
        item = FACTORY[k]
        name = DIR_TOKEN.get(item.bit_length() - 1) or [t for t, v in ITEM_TOKENS.items() if v == item][0]
        perpendicular = ("left", "right") if item & (bit(U) | bit(D)) else ("up", "down") if item & (bit(L) | bit(R)) else \
            ("up", "right", "down", "left")
        for other in ("X", "Y") + perpendicular:
            cases.append(("%s:%s:+%s" % (key, name, other), key, name, "+" + other))
            if other in DIR_TOKEN.values():
                cases.append(("%s:%s:-%s" % (key, name, other), key, name, "-" + other))
    return cases


def v23_already_table():
    """label -> the pad after each report: item held | the press with the other change | a repeat | the key let go |
    all let go."""
    table = {}
    for label, key, item, change in v23_already_cases():
        other = change[1:]
        first = "+" + item + (" +" + other if change[0] == "-" else "")
        last = "-" + item + (" -" + other if change[0] == "+" else "")
        rows = simulate([first, ("+" + key + " " + change), ".", "-" + key, last], (key,))
        table[label] = " | ".join(fmt(r.pad) for r in rows[1:])
    return table


# ------------------------------------------------------------------------------- the exhaustive search (V25) and walk

OPPOSITE = {bit(U): bit(D), bit(D): bit(U), bit(R): bit(L), bit(L): bit(R)}
SEARCH_REAL = [("up", bit(U)), ("right", bit(R)), ("down", bit(D)), ("left", bit(L)), ("A", bit(0)), ("X", bit(2))]
SEARCH_KEYS = [0, 3, 1, 2, 4]                 # outer right, outer left, inner right, inner left, SAX left


def exhaustive(depth, max_changes, H, echoes=None, stop_at_first=False):
    """Every sequence from rest of `depth` reports; each report changes 1..max_changes of the inputs (the four real D-pad
    directions, never two opposite, A, X, the keys outer right, outer left, inner right, inner left, SAX left). Factory
    stored items; `echoes` = what the controller adds (default factory). Returns the ghosts found as a list of
    (path, pad, hold): a ghost is a pad item outside the union of the ideal items (real items plus the echoes of held
    keys outside the hide set) from the report before the hold began through the hold."""
    E = list(FACTORY if echoes is None else echoes)
    events = [("r", nm, v) for nm, v in SEARCH_REAL] + [("k", KEYS[k], k) for k in SEARCH_KEYS]
    e0 = Echo(H, FACTORY)
    e0.step(0, 8, 0)
    frontier = [(e0, 0, 0, 0, ())]
    seen = set()
    ghosts = []
    states = 0
    for _ in range(depth):
        nxt = []
        for e, real, keys, hold, path in frontier:
            for cnt in range(1, max_changes + 1):
                for mv in itertools.combinations(events, cnt):
                    nreal, nkeys = real, keys
                    for kind, _, v in mv:
                        if kind == "r":
                            nreal ^= v
                        else:
                            nkeys ^= bit(v)
                    if any(nreal & d and nreal & OPPOSITE[d] for d in OPPOSITE):
                        continue
                    btn, hat, ex = controller(nreal, nkeys, E)
                    ne = e.clone()
                    w = ne.step(btn, hat, ex)
                    out = word_pad(w, btn, hat)
                    raw_ideal = nreal
                    for k in range(6):
                        if nkeys >> k & 1 and not H >> k & 1:
                            raw_ideal |= E[k]
                    if not nkeys & H:
                        nhold = raw_ideal
                    elif not keys & H:
                        prev_ideal = real
                        for k in range(6):
                            if keys >> k & 1 and not H >> k & 1:
                                prev_ideal |= E[k]
                        nhold = prev_ideal | raw_ideal
                    else:
                        nhold = hold | raw_ideal
                    label = " ".join(("+" if (nreal if kind == "r" else nkeys) & (v if kind == "r" else bit(v)) else "-") + nm
                                     for kind, nm, v in mv)
                    npath = path + (label,)
                    if nkeys & H and out & ~nhold:
                        ghosts.append((npath, fmt(out), fmt(nhold)))
                        if stop_at_first:
                            return ghosts, states
                    key = (ne.state_bytes(), nreal, nkeys, nhold)
                    if key in seen:
                        continue
                    seen.add(key)
                    states += 1
                    nxt.append((ne, nreal, nkeys, nhold, npath))
        frontier = nxt
    return ghosts, states


WALK_SETS = {"factory": FACTORY,
             "AXYB/RB": [bit(0), bit(2), bit(3), bit(1), bit(5), bit(5)],
             "turned/LB X": [bit(U), bit(L), bit(D), bit(R), bit(4), bit(2)],
             "cleared": [0] * 6}
WALK_DIRS = [0, bit(U), bit(R), bit(D), bit(L), bit(U) | bit(R), bit(R) | bit(D), bit(D) | bit(L), bit(L) | bit(U)]


def walk(seed, steps, H, resets=False, p_two=0.3):
    """Random walk of the controller model (the real D-pad single or diagonal, never two opposite directions; A B X; the
    six keys; about a third of the changes come two in one report; the echo set changes between holds). Returns
    (ghosts per echo set at the hold, reports per echo set, repeat mismatches, no-held-state mismatches)."""
    rnd = random.Random(seed)
    names = list(WALK_SETS)
    cur_set = "factory"
    E = WALK_SETS[cur_set]
    e = Echo(H, FACTORY)
    dpad = btn = keys = hold = 0
    hold_set = cur_set
    ghosts = {n: 0 for n in names}
    reports = {n: 0 for n in names}
    bad_repeat = bad_fresh = 0
    for _ in range(steps):
        n_changes = 0
        if rnd.random() < 0.12:
            n_changes = 2 if rnd.random() < p_two else 1
        prev_held = keys & H
        prev_ideal = dpad | btn
        for k in range(6):
            if keys >> k & 1 and not H >> k & 1:
                prev_ideal |= E[k]
        for _ in range(n_changes):
            c = rnd.random()
            if c < 0.4:
                dpad = rnd.choice(WALK_DIRS)
            elif c < 0.6:
                btn ^= rnd.choice([bit(0), bit(1), bit(2)])
            else:
                keys ^= bit(rnd.randrange(6))
        if n_changes == 0 and keys == 0 and rnd.random() < 0.002:
            cur_set = rnd.choice(names)
            E = WALK_SETS[cur_set]
        if resets and rnd.random() < 0.0005:
            e.reset()
        real = dpad | btn
        b, h, ex = controller(real, keys, E)
        before = e.clone()
        w = e.step(b, h, ex)
        twin = e.clone()
        w2 = twin.step(b, h, ex)                               # the same report again
        if (w2 & (3 << 25)) or (w & ~(3 << 25)) != (w2 & ~(3 << 25)) or twin.state_bytes() != e.state_bytes():
            bad_repeat += 1
        if not keys & H:
            fresh = Echo(H, FACTORY)
            fresh.step(b, h, ex)
            if fresh.state_bytes() != e.state_bytes():
                bad_fresh += 1
        del before
        out = word_pad(w, b, h)
        ideal = real
        for k in range(6):
            if keys >> k & 1 and not H >> k & 1:
                ideal |= E[k]
        if not keys & H:
            hold, hold_set = ideal, cur_set
        elif not prev_held:
            hold, hold_set = prev_ideal | ideal, cur_set
        else:
            hold |= ideal
        reports[hold_set] += 1
        if keys & H and out & ~hold:
            ghosts[hold_set] += 1
    return ghosts, reports, bad_repeat, bad_fresh


# --------------------------------------------------------------------------------------------------------------- CLI

def main(argv):
    if len(argv) >= 2 and argv[0] == "replay":
        atts = load_attempts(argv[1])
        frames_list = [[f for _, f in a[3]] for a in atts]
        r = replay_all_masks(frames_list)
        print("attempts %d, reports %d x 64 masks: wrong %d, ghosts %d, ambiguous %d, recovered %d, other %d, unconfirmed %d" % (
            len(atts), r["reports"], r["wrong"], r["ghosts"], r["ambiguous"], r["recovered"], r["other"], len(r["unconfirmed"])))
        return 0 if r["wrong"] == 0 and r["ghosts"] == 0 else 1
    if len(argv) >= 4 and argv[0] == "exhaust":
        depth, maxch = int(argv[1]), int(argv[2])
        bad = 0
        for hs in argv[3:]:
            ghosts, states = exhaustive(depth, maxch, int(hs, 16))
            print("depth %d, up to %d changes, hide %s: %d states, %d ghosts" % (depth, maxch, hs, states, len(ghosts)))
            for path, pad, hold in ghosts[:5]:
                print("   ghost pad=%s hold=%s | %s" % (pad, hold, " ; ".join(path)))
            bad += len(ghosts)
        return 1 if bad else 0
    if argv and argv[0] == "v23":
        print(json.dumps({"axis": v23_table(), "already": v23_already_table()}, indent=1, sort_keys=True))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
