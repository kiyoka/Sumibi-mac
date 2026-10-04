#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
sumibi_development=0
case "${1:-}" in
    '') ;;
    --development) sumibi_development=1; shift ;;
    *) echo 'Usage: sh App/build.sh [--development]' >&2; exit 1 ;;
esac
[ "$#" -eq 0 ] || { echo 'Unexpected build arguments.' >&2; exit 1; }
# Never inherit the development feature flag from the shell in a production build.
export SUMIBI_DEVELOPMENT_FEATURES="$sumibi_development"
swift build -c release --product SumibiIME
sumibi_bin_path="$(swift build -c release --show-bin-path)"
sumibi_bundle=".build/app/Sumibi.app"
sumibi_iconset=".build/app/AppIcon.iconset"
if [ "$sumibi_development" = 1 ]; then
    sumibi_bundle=".build/development/Sumibi.app"
    sumibi_iconset=".build/development/AppIcon.iconset"
fi
sumibi_work="$(dirname "$sumibi_bundle")"
rm -rf "$sumibi_bundle" "$sumibi_iconset"
mkdir -p "$sumibi_bundle/Contents/MacOS"
mkdir -p "$sumibi_bundle/Contents/Resources/ja.lproj"
mkdir -p "$sumibi_bundle/Contents/Resources/en.lproj"
mkdir -p "$sumibi_bundle/Contents/Resources/SudachiDict"
mkdir -p "$sumibi_iconset"
cp "$sumibi_bin_path/SumibiIME" "$sumibi_bundle/Contents/MacOS/Sumibi"
cp App/Info.plist "$sumibi_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SumibiDevelopmentBuild bool $([ "$sumibi_development" = 1 ] && echo true || echo false)" "$sumibi_bundle/Contents/Info.plist"
cp App/ja.lproj/InfoPlist.strings "$sumibi_bundle/Contents/Resources/ja.lproj/InfoPlist.strings"
cp App/en.lproj/InfoPlist.strings "$sumibi_bundle/Contents/Resources/en.lproj/InfoPlist.strings"
cp App/Resources/MenuBarIcon.png App/Resources/MenuBarIcon@2x.png "$sumibi_bundle/Contents/Resources/"
cp App/Resources/SudachiCandidates.tsv "$sumibi_bundle/Contents/Resources/"
cp ThirdParty/SudachiDict/LICENSE-2.0.txt ThirdParty/SudachiDict/LEGAL "$sumibi_bundle/Contents/Resources/SudachiDict/"
printf 'APPL????' > "$sumibi_bundle/Contents/PkgInfo"
# アプリアイコン: Development/Tools/AppIcon.swiftでiOS版から作ったApp/Resources/AppIcon.pngを元にする。
for icon_spec in '16x16:16' '16x16@2x:32' '32x32:32' '32x32@2x:64' \
                 '128x128:128' '128x128@2x:256' '256x256:256' '256x256@2x:512' \
                 '512x512:512' '512x512@2x:1024'; do
    icon_name="${icon_spec%%:*}"
    icon_size="${icon_spec##*:}"
    sips -z "$icon_size" "$icon_size" App/Resources/AppIcon.png \
         --out "$sumibi_iconset/icon_${icon_name}.png" >/dev/null
done
iconutil -c icns -o "$sumibi_bundle/Contents/Resources/AppIcon.icns" "$sumibi_iconset"
# 入力メニューのアイコン: macOSは入力メニューのアイコンを型抜き(テンプレート画像)として描く(Info.plistのTISIconIsTemplate)。
# 地の塗られたアプリアイコンでは線画まで塗りつぶされるので、メニューバーのアイコンと同じ線画だけの画像を使う。
sips -z 16 16 App/Resources/MenuBarIcon@2x.png --out "$sumibi_work/InputMenuIcon.png" >/dev/null
sips -z 32 32 App/Resources/MenuBarIcon@2x.png --out "$sumibi_work/InputMenuIcon@2x.png" >/dev/null
tiffutil -cathidpicheck "$sumibi_work/InputMenuIcon.png" "$sumibi_work/InputMenuIcon@2x.png" \
         -out "$sumibi_bundle/Contents/Resources/InputMenuIcon.tiff" >/dev/null
sumibi_sign_identity="${SUMIBI_SIGN_IDENTITY:-${SUMIBI_PROTOTYPE_SIGN_IDENTITY:--}}"
if [ "$sumibi_sign_identity" = "-" ]; then
    codesign --force --sign - "$sumibi_bundle"
else
    codesign --force --options runtime --sign "$sumibi_sign_identity" "$sumibi_bundle"
fi
printf '%s\n' "$sumibi_bundle"
