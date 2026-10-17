#!/bin/bash
# macOS + full Xcode: exercise the real SceneKit loader and bone poses offscreen.
set -euo pipefail
cd "$(dirname "$0")/.."
rig_check_dir=$(mktemp -d /tmp/haymaker-rigs.XXXXXX)
trap 'rm -rf "$rig_check_dir"' EXIT
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -emit-library -emit-module -module-name HaymakerKit \
  Packages/HaymakerKit/Sources/HaymakerKit/*.swift \
  -o "$rig_check_dir/libHaymakerKit.dylib" -emit-module-path "$rig_check_dir/HaymakerKit.swiftmodule"
xcrun swiftc -parse-as-library -I "$rig_check_dir" -L "$rig_check_dir" -lHaymakerKit \
  Haymaker/BoxerModel.swift scripts/verify_fighter_rigs.swift -o "$rig_check_dir/verify"
cp Haymaker/Models/*.fighter "$rig_check_dir/"
DYLD_LIBRARY_PATH="$rig_check_dir" "$rig_check_dir/verify" "${1:-/tmp/haymaker-rig-guard.png}"
