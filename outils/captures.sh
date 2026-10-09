#!/bin/bash
# README captures — CHARTE.md §12. `make shots` delegates here.
#
# Cadastre shows whatever folder it measures, so the captures never point it at
# a real disk: outils/demo.sh builds an invented "Projects" folder in
# /tmp/cadastre-demo, and every shot measures that. The marker history goes to
# the same place (CADASTRE_HOME), not to the user's.
#
# Each shot launches the bundle's binary directly — so that CADASTRE_HOME
# reaches it — on one view, in one language, and captures its window with the
# charter's capturer. Views: the map by file type (hero), the map by shared
# blocks, the reclaim panel, and "what changed" after a simulated week.
set -euo pipefail
cd "$(dirname "$0")/.."
capturer=${CHARTE:-../../Charte}/outils/capturer.sh
app=build/Cadastre.app
[ -d "$app" ] || { echo "captures: build the app first (make package)" >&2; exit 1; }
binary=$app/Contents/MacOS/cadastre
demo=/tmp/cadastre-demo
export CADASTRE_HOME=$demo/history

# The fixture is rebuilt from scratch: "what changed" mutates it.
rm -rf /tmp/cadastre-demo
mkdir -p "$demo"
./outils/demo.sh "$demo"

shot() {  # shot <language> <out> <cadastre arguments…>
  local lang=$1 out=$2; shift 2
  local locale; locale=$( [ "$lang" = en ] && echo en_GB || echo fr_FR )
  pkill -x cadastre 2>/dev/null || true
  sleep 1
  ("$binary" "$demo/Projects" --ui "$@" -AppleLanguages "($lang)" -AppleLocale "$locale" >/dev/null 2>&1 &)
  sleep 5
  "$capturer" cadastre "$out"
}

for lang in en fr; do
  suffix=$( [ "$lang" = en ] && echo "" || echo ".fr" )
  shot "$lang" "docs/img/map$suffix.png"
  shot "$lang" "docs/img/shared$suffix.png" --color-mode sharing
  shot "$lang" "docs/img/reclaim$suffix.png" --open reclaim
done

# A marker, a week of work, and the comparison.
pkill -x cadastre 2>/dev/null || true
"$binary" "$demo/Projects" --save auto --no-color >/dev/null
sleep 1
./outils/demo.sh "$demo" --change
for lang in en fr; do
  suffix=$( [ "$lang" = en ] && echo "" || echo ".fr" )
  shot "$lang" "docs/img/changes$suffix.png" --since last --open changes
done
pkill -x cadastre 2>/dev/null || true
