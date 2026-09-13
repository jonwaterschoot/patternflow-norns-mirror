#!/usr/bin/env python3
"""Check that every relative link and #anchor in the docs resolves.

The docs cross-reference each other heavily and the numbered filenames invite
renames, so a broken link here is a matter of when. Moving one section out of
the README already produced two dead anchors that nothing else would have
caught.

    python tools/check_docs.py

Anchor slugs follow GitHub's rule closely enough for our headings: lowercase,
punctuation dropped, whitespace to hyphens. vendor/ is skipped — those are
other people's docs.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP = {".git", "vendor", "__pycache__", "node_modules"}
LINK = re.compile(r"\[([^\]]*)\]\(([^)]+)\)")
HEADING = re.compile(r"^#{1,6}\s+(.*)$", re.M)


def slug(text):
    s = text.strip().lower()
    s = re.sub(r"[^\w\s-]", "", s)
    return re.sub(r"\s", "-", s)


def main():
    os.chdir(ROOT)
    pages = {}
    for root, dirs, files in os.walk("."):
        dirs[:] = [d for d in dirs if d not in SKIP]
        for fn in files:
            if fn.endswith(".md"):
                p = os.path.normpath(os.path.join(root, fn))
                text = open(p, encoding="utf-8").read()
                pages[p] = (text, {slug(m.group(1)) for m in HEADING.finditer(text)})

    problems = 0
    for page, (text, _) in sorted(pages.items()):
        for m in LINK.finditer(text):
            target = m.group(2).strip()
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            path, _, anchor = target.partition("#")
            resolved = (
                page if not path
                else os.path.normpath(os.path.join(os.path.dirname(page), path))
            )
            if not os.path.exists(resolved):
                print("broken link   %s  ->  %s" % (page, target))
                problems += 1
                continue
            # Only .md targets have anchors we can check; anything else
            # (a source file, a directory) is checked for existence only.
            if anchor and resolved in pages and anchor not in pages[resolved][1]:
                print("bad anchor    %s  ->  %s" % (page, target))
                near = [h for h in sorted(pages[resolved][1]) if anchor[:8] in h]
                if near:
                    print("              did you mean: %s" % ", ".join(near))
                problems += 1

    print("%d markdown files, %d problems" % (len(pages), problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
