#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
swift build --product SumibiPrototypeIME
prototype_bin_path="$(swift build --show-bin-path)"
prototype_bundle=".build/prototype/SumibiPrototypeIME.app"
prototype_iconset=".build/prototype/PrototypeIcon.iconset"
mkdir -p "$prototype_bundle/Contents/MacOS"
mkdir -p "$prototype_bundle/Contents/Resources"
mkdir -p "$prototype_iconset"
cp "$prototype_bin_path/SumibiPrototypeIME" "$prototype_bundle/Contents/MacOS/"
cp Prototype/Info.plist "$prototype_bundle/Contents/Info.plist"
printf 'APPL????' > "$prototype_bundle/Contents/PkgInfo"
swift Prototype/Icon.swift "$prototype_bundle/Contents/Resources/PrototypeIcon.tiff" ".build/prototype/PrototypeIcon.png"
for icon_spec in '16x16:16' '16x16@2x:32' '32x32:32' '32x32@2x:64' \
                 '128x128:128' '128x128@2x:256' '256x256:256' '256x256@2x:512' \
                 '512x512:512' '512x512@2x:1024'; do
    icon_name="${icon_spec%%:*}"
    icon_size="${icon_spec##*:}"
    sips -z "$icon_size" "$icon_size" ".build/prototype/PrototypeIcon.png" \
         --out "$prototype_iconset/icon_${icon_name}.png" >/dev/null
done
iconutil -c icns -o "$prototype_bundle/Contents/Resources/PrototypeIcon.icns" "$prototype_iconset"
prototype_sign_identity="${SUMIBI_PROTOTYPE_SIGN_IDENTITY:--}"
if [ "$prototype_sign_identity" = "-" ]; then
    codesign --force --sign - "$prototype_bundle"
else
    codesign --force --options runtime --sign "$prototype_sign_identity" "$prototype_bundle"
fi
printf '%s\n' "$prototype_bundle"
