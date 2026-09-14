#!/usr/bin/env python3
"""Check that every relative link and #anchor in the docs resolves.

The docs cross-reference each other heavily and the numbered filenames invite
renames, so a broken link here is a matter of when. Moving one section out of
the README already produced two dead anchors that nothing else would have
caught.

    python tools/check_docs.py

Anchor slugs follow GitHub's rule closely enough for our headings: lowercase,
punctuation dropped, whitespace to hyphens.

Files are found by asking git, not by walking the tree. Walking meant a
hand-maintained skip list, and it was never finished — vendor/ was excluded but
build/libdeps/ was not, so the day the build moved inside the repo this tool
started reporting broken links in a vendored Bluetooth library.

Tracked AND untracked-but-not-ignored, which matters: a brand-new page is
untracked until it is staged, and checking only tracked files meant the one
document most likely to have a bad link was the one document never checked.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LINK = re.compile(r"\[([^\]]*)\]\(([^)]+)\)")
HEADING = re.compile(r"^#{1,6}\s+(.*)$", re.M)


def slug(text):
    s = text.strip().lower()
    s = re.sub(r"[^\w\s-]", "", s)
    return re.sub(r"\s", "-", s)


def main():
    os.chdir(ROOT)
    try:
        listing = subprocess.run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.md"],
            capture_output=True, text=True, check=True,
        ).stdout.split("\n")
    except (subprocess.CalledProcessError, FileNotFoundError):
        sys.exit("not a git checkout, or git is not on PATH")

    pages = {}
    for rel in listing:
        rel = rel.strip()
        if not rel:
            continue
        p = os.path.normpath(rel)
        if not os.path.exists(p):   # tracked but deleted in the working tree
            continue
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
