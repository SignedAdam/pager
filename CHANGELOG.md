# Changelog

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
