#!/usr/bin/env python3
"""Release notes (the Markdown publish-release.sh is given) as the HTML Sparkle shows in its update
window, carried in the appcast entry itself.

The entry used to point Sparkle at the GitHub release page, which Sparkle drew whole — GitHub's
header, Sign in, the repository tabs — in a small window (the owner, beta 2 → beta 3, 10 October).

Handles what the notes use and no more: `##` headings, paragraphs, `-` lists, **bold**, `code` and
[links](https://…). Everything else is escaped as text.

Usage: release-notes-html.py NOTES.md VERSION
"""
import html
import re
import sys

STYLE = """<style>
:root { color-scheme: light dark; }
body { font: 13px -apple-system, system-ui, sans-serif; line-height: 1.45; margin: 12px 16px; }
h3 { font-size: 13px; margin: 14px 0 4px; }
p { margin: 6px 0; }
ul { margin: 4px 0 8px; padding-left: 18px; }
li { margin: 2px 0; }
code { font: 12px ui-monospace, Menlo, monospace; }
a { color: #2C7A7B; }
@media (prefers-color-scheme: dark) { a { color: #59B3B0; } }
.more { margin-top: 14px; font-size: 12px; opacity: 0.8; }
</style>"""


def inline(text: str) -> str:
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\[([^\]]+)\]\((https://[^)\s]+)\)", r'<a href="\2">\1</a>', text)
    return text


def convert(markdown: str) -> str:
    out, paragraph, in_list = [], [], False

    def flush_paragraph():
        if paragraph:
            out.append("<p>" + inline(" ".join(paragraph)) + "</p>")
            paragraph.clear()

    def close_list():
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    for raw in markdown.splitlines():
        line = raw.rstrip()
        if not line.strip():
            flush_paragraph()
            close_list()
        elif line.startswith("## "):
            flush_paragraph()
            close_list()
            out.append("<h3>" + inline(line[3:]) + "</h3>")
        elif line.lstrip().startswith("- "):
            flush_paragraph()
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append("<li>" + inline(line.lstrip()[2:]) + "</li>")
        elif in_list and raw.startswith("  "):
            out[-1] = out[-1][:-5] + " " + inline(line.strip()) + "</li>"
        else:
            close_list()
            paragraph.append(line.strip())
    flush_paragraph()
    close_list()
    return "\n".join(out)


if __name__ == "__main__":
    notes_path, version = sys.argv[1], sys.argv[2]
    body = convert(open(notes_path, encoding="utf-8").read())
    link = f"https://github.com/melonfleet/flotilla/releases/tag/v{html.escape(version)}"
    page = f'{STYLE}\n{body}\n<p class="more"><a href="{link}">Full release on GitHub</a></p>'
    # It travels inside CDATA; the one sequence that would end it early cannot appear.
    print(page.replace("]]>", "]]&gt;"))
