#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
swift build -c release --product SumibiPrototypeIME
prototype_bin_path="$(swift build -c release --show-bin-path)"
prototype_bundle=".build/prototype/Sumibi.app"
prototype_iconset=".build/prototype/AppIcon.iconset"
rm -rf "$prototype_bundle" "$prototype_iconset"
mkdir -p "$prototype_bundle/Contents/MacOS"
mkdir -p "$prototype_bundle/Contents/Resources/ja.lproj"
mkdir -p "$prototype_bundle/Contents/Resources/en.lproj"
mkdir -p "$prototype_iconset"
cp "$prototype_bin_path/SumibiPrototypeIME" "$prototype_bundle/Contents/MacOS/Sumibi"
cp Prototype/Info.plist "$prototype_bundle/Contents/Info.plist"
cp Prototype/ja.lproj/InfoPlist.strings "$prototype_bundle/Contents/Resources/ja.lproj/InfoPlist.strings"
cp Prototype/en.lproj/InfoPlist.strings "$prototype_bundle/Contents/Resources/en.lproj/InfoPlist.strings"
cp Prototype/Resources/MenuBarIcon.png Prototype/Resources/MenuBarIcon@2x.png "$prototype_bundle/Contents/Resources/"
printf 'APPL????' > "$prototype_bundle/Contents/PkgInfo"
# アプリアイコン: Prototype/AppIcon.swiftでiOS版から作ったPrototype/Resources/AppIcon.pngを元にする。
for icon_spec in '16x16:16' '16x16@2x:32' '32x32:32' '32x32@2x:64' \
                 '128x128:128' '128x128@2x:256' '256x256:256' '256x256@2x:512' \
                 '512x512:512' '512x512@2x:1024'; do
    icon_name="${icon_spec%%:*}"
    icon_size="${icon_spec##*:}"
    sips -z "$icon_size" "$icon_size" Prototype/Resources/AppIcon.png \
         --out "$prototype_iconset/icon_${icon_name}.png" >/dev/null
done
iconutil -c icns -o "$prototype_bundle/Contents/Resources/AppIcon.icns" "$prototype_iconset"
# 入力メニューのアイコン: macOSは入力メニューのアイコンを型抜き(テンプレート画像)として描く(Info.plistのTISIconIsTemplate)。
# 地の塗られたアプリアイコンでは線画まで塗りつぶされるので、メニューバーのアイコンと同じ線画だけの画像を使う。
sips -z 16 16 Prototype/Resources/MenuBarIcon@2x.png --out ".build/prototype/InputMenuIcon.png" >/dev/null
sips -z 32 32 Prototype/Resources/MenuBarIcon@2x.png --out ".build/prototype/InputMenuIcon@2x.png" >/dev/null
tiffutil -cathidpicheck ".build/prototype/InputMenuIcon.png" ".build/prototype/InputMenuIcon@2x.png" \
         -out "$prototype_bundle/Contents/Resources/InputMenuIcon.tiff" >/dev/null
prototype_sign_identity="${SUMIBI_PROTOTYPE_SIGN_IDENTITY:--}"
if [ "$prototype_sign_identity" = "-" ]; then
    codesign --force --sign - "$prototype_bundle"
else
    codesign --force --options runtime --sign "$prototype_sign_identity" "$prototype_bundle"
fi
printf '%s\n' "$prototype_bundle"
