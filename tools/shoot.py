#!/usr/bin/env python3
"""Screenshot the panels for the README.

Panels are transparent and blurred, so a plain screen grab would bake whatever
happened to be behind them into the picture. This raises a full screen backdrop
first, places panels on it, reads back where each one actually landed, and
captures exactly that region.

    python3 tools/shoot.py            every shot
    python3 tools/shoot.py hero ask   just those
"""
import os
import re
import shutil
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGER = os.path.join(REPO, "bin", "pager")
OUT = os.path.join(REPO, "docs")
BACKDROP = "/tmp/backdrop"
PLACED = re.compile(r"placed at \((-?\d+), (-?\d+)\) size (\d+)x(\d+)")

LIME, RED, GREEN, BLUE, PURPLE = "#c7ff00", "#ff5f57", "#28c840", "#5ac8fa", "#bf5af2"


def screen():
    out = subprocess.run([PAGER, "--screen"], capture_output=True, text=True).stdout
    # --screen also lists each display, whose fields are not plain integers.
    values = {}
    for line in out.strip().splitlines():
        parts = line.split()
        if parts[0] in ("visible", "frame", "primary", "screens"):
            values[parts[0]] = [int(n) for n in parts[1:]]
    frame_h = values["frame"][3]
    visible = values["visible"]
    # The backdrop sits below the menu bar, so anything captured above the
    # visible area would show the real desktop's menu bar instead.
    ceiling = frame_h - (visible[1] + visible[3])
    return frame_h, visible[2], ceiling


FRAME_H, SCREEN_W, CEILING = screen()


def raise_panel(args, seconds=240):
    """Start a panel and return (process, rect) once it has told us where it is."""
    env = dict(os.environ, PAGER_DEBUG="1")
    process = subprocess.Popen([PAGER] + args + ["--seconds", str(seconds)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                               text=True, env=env)
    deadline = time.time() + 8
    while time.time() < deadline:
        line = process.stderr.readline()
        if not line:
            break
        found = PLACED.search(line)
        if found:
            x, y, w, h = (int(n) for n in found.groups())
            return process, (x, y, w, h)
    return process, None


def capture(rects, name, pad=26, full=False):
    if full:
        region = (0, CEILING, SCREEN_W, FRAME_H - CEILING)
    else:
        left = min(r[0] for r in rects) - pad
        right = max(r[0] + r[2] for r in rects) + pad
        bottom = min(r[1] for r in rects) - pad
        top = max(r[1] + r[3] for r in rects) + pad
        left, bottom = max(0, left), max(0, bottom)
        capture_top = max(CEILING, FRAME_H - top)
        region = (left, capture_top, right - left, FRAME_H - bottom - capture_top)
    path = os.path.join(OUT, name + ".png")
    subprocess.run(["screencapture", "-x", "-R", ",".join(str(int(n)) for n in region), path],
                   check=True)
    return path


def shoot(name, panels, pad=26, settle=1.4, full=False):
    # Clear anything left over, or a stray panel from the last shot ends up in
    # the corner of this one.
    subprocess.run(["pkill", "-f", "bin/pager --title"], capture_output=True)
    time.sleep(0.5)
    live, rects = [], []
    for args in panels:
        process, rect = raise_panel(args)
        live.append(process)
        if rect:
            rects.append(rect)
        time.sleep(0.35)
    time.sleep(settle)
    if not rects:
        print(f"  {name}: nothing placed, skipped")
    else:
        path = capture(rects, name, pad=pad, full=full)
        size = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
                              capture_output=True, text=True).stdout
        dims = "x".join(re.findall(r": (\d+)", size))
        print(f"  {name}.png  {dims}")
    for process in live:
        process.terminate()
    time.sleep(0.6)
    subprocess.run(["pkill", "-f", "bin/pager --title"], capture_output=True)
    for slot in os.listdir(os.path.expanduser("~/.pager")):
        if slot.startswith("slot-"):
            os.remove(os.path.join(os.path.expanduser("~/.pager"), slot))
    time.sleep(0.3)


DEPLOY = [
    "--title", "Deploy failed on production",
    "--app", "coolify", "--icon", "exclamationmark.triangle", "--source", "deploy",
    "--accent", RED, "--chip", "production", "--chip", "8f21ac3", "--chip", "2m14s ago",
    "--body", "3 of 12 containers unhealthy after the rollout. Traffic is still on the "
              "previous revision, so nothing is down *yet*.",
    "--action", "Logs:", "--action-icon", "doc.text",
    "--action", "Rollback:", "--action-fill", RED, "--action-text", "#ffffff",
    "--width", "430", "--corner", "bottom-right", "--stack", "none",
]

ASK = [
    "--title", "Ship 1.4.0 to production?",
    "--app", "Claude Code", "--icon", "sparkles", "--source", "release",
    "--accent", LIME, "--chip", "12 commits", "--chip", "all checks green",
    "--body", "An agent is blocked on `answer=$(pager …)` and will carry on the moment "
              "you press one of these.",
    "--action", "Ship it:", "--action-fill", LIME, "--action-text", "#12140f",
    "--action", "Not yet:",
    "--width", "420", "--corner", "bottom-left", "--stack", "none",
]

AUDIO = [
    "--title", "Three takes, pick one",
    "--app", "studio", "--icon", "waveform", "--source", "voice",
    "--accent", LIME,
    "--audio", "chirp:chirp", "--audio", "rise:rise", "--audio", "fall:fall",
    "--choose", "Keep:", "--width", "430",
    "--corner", "top-left", "--stack", "none",
]

CHART = [
    "--title", "Sales are up 34% this week",
    "--app", "acme", "--icon", "chart.xyaxis.line", "--source", "weekly",
    "--accent", GREEN, "--chip", "mrr $1,840", "--chip", "12 new, 2 churned",
    "--sparkline", "4,6,5,9,8,12,17,16,22,21,28,34",
    "--body", "Best week since launch. The dip on Tuesday was the outage.",
    "--action", "Dashboard:", "--action-icon", "arrow.up.right.square",
    "--width", "420", "--corner", "top-right", "--stack", "none",
]

MEDIA = [
    "--title", "Render finished", "--app", "remotion", "--source", "video",
    "--icon", "film", "--accent", LIME, "--chip", "1080x1920", "--chip", "14s",
    "--image", os.path.join(REPO, "assets", "waves.gif"),
    "--action", "Open:", "--action-icon", "play.fill",
    "--width", "400", "--corner", "bottom-right", "--stack", "none",
]

BRAND = [
    "--title", "Got a cool idea, or found a bug?",
    "--app", "pager", "--icon", "heart", "--accent", LIME,
    "--body", "Open an issue on GitHub and I will take a look.\n\n*- Adam*",
    "--action", "Open an issue:", "--action-icon", "assets/github.png",
    "--action-fill", "#24292f", "--action-text", "#ffffff",
    "--width", "420", "--corner", "bottom-right", "--stack", "none",
]


def stack_panels():
    return [["--title", f"Backup {i} finished", "--app", "cron", "--source", "nightly",
             "--icon", "externaldrive", "--accent", BLUE, "--width", "350",
             "--chip", f"{i * 4}.{i} GB",
             "--body", "Each panel measures its real height, so a tall one and a short "
                       "one still sit flush.",
             "--corner", "bottom-left", "--stack", "vertical"] for i in (1, 2, 3)]


def cascade_panels():
    return [["--title", f"Test suite {i} passed", "--app", "ci", "--source", "github",
             "--icon", "checkmark.seal", "--accent", PURPLE, "--width", "350",
             "--body", "Fanned out, so every title behind stays readable.",
             "--corner", "top-left", "--stack", "cascade"] for i in (1, 2, 3)]


def at(panel, corner, offset):
    """Same panel, moved into a cluster for the group shot."""
    out = list(panel)
    for flag, value in (("--corner", corner), ("--offset", offset)):
        if flag in out:
            out[out.index(flag) + 1] = value
        else:
            out += [flag, value]
    return out


def hero_panels():
    return [
        at(AUDIO,  "top-left",     "280,-190"),
        at(CHART,  "top-right",    "-280,-190"),
        at(ASK,    "bottom-left",  "280,190"),
        at(DEPLOY, "bottom-right", "-280,190"),
    ]


def reflow_shot():
    """Two stills: three panels, then the bottom one expires and the rest slide
    down into the space. A recording never caught the move, and the pair says it
    more clearly than an animation would anyway."""
    live = []
    specs = [
        (["--title", "Nightly backup finished", "--app", "cron", "--source", "backup",
          "--icon", "externaldrive", "--accent", BLUE, "--chip", "18.4 GB"], 6),
        (["--title", "Test suite passed", "--app", "ci", "--source", "github",
          "--icon", "checkmark.seal", "--accent", GREEN, "--chip", "412 tests"], 40),
        (["--title", "Deploy failed on production", "--app", "coolify", "--source", "deploy",
          "--icon", "exclamationmark.triangle", "--accent", RED, "--chip", "production"], 40),
    ]
    rects = []
    for args, seconds in specs:
        process, rect = raise_panel(args + ["--corner", "bottom-right"], seconds=seconds)
        live.append(process)
        if rect:
            rects.append(rect)
        time.sleep(0.4)
    time.sleep(1.4)
    before = capture(rects, "_reflow_before", pad=30)
    time.sleep(6.5)                       # the bottom one expires, the others slide down
    after = capture(rects, "_reflow_after", pad=30)
    for process in live:
        process.terminate()
    gap = 34
    subprocess.run(["magick", before, "-background", "#0e1013", "-splice", f"{gap}x0",
                    after, "+append", "-bordercolor", "#0e1013", "-border", "10",
                    os.path.join(OUT, "reflow.png")], check=True)
    for temp in (before, after):
        os.remove(temp)
    print("  reflow.png  (before | after)")


SHOTS = {
    "hero":  (lambda: hero_panels(), dict(pad=44, settle=2.0)),
    "deploy": (lambda: [DEPLOY], {}),
    "ask":    (lambda: [ASK], {}),
    "audio":  (lambda: [AUDIO], {}),
    "chart":  (lambda: [CHART], {}),
    "media":  (lambda: [MEDIA], dict(settle=2.2)),
    "brand":  (lambda: [BRAND], {}),
    "stack":   (lambda: stack_panels(), dict(pad=30, settle=1.8)),
    "cascade": (lambda: cascade_panels(), dict(pad=30, settle=1.8)),
}

if __name__ == "__main__":
    if not os.path.exists(BACKDROP):
        sys.exit("build the backdrop first: swiftc -O -o /tmp/backdrop tools/backdrop.swift -framework Cocoa")
    os.makedirs(OUT, exist_ok=True)
    wanted = sys.argv[1:] or (list(SHOTS) + ["reflow"])
    backdrop = subprocess.Popen([BACKDROP], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.2)
    try:
        for name in wanted:
            if name == "reflow":
                reflow_shot()
                continue
            build, options = SHOTS[name]
            shoot(name, build(), **options)
    finally:
        backdrop.terminate()
        subprocess.run(["pkill", "-f", "bin/pager --title"], capture_output=True)
    print("\n  done ->", OUT)
