# Changelog

## Unreleased

**Idle means idle.** Every age and time-left label had its own once-a-second
timer, and each one made its window lay itself out again. With a few dozen rows
the event log redrew well over a hundred times a second, even after it was
closed, and a running overlay could sit at 40% CPU. Now one clock per window
drives the labels: every second while one shows seconds, every minute
otherwise. The log's clock stops while the log is closed or minimized, and the
overlay's while it has no lines. A new event no longer redraws every row of the
log. `make test` checks this with the real app, off screen.

**History is kept forever.** Past 4 MB, `events.jsonl` moves to a dated file
beside it (`events-20261023-101500.jsonl`) instead of replacing the one
before, which was deleted. Startup still reads only the newest 2000 events. The
log shows the newest first and loads older ones as you scroll; its search and
filters cover every file, including the `events.jsonl.1` older versions kept.

## 1.1.2

**Close a line with the pointer.** Point at a line and its time slot turns into
an ×; a click there (or anywhere on the line) closes it and never reaches the
app underneath. While the stream is pointed at, **Clear all** appears under the
last line. The line you point at stays bright and the others step back. No
permission needed, no layout shift, and quick enough to close several in a row.
The menu bar panel also has Clear and a × per line on screen, and
`pager ambient --dismiss newest|all` does it from a script. Optional keyboard
shortcuts (⌃⌥⌫, ⌃⌥⇧⌫) are in Settings, off by default.

**Time left, and pins.** The right slot shows how long a line has left on
screen (`45s`, `9m`, `2h`) instead of its age, and a pin for a sticky line. The
event log and the menu bar panel still show ages.

**Nothing stays forever by accident.** Sticky lines leave the screen after 12
hours by default (Settings → Stickies; 0 keeps them until dismissed) and stay
open in the log. The expiry timer no longer stalls while a menu is open or when
App Nap would have stretched it to minutes on an idle Mac.

**Settings** has real margins and plain switch rows instead of pill toggles.

## 1.1.1

A panel with a video crashed as it opened: the video started playing while the
panel was still being built, and holding the countdown reached for a bar that
did not exist yet. 1.1.0 only.

## 1.1.0

**Hub panels.** A hub event with `data.panel` also raises a full panel on the
reader, once per event and at most three a minute (the rest fold into one),
so a server can reach the panel surface without a shell on the Mac.

**Ambient stream.** `pager ambient` keeps a quiet, click-through stream of
one-line events in a corner of the screen: source on the left, message on the
right, a live age (`now`, `12s`, `4m`), gone after 60 seconds by default or
sticky until middle-clicked. Text first, with optional cards, icons, backdrop
and, on macOS 15, effects. Menu bar item, a compact settings window and a
searchable history window; `pager log --window` lists ambient events too.

**Shade.** A feathered, frosted dark shade behind the stream and a thin halo on
the text keep lines readable over light windows; one slider sets its strength.

**Marks and pauses.** Sources show their brand mark and colour (Simple Icons) or a
monogram. The menu bar pauses for 15 minutes, an hour or until tomorrow, and
`--pause` does it from a script. With Accessibility allowed, a middle-click on a
line no longer reaches the app underneath.

**`pager event`** puts a line on it from any script, over a local socket, with
no server. With `--hub` it publishes to a hub instead.

**Hubs.** Any server speaking the [Ambient protocol](docs/protocol.md) can feed
the stream. `pager ambient connect <url> --key <reader key>` checks the hub's
`/info` and keeps the key in the Keychain; several hubs merge into one stream.
The client resumes with `Last-Event-ID`, backs off with jitter, reconnects after
60 silent seconds or a wake from sleep, restores open stickies, and syncs
dismissals per reader. Catch-up never replays a burst: only lines still inside
their lifetime return, without animation. Hub events are data and never run
anything.

**Running it.** `--install` adds a LaunchAgent that starts at login and restarts
after a crash; `--status`, `--demo` and `--selftest` do what they say.

**Smoother countdown.** A panel's countdown bar is one linear animation drawn at
the display's refresh rate instead of a timer nudging it a few points at a
time, so short panels no longer stutter. Pinning and playing audio still stop
it where it is, and it carries on from there.

**Build.** The program is now every file in `src/`: `Pager.swift` (the panel,
unchanged in behaviour) and `Ambient*.swift`. Still no dependencies, still
macOS 13. `make check` runs the ambient selftest; `make hub-test` drives the
overlay against `tools/mock-hub.py`, a small stdlib hub for tests.

## 1.0.0

First public release.

**The panel.** A non-activating `NSPanel` that floats over everything including
full screen spaces and can never become the key window, so it cannot take a
keystroke from you. Title, body, identity header, caption chips, an accent
colour, and a countdown you can see draining.

**Buttons that do things.** `--action "Label:command"` runs shell. Actions can
carry an icon, a background and a label colour, so one button can look like
GitHub while the rest stay quiet. `--copy` adds right click copy entries.

**Answers.** A pressed action prints its label to stdout, so a caller running
pager in the foreground blocks until it is answered and reads the answer back.
No daemon, no socket, no polling.

**Media.** `--image` for stills and animated GIFs, `--video` with inline
controls that re-fits to the clip's real aspect ratio, `--loop` to repeat it,
`--audio` for player rows with waveforms read out of the file, `--choose` to put
a button on every row, and `--sparkline` for a small line chart.

**Placement.** Four corners, each stacking on its own. Stacking is measured
rather than assumed, so panels of different heights sit flush, and a panel that
closes does not leave a hole: the ones above slide down into the space, which
they work out from the slot files alone, since they are separate processes that
never talk to each other. `cascade` fans
them out far enough that every title behind stays readable. `none` piles them on
one spot. Dragging detaches a panel and moves the corner everything after stacks
from.

**On the panel.** Pin, fold, remind (10 minutes to tomorrow at 9, by re-running
its own arguments), middle click to dismiss, and a right click menu carrying all
of it.

**Text.** `**bold**`, `*italic*` and `` `code` `` in titles and bodies.

**Ten sounds**, each from a different synthesis mechanism. Silence is the
default.

**Onboarding.** `pager --tour` walks through everything in ten panels with an
autoplay toggle, and offers to install the reference for Claude Code, opencode,
Codex and Gemini CLI where each already looks.

**Two monitors.** A panel follows the screen you are working on. `--display <n>`
pins it to one, and `pager --screen` lists them.

**Install.** One Swift file, no dependencies. A universal binary ships in
`dist/` so a compiler is optional, and `make tarball` builds a self-contained
archive that installs without git or a compiler. Pushing a tag builds that
archive, installs it from scratch, and attaches it to the release.

**Modest about resources.** The countdown ticks about once per point it moves
rather than at 30fps, a panel with nothing beneath it starts no watcher at all,
and the log keeps its last few thousand lines instead of growing forever.
