#!/bin/bash
# A guided tour of pager, driven by pager.
#
# Every panel below is raised by this script, which then blocks reading the
# panel's stdout. Clicking a button prints its label and unblocks us. That is
# the callback mechanism demonstrating itself: nothing here polls, nothing
# holds a socket, and the tour is a plain shell script.
#
#   pager --tour
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAGER="${PAGER_CMD:-$REPO/bin/pager}"
LIME="#c7ff00"
RED="#ff5f57"
GREEN="#28c840"
BLUE="#5ac8fa"
PURPLE="#bf5af2"

AUTO=0
INTERVAL=13

# --auto runs the whole thing hands free, which is what a screen recording
# needs and what a demo on someone else's machine wants.
while [ $# -gt 0 ]; do
    case "$1" in
        --auto)  AUTO=1; [ -n "${2:-}" ] && [ -z "${2##[0-9]*}" ] && { INTERVAL=$2; shift; } ;;
        --step)  INTERVAL="${2:-13}"; shift ;;
    esac
    shift
done
STEP=0
TOTAL=10
LAST=""

[ -x "$PAGER" ] || { echo "build it first: $REPO/install.sh" >&2; exit 1; }

# Demo panels go in the left corners, the step itself bottom right. An
# explicit corner ignores whatever anchor a dragged panel left behind, so the
# tour lands in the same place every time without disturbing your setup.
ASIDES=()
clear_asides() {
    for pid in ${ASIDES[@]+"${ASIDES[@]}"}; do kill "$pid" 2>/dev/null; done
    ASIDES=()
}
trap clear_asides EXIT

# Raise one step and wait for an answer. The control buttons are appended to
# whatever the step asked for, so each step only has to describe itself.
step() {
    STEP=$((STEP + 1))
    local seconds=900 auto_label="Autoplay"
    if [ "$AUTO" = 1 ]; then seconds=$INTERVAL; auto_label="Stop autoplay"; fi

    LAST=$("$PAGER" "$@" \
        --app "pager" --chip "$STEP of $TOTAL" \
        --width 560 --seconds "$seconds" --corner bottom-right --stack none \
        --action "Next:" --action "$auto_label:" --action "Skip:" | tail -1)

    case "$LAST" in
        "Skip")          farewell; exit 0 ;;
        "Autoplay")      AUTO=1 ;;
        "Stop autoplay") AUTO=0 ;;
        "")              [ "$AUTO" = 1 ] || exit 0 ;;
    esac
}

# A demo panel that sits beside the step explaining it, and is cleared when
# the next group arrives so the screen never accumulates leftovers.
aside() { "$PAGER" "$@" --app "pager" --seconds 240 >/dev/null 2>&1 & ASIDES+=($!); }

farewell() {
    "$PAGER" --title "Tour ended" --app "pager" --accent "$LIME" --seconds 7 \
        --body "Run it again any time with \`pager --tour\`, or \`make tour\` in the repo." >/dev/null 2>&1 &
}

# Commits per day for the last fortnight, as a sparkline.
git_activity() {
    local repo="$1" out="" day count
    for i in $(seq 13 -1 0); do
        day=$(date -v-${i}d +%Y-%m-%d 2>/dev/null) || return 1
        count=$(git -C "$repo" log --since="$day 00:00" --until="$day 23:59:59" \
                --oneline 2>/dev/null | wc -l | tr -d ' ')
        out="$out,$count"
    done
    echo "${out#,}"
}

detect_harnesses() {
    HARNESS_NAMES=(); HARNESS_KINDS=()
    [ -d "$HOME/.claude/skills" ]   && { HARNESS_NAMES+=("Claude Code"); HARNESS_KINDS+=("claude"); }
    [ -d "$HOME/.config/opencode" ] && { HARNESS_NAMES+=("opencode");    HARNESS_KINDS+=("opencode"); }
    [ -f "$HOME/.codex/AGENTS.md" ] && { HARNESS_NAMES+=("Codex");       HARNESS_KINDS+=("codex"); }
    [ -d "$HOME/.gemini" ]          && { HARNESS_NAMES+=("Gemini CLI");  HARNESS_KINDS+=("gemini"); }
}

# Skills-style harnesses get a symlink so the repo stays the only source of
# truth. Single-file harnesses get a fenced block that is replaced, never
# appended twice.
install_for() {
    case "$1" in
        claude)   mkdir -p "$HOME/.claude/skills"
                  ln -sfn "$REPO/skills/pager" "$HOME/.claude/skills/pager" ;;
        opencode) mkdir -p "$HOME/.config/opencode/skills"
                  ln -sfn "$REPO/skills/pager" "$HOME/.config/opencode/skills/pager" ;;
        codex)    write_block "$HOME/.codex/AGENTS.md" ;;
        gemini)   mkdir -p "$HOME/.gemini"; write_block "$HOME/.gemini/GEMINI.md" ;;
    esac
}

write_block() {
    local file="$1" tmp
    tmp=$(mktemp)
    [ -f "$file" ] && sed '/<!-- pager:start -->/,/<!-- pager:end -->/d' "$file" > "$tmp"
    {
        cat "$tmp" 2>/dev/null
        echo
        echo "<!-- pager:start -->"
        echo "## Notifying the user on screen (pager)"
        echo
        echo "\`pager\` raises a floating macOS panel with buttons that run commands."
        echo "It never takes the keyboard, so it is safe to raise while the user types."
        echo
        echo "- Tell them something: \`pager --title \"Tests passed\" --action \"Open:open <url>\"\`"
        echo "- Ask them something: \`answer=\$(pager --title \"Ship it?\" --action \"Yes:\" --action \"No:\")\`"
        echo "- Recipes: \`pager --examples\`. Full reference: $REPO/skills/pager/SKILL.md"
        echo "- Building anything that can fail or produce an event they would want"
        echo "  (errors, deploys, cron, sales, long jobs)? Wire a \`pager\` call into it."
        echo "<!-- pager:end -->"
    } > "$file"
    rm -f "$tmp"
}

# ---------------------------------------------------------------- the tour

step --title "This is pager" --accent "$LIME" --icon "bell.badge" --sound chirp \
     --body "A floating panel that anything on your machine can raise. A shell script, a cron job, a git hook, an agent.

**Keep typing.** It cannot take a keystroke from you. Not by being careful, by construction: this window is built so macOS will never make it the focused one. That is the whole reason it exists rather than a terminal popup, which has to steal your keyboard to be dismissed."

step --title "Deploy failed on production" --accent "$RED" --sound alarm \
     --source "coolify" --icon "exclamationmark.triangle" \
     --chip "production" --chip "8f21ac3" \
     --body "Colour carries the meaning. Red for failure, green for money, amber for degraded, blue for information.

**Rollback is a button**, not a link to a dashboard where the button lives. Any action runs a shell command, so the thing you would have gone looking for is already here.

Sound is *optional* and silence is the default. Ten are bundled, each built on a different synthesis mechanism so they are tellable apart at low volume." \
     --action "Rollback:" --action-fill "$RED" --action-text "#ffffff" \
     --action "Logs:" --action-icon "doc.text"

clear_asides
aside --title "An animated GIF" --source "image" --accent "$LIME" --image "$REPO/assets/waves.gif" \
      --body "\`--image\` takes a still or a GIF." --corner bottom-left
sleep 0.25
aside --title "Video, looping" --source "video" --accent "$LIME" --video "$REPO/assets/clip.mp4" --loop \
      --body "\`--video\` re-fits to the clip's shape. \`--loop\` repeats it." --corner bottom-left
sleep 0.25
aside --title "Sound you can see" --source "audio" --accent "$LIME" --width 420 --corner bottom-left \
      --audio "chirp:chirp" --audio "rise:rise" --audio "fall:fall" --choose "Keep:"
sleep 0.25
step --title "It carries media, not just words" --accent "$LIME" --icon "photo.on.rectangle" \
     --body "Three panels just appeared beside this one.

**A GIF**, playing. **A video**, with its own controls, sized to the clip rather than crammed into a 16:9 box, and looping because it was given \`--loop\`. **Three sounds**, each drawn as the real waveform read out of the file. Click a wave to seek. Starting one stops the others, and while anything plays the countdown holds, so a voice message never gets cut off.

Stills, charts, screenshots and voice notes all live here."

step --title "This panel is a blocked shell script" --accent "$BLUE" \
     --icon "arrow.triangle.2.circlepath" \
     --body "Right now a script is sitting at \`answer=\$(pager …)\` waiting for you.

Whichever button you press prints its label to stdout, and the script carries on. That is the whole callback mechanism. No daemon, no socket, no polling.

It means an agent can **ask you a question** in the middle of a task and simply continue when you answer. To the agent it is a command that took ninety seconds to return. Nothing resumes, nothing reconnects." \
     --action "Copy the snippet:printf 'answer=\$(pager --title \"Ship it?\" --action \"Yes:\" --action \"No:\")\\n' | pbcopy"

SPARK=$(git_activity "$PWD" 2>/dev/null || true)
case "${SPARK:-}" in ""|*[!0,]*) : ;; *) SPARK="" ;; esac
[ -n "${SPARK:-}" ] || SPARK=$(git_activity "$REPO")
COMMITS=$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 0)
clear_asides
aside --title "A still image" --source "image" --accent "$GREEN" --image "$REPO/assets/still.png" \
      --body "Charts, screenshots, a failing test's output." --corner bottom-left
sleep 0.25
step --title "Data, and a menu on every panel" --accent "$GREEN" --icon "chart.xyaxis.line" \
     --sparkline "${SPARK:-1,2,1,4,3,6,5,9,7,12,10,14,11,16}" \
     --chip "$COMMITS commits" \
     --body "That line is **real**: commits per day for the last fortnight, read from the repo you are standing in. A summary can arrive as a shape instead of a number.

Now **right click anywhere on this panel.** Everything the buttons do is in there, plus any copy entries the caller defined. Two are waiting for you." \
     --copy "Copy the install line:git clone https://github.com/SignedAdam/pager.git ~/dev/pager && ~/dev/pager/install.sh" \
     --copy "Copy this panel's command:pager --title 'Data' --sparkline '1,4,3,9' --copy 'Label:text'"

step --title "Pin it, fold it, move it, or deal with it later" --accent "$LIME" --icon "pin" \
     --body "Top right of every panel, in order:

**fold** collapses it to just this line. **pin** stops the countdown so it stays until you deal with it. **clock** brings it back in 10 minutes, 30, an hour, 3 hours, or tomorrow at 9, by re-running its own arguments after a sleep, so what returns is *exactly* this panel. **x** dismisses it.

**Drag it anywhere.** It leaves the stack, the others close the gap, and where you drop it becomes the corner every panel after stacks from. Middle click anywhere dismisses instantly."

step --title "Text and buttons can look like *anything*" --accent "$PURPLE" --icon "paintbrush" \
     --body "Titles and bodies take **bold**, *italic* and \`inline code\`, so \`--body\` can hold a real sentence with a **file path** or a \`command\` in it and you never touch an attributed string.

Any action takes an icon, a background and a label colour. An SF Symbol name or an image file both work. Use it for the one button that deserves to stand out." \
     --action "Merge:" --action-icon "arrow.triangle.merge" --action-fill "#8250df" --action-text "#ffffff" \
     --action "Discard:" --action-icon "trash"

clear_asides
for i in 1 2 3; do
  aside --title "Stacked $i" --source "bottom left" --accent "$BLUE" --width 330 \
        --body "Measured, so a tall one and a short one sit flush." \
        --corner bottom-left --stack vertical
  sleep 0.2
done
for i in 1 2 3; do
  aside --title "Cascaded $i" --source "top left" --accent "$PURPLE" --width 330 \
        --body "Fanned, so every title behind stays readable." \
        --corner top-left --stack cascade
  sleep 0.2
done
step --title "Two ways to arrange them" --accent "$LIME" --icon "square.stack.3d.up" \
     --body "Six panels just appeared. Bottom left, **three stacked**. Top left, **three cascaded**.

\`--stack vertical\` is the default. Each panel measures the height it actually occupies and writes it down, so a tall one with a chart and a one-line one still sit flush.

\`--stack cascade\` fans them out, each one stepped far enough to keep the title behind it readable. Good when a burst arrives together and you want to see what is in the pile.

\`--stack none\` is the third: every panel in exactly the same place, newest on top and the rest hidden behind it. That is what you want when a job fires often and only the latest matters. \`--gap\` sets the spacing for stacking.

\`--corner\` picks which of the four corners a panel belongs to, and each corner stacks on its own, which is how those two groups ignore each other."

detect_harnesses
if [ ${#HARNESS_NAMES[@]} -gt 0 ]; then
    LIST=$(printf '%s, ' "${HARNESS_NAMES[@]}"); LIST="${LIST%, }"
    INSTALL="Install for all ${#HARNESS_NAMES[@]}"
    step --title "Want your agents to know about pager?" --accent "$LIME" --icon "sparkles" \
         --body "An agent will raise one now and then. The real use is an agent **wiring pager into your code once**, and it running forever with nobody in the loop. An error handler, a deploy hook, a cron job, a \`trap\` line at the top of a backup script written a year ago.

Found **$LIST** on this machine. Installing drops the reference where each one already looks, so they reach for pager without being told. Skills-style harnesses get a symlink to this repo, so it can never go stale. Single-file ones get a small block that is replaced on reinstall rather than appended twice.

They read separate directories, so installing for one does not cover the others." \
         --action "$INSTALL:" --action-fill "$LIME" --action-text "#12140f" \
         --action "Not now:"
    if [ "$LAST" = "$INSTALL" ]; then
        for kind in "${HARNESS_KINDS[@]}"; do install_for "$kind"; done
        "$PAGER" --title "Installed for ${#HARNESS_NAMES[@]} agent harnesses" --accent "$GREEN" \
                 --sound rise --seconds 9 --body "$LIST" >/dev/null 2>&1 &
    fi
else
    step --title "No agent harnesses found" --accent "$LIME" --icon "sparkles" \
         --body "The real use of pager is an agent **wiring it into your code once**, and it running forever with nobody in the loop.

The reference lives at \`skills/pager/SKILL.md\` in this repo. Point whatever you use at it and it will know the flags, the colour conventions, and how to wire pager into bash, Python and cron."
fi

step --title "Got a cool idea, or found a bug?" --accent "$LIME" --icon "heart" --sound glass \
     --body "Open an issue on GitHub and I will take a look.

*- Adam*" \
     --action "Open an issue:open https://github.com/SignedAdam/pager/issues/new" \
     --action-icon "assets/github.png" --action-fill "#24292f" --action-text "#ffffff"

"$PAGER" --title "That is pager" --accent "$LIME" --sound chirp --seconds 14 \
    --body "\`pager --tour\` runs this again. \`pager --examples\` prints recipes. \`pager --sounds\` plays the ten. \`make\` in the repo lists the rest." >/dev/null 2>&1 &
