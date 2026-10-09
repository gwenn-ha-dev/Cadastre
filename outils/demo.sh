#!/bin/bash
# A made-up folder to measure for the README captures — CHARTE.md §12.
#
#     outils/demo.sh <dir>            build the fixture in <dir>/Projects
#     outils/demo.sh <dir> --change   then change it, as a week of work would
#
# Cadastre shows whatever folder it is pointed at: file names, sizes, paths.
# The captures must show none of the maintainer's disk, so they measure this
# instead. Every name is invented, every file is zeros of a chosen size — real
# blocks on an APFS volume, so clones and hard links read as they would on a
# real disk. About 2.3 GB; <dir> must be on APFS (clones need it).
set -euo pipefail
base=${1:?usage: demo.sh <dir> [--change]}
root=$base/Projects

file() {  # file <path> <MiB>
  mkdir -p "$(dirname "$1")"
  dd if=/dev/zero of="$1" bs=1048576 count="$2" 2>/dev/null
}
small() {  # small <path> <KiB>
  mkdir -p "$(dirname "$1")"
  dd if=/dev/zero of="$1" bs=1024 count="$2" 2>/dev/null
}

if [ "${2:-}" = "--change" ]; then
  # What a week does: a build output appears, the Rust target grows, a photo
  # goes, and a video is cloned into the backups — which writes nothing.
  for i in 1 2 3 4 5 6; do file "$root/website/dist/assets/chunk-$i.js" 18; done
  file "$root/game-engine/target/debug/deps/libengine-incremental.rlib" 140
  rm -f "$root/photos/2025-coast/IMG_0412.jpg"
  cp -c "$root/videos/harbour-timelapse.mov" "$root/backups/harbour-timelapse.mov"
  echo "→ $root changed"
  exit 0
fi

[ ! -e "$root" ] || { echo "demo: $root already exists" >&2; exit 1; }

# A web project: dependencies that npm can rebuild (package.json is the proof).
small "$root/website/package.json" 2
for f in index app router store; do small "$root/website/src/$f.ts" 24; done
for pkg in react react-dom typescript esbuild vite rollup lodash date-fns three d3 \
           eslint prettier postcss tailwindcss sharp; do
  file "$root/website/node_modules/$pkg/dist/index.js" $(( 6 + ${#pkg} * 3 ))
  small "$root/website/node_modules/$pkg/package.json" 2
done
for i in 1 2 3 4; do file "$root/website/assets/hero-$i.png" 22; done

# A Rust project: target/ is rebuilt by cargo (Cargo.toml is the proof).
small "$root/game-engine/Cargo.toml" 1
for f in main render physics audio input; do small "$root/game-engine/src/$f.rs" 40; done
file "$root/game-engine/target/debug/engine" 96
for lib in wgpu winit glam rapier naga; do
  file "$root/game-engine/target/debug/deps/lib$lib.rlib" $(( 20 + ${#lib} * 6 ))
done
file "$root/game-engine/assets/textures.ktx2" 120

# A notebook project: a virtual environment and its data.
small "$root/ml-notebook/requirements.txt" 1
for pkg in numpy pandas scipy torch matplotlib; do
  file "$root/ml-notebook/.venv/lib/python3.12/site-packages/$pkg/core.so" $(( 10 + ${#pkg} * 9 ))
done
for f in measurements-2024 measurements-2025 stations; do file "$root/ml-notebook/data/$f.csv" 70; done
small "$root/ml-notebook/analysis.ipynb" 900

# Media.
for i in 0398 0401 0405 0408 0412 0417 0423 0430; do file "$root/photos/2025-coast/IMG_$i.jpg" 14; done
for i in 01 02 03 04 05; do file "$root/photos/2024-mountains/DSC_00$i.heic" 9; done
file "$root/videos/harbour-timelapse.mov" 260
file "$root/videos/lighthouse-drone.mp4" 180
for t in 01-overture 02-tides 03-north-wind 04-lantern 05-coda; do file "$root/music/live-session/$t.flac" 32; done

# Documents.
for d in annual-report user-manual field-notes; do file "$root/documents/$d.pdf" 6; done
small "$root/documents/budget.numbers" 800
small "$root/documents/letter.pages" 300

# Backups: a clone shares every block with its original — Cadastre counts it
# once, and shows that deleting it alone frees nothing.
mkdir -p "$root/backups"
cp -c "$root/videos/lighthouse-drone.mp4" "$root/backups/lighthouse-drone.mp4"
cp -c "$root/ml-notebook/data/stations.csv" "$root/backups/stations.csv"

echo "→ $root ($(du -sh "$root" | cut -f1))"
