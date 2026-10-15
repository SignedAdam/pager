# Contributing

Ideas and bug reports are both welcome. There are templates for each, and a bug
report is much easier to act on with the output of `PAGER_DEBUG=1` in it.

## Getting set up

```bash
git clone https://github.com/SignedAdam/pager.git
cd pager
make install      # builds, links, starts the tour
make              # lists everything else
```

You need the Xcode command line tools to build (`xcode-select --install`).
Running it needs nothing.

## Before you open a pull request

```bash
make check    # syntax checks every script and typechecks the Swift
make test     # drives all ten tour steps through a stub, no windows open
```

Both run in CI on every push. If you changed anything about how a panel looks,
also run `make shots` and commit the regenerated pictures, so the README never
shows something the code no longer does.

If you changed anything in `src/`, run `make release` and commit `dist/pager`
too. That is the universal binary people without a compiler install, and CI
fails if it is older than the source.

## How the code is laid out

`src/Pager.swift` is the panel. It reads top to bottom in the order things happen.

| | |
|---|---|
| `Debug` | `PAGER_DEBUG=1` tracing. Both of the worst bugs here were silent |
| `Theme` | every size, as one number times a screen-derived scale |
| `Markup` | the `**bold**` / `*italic*` / `` `code` `` subset |
| `Pill`, `Glyph`, `Chip`, `Sparkline`, `WaveView` | the parts you can see |
| `Clip`, `AudioRow`, `Playback` | reading waveforms, and one sound at a time |
| `Options` | every flag, parsed in one switch |
| `Slots` | corners, stacking, and the lock that stops two panels racing |
| `Pager` | builds the panel, owns the timer, runs the actions |

**To add a field:** add a flag and one line in `Options.parse`, then one line in
`build`. That is the whole extension story, and it is deliberate. There is no
plugin system and no config schema.

The ambient stream sits beside it and the panel never calls into it, apart from
the two words `ambient` and `event` at the entry point:

| | |
|---|---|
| `AmbientModel.swift` | the event record, settings, lifetime rules, the SSE parser, history files. No UI |
| `AmbientFeed.swift` | the local socket, Keychain, and one SSE client per hub |
| `Ambient.swift` | the store, the overlay views, the menu bar app, middle-click |
| `AmbientEffects.swift` | styled text, and the macOS 15 TextRenderer effects |
| `AmbientWindows.swift` | the settings and history windows |
| `AmbientCommands.swift` | `pager ambient ...` and `pager event` |
| `AmbientSelfTest.swift` | `pager ambient --selftest`, run by `make check` |

The wire format is [docs/protocol.md](docs/protocol.md). If you change what the
client sends or expects, change the protocol doc and `tools/mock-hub.py` with
it, and run `make hub-test`. It draws a few short test lines on screen.

## Two rules

**Flags are additive only.** Once someone has `pager` inside a cron job or an
error handler, the flags are a contract. Renaming one breaks their script
silently, and they find out the next time it fails to notify them. Add new
flags freely; do not change what an existing one means.

**Nothing may steal the keyboard.** The panel is a non-activating `NSPanel` and
must stay one. That is what lets it appear while someone is typing. No feature
is worth breaking it.

## Style

Comments explain why something is the way it is, usually because the obvious
version was wrong. They do not restate what the code says. If a comment could be
deleted without losing anything, delete it.
