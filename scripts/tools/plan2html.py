#!/usr/bin/env python3
"""Render a plan Markdown file to a self-contained HTML page for phone reading.

usage: python3 scripts/tools/plan2html.py docs/plans/<name>.md [docs/plans/<name>.html]

If `<name>.summary.html` exists next to the Markdown file, it is placed above the plan as a plain-language summary card.
Needs the `markdown` package (python3 -m pip install markdown).
"""
import os
import re
import sys

import markdown

src = sys.argv[1]
dst = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(src)[0] + ".html"
lines = open(src, encoding="utf-8").read().split("\n")
sidecar = os.path.splitext(src)[0] + ".summary.html"
summary = open(sidecar, encoding="utf-8").read() if os.path.exists(sidecar) else ""

# python-markdown nests lists on 4-space steps; the plans use 2/4/5/6.
INDENT = {0: 0, 2: 4, 3: 4, 4: 8, 5: 8, 6: 12, 7: 12, 8: 16}


def remap(n):
    return INDENT.get(n, n * 2)


out = []
i = 0
while i < len(lines):
    line = lines[i]
    m = re.match(r"^( *)```", line)
    if m:
        k = len(m.group(1))
        j = i + 1
        body = []
        while j < len(lines) and not re.match(r"^ *```\s*$", lines[j]):
            body.append(lines[j])
            j += 1
        if k == 0:
            out.append(line)
            out.extend(body)
            out.append("```")
        else:
            # fenced block inside a list item -> indented code block
            pad = " " * (remap(k) + 4)
            out.append("")
            for b in body:
                out.append(pad + (b[k:] if b[:k].strip() == "" else b.lstrip()))
            out.append("")
        i = j + 1
        continue
    m = re.match(r"^( +)(\S.*)$", line)
    if m:
        out.append(" " * remap(len(m.group(1))) + m.group(2))
    else:
        out.append(line)
    i += 1

md = markdown.Markdown(
    extensions=["tables", "fenced_code", "sane_lists", "toc"],
    extension_configs={"toc": {"toc_depth": "2-3"}},
)
body = md.convert("\n".join(out))
toc = md.toc
body = body.replace("<table>", '<div class="tw"><table>').replace("</table>", "</table></div>")
# evidence tags as small pills
body = re.sub(r"<strong>(M|R|G|G·T[0-9.]+(?:, ?T[0-9.]+)*)</strong>", r'<span class="tag">\1</span>', body)
title_match = re.search(r"<h1[^>]*>(.*?)</h1>", body, flags=re.S)
title = re.sub(r"<[^>]+>", "", title_match.group(1)).strip() if title_match else os.path.basename(src)

CSS = """
:root{--bg:#f6f7f9;--surface:#fff;--text:#1b1f24;--muted:#5b6470;--line:#d9dee5;--accent:#0b62d6;
--code-bg:#eef1f5;--head:#eef2f7;--tag-bg:#e4ecf9;--tag-text:#0b4aa6;--warn-bg:#fff4d6;--warn-text:#6b4a00}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#12151a;--surface:#1a1e25;--text:#e6e9ee;
--muted:#9aa4b2;--line:#2c333d;--accent:#6aa9ff;--code-bg:#232933;--head:#222832;--tag-bg:#1f3050;--tag-text:#a9c8ff;
--warn-bg:#3a2f10;--warn-text:#ffd98a}}
:root[data-theme="dark"]{--bg:#12151a;--surface:#1a1e25;--text:#e6e9ee;--muted:#9aa4b2;--line:#2c333d;--accent:#6aa9ff;
--code-bg:#232933;--head:#222832;--tag-bg:#1f3050;--tag-text:#a9c8ff;--warn-bg:#3a2f10;--warn-text:#ffd98a}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
main{max-width:900px;margin:0 auto;padding:20px 16px 64px}
h1{font-size:1.55rem;line-height:1.25;margin:8px 0 12px}
h2{font-size:1.25rem;margin:36px 0 10px;padding-top:14px;border-top:1px solid var(--line)}
h3{font-size:1.05rem;margin:24px 0 8px}
p,li{overflow-wrap:anywhere}
ul,ol{padding-left:1.3em}
li{margin:3px 0}
a{color:var(--accent)}
hr{border:0;border-top:1px solid var(--line);margin:28px 0}
code{font:0.86em ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--code-bg);padding:1px 4px;border-radius:4px}
pre{background:var(--code-bg);padding:12px;border-radius:8px;overflow-x:auto;line-height:1.4}
pre code{background:none;padding:0;font-size:0.82rem;overflow-wrap:normal}
.tw{overflow-x:auto;margin:12px 0;border:1px solid var(--line);border-radius:8px;background:var(--surface)}
table{border-collapse:collapse;width:max-content;min-width:100%;font-size:0.92rem}
th,td{padding:7px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top;min-width:4em;max-width:22em}
th{background:var(--head);font-weight:600;white-space:nowrap}
tr:last-child td{border-bottom:0}
.card{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:4px 16px 12px;margin:16px 0}
.card h2{border-top:0;margin-top:10px;padding-top:0}
.status{display:inline-block;background:var(--warn-bg);color:var(--warn-text);font-weight:600;font-size:0.88rem;
padding:4px 10px;border-radius:999px;margin:12px 0 0}
.tag{display:inline-block;background:var(--tag-bg);color:var(--tag-text);font-size:0.75em;font-weight:700;
padding:0 5px;border-radius:4px;white-space:nowrap}
details.toc{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:10px 16px;margin:16px 0}
details.toc summary{font-weight:600;cursor:pointer}
details.toc ul{list-style:none;padding-left:0.9em;margin:6px 0}
details.toc a{text-decoration:none}
.note{color:var(--muted);font-size:0.88rem}
"""

html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>{CSS}</style>
</head>
<body>
<main>
<p class="note">GDHub · generated from <code>{src}</code>, which is the source of truth</p>
{summary}
<details class="toc"><summary>Contents of the full plan</summary>{toc}</details>
{body}
</main>
</body>
</html>
"""
open(dst, "w", encoding="utf-8").write(html)
print("wrote", dst, "bytes", len(html))
