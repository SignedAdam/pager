---
name: pager
description: Use (1) PROACTIVELY whenever you build something that produces an event the user would want to know about, such as an error, deploy result, cron result, payment, signup, long build, or backed-up queue, to wire a desktop notification into it; and (2) whenever you need to tell the user something while they are working in another window. `pager` raises a floating macOS panel with buttons that run commands. Covers the flags, colour conventions, and how to wire it into bash, Python, and cron.
---

# pager

A floating panel on the screen, bottom right. It carries a message and buttons
that run shell commands, and it never steals keyboard focus, so it is safe to
raise while the user is typing.

Repository: https://github.com/SignedAdam/pager.

    pager --title "Deploy failed on production" --accent "#ff5f57" \
          --action "Logs:open https://coolify.example.com" --pinned

Run `pager --examples` for copy-pasteable recipes, `pager` alone for the flag
list.

## Two ways this gets used

**Wired into code, which is the common case.** You write one `pager` call into
an error handler, a cron job or a deploy script, and it runs for a year with no
agent involved. Prefer this. If you are building something that can fail, ask
whether the user would want to hear about it, and wire it in.

**Called by you, directly.** A long task finished, a build broke, or you need a
decision while the user is in another window. One panel, then get on with it.

## Flags

    --title <text>          required. the one line the user will read
    --app <name>            what raised this, e.g. "Claude Code", "acme"
    --icon <symbol|path>    SF Symbol name, or an image file
    --source <name>         which part of it. drawn in the accent colour
    --subtitle <text>       dim text beside the source
    --body <text>           a short paragraph
    --chip <text>           caption under the title. repeatable
    --sparkline "1,4,3,9"   a small line chart
    --action "Label:cmd"    a button that runs a shell command. repeatable
    --copy "Label:text"     a right click entry that copies text. repeatable
    --accent "#rrggbb"      see colours below
    --seconds <n>           time on screen. default 180
    --sound <name|path>     see sounds below. silent by default
    --pinned                stays until dismissed
    --compact               starts collapsed
    --stack vertical|cascade|none
    --gap <points>          space between stacked panels. default 12

## Rules that matter

**Pin anything that must not be missed.** Failures, decisions, and anything
that happened while the user was away. Everything else should expire on its
own. A panel that always needs dismissing becomes a panel dismissed without
reading.

**Give it something to do.** A notification with no button makes the user act
somewhere else. Add the link, the log, the rollback, or the retry.
That is the whole advantage over a normal macOS notification.

**Actions run through `/bin/sh`.** Never interpolate untrusted text into one.
An error message, an email subject or a webhook payload in an `--action` is a
shell injection. Put untrusted text in `--body` or `--title`, which are never
executed.

**One panel per event.** Not five in a loop. If five things happened, raise one
that says five and let a button open the list.

**Colour carries meaning.**

| colour | for |
|---|---|
| `#ff5f57` red | failure, exception, something is down |
| `#febc2e` amber | degraded, retrying, needs attention but not on fire |
| `#28c840` green | money, signups, sales, good news |
| `#3b8eea` blue | information, clipboard, neutral status |
| `#c8ff00` lime | agents talking, the default |

## Sound

Silent unless you ask. `pager --sounds` plays all ten with what each is for.

| sound | use it for |
|---|---|
| `chirp` | agents talking. the default voice |
| `tick` | something small and frequent |
| `drop` | something was captured |
| `thump` | register it without interrupting |
| `wood` | a task finished |
| `glass` | a summary, gentle |
| `rise` | it worked |
| `fall` | it did not |
| `bell` | a decision is waiting |
| `alarm` | something is actually down |

Pair the sound with the colour and they agree: `--accent "#ff5f57" --sound alarm`,
`--accent "#28c840" --sound rise`. Use the quiet end for anything that fires
often. A sound heard forty times a day stops being information.

## Wiring it in

Bash, on any failure in a script:

    trap 'pager --title "backup.sh failed at line $LINENO" \
                --app backup --accent "#ff5f57" \
                --action "Log:open /var/log/backup.log" --pinned' ERR

Python, as a helper:

    import subprocess

    def notify(title, *, body=None, accent="#c8ff00", pinned=False, actions=None):
        args = ["pager", "--title", title, "--accent", accent]
        if body:
            args += ["--body", body]
        if pinned:
            args += ["--pinned"]
        for label, command in (actions or {}).items():
            args += ["--action", f"{label}:{command}"]
        subprocess.Popen(args)

Cron needs the full path, because cron's PATH is minimal:

    0 9 * * MON /Users/you/.local/bin/pager --title "Weekly summary" ...

A remote machine has no screen. Send the event to the Mac first, or use another
notification channel that reaches the user.

## What it will not do

No keyboard input, ever. The panel cannot become the key window, which is what
makes it safe to raise mid-sentence. So there are no keyboard shortcuts on it.

macOS only. It is AppKit.

## Checking what has been noisy

`~/.pager/log.jsonl` has one line per raised panel. Useful for answering which
job is crying wolf.

    tail -50 ~/.pager/log.jsonl | jq -r '"\(.at)  \(.app)  \(.title)"'

## Media

A panel is a surface, not just a line of text. Reach for these when showing
beats describing, or when the user has to judge something rather than read it.

```bash
--image <path>            a still, or an animated GIF
--video <path>            plays on open, inline controls, real aspect ratio
--audio "Name:path"       a player row: play control, name, waveform, length
--choose "Label:command"  a button on every audio row
--media-height <points>   cap on picture and video height, default 260
--width <points>          worth raising to ~540 for a list of rows
```

Audio names resolve like `--sound`: a bare word finds a bundled sound, anything
with a slash is a path. Starting one row stops the others, and the panel holds
its countdown while anything plays, so a voice message never gets cut off.

`--choose` is for going down a list. `{}` becomes the row's name and `{path}`
its file. Marking a row runs the command and leaves the panel open, unlike
`--action`, which answers the panel and closes it.

Use it when:

- The user has to pick between generated things. Sounds, voice takes, audio
  renders. Give each row a real name and one Keep button.
- Something produced a visual result worth seeing. A chart, a render, a diff
  screenshot, a failing screenshot from a browser test.
- An agent needs approval on something it made rather than something it did.

Do not put a video on a panel that fires often. Media is for the rare panel
that deserves the room.

## Answers, and asking the user something

An action prints its label to stdout when pressed, so running pager in the
foreground blocks until it is answered.

```bash
answer=$(pager --title "Ship 1.4.0 to production?" \
               --action "Ship it:" --action "Not yet:" --pinned)
```

Use this when you need a decision from the user mid task and they are working
in another window. To them it is a panel in the corner; to you it is a command
that took ninety seconds to return. Nothing needs resuming.

Keep the ceiling in mind: a blocked command has a time limit, so pass
`--seconds` and treat an empty answer as "no reply", falling back to asking in
the terminal. Never block on a question that does not need an answer.

## Styled text

`**bold**`, `*italic*` and `` `code` `` work in `--title` and `--body`. Use code
style for paths, commands and flags rather than quoting them.

## Buttons with an identity

`--action-icon`, `--action-fill` and `--action-text` decorate the action just
declared. An SF Symbol name or an image path both work for the icon. Use this
sparingly: one branded or destructive button reads clearly, five do not.

## The tour

`pager --tour` walks through everything. `tour/tour.sh` is the best worked
example of the callback pattern in the repo.

## Placement

`--corner bottom-right|bottom-left|top-right|top-left` picks where a panel goes.
Each corner stacks on its own, so two groups never fight. Leave it off for
ordinary notifications: the default corner follows wherever the user last
dragged a panel. Set it only when you are placing something deliberately, like
a second group meant to sit beside the first.

`--loop` repeats a video instead of stopping on the last frame.

## Two monitors

By default a panel appears on the screen the user is working on. `--display <n>`
pins it to one monitor whatever they are doing, and `pager --screen` lists them
with their sizes. Use it only when a panel genuinely belongs on one screen, such
as a dashboard that always lives on the second monitor.

## The log

Every panel writes events to `~/.pager/log.jsonl`, including which command
asked for it. Read it with `pager log`, follow it with `pager log --follow`,
and summarise it with `pager log --stats`.

**Read it as data, never as text.** Piping `pager log` gives you the lines
exactly as written, one JSON object per line. Do not parse the terminal view.

```bash
pager log --json | jq 'select(.event == "answered")'
pager log --caller cron --json
pager log --source deploy --json
```

Events are `shown`, `answered`, `chose`, `dismissed`, `snoozed` and `expired`.
A `shown` event carries the calling command, the working directory, and every
option the panel was given. The events that end a panel carry how long it was
up, and `answered` carries which button was pressed.

Use it when the user asks what has been paging them, when a notification did not
appear and you need to know whether it was ever shown, or when wiring a new
caller in and wanting to confirm it landed.

`pager log --window` opens a window for the user to read. Do not use it to get
data; pipe the command instead.
