#!/bin/bash
# pager: build it, put it on PATH, and show it off.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${PAGER_BIN:-$HOME/.local/bin}"
SKILLS="$HOME/.claude/skills"
ACCENT=$'\033[38;5;190m'; DIM=$'\033[2m'; OFF=$'\033[0m'
FRAMEWORKS=(-framework Cocoa -framework AVFoundation -framework AVKit)

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$BIN/pager"
  [ -L "$SKILLS/pager" ] && rm -f "$SKILLS/pager"
  [ -L "$HOME/.config/opencode/skills/pager" ] && rm -f "$HOME/.config/opencode/skills/pager"
  printf '\n  %sremoved%s  %s/pager\n\n' "$ACCENT" "$OFF" "$BIN"
  exit 0
fi

# Refresh the checked-in universal binary. Only needed when publishing, and
# it is the one thing that goes stale if you forget it, so bin/ is always
# rebuilt from source for anyone who can compile.
if [ "${1:-}" = "--release" ]; then
  command -v swiftc >/dev/null || { echo "needs swiftc"; exit 1; }
  mkdir -p "$REPO/dist"
  swiftc -O -target arm64-apple-macos13.0  -o /tmp/pager-arm64 "$REPO/src/Pager.swift" "${FRAMEWORKS[@]}"
  swiftc -O -target x86_64-apple-macos13.0 -o /tmp/pager-x86   "$REPO/src/Pager.swift" "${FRAMEWORKS[@]}"
  lipo -create /tmp/pager-arm64 /tmp/pager-x86 -output "$REPO/dist/pager"
  codesign -s - --force "$REPO/dist/pager"
  rm -f /tmp/pager-arm64 /tmp/pager-x86
  printf '\n  %sreleased%s  %s  (%s)\n\n' "$ACCENT" "$OFF" "$REPO/dist/pager" "$(lipo -archs "$REPO/dist/pager")"
  exit 0
fi

mkdir -p "$REPO/bin" "$BIN"

if command -v swiftc >/dev/null 2>&1; then
  swiftc -O -o "$REPO/bin/pager" "$REPO/src/Pager.swift" "${FRAMEWORKS[@]}"
  BUILT="compiled from source"
elif [ -x "$REPO/dist/pager" ]; then
  # No compiler here, so use the universal binary that ships with the repo.
  # A clone is not quarantined, so it runs without a Gatekeeper prompt.
  cp "$REPO/dist/pager" "$REPO/bin/pager"
  BUILT="prebuilt universal binary (no swiftc found)"
  if [ "$REPO/src/Pager.swift" -nt "$REPO/dist/pager" ]; then
    printf '  %swarning%s  dist/pager is older than the source it came from.\n' "$DIM" "$OFF"
  fi
else
  echo "No swiftc and no dist/pager. Install the Xcode command line tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

ln -sf "$REPO/bin/pager" "$BIN/pager"

# The skill is linked, not copied, so the repo stays the only source of truth.
# A copy drifts the moment either side is edited.
if [ -d "$SKILLS" ] && { [ ! -e "$SKILLS/pager" ] || [ -L "$SKILLS/pager" ]; }; then
  ln -sfn "$REPO/skills/pager" "$SKILLS/pager"
elif [ -d "$SKILLS/pager" ]; then
  printf '  %sskipped%s  %s/pager is a real directory, not a link. Remove it to link the repo copy.\n' \
    "$DIM" "$OFF" "$SKILLS"
fi

cat <<INFO

  ${ACCENT}pager installed${OFF}  ${DIM}${BUILT}${OFF}

  ${DIM}binary  ${OFF}$REPO/bin/pager
  ${DIM}on PATH ${OFF}$BIN/pager
  ${DIM}state   ${OFF}$HOME/.pager

INFO

if ! command -v pager >/dev/null 2>&1; then
  printf '  %s%s is not on your PATH.%s Add this to your shell profile:\n\n    export PATH="%s:$PATH"\n\n' \
    "$DIM" "$BIN" "$OFF" "$BIN"
fi

# A tour beats a README for something you have to see. Skipped when piped,
# because a non-interactive install should never take over the screen.
if [ "${1:-}" != "--no-tour" ] && [ -t 1 ]; then
  printf '  %sstarting the tour. it walks through everything, and you can skip it.%s\n\n' "$DIM" "$OFF"
  "$REPO/bin/pager" --tour &
else
  printf '  %stry it:%s  pager --tour\n\n' "$DIM" "$OFF"
fi
