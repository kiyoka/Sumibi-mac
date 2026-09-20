#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
swift build --product SumibiPrototypeIME
prototype_bin_path="$(swift build --show-bin-path)"
prototype_bundle=".build/prototype/SumibiPrototypeIME.app"
mkdir -p "$prototype_bundle/Contents/MacOS"
mkdir -p "$prototype_bundle/Contents/Resources"
cp "$prototype_bin_path/SumibiPrototypeIME" "$prototype_bundle/Contents/MacOS/"
cp Prototype/Info.plist "$prototype_bundle/Contents/Info.plist"
swift Prototype/Icon.swift "$prototype_bundle/Contents/Resources/PrototypeIcon.tiff"
codesign --force --sign - "$prototype_bundle"
printf '%s\n' "$prototype_bundle"
