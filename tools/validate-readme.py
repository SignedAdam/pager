#!/usr/bin/env python3
"""Check a candidate README against the actual program.

Catches the two things a writer cannot be expected to get right on their own:
flags that do not exist, and images that are not there. Also flags the words
Adam has objected to.
"""
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REAL_FLAGS = set(re.findall(r'"(--[a-z-]+)"', open(f"{REPO}/src/Pager.swift").read()))
REAL_FLAGS |= {"--tour", "--examples", "--sounds", "--version", "--screen", "--help", "-v"}
REAL_FLAGS |= set(re.findall(r'"(--[a-z-]+)"', open(f"{REPO}/install.sh").read()))  # installer flags
REAL_FLAGS |= {"--install", "--uninstall", "--no-tour", "--release"}
MAKE_TARGETS = set(re.findall(r'^([a-z-]+):', open(f"{REPO}/Makefile").read(), re.M))


def check(path):
    text = open(path).read()
    name = os.path.basename(os.path.dirname(path))
    problems, notes = [], []

    used = set(re.findall(r'(?<![\w-])(--[a-z][a-z-]*)', text))
    invented = sorted(f for f in used if f not in REAL_FLAGS)
    if invented:
        problems.append(f"flags that do not exist: {', '.join(invented)}")

    missing_flags = sorted(f for f in REAL_FLAGS if f not in used and f.startswith("--")
                           and f not in {"--screen", "--help", "--meta"})
    if missing_flags:
        notes.append(f"{len(missing_flags)} flags undocumented: {', '.join(missing_flags[:6])}"
                     + ("…" if len(missing_flags) > 6 else ""))

    for image in sorted(set(re.findall(r'(docs/[\w.-]+\.(?:png|gif))', text))):
        if not os.path.exists(os.path.join(REPO, image)):
            problems.append(f"image not in repo: {image}")

    # Only count "make x" written as a command, not "make them" in a sentence.
    for target in sorted(set(re.findall(r'(?:^|`|\$ )make ([a-z-]+)', text, re.M))):
        if target not in MAKE_TARGETS:
            problems.append(f"make target does not exist: {target}")

    raised = len(re.findall(r'\brais(e|es|ed|ing)\b', text, re.I))
    if raised:
        problems.append(f'uses "raise" {raised}x')
    if "—" in text or "–" in text:
        problems.append(f"em or en dashes: {text.count('—') + text.count('–')}")
    hype = [w for w in ("blazing", "seamless", "effortless", "powerful", "beautiful",
                        "delightful", "magical", "simply", "just works") if w in text.lower()]
    if hype:
        notes.append(f"hype words: {', '.join(hype)}")

    words = len(text.split())
    images = len(re.findall(r'!\[|<img', text))
    blocks = text.count("```") // 2

    print(f"\n{'=' * 70}\n  {name}")
    print(f"  {len(text.splitlines())} lines, {words} words, {images} images, {blocks} code blocks")
    print(f"{'=' * 70}")
    for p in problems:
        print(f"  FAIL  {p}")
    for n in notes:
        print(f"  note  {n}")
    if not problems:
        print("  clean")
    return len(problems)


if __name__ == "__main__":
    total = 0
    for candidate in (sys.argv[1:] or [os.path.join(REPO, "README.md")]):
        if os.path.exists(candidate):
            total += check(candidate)
    print(f"\n  {total} hard problems\n")
    sys.exit(1 if total else 0)
