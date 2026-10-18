#!/bin/bash
# macOS + full Xcode: load every HMR2 rig and fighter.clips offscreen, drive the
# real animation, choreography and engine code, run continuity / contact / floor /
# deformation checks and render QA contact sheets.
#   bash scripts/verify_fighter_rigs.sh [output-dir]      (default build/fighter-qa)
# HAYMAKER_FIGHTER_ASSETS overrides the asset folder (default Haymaker/Models);
# HAYMAKER_RIG_WORKDIR overrides the build folder (default <output-dir>/work).
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-build/fighter-qa}
work=${HAYMAKER_RIG_WORKDIR:-$out/work}
assets=${HAYMAKER_FIGHTER_ASSETS:-Haymaker/Models}
mkdir -p "$out" "$work"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -O -enable-testing -emit-library -emit-module -module-name HaymakerKit \
  Packages/HaymakerKit/Sources/HaymakerKit/*.swift \
  -o "$work/libHaymakerKit.dylib" -emit-module-path "$work/HaymakerKit.swiftmodule"
xcrun swiftc -O -parse-as-library -I "$work" -L "$work" -lHaymakerKit \
  Haymaker/FighterRig.swift Haymaker/FighterClips.swift Haymaker/FighterAnimator.swift \
  Haymaker/BoxerModel.swift Haymaker/FootPlanting.swift Haymaker/BoutChoreographer.swift scripts/verify_fighter_rigs.swift \
  -o "$work/verify"
# The loaders read Bundle.main, which for a command-line tool is the binary's folder.
cp "$assets"/*.fighter "$assets"/fighter.clips "$work/"
DYLD_LIBRARY_PATH="$work" "$work/verify" "$out"
