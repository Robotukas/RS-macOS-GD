#!/usr/bin/env python3 -I
"""Render a Claude Code session transcript (.jsonl) as Markdown for docs/sessions/.

User and assistant messages only: tool calls, tool output, system reminders, hook context and background-task
notifications are left out, and personal identifiers are redacted (e-mail addresses, the home directory, device
identifiers, the owner's name). Usage:

    session2md.py SESSION.jsonl OUT.md --title "…" [--since 2026-11-08T21:18] [--name "First Last"]
"""
import argparse, datetime, json, re, sys

REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)
TAGGED = re.compile(r"<(local-command-caveat|command-name|command-message|command-args|local-command-stdout|task-notification|pasted_content[^>]*)>.*?</\1>", re.S)
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
UDID = re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b|\b[0-9a-f]{40}\b")
HOME = re.compile(r"/Users/[A-Za-z0-9._-]+")
KEEP_EMAILS = {"noreply@anthropic.com"}


def redact(text, names):
    text = EMAIL.sub(lambda m: m.group(0) if m.group(0) in KEEP_EMAILS else "[email redacted]", text)
    text = HOME.sub("~", text)
    text = UDID.sub("[device id redacted]", text)
    for n in names:
        if n:
            text = re.sub(re.escape(n), "the owner", text, flags=re.I)
    return text


def text_of(message, role):
    c = message.get("content")
    if isinstance(c, str):
        return c, False
    parts, image = [], False
    for b in c or []:
        t = b.get("type")
        if t == "text":
            parts.append(b.get("text", ""))
        elif t == "image":
            image = True
    return "\n\n".join(p for p in parts if p.strip()), image


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("jsonl"); ap.add_argument("out")
    ap.add_argument("--title", required=True)
    ap.add_argument("--since", default="")
    ap.add_argument("--name", action="append", default=[])
    ap.add_argument("--intro", default="")
    a = ap.parse_args()
    since = a.since
    out, n_user, n_claude, last = [], 0, 0, None
    for line in open(a.jsonl, encoding="utf-8"):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        role = d.get("type")
        if role == "attachment":
            # A message the owner sent while a turn was running is stored as a queued command, not as a user entry.
            at = d.get("attachment") or {}
            if at.get("type") != "queued_command" or (at.get("origin") or {}).get("kind") != "human":
                continue
            prompt = at.get("prompt")
            d = {"type": "user", "timestamp": at.get("timestamp") or d.get("timestamp", ""),
                 "message": {"content": prompt if isinstance(prompt, (str, list)) else ""}}
            role = "user"
        if role not in ("user", "assistant") or d.get("isSidechain") or d.get("isMeta"):
            continue
        ts = d.get("timestamp", "")
        if since and ts[:16] < since:
            continue
        if d.get("isCompactSummary"):
            out.append("---\n\n*(The conversation's context was compacted here; the session continued.)*\n\n---\n")
            continue
        text, image = text_of(d.get("message", {}), role)
        if role == "user":
            if "[SYSTEM NOTIFICATION - NOT USER INPUT]" in text:
                continue
            text = TAGGED.sub("", REMINDER.sub("", text))
            text = re.sub(r"^The user sent a new message while you were working:\n", "", text.strip())
            text = re.sub(r"\n*This is how Claude Code surfaces messages the user sends mid-turn.*$", "", text, flags=re.S)
        text = text.strip()
        if not text and not image:
            continue
        if role == "user" and text.startswith("This session is being continued from a previous conversation"):
            out.append("---\n\n*(The conversation's context was compacted here; the session continued.)*\n\n---\n")
            continue
        try:
            when = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).strftime("%Y-%m-%d %H:%M")
        except ValueError:
            when = ts[:16]
        who = "Owner" if role == "user" else "Claude"
        body = redact(text, a.name)
        if image:
            body = (body + "\n\n" if body else "") + "*[image attached]*"
        key = (who, body)
        if key == last:
            continue
        last = key
        out.append(f"### {who} — {when}\n\n{body}\n")
        if role == "user": n_user += 1
        else: n_claude += 1
    head = f"# {a.title}\n\n{a.intro}\n\n---\n\n" if a.intro else f"# {a.title}\n\n---\n\n"
    open(a.out, "w", encoding="utf-8").write(head + "\n".join(out))
    print(f"{a.out}: {n_user} owner messages, {n_claude} Claude messages", file=sys.stderr)


if __name__ == "__main__":
    main()
