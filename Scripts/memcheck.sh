#!/bin/bash
# Memory-growth smoke test: opens a Markdown, a Mermaid and a LaTeX project, compiles, closes them,
# and repeats. Fails when the app's footprint after closing keeps climbing across cycles.
#
#   Scripts/memcheck.sh [path/to/Proof.app] [cycles=5] [max growth MiB=25]
#
# Runs a throwaway copy with its own bundle id, so your settings and recents are untouched.
# Needs Accessibility permission for the terminal (System Events drives the menus).
set -euo pipefail
exec 2>/dev/null

SRC=${1:-build/Proof.app}
CYCLES=${2:-5}
MAX_GROWTH=${3:-25}
[ -d "$SRC" ] || { echo "No app at $SRC (run Scripts/build-app.sh first)"; exit 2; }

WORK=$(mktemp -d)
APP="$WORK/ProofMemcheck.app"
BUNDLE_ID=com.taufanzamzami.compilerpro.memcheck
cp -R "$SRC" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP" >/dev/null
defaults write $BUNDLE_ID cp.autoCheckUpdates -bool false
defaults write $BUNDLE_ID cp.restoreSession -bool false

mkdir -p "$WORK/md" "$WORK/mmd" "$WORK/tex"
printf '# Notes\n\nInline $e^{i\\pi}+1=0$.\n\n```mermaid\ngraph TD; A-->B\n```\n\n- [ ] task\n' > "$WORK/md/notes.md"
printf 'graph TD\n  A[Start] --> B{Check}\n  B -->|yes| C[Done]\n  B -->|no| A\n' > "$WORK/mmd/flow.mmd"
printf '\\documentclass{article}\n\\begin{document}\n\\section{Hi}\n$\\int_0^1 x\\,dx$\n\\end{document}\n' > "$WORK/tex/main.tex"

open -n -a "$APP"; sleep 5
PID=$(pgrep -f "$APP/Contents/MacOS" | head -1)
cleanup() { kill "$PID" 2>/dev/null || true; defaults delete $BUNDLE_ID >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

osa() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to $1" 2>/dev/null || true; }
footprint_mib() { footprint -p "$PID" -f bytes --noCategories | awk '/phys_footprint:/ {printf "%.1f", $2/1048576; exit}'; }

echo "cold start: $(footprint_mib) MiB"
first=""
for c in $(seq 1 "$CYCLES"); do
  for f in "$WORK/md/notes.md" "$WORK/mmd/flow.mmd" "$WORK/tex/main.tex"; do open -a "$APP" "$f"; sleep 4; done
  osa 'set frontmost to true'; osa 'click menu item "Compile" of menu "Build" of menu bar 1'; sleep 15
  open_mib=$(footprint_mib)
  case "$(osa 'get name of windows')" in
    *" – "*) ;;
    *) echo "Cannot see the app's windows (screen locked, or no Accessibility permission)"; exit 2 ;;
  esac
  for _ in 1 2 3 4 5 6; do
    case "$(osa 'get name of windows')" in
      *" – "*) osa 'set frontmost to true'; osa 'click menu item "Close" of menu "File" of menu bar 1'; sleep 2 ;;
      *) break ;;
    esac
  done
  sleep 30
  closed_mib=$(footprint_mib)
  echo "cycle $c: open $open_mib MiB, closed $closed_mib MiB"
  [ -z "$first" ] && first=$closed_mib
done

growth=$(awk -v a="$first" -v b="$closed_mib" 'BEGIN{printf "%.1f", b-a}')
echo "growth after close, cycle 1 -> $CYCLES: $growth MiB (limit $MAX_GROWTH)"
awk -v g="$growth" -v m="$MAX_GROWTH" 'BEGIN{exit !(g <= m)}' && echo PASS || { echo FAIL; exit 1; }
