#!/bin/sh
# Build only; never installs or replaces the running input method.
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -ne 0 ]; then
    echo "Usage: sh $0 (production build only)" >&2
    exit 1
fi

distribution_identity="${SUMIBI_DEVELOPER_ID_APPLICATION:-}"
case "$distribution_identity" in
    'Developer ID Application: '*) ;;
    *) echo 'Set SUMIBI_DEVELOPER_ID_APPLICATION to the full Developer ID Application identity name.' >&2; exit 1 ;;
esac
if ! security find-identity -v -p codesigning | grep -F "\"$distribution_identity\"" >/dev/null; then
    echo 'Developer ID Application identity with a private key was not found.' >&2
    exit 1
fi

# Explicitly override inherited signing settings. Only the separate distribution
# copy gets the Developer ID signature and secure timestamp.
SUMIBI_SIGN_IDENTITY=- sh App/build.sh
ruby Development/verify-build.rb production .build/app/Sumibi.app
mkdir -p .build/distribution
distribution_work="$(mktemp -d "$PWD/.build/distribution/build.XXXXXX")"
distribution_app="$distribution_work/Sumibi.app"
ditto --norsrc --noextattr --noacl .build/app/Sumibi.app "$distribution_app"
codesign --force --options runtime --timestamp --sign "$distribution_identity" "$distribution_app"
codesign --verify --strict --verbose=2 "$distribution_app"
distribution_signature="$(codesign --display --verbose=4 "$distribution_app" 2>&1)"
printf '%s\n' "$distribution_signature"
printf '%s\n' "$distribution_signature" | grep -Fx "Authority=$distribution_identity" >/dev/null
printf '%s\n' "$distribution_signature" | grep '^Timestamp=' >/dev/null
printf '%s\n' "$distribution_signature" | grep 'flags=.*runtime' >/dev/null
printf 'Architectures: '
lipo -archs "$distribution_app/Contents/MacOS/Sumibi"
printf 'Distribution app: %s\n' "$distribution_app"
