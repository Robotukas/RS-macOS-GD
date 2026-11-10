#!/usr/bin/env python3
"""Reads the run file of the Developer-mode template "Paddles and SAX: what the controller adds (survey)" (picker row
10, template id echo-survey) and prints what the controller's receiver sent, per key and per Profile block: which extra
bit each key set, which button or D-pad direction the controller added next to it (the "echo"), how many reports after
(or before) the bit that echo came and went, what the hat showed with two keys down, what Profile does during a hold,
and whether an analog field moved. It then checks the gate of remap step 2 (docs/plans/remap-step2-plan.md, "Templates
and checks", row 10) and works out the window W and the grace G the echo filter needs, plus the probe direction and the
picks of row 11. That text is the "S2 result".

    python3 scripts/tools/echo-survey.py RUN.json [RUN.json ...]
    python3 scripts/tools/echo-survey.py --json RUN.json          the same data as JSON
    python3 scripts/tools/echo-survey.py --capture CAPTURE.txt    a hidcap capture (scuf-envision/captures/02-button-walk.txt)

Exit 0: the gate passes. 1: it fails (the reasons are printed). 2: a file cannot be used.

The input: `steps[].attempts[].receiver` = [{n, t, hex}] (docs/protocol/developer-mode-files.md, "Recording the receiver"):
every report 0x06 whose non-stick bytes changed, plus the first of the step. `n` counts reports, so a lag of 0 means the
echo changed in the same report as the key's bit, 1 means the next report, -1 means the echo came one report before.
Standard library only."""
import argparse
import json
import re
import sys
from collections import Counter, namedtuple

# The extra bit each key sets (report 0x06 bytes 12-15, bits 19..31 = extra bits 0..12), the survey's table.
KEYS = [
    ("paddle_outer_right", 0, "Paddle outer right"),
    ("paddle_inner_right", 1, "Paddle inner right"),
    ("paddle_inner_left", 2, "Paddle inner left"),
    ("paddle_outer_left", 3, "Paddle outer left"),
    ("sax_left", 4, "SAX left"),
    ("sax_right", 5, "SAX right"),
]
KEY_MASK = {k: 1 << b for k, b, _ in KEYS}
KEY_LABEL = {k: label for k, _, label in KEYS}
BIT_OWNER = {b: k for k, b, _ in KEYS}

BUTTONS = ["A", "B", "X", "Y", "LB", "RB", "View", "Menu", "L3", "R3", "Start", "G1", "G2", "G3", "G4", "G5", "Profile",
           "Button 18", "Button 19"]
HAT = {0: ("up",), 1: ("up", "right"), 2: ("right",), 3: ("right", "down"), 4: ("down",), 5: ("down", "left"),
       6: ("left",), 7: ("left", "up")}
TRIGGER_ACTIVE = 100            # the receiver value above which a trigger counts as pulled (triggerActiveRaw)
STICK_MOVED = 2000              # an int16 stick value this far from the baseline counts as moved

# Windows in which a change of a standard field is attributed to a key edge (reports before and after the edge).
PRESS_BEFORE, PRESS_AFTER, RELEASE_BEFORE, RELEASE_AFTER = 3, 8, 3, 10
# The gate (plan: row 10, "Gate (S2)").
GATE_LEAD, GATE_PRESS_LAG, GATE_RELEASE_LAG, GATE_REEMERGE_LAG, GATE_PROFILE_LAG = 1, 3, 7, 7, 3
W_MAX, G_MAX = 4, 8

Frame = namedtuple("Frame", "n t raw extra hat buttons lt rt sticks items")


class SurveyError(Exception):
    pass


def decode(n, t, raw):
    if len(raw) != 16 or raw[0] != 6:
        raise SurveyError("report %s is not a 16-byte report 0x06: %s" % (n, " ".join("%02x" % b for b in raw)))
    word = raw[12] | raw[13] << 8 | raw[14] << 16 | raw[15] << 24
    trig = raw[9] | raw[10] << 8 | raw[11] << 16
    lt, rt, hat = trig & 0x3FF, (trig >> 10) & 0x3FF, (trig >> 20) & 0xF
    buttons, extra = word & 0x7FFFF, (word >> 19) & 0x1FFF
    items = {BUTTONS[i] for i in range(19) if buttons >> i & 1}
    items |= {"D-pad " + d for d in HAT.get(hat, ())}
    if lt > TRIGGER_ACTIVE:
        items.add("LT")
    if rt > TRIGGER_ACTIVE:
        items.add("RT")
    sticks = tuple(int.from_bytes(bytes(raw[1 + 2 * i:3 + 2 * i]), "little", signed=True) for i in range(4))
    return Frame(n, t, tuple(raw), extra, hat, buttons, lt, rt, sticks, frozenset(items))


def decode_hex(entry):
    try:
        raw = [int(x, 16) for x in str(entry["hex"]).split()]
        return decode(int(entry["n"]), float(entry.get("t", 0)), raw)
    except (KeyError, ValueError, TypeError) as e:
        raise SurveyError("a receiver entry cannot be read (%s): %r" % (e, entry))


# ----------------------------------------------------------------------------------------------------------------- input

def load_run(path):
    try:
        with open(path, "rb") as f:
            data = json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError) as e:
        raise SurveyError("%s: cannot read (%s)" % (path, e))
    if not isinstance(data, dict) or "steps" not in data:
        raise SurveyError("%s: not a run report" % path)
    steps = []
    for st in data["steps"]:
        attempts = [a for a in st.get("attempts", []) if not a.get("superseded")] or st.get("attempts", [])
        att = attempts[-1] if attempts else {}
        rec = att.get("receiver")
        if rec is None:
            continue
        steps.append({"stepId": st.get("stepId", ""), "controls": st.get("controls", []), "kind": st.get("kind", ""),
                      "verdict": (att.get("verdict") or {}).get("verdict", ""), "frames": [decode_hex(e) for e in rec],
                      "dropped": att.get("receiverDropped", 0)})
    if not steps:
        raise SurveyError("%s: no step has a `receiver` list; run the echo-survey template (picker row 10)" % path)
    return steps


def capture_steps(path):
    """A hidcap text capture (`... id=0x06 len=16 (+N identical before): <hex>`) as one step over the six keys, with the
    report index kept from the "identical before" counts. Only reports whose non-stick bytes changed are kept."""
    pat = re.compile(r"id=0x06 len=16(?: \(\+(\d+) identical before\))?: ([0-9a-fA-F ]+)$")
    frames, prev, n = [], None, -1
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError as e:
        raise SurveyError("%s: cannot read (%s)" % (path, e))
    for line in lines:
        m = pat.search(line.strip())
        if not m:
            continue
        n += (int(m.group(1)) if m.group(1) else 0) + 1
        raw = [int(x, 16) for x in m.group(2).split()]
        if len(raw) != 16:
            continue
        if prev is None or raw[9:] != prev[9:]:
            frames.append(decode(n, n / 1000.0, raw))
        prev = raw
    if not frames:
        raise SurveyError("%s: no report 0x06 found" % path)
    return [{"stepId": "capture", "controls": [k for k, _, _ in KEYS], "kind": "record", "verdict": "recorded",
             "frames": frames, "dropped": 0}]


# -------------------------------------------------------------------------------------------------------- one step

def edges(frames, mask):
    """Indexes (into `frames`) where the bits of `mask` all became set / not all set."""
    rises, falls, was = [], [], frames[0].extra & mask == mask if frames else False
    for i, f in enumerate(frames):
        on = f.extra & mask == mask
        if on and not was:
            rises.append(i)
        elif was and not on:
            falls.append(i)
        was = on
    return rises, falls


def item_changes(frames, i):
    """(rose, fell) standard items at entry i, against the entry before."""
    prev = frames[i - 1].items if i > 0 else frozenset()
    return frames[i].items - prev, prev - frames[i].items


def analyse_key(frames, key, bits_seen):
    """Every press of `key` in this step with what the controller added next to it."""
    mask = KEY_MASK[key]
    if not any(f.extra & mask for f in frames) and len(bits_seen) == 1:
        mask = next(iter(bits_seen))            # the table is wrong for this key: follow the bit that was seen
    rises, falls = edges(frames, mask)
    presses = []
    for k, r in enumerate(rises):
        fall = next((f for f in falls if f > r), None)
        n_r = frames[r].n
        n_f = frames[fall].n if fall is not None else None
        # echo items: those that came on within the window around the rise and were not on before it
        echo = {}
        for j in range(len(frames)):
            if frames[j].n < n_r - PRESS_BEFORE or frames[j].n > n_r + PRESS_AFTER or j == 0:
                continue
            rose, _ = item_changes(frames, j)
            for item in rose:
                echo.setdefault(item, {"item": item, "pressLag": frames[j].n - n_r, "releaseLag": None})
        for item, e in echo.items():
            if n_f is None:
                continue
            for j in range(1, len(frames)):
                if n_f - RELEASE_BEFORE <= frames[j].n <= n_f + RELEASE_AFTER and item in item_changes(frames, j)[1]:
                    e["releaseLag"] = frames[j].n - n_f
                    break
        rose_bits = [b for b in range(13) if (frames[r].extra & ~(frames[r - 1].extra if r else 0)) >> b & 1]
        presses.append({"key": key, "riseN": n_r, "fallN": n_f, "bitsAtRise": rose_bits, "echo": sorted(echo.values(), key=lambda e: e["item"])})
    return presses


def analyse_step(step):
    frames = step["frames"]
    controls = step["controls"]
    sid = step["stepId"]
    keys = [c for c in controls if c in KEY_MASK]
    bits_seen = set()
    for i in range(1, len(frames)):
        for b in range(13):
            if frames[i].extra >> b & 1 and not frames[i - 1].extra >> b & 1:
                bits_seen.add(1 << b)
    out = {"stepId": sid, "controls": controls, "frames": len(frames), "dropped": step.get("dropped", 0),
           "bitsSeen": sorted(b.bit_length() - 1 for b in bits_seen), "presses": [], "notes": []}
    for key in keys:
        out["presses"] += analyse_key(frames, key, bits_seen)
    # hat and standard items by which keys are down
    combos = {}
    for f in frames:
        down = tuple(sorted(BIT_OWNER.get(b, "bit%d" % b) for b in range(13) if f.extra >> b & 1))
        combos.setdefault(down, set()).add(f.hat)
    out["hatByKeysDown"] = {"+".join(k) or "none": sorted(v) for k, v in sorted(combos.items())}
    base = frames[0]
    out["analog"] = {"lt": max(f.lt for f in frames), "rt": max(f.rt for f in frames)}
    out["analogMoved"] = any(f.lt != base.lt or f.rt != base.rt for f in frames)
    out["stickMoved"] = any(abs(a - b) > STICK_MOVED for f in frames for a, b in zip(f.sticks, base.sticks))
    out["items"] = sorted({it for f in frames for it in f.items})
    out["reemergence"] = reemergence(frames, keys, out["presses"]) if len(keys) == 2 and sid.startswith("outer-right-") else []
    out["profileEdges"] = profile_edges(frames, keys, out["presses"]) if "profile" in controls else []
    out["realDirection"] = real_direction(frames, sid, out["presses"])
    return out


def reemergence(frames, keys, presses):
    """Two keys, the first held and the second pressed: after the second is let go, how many reports until the first
    key's own echo is back. lag None = it never went away (or never came back in the file); negative = it was back
    before the second key's release."""
    held, other = [p for p in presses if p["key"] == keys[0]], [p for p in presses if p["key"] == keys[1]]
    if not held or not held[0]["echo"]:
        return []
    echo = {e["item"] for e in held[0]["echo"]}
    result = []
    for p in other:
        if p["fallN"] is None:
            continue
        gone = next((f for f in frames if p["riseN"] <= f.n <= p["fallN"] and not echo <= f.items), None)
        back = next((f for f in frames if gone is not None and f.n > gone.n and echo <= f.items), None)
        result.append({"key": keys[0], "pressedKey": keys[1], "echoDropped": gone is not None,
                       "lag": None if back is None else back.n - p["fallN"]})
    return result


def profile_edges(frames, keys, presses):
    """Profile pressed or let go while the key is held: how many reports until anything else changed (None = not until
    the key was let go)."""
    key_press = next((p for p in presses if p["fallN"] is not None), None)
    if key_press is None:
        return []
    out = []
    for i in range(1, len(frames)):
        rose, fell = item_changes(frames, i)
        if "Profile" in rose or "Profile" in fell:
            n_edge = frames[i].n
            if not key_press["riseN"] <= n_edge < key_press["fallN"]:
                continue
            change = None
            for j in range(i, len(frames)):
                if frames[j].n >= key_press["fallN"]:
                    break
                r, f = item_changes(frames, j)
                other = (r | f) - {"Profile"}
                if other and frames[j].n >= n_edge:
                    change = {"lag": frames[j].n - n_edge, "rose": sorted(r - {"Profile"}), "fell": sorted(f - {"Profile"})}
                    break
            out.append({"edge": "pressed" if "Profile" in rose else "let go", "n": n_edge, "change": change})
    return out


REAL = {"up-held-": "D-pad up", "outer-right-dpad-up": "D-pad up", "outer-right-dpad-left": "D-pad left"}


def real_direction(frames, sid, presses):
    """Whether a real D-pad direction the owner holds or presses while a paddle is held reached the hat. For
    `up-held-*` the direction must stay on for the whole time the paddle is down; for the two blocks that press a
    direction twice it must come on twice while the paddle is held."""
    if not presses:
        return None
    if sid.startswith("up-held-"):
        p = presses[0]
        if p["fallN"] is None:
            return None
        before = [f for f in frames if f.n < p["riseN"]]
        if not before or "D-pad up" not in before[-1].items:
            return {"checked": "D-pad up held", "ok": None, "why": "D-pad up was not on before the key went down"}
        dropped = [f.n for f in frames if p["riseN"] <= f.n < p["fallN"] and "D-pad up" not in f.items]
        return {"checked": "D-pad up held", "ok": not dropped, "why": "" if not dropped else "D-pad up dropped at report %d while the key was down" % dropped[0]}
    for prefix, item in (("outer-right-dpad-up", "D-pad up"), ("outer-right-dpad-left", "D-pad left")):
        if sid == prefix:
            p = presses[0]
            if p["fallN"] is None:
                return None
            ons = sum(1 for i in range(1, len(frames))
                      if p["riseN"] <= frames[i].n < p["fallN"] and item in item_changes(frames, i)[0])
            return {"checked": item + " pressed twice", "ok": ons >= 2, "why": "" if ons >= 2 else "%s came on %d time(s) while the key was held (needs 2)" % (item, ons)}
    return None


# --------------------------------------------------------------------------------------------------------- the survey

def profile_of(sid):
    m = re.match(r"profile-(\d+)-", sid)
    return int(m.group(1)) if m else 0


def survey(steps):
    results = [analyse_step(s) for s in steps]
    per_profile = {}
    worst = {"pressLag": 0, "releaseLag": 0, "lead": 0, "reemergence": 0, "profileEdge": 0}
    edges_total = edges_same = 0
    for r in results:
        for p in r["presses"]:
            if p["fallN"] is not None:
                edges_total += 2
            else:
                edges_total += 1
            echo_items = [e["item"] for e in p["echo"]]
            if echo_items and all(e["pressLag"] == 0 for e in p["echo"]):
                edges_same += 1
            if p["fallN"] is not None and echo_items and all(e["releaseLag"] == 0 for e in p["echo"]):
                edges_same += 1
            for e in p["echo"]:
                if e["pressLag"] >= 0:
                    worst["pressLag"] = max(worst["pressLag"], e["pressLag"])
                else:
                    worst["lead"] = max(worst["lead"], -e["pressLag"])
                if e["releaseLag"] is not None:
                    worst["releaseLag"] = max(worst["releaseLag"], e["releaseLag"])
        for x in r["reemergence"]:
            if x["lag"] is not None:
                worst["reemergence"] = max(worst["reemergence"], x["lag"])
        for x in r["profileEdges"]:
            if x["change"]:
                worst["profileEdge"] = max(worst["profileEdge"], x["change"]["lag"])
        if r["stepId"].startswith("alone-") or re.match(r"profile-\d+-", r["stepId"]) or r["stepId"] == "capture":
            for p in r["presses"]:
                per_profile.setdefault(profile_of(r["stepId"]), {}).setdefault(p["key"], Counter())[tuple(e["item"] for e in p["echo"])] += 1
    w = max(1, max(worst["pressLag"], worst["profileEdge"]) + 1)
    g = max(1, max(worst["releaseLag"], worst["reemergence"]) + 1)
    gate = check_gate(results, worst, w, g)
    echoes = {str(prof): {key: [{"echo": list(items), "presses": n} for items, n in c.most_common()] for key, c in keys.items()}
              for prof, keys in sorted(per_profile.items())}
    return {"steps": results, "echoByProfile": echoes, "edges": {"total": edges_total, "sameReport": edges_same},
            "worst": worst, "W": w, "G": g, "gate": gate, "row11": row11(per_profile, results)}


def check_gate(results, worst, w, g):
    checks = []

    def add(name, ok, detail=""):
        checks.append({"check": name, "ok": ok, "detail": detail})

    for r in results:
        sid = r["stepId"]
        alone = sid.startswith("alone-") or re.match(r"profile-\d+-", sid)
        if alone and len(r["controls"]) == 1 and r["controls"][0] in KEY_MASK:
            key = r["controls"][0]
            table = KEY_MASK[key].bit_length() - 1
            ok = r["bitsSeen"] == [table]
            add("%s: exactly one extra bit, the table's" % sid, ok,
                "" if ok else "saw extra bits %s, the table says %d" % (r["bitsSeen"] or "none", table))
            if r["stickMoved"]:
                add("%s: no echo on a stick" % sid, False, "a stick value moved while only a key was pressed")
            if not r["presses"]:
                add("%s: the key was pressed" % sid, False, "no press of the key was recorded")
    leads = [(r["stepId"], p["key"], e["item"], e["pressLag"]) for r in results for p in r["presses"] for e in p["echo"] if e["pressLag"] < -GATE_LEAD]
    add("an echo comes at most %d report before its bit" % GATE_LEAD, not leads, "; ".join("%s %s %s %d" % x for x in leads[:3]))
    late = [(r["stepId"], p["key"], e["item"], e["pressLag"]) for r in results for p in r["presses"] for e in p["echo"] if e["pressLag"] > GATE_PRESS_LAG]
    add("an echo comes at most %d reports after its bit" % GATE_PRESS_LAG, not late, "; ".join("%s %s %s +%d" % x for x in late[:3]))
    rel = [(r["stepId"], p["key"], e["item"], e["releaseLag"]) for r in results for p in r["presses"] for e in p["echo"]
           if e["releaseLag"] is not None and e["releaseLag"] > GATE_RELEASE_LAG]
    add("an echo goes at most %d reports after the key's release" % GATE_RELEASE_LAG, not rel, "; ".join("%s %s %s +%d" % x for x in rel[:3]))
    stuck = [(r["stepId"], p["key"], e["item"]) for r in results if r["stepId"].startswith(("alone-", "profile-")) and "block" not in r["stepId"]
             for p in r["presses"] if p["fallN"] is not None for e in p["echo"] if e["releaseLag"] is None]
    add("every echo of a key pressed alone goes again with the key", not stuck, "; ".join("%s %s %s" % x for x in stuck[:3]))
    re_bad = [(r["stepId"], x["lag"]) for r in results for x in r["reemergence"] if x["lag"] is not None and x["lag"] > GATE_REEMERGE_LAG]
    add("the remaining key's direction comes back at most %d reports after the release" % GATE_REEMERGE_LAG, not re_bad, "; ".join("%s +%d" % x for x in re_bad[:3]))
    real_bad = [(r["stepId"], r["realDirection"]["why"]) for r in results if r["realDirection"] and r["realDirection"]["ok"] is False]
    add("the hat never drops a real direction while a paddle is held", not real_bad, "; ".join("%s: %s" % x for x in real_bad[:3]))
    prof_bad = [(r["stepId"], x["edge"], x["change"]["lag"]) for r in results for x in r["profileEdges"] if x["change"] and x["change"]["lag"] > GATE_PROFILE_LAG]
    add("after a Profile edge during a hold the echo changes within %d reports or not until release" % GATE_PROFILE_LAG, not prof_bad,
        "; ".join("%s Profile %s +%d" % x for x in prof_bad[:3]))
    add("W stays within 0..4 and G within 0..8", w <= W_MAX and g <= G_MAX, "W would be %d, G %d" % (w, g))
    dropped = [r["stepId"] for r in results if r["dropped"]]
    add("no step lost reports to the cap", not dropped, ", ".join(dropped[:3]))
    return {"pass": all(c["ok"] for c in checks), "checks": checks,
            "review": "Combinations and hat values by keys down are listed per step: read them against the echo cases E1-E29; "
                      "this tool cannot decide that part of the gate."}


ROW11_PICKS = {"paddle_outer_right": "R3", "paddle_outer_left": "L3", "paddle_inner_left": "Nothing", "sax_left": "View", "sax_right": "Menu"}
DIRECTIONS = ["D-pad up", "D-pad right", "D-pad down", "D-pad left"]


def row11(per_profile, results):
    seen = {}
    for prof, keys in per_profile.items():
        for key, c in keys.items():
            for items in c:
                seen.setdefault(key, set()).update(items)
    outer_right = seen.get("paddle_outer_right", set())
    probe = next((d for d in DIRECTIONS if d not in outer_right), None)
    every = set().union(*seen.values()) if seen else set()
    clash = sorted(p for p in set(ROW11_PICKS.values()) - {"Nothing"} if p in every)
    return {"probeDirection": probe or "none (outer right's echo covers every direction)",
            "everyEchoSeen": sorted(every), "picks": ROW11_PICKS,
            "picksInsideAnEcho": clash, "picksOk": not clash and probe is not None}


# ------------------------------------------------------------------------------------------------------------- output

def lag_text(v):
    return "-" if v is None else ("same report" if v == 0 else ("%+d" % v))


def render(res):
    out = []
    out.append("ECHO SURVEY (%d steps with receiver reports)" % len(res["steps"]))
    out.append("")
    out.append("Echo per key and profile (profile 0 = the one you started on; N = after Profile block N):")
    for prof, keys in res["echoByProfile"].items():
        out.append("  profile %s" % prof)
        for key, label in ((k, l) for k, _, l in KEYS):
            if key in keys:
                parts = ["%s x%d" % ("+".join(x["echo"]) or "nothing", x["presses"]) for x in keys[key]]
                out.append("    %-20s extra bit %d  echo: %s" % (label, KEY_MASK[key].bit_length() - 1, "; ".join(parts)))
    out.append("")
    out.append("Key edges: %d, of which the echo changed in the same report: %d" % (res["edges"]["total"], res["edges"]["sameReport"]))
    out.append("")
    for r in res["steps"]:
        out.append("[%s] controls %s, %d reports kept%s" % (r["stepId"], ", ".join(r["controls"]), r["frames"], ", %d dropped" % r["dropped"] if r["dropped"] else ""))
        out.append("    extra bits that came on: %s" % (", ".join(str(b) for b in r["bitsSeen"]) or "none"))
        for i, p in enumerate(r["presses"], 1):
            echo = ", ".join("%s (press %s, release %s)" % (e["item"], lag_text(e["pressLag"]), lag_text(e["releaseLag"])) for e in p["echo"]) or "no new button or direction"
            out.append("    %s press %d at report %d: %s" % (KEY_LABEL[p["key"]], i, p["riseN"], echo))
        for combo, hats in r["hatByKeysDown"].items():
            if "+" in combo or r["stepId"].startswith(("outer-right-", "up-held-", "together-", "a-held-", "sax-left-held-")):
                out.append("    hat with %s down: %s" % (combo, ", ".join(str(h) for h in hats)))
        for x in r["reemergence"]:
            out.append("    after %s is let go the held key's direction %s (lag %s)" % (KEY_LABEL.get(x["pressedKey"], x["pressedKey"]),
                       "dropped and came back" if x["echoDropped"] else "never went away", lag_text(x["lag"])))
        for x in r["profileEdges"]:
            ch = x["change"]
            out.append("    Profile %s at report %d: %s" % (x["edge"], x["n"], "nothing else changed until the key was let go" if not ch else
                       "echo changed after %s report(s): on %s, off %s" % (ch["lag"], ", ".join(ch["rose"]) or "-", ", ".join(ch["fell"]) or "-")))
        if r["realDirection"]:
            rd = r["realDirection"]
            out.append("    real direction (%s): %s" % (rd["checked"], {True: "reached the hat", False: "LOST: " + rd["why"], None: "not checked: " + rd["why"]}[rd["ok"]]))
        if r["analogMoved"]:
            out.append("    an analog field moved: LT up to %d, RT up to %d" % (r["analog"]["lt"], r["analog"]["rt"]))
        if r["stickMoved"]:
            out.append("    a stick value moved during this step")
    out.append("")
    w = res["worst"]
    out.append("Worst measured: press lag %d, release lag %d, lead %d, return of the held key's direction %d, Profile-edge lag %d reports" %
               (w["pressLag"], w["releaseLag"], w["lead"], w["reemergence"], w["profileEdge"]))
    out.append("Chosen: W = %d (worst press or Profile-edge lag + 1, at least 1), G = %d (worst release or return lag + 1, at least 1), S = 0x01F803FF" % (res["W"], res["G"]))
    r11 = res["row11"]
    out.append("Row 11 probe direction: %s. Picks %s: %s" % (r11["probeDirection"], ", ".join("%s -> %s" % kv for kv in r11["picks"].items()),
               "outside every echo seen" if r11["picksOk"] else "CHECK: inside an echo seen: %s" % ", ".join(r11["picksInsideAnEcho"] or ["(no probe direction)"])))
    out.append("")
    out.append("GATE: %s" % ("PASS" if res["gate"]["pass"] else "FAIL"))
    for c in res["gate"]["checks"]:
        out.append("  [%s] %s%s" % ("ok" if c["ok"] else "FAIL", c["check"], "" if c["ok"] or not c["detail"] else ": " + c["detail"]))
    out.append("  " + res["gate"]["review"])
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Read the echo-survey run file(s).")
    ap.add_argument("files", nargs="*", help="run report(s) written by the echo-survey template")
    ap.add_argument("--capture", help="a hidcap text capture instead of a run report")
    ap.add_argument("--json", action="store_true", help="print JSON instead of text")
    args = ap.parse_args(argv)
    try:
        steps = []
        for path in args.files:
            steps += load_run(path)
        if args.capture:
            steps += capture_steps(args.capture)
        if not steps:
            ap.error("give a run report or --capture")
        res = survey(steps)
    except SurveyError as e:
        print("echo-survey: %s" % e, file=sys.stderr)
        return 2
    print(json.dumps(res, indent=2, sort_keys=True) if args.json else render(res))
    return 0 if res["gate"]["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
