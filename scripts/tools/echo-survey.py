#!/usr/bin/env python3
"""Reads the run file of the Developer-mode template "Paddles and SAX: what the controller adds (survey)" (picker row
10, template id echo-survey) and prints what the controller's receiver sent, per key and per Profile block: which extra
bit each key set, which button or D-pad direction the controller added next to it (the "echo"), what the hat showed with
two keys down, what Profile does during a hold, and whether an analog field moved. It then checks the gate of remap
step 2 (docs/plans/remap-step2-plan.md, "Templates and checks", row 10, "Gate from v3 on"), replays the echo rule
(scripts/tools/echo_rule.py) over every attempt under all 64 hide masks, and checks the probe direction and the picks of
row 11. That text is the "S2 result".

    python3 scripts/tools/echo-survey.py RUN.json [RUN.json ...]
    python3 scripts/tools/echo-survey.py --json RUN.json          the same data as JSON
    python3 scripts/tools/echo-survey.py --capture CAPTURE.txt    a hidcap capture (scuf-envision/captures/02-button-walk.txt)

Exit 0: the gate passes. 1: it fails (the reasons are printed, each naming its step and attempt). 2: a file cannot be used.

The input: `steps[].attempts[].receiver` = [{n, t, hex}] (docs/protocol/developer-mode-files.md, "Recording the receiver"):
every report 0x06 whose non-stick bytes changed, plus the first of the step. `n` counts reports. Every attempt is read,
superseded ones included, each from a fresh state. A change of an item belongs to a key only in that key's own edge
report (the report where its extra bit changed) and only when no other of the six keys changed in that report; a cancel
counts as the opposite direction (the oracle's `changed`; a release is read backwards, what it took away). Standard
library only."""
import argparse
import importlib.util
import json
import os
import re
import sys
from collections import Counter, namedtuple

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("echo_rule", os.path.join(_HERE, "echo_rule.py"))
ER = importlib.util.module_from_spec(_spec)
sys.modules.setdefault("echo_rule", ER)
_spec.loader.exec_module(ER)

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
KEY_INDEX = {k: b for k, b, _ in KEYS}
SIX = 0x3F

BUTTONS = ["A", "B", "X", "Y", "LB", "RB", "View", "Menu", "L3", "R3", "Start", "G1", "G2", "G3", "G4", "G5", "Profile",
           "Button 18", "Button 19"]
HAT = {0: ("up",), 1: ("up", "right"), 2: ("right",), 3: ("right", "down"), 4: ("down",), 5: ("down", "left"),
       6: ("left",), 7: ("left", "up")}
TRIGGER_ACTIVE = 100            # the receiver value above which a trigger counts as pulled (triggerActiveRaw)
STICK_MOVED = 2000              # an int16 stick value this far from the baseline counts as moved

# Windows in which a change in another report is listed as "other change, N reports from <key>".
PRESS_BEFORE, PRESS_AFTER, RELEASE_BEFORE, RELEASE_AFTER = 3, 8, 3, 10
# The gate (plan: row 10, "Gate from v3 on"): an echo that was already on counts for at least this many reports.
ALREADY_ON_REPORTS = 8

Frame = namedtuple("Frame", "n t raw extra hat buttons lt rt sticks items mask")


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
    return Frame(n, t, tuple(raw), extra, hat, buttons, lt, rt, sticks, frozenset(items), ER.items_of(buttons, hat))


def decode_hex(entry):
    try:
        raw = [int(x, 16) for x in str(entry["hex"]).split()]
        return decode(int(entry["n"]), float(entry.get("t", 0)), raw)
    except (KeyError, ValueError, TypeError) as e:
        raise SurveyError("a receiver entry cannot be read (%s): %r" % (e, entry))


# ----------------------------------------------------------------------------------------------------------------- input

def load_run(path):
    """Every attempt that has receiver reports, superseded ones included, as one entry each (`attempt` = its index in
    the step). Also reads the committed fixture `Tests/GDHubTests/Fixtures/echo-survey-s2.json` (scripts/tools/echo-fixture.py),
    which lists the trimmed attempts directly."""
    try:
        with open(path, "rb") as f:
            data = json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError) as e:
        raise SurveyError("%s: cannot read (%s)" % (path, e))
    if isinstance(data, dict) and isinstance(data.get("attempts"), list) and "steps" not in data:
        items = []
        seen = Counter()
        for a in data["attempts"]:
            sid = a.get("stepId", "")
            items.append((sid, a.get("controls", []), seen[sid], a))
            seen[sid] += 1
    elif isinstance(data, dict) and "steps" in data:
        items = [(st.get("stepId", ""), st.get("controls", []), ai, att) for st in data["steps"]
                 for ai, att in enumerate(st.get("attempts", []))]
    else:
        raise SurveyError("%s: not a run report" % path)
    steps = []
    for sid, controls, ai, att in items:
        rec = att.get("receiver")
        if not rec:
            continue
        steps.append({"stepId": sid, "controls": controls, "kind": "record", "attempt": ai, "superseded": bool(att.get("superseded")),
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
             "attempt": 0, "superseded": False, "frames": frames, "dropped": 0}]


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


def mask_names(m):
    return [ER.ITEM_NAMES[i] for i in range(14) if m >> i & 1]


def other_changes(a, b):
    """What changed between two reports besides the 14 items and the extra bits: Start, a G key, Profile, buttons 18-19, a
    trigger crossing the active level, a stick moving."""
    names = [BUTTONS[i] for i in range(10, 19) if (a.buttons ^ b.buttons) >> i & 1]
    if (a.lt > TRIGGER_ACTIVE) != (b.lt > TRIGGER_ACTIVE):
        names.append("LT")
    if (a.rt > TRIGGER_ACTIVE) != (b.rt > TRIGGER_ACTIVE):
        names.append("RT")
    if any(abs(x - y) > STICK_MOVED for x, y in zip(a.sticks, b.sticks)):
        names.append("stick")
    return names


def six_edges(frames, owner):
    """Every report where the extra bit of one of the six keys changed (`owner`: bit -> key). With exactly one key
    changed (`shared` False) the items it changed in that report are read: on a press what came on, on a release what it
    took away, a cancel counted as the opposite direction."""
    result = []
    for i in range(1, len(frames)):
        d = (frames[i].extra ^ frames[i - 1].extra) & sum(1 << b for b in owner)
        if not d:
            continue
        bits = [b for b in sorted(owner) if d >> b & 1]
        prev, cur = frames[i - 1], frames[i]
        e = {"i": i, "n": cur.n, "keys": [owner[b] for b in bits], "shared": len(bits) > 1}
        if len(bits) == 1:
            rise = bool(cur.extra >> bits[0] & 1)
            ch = ER.changed(prev.mask, cur.mask) if rise else ER.changed(cur.mask, prev.mask)
            e.update(key=owner[bits[0]], kind="rise" if rise else "fall", mask=ch, changed=mask_names(ch),
                     others=other_changes(prev, cur))
        result.append(e)
    return result


def is_alone(sid, controls):
    return (sid.startswith("alone-") or re.match(r"profile-\d+-", sid) is not None) and len(controls) == 1 and controls[0] in KEY_MASK


def profile_of(sid):
    m = re.match(r"profile-(\d+)-", sid)
    return int(m.group(1)) if m else 0


def analyse_step(step):
    """One attempt of one step."""
    frames = step["frames"]
    controls = step["controls"]
    sid = step["stepId"]
    keys = [c for c in controls if c in KEY_MASK]
    bits_seen = set()
    for i in range(1, len(frames)):
        for b in range(13):
            if frames[i].extra >> b & 1 and not frames[i - 1].extra >> b & 1:
                bits_seen.add(b)
    owner = dict(BIT_OWNER)
    key_bit = {k: KEY_INDEX[k] for k in keys}
    for k in keys:      # the table may be wrong for this key: follow the one bit that was seen (not in a redone attempt: a slip)
        if KEY_INDEX[k] not in bits_seen and len(bits_seen) == 1 and not step.get("superseded"):
            key_bit[k] = next(iter(bits_seen))
            owner[key_bit[k]] = k
    alone = is_alone(sid, controls)
    touched = []
    if alone:
        for b in sorted(bits_seen):
            if b != key_bit[keys[0]] and b in BIT_OWNER:
                count = sum(1 for i in range(1, len(frames)) if frames[i].extra >> b & 1 and not frames[i - 1].extra >> b & 1)
                touched.append({"key": BIT_OWNER[b], "count": count})
    six = six_edges(frames, owner)
    by_i = {e["i"]: e for e in six}
    out = {"stepId": sid, "attempt": step.get("attempt", 0), "superseded": step.get("superseded", False), "controls": controls,
           "frames": len(frames), "dropped": step.get("dropped", 0), "alone": alone,
           "bitsSeen": sorted(bits_seen), "touched": touched, "presses": [], "edges": six}
    for key in keys:
        mask = 1 << key_bit[key]
        rises, falls = edges(frames, mask)
        for r in rises:
            fall = next((f for f in falls if f > r), None)
            n_r = frames[r].n
            e_r = by_i.get(r)
            echo = []
            if e_r is not None and not e_r["shared"]:
                released = by_i.get(fall) if fall is not None else None
                released_names = released["changed"] if released is not None and not released["shared"] else []
                echo = [{"item": it, "pressLag": 0, "releaseLag": 0 if fall is not None and it in released_names else None}
                        for it in e_r["changed"]]
            near = []
            for j in range(1, len(frames)):
                if j == r or j in by_i or not n_r - PRESS_BEFORE <= frames[j].n <= n_r + PRESS_AFTER:
                    continue
                rose, fell = item_changes(frames, j)
                for it in sorted(rose):
                    near.append({"item": it, "lag": frames[j].n - n_r, "change": "came on"})
                for it in sorted(fell):
                    near.append({"item": it, "lag": frames[j].n - n_r, "change": "went off"})
            rose_bits = [b for b in range(13) if (frames[r].extra & ~(frames[r - 1].extra if r else 0)) >> b & 1]
            out["presses"].append({"key": key, "riseN": n_r, "fallN": frames[fall].n if fall is not None else None,
                                   "riseIndex": r, "fallIndex": fall, "bitsAtRise": rose_bits, "echo": echo,
                                   "shared": e_r is not None and e_r["shared"], "other": near})
    combos = {}
    for f in frames:
        down = tuple(sorted(BIT_OWNER.get(b, "bit%d" % b) for b in range(13) if f.extra >> b & 1))
        combos.setdefault(down, set()).add(f.hat)
    out["hatByKeysDown"] = {"+".join(k) or "none": sorted(v) for k, v in sorted(combos.items())}
    base = frames[0]
    out["analog"] = {"lt": max(f.lt for f in frames), "rt": max(f.rt for f in frames)}
    out["analogMoved"] = any(f.lt != base.lt or f.rt != base.rt for f in frames)
    out["stickMoved"] = any(abs(a - b) > STICK_MOVED for f in frames for a, b in zip(f.sticks, base.sticks))
    out["otherPadMoved"] = sorted({n for i in range(1, len(frames)) for n in other_changes(frames[i - 1], frames[i])})
    out["items"] = sorted({it for f in frames for it in f.items})
    out["reemergence"] = reemergence(frames, keys, out["presses"]) if len(keys) == 2 and sid.startswith("outer-right-") else []
    out["profileEdges"] = profile_edges(frames, keys, out["presses"]) if "profile" in controls else []
    return out


def reemergence(frames, keys, presses):
    """Reported, not judged. Two keys, the first held and the second pressed: after the second is let go, how many reports
    until the first key's own echo is back. lag None = it never went away (or never came back in the file); negative = it
    was back before the second key's release."""
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
    """Reported, not judged. Profile pressed or let go while the key is held: how many reports until anything else changed
    (None = not until the key was let go)."""
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


# --------------------------------------------------------------------------------------------------------- the survey

def echo_on_for(frames, i, mask, rise):
    """The echo item was on, without a break, for at least ALREADY_ON_REPORTS reports before a press at entry i (rise), or
    stays on for that long after a release (fall)."""
    if rise:
        j = i - 1
        if j < 0 or not ER.on_in(frames[j].mask, mask):
            return False
        while j > 0 and ER.on_in(frames[j - 1].mask, mask):
            j -= 1
        return frames[i].n - frames[j].n >= ALREADY_ON_REPORTS
    if not ER.on_in(frames[i].mask, mask):
        return False
    j = i + 1
    while j < len(frames) and ER.on_in(frames[j].mask, mask):
        j += 1
    end = frames[j].n if j < len(frames) else frames[-1].n
    return end - frames[i].n >= ALREADY_ON_REPORTS


def echo_lag(frames, e, mask):
    """For a failed edge: how many reports from the key's edge the echo item changed in another report (None = not
    within the windows around the edge)."""
    rise = e["kind"] == "rise"
    lo, hi = (PRESS_BEFORE, PRESS_AFTER) if rise else (RELEASE_BEFORE, RELEASE_AFTER)
    for j in range(1, len(frames)):
        if j == e["i"] or not e["n"] - lo <= frames[j].n <= e["n"] + hi:
            continue
        if mask is None:                           # the echo is not known: the first item that changed in another report
            flipped = (frames[j].mask ^ frames[j - 1].mask) & 0x3FF
            if flipped and (frames[j].mask & ~frames[j - 1].mask if rise else frames[j - 1].mask & ~frames[j].mask):
                return frames[j].n - e["n"]
            continue
        was, now = ER.on_in(frames[j - 1].mask, mask), ER.on_in(frames[j].mask, mask)
        if (rise and now and not was) or (not rise and was and not now):
            return frames[j].n - e["n"]
    return None


def key_state_echoes(results):
    """(profile state, key) -> Counter of the item masks the key's clean single-item presses changed."""
    measured = {}
    for r in results:
        st = profile_of(r["stepId"])
        for e in r["edges"]:
            if e.get("kind") == "rise" and not e["shared"] and not e["others"] and bin(e["mask"]).count("1") == 1:
                measured.setdefault((st, e["key"]), Counter())[e["mask"]] += 1
    return measured


def judge_edges(steps, results, echo_of):
    """Gate: every key edge where only that key changes either changes exactly its echo in its own report or changes
    nothing because the echo item was already on for ALREADY_ON_REPORTS reports. Fills each edge's `verdict`."""
    total = Counter()
    failures, lags = [], {"pressLag": 0, "releaseLag": 0, "lead": 0}
    for step, r in zip(steps, results):
        st = profile_of(r["stepId"])
        frames = step["frames"]
        for e in r["edges"]:
            if e["shared"]:
                e["verdict"] = "shared"
                total["shared"] += 1
                continue
            if e["others"] or bin(e["mask"]).count("1") > 1:
                e["verdict"] = "with"
                total["with"] += 1
                continue
            echo = echo_of.get((st, e["key"]))
            if e["mask"] and (echo is None or e["mask"] == echo):
                e["verdict"] = "exact"
                total["exact"] += 1
            elif e["mask"] == 0 and echo is not None and echo_on_for(frames, e["i"], echo, e["kind"] == "rise"):
                e["verdict"] = "already"
                total["already"] += 1
            else:
                e["verdict"] = "other"
                total["other"] += 1
                lag = echo_lag(frames, e, echo)
                if lag is not None:
                    if e["kind"] == "rise":
                        lags["pressLag" if lag > 0 else "lead"] = max(lags["pressLag" if lag > 0 else "lead"], abs(lag))
                    else:
                        lags["releaseLag"] = max(lags["releaseLag"], lag if lag > 0 else 0)
                if e["mask"] == 0:
                    why = ("its echo %s did not change in the key's own report and was not already on for %d reports"
                           % (" and ".join(mask_names(echo)) if echo else "(none seen in this state)", ALREADY_ON_REPORTS))
                    if lag is not None:
                        why += "; it changed %+d reports from the edge" % lag
                else:
                    why = "changed %s, the key's echo is %s" % (" and ".join(e["changed"]), " and ".join(mask_names(echo)) if echo else "unknown")
                failures.append("%s (attempt %d) %s %s at report %d: %s" % (r["stepId"], r["attempt"], KEY_LABEL.get(e["key"], e["key"]),
                                "press" if e["kind"] == "rise" else "release", e["n"], why))
    return total, failures, lags


def replay_survey(steps, results, echo_of):
    """The echo rule over every attempt under all 64 hide masks, with the echoes just measured as the stored items and as the
    truth model's echoes."""
    totals = {"reports": 0, "wrong": 0, "wrongExcused": 0, "ghosts": 0, "ambiguous": 0, "recovered": 0, "other": 0,
              "unconfirmed": 0, "unconfirmedClean": 0, "unconfirmedShared": 0, "unconfirmedWithItem": 0}
    clean_list = []
    problems = []
    by_state = {}
    for idx, r in enumerate(results):
        by_state.setdefault(profile_of(r["stepId"]), []).append(idx)
    for st, idxs in sorted(by_state.items()):
        E = [echo_of.get((st, k)) or ER.FACTORY[b] for b, (k, _, _) in enumerate(KEYS)]
        frames_list = [[ER.Frame(f.buttons, f.hat, f.extra, f.mask) for f in steps[i]["frames"]] for i in idxs]
        for H in range(64):
            res = ER.replay(frames_list, H, E, E)
            totals["reports"] += res["reports"] if H == 0 else 0
            for key in ("wrong", "wrongExcused", "ghosts", "ambiguous", "recovered", "other"):
                totals[key] += res[key]
            for ai, rep, bit_k, nchanged in res["unconfirmed"]:
                idx = idxs[ai]
                totals["unconfirmed"] += 1
                edge = next((e for e in results[idx]["edges"] if e["i"] == rep), None)
                if nchanged >= 2:
                    totals["unconfirmedShared"] += 1
                elif edge is None or edge["shared"] or edge["others"] or edge["mask"] & ~E[bit_k]:
                    totals["unconfirmedWithItem"] += 1
                else:
                    totals["unconfirmedClean"] += 1
                    clean_list.append("%s (attempt %d) %s press at report %d under hide mask 0x%02x" % (
                        results[idx]["stepId"], results[idx]["attempt"], KEYS[bit_k][2], results[idx]["edges"] and edge["n"] if edge else 0, H))
            for kind, where in (("wrong", res["wrongAt"]), ("ghost", res["ghostAt"])):
                for ai, rep in where[:2]:
                    idx = idxs[ai]
                    problems.append("%s: %s (attempt %d) report %d under hide mask 0x%02x" % (kind, results[idx]["stepId"],
                                    results[idx]["attempt"], steps[idx]["frames"][rep].n, H))
    totals["problems"] = problems[:10]
    totals["cleanUnconfirmed"] = clean_list[:10]
    return totals


def survey(steps):
    results = [analyse_step(s) for s in steps]
    measured = key_state_echoes(results)
    echo_of = {k: c.most_common(1)[0][0] for k, c in measured.items()}
    edge_total, edge_failures, lags = judge_edges(steps, results, echo_of)
    per_profile = {}
    for r in results:
        if r["alone"] or r["stepId"] == "capture":
            for p in r["presses"]:
                if p["echo"] and not p["shared"]:
                    per_profile.setdefault(profile_of(r["stepId"]), {}).setdefault(p["key"], Counter())[tuple(e["item"] for e in p["echo"])] += 1
    echoes = {str(prof): {key: [{"echo": list(items), "presses": n} for items, n in c.most_common()] for key, c in keys.items()}
              for prof, keys in sorted(per_profile.items())}
    replay = replay_survey(steps, results, echo_of)
    n_edges = sum(edge_total[k] for k in ("exact", "already", "other"))
    edge_summary = {"total": n_edges, "sameReport": edge_total["exact"], "alreadyOn": edge_total["already"], "other": edge_total["other"],
                    "withInput": edge_total["with"], "shared": edge_total["shared"]}
    gate = check_gate(steps, results, measured, edge_failures, replay)
    return {"steps": results, "echoByProfile": echoes, "edges": edge_summary, "worst": lags, "replay": replay,
            "touched": [dict(t, stepId=r["stepId"], attempt=r["attempt"]) for r in results for t in r["touched"]],
            "gate": gate, "row11": row11(per_profile, results)}


def named(r):
    return "%s (attempt %d)" % (r["stepId"], r["attempt"])


def check_gate(steps, results, measured, edge_failures, replay):
    checks = []

    def add(name, bad):
        checks.append({"check": name, "ok": not bad, "detail": "; ".join(bad[:3]) + (" (and %d more)" % (len(bad) - 3) if len(bad) > 3 else "")})

    bits_bad, other_bad, wide_bad = [], [], []
    for r in results:
        if not r["alone"]:
            continue
        key = r["controls"][0]
        table = KEY_INDEX[key]
        if table not in r["bitsSeen"]:
            if not r["superseded"]:          # in a redone attempt the owner may have pressed the wrong key: reported as touched
                bits_bad.append("%s: saw extra bits %s, the table says %d" % (named(r), r["bitsSeen"] or "none", table))
        else:
            extra = [b for b in r["bitsSeen"] if b != table and b not in BIT_OWNER]
            if extra:
                bits_bad.append("%s: saw extra bits %s outside the six keys' table bits" % (named(r), extra))
        if not r["presses"] and not r["superseded"]:
            bits_bad.append("%s: no press of the key was recorded" % named(r))
        moved = list(r["otherPadMoved"]) + (["stick"] if r["stickMoved"] and "stick" not in r["otherPadMoved"] else [])
        if moved:
            other_bad.append("%s: %s changed while only a key was pressed" % (named(r), ", ".join(moved)))
        for p in r["presses"]:
            if len(p["echo"]) > 1:
                wide_bad.append("%s: %s press at report %d changed %s" % (named(r), KEY_LABEL[p["key"]], p["riseN"], " and ".join(e["item"] for e in p["echo"])))
    add("each key pressed alone raises exactly its table bit (a touched neighbour is reported, not failed)", bits_bad)
    add("no echo on a stick, a trigger, Start, a G key or Profile", other_bad)
    unstable = ["state %d, %s: %s" % (st, KEY_LABEL[key], ", ".join(" and ".join(ER.item_text(m).split("+")) for m in c))
                for (st, key), c in sorted(measured.items()) if len(c) > 1]
    add("each key's echo is one receiver button or one D-pad direction, the same in every press of a state", unstable + wide_bad)
    add("every key edge changes exactly its echo in its own report, or the echo was already on for %d reports" % ALREADY_ON_REPORTS, edge_failures)
    add("replay of the v3 rule (all 64 hide masks): 0 wrong, 0 ghosts", replay["problems"])
    add("an unconfirmed press that is clean (only that key changed, nothing else on the pad)", replay["cleanUnconfirmed"])
    add("no step lost reports to the cap", [named(r) for r in results if r["dropped"]])
    return {"pass": all(c["ok"] for c in checks), "checks": checks,
            "review": "Reported, not judged: the echo per key and state, the hat by keys down, the return of the held key's "
                      "direction, the Profile edges, 'shared' and 'with <item>' presses, other changes near an edge."}


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
    out.append("ECHO SURVEY (%d attempts with receiver reports)" % len(res["steps"]))
    out.append("")
    out.append("Echo per key and profile (profile 0 = the one you started on; N = after Profile block N):")
    for prof, keys in res["echoByProfile"].items():
        out.append("  profile %s" % prof)
        for key, label in ((k, l) for k, _, l in KEYS):
            if key in keys:
                parts = ["%s x%d" % ("+".join(x["echo"]) or "nothing", x["presses"]) for x in keys[key]]
                out.append("    %-20s extra bit %d  echo: %s" % (label, KEY_INDEX[key], "; ".join(parts)))
    out.append("")
    e = res["edges"]
    out.append("Key edges: %d, of which the echo changed in the same report: %d, already on for %d+ reports: %d, anything else: %d"
               % (e["total"], e["sameReport"], ALREADY_ON_REPORTS, e["alreadyOn"], e["other"]))
    out.append("  not judged: %d with another input in the same report, %d with two keys in one report (shared)" % (e["withInput"], e["shared"]))
    if res["touched"]:
        out.append("")
        for t in res["touched"]:
            out.append("touched %s %d time%s (attempt %d of %s)" % (KEY_LABEL[t["key"]], t["count"], "" if t["count"] == 1 else "s", t["attempt"], t["stepId"]))
    out.append("")
    for r in res["steps"]:
        out.append("[%s] attempt %d%s, controls %s, %d reports kept%s" % (r["stepId"], r["attempt"], " (superseded)" if r["superseded"] else "",
                   ", ".join(r["controls"]), r["frames"], ", %d dropped" % r["dropped"] if r["dropped"] else ""))
        out.append("    extra bits that came on: %s" % (", ".join(str(b) for b in r["bitsSeen"]) or "none"))
        for i, p in enumerate(r["presses"], 1):
            if p["shared"]:
                echo = "shared: two of the six keys changed in this report"
            else:
                echo = ", ".join("%s (press %s, release %s)" % (x["item"], lag_text(x["pressLag"]), lag_text(x["releaseLag"])) for x in p["echo"]) or "no new button or direction"
            out.append("    %s press %d at report %d: %s" % (KEY_LABEL[p["key"]], i, p["riseN"], echo))
            for o in p["other"][:3]:
                out.append("        other change, %s reports from %s: %s %s" % (("%+d" % o["lag"]) if o["lag"] else "0", KEY_LABEL[p["key"]], o["item"], o["change"]))
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
        if r["analogMoved"]:
            out.append("    an analog field moved: LT up to %d, RT up to %d" % (r["analog"]["lt"], r["analog"]["rt"]))
        if r["stickMoved"]:
            out.append("    a stick value moved during this step")
    out.append("")
    rp = res["replay"]
    out.append("Replay of the v3 rule: %d reports × 64 masks: wrong %d, ghosts %d, ambiguous %d, unconfirmed clean %d (shared %d, with-item %d)" % (
        rp["reports"], rp["wrong"], rp["ghosts"], rp["ambiguous"], rp["unconfirmedClean"], rp["unconfirmedShared"], rp["unconfirmedWithItem"]))
    out.append("  recovered directions %d, presses read as another item (OTHER) %d, reports in a hold with an unconfirmed press that differ from the target (accepted limit) %d"
               % (rp["recovered"], rp["other"], rp["wrongExcused"]))
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
