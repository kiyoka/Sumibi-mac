#!/bin/sh
# Create a home-domain-only product; never install it or run the input method.
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -ne 1 ] || [ ! -d "$1/Contents" ]; then
    echo "Usage: sh $0 /path/to/Developer-ID-signed/Sumibi.app" >&2
    exit 1
fi
distribution_app="$1"
case "$distribution_app" in
    /*) ;;
    *) echo 'Provide an absolute application path.' >&2; exit 1 ;;
esac
distribution_identity="${SUMIBI_DEVELOPER_ID_INSTALLER:-}"
case "$distribution_identity" in
    'Developer ID Installer: '*) ;;
    *) echo 'Set SUMIBI_DEVELOPER_ID_INSTALLER to the full Developer ID Installer identity name.' >&2; exit 1 ;;
esac
if ! security find-identity -v -p basic | grep -F "\"$distribution_identity\"" >/dev/null; then
    echo 'Developer ID Installer identity with a private key was not found.' >&2
    exit 1
fi
ruby Development/verify-build.rb production "$distribution_app"
distribution_signature="$(codesign --display --verbose=4 "$distribution_app" 2>&1)"
printf '%s\n' "$distribution_signature" | grep '^Authority=Developer ID Application:' >/dev/null
printf '%s\n' "$distribution_signature" | grep '^Timestamp=' >/dev/null
printf '%s\n' "$distribution_signature" | grep 'flags=.*runtime' >/dev/null
distribution_team="$(printf '%s\n' "$distribution_signature" | sed -n 's/^TeamIdentifier=//p')"
if [ -z "$distribution_team" ]; then
    echo 'App signing team is missing.' >&2; exit 1
fi
case "$distribution_identity" in
    *" ($distribution_team)") ;;
    *) echo 'Application and Installer identities must belong to the same team.' >&2; exit 1 ;;
esac
distribution_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$distribution_app/Contents/Info.plist")"
if [ "$distribution_bundle_id" != 'org.sumibi.inputmethod.Sumibi' ]; then
    echo 'Unexpected application bundle identifier.' >&2; exit 1
fi
distribution_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$distribution_app/Contents/Info.plist")"
distribution_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$distribution_app/Contents/Info.plist")"
distribution_min_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$distribution_app/Contents/Info.plist")"
for distribution_number in "$distribution_version" "$distribution_build" "$distribution_min_os"; do
    case "$distribution_number" in
        ''|*[!0-9.]*|.*|*.|*..*) echo 'Version, build and minimum OS must contain digits separated by dots.' >&2; exit 1 ;;
    esac
done
distribution_architectures="$(lipo -archs "$distribution_app/Contents/MacOS/Sumibi")"
case "$distribution_architectures" in
    arm64|x86_64|'arm64 x86_64'|'x86_64 arm64') ;;
    *) echo 'Unsupported executable architecture.' >&2; exit 1 ;;
esac
distribution_architectures="$(printf '%s' "$distribution_architectures" | tr ' ' ',')"
mkdir -p .build/distribution
distribution_work="$(mktemp -d "$PWD/.build/distribution/package.XXXXXX")"
mkdir "$distribution_work/payload"
ditto --norsrc --noextattr --noacl "$distribution_app" "$distribution_work/payload/Sumibi.app"
pkgbuild --root "$distribution_work/payload" --component-plist Distribution/components.plist \
    --identifier org.sumibi.inputmethod.Sumibi.user --version "$distribution_build" \
    --install-location '/Library/Input Methods' "$distribution_work/Sumibi-component.pkg"
sed -e "s/@BUILD@/$distribution_build/g" -e "s/@ARCHITECTURES@/$distribution_architectures/g" \
    -e "s/@MIN_OS@/$distribution_min_os/g" \
    Distribution/Distribution.xml.in > "$distribution_work/Distribution.xml"
distribution_pkg="$distribution_work/Sumibi-$distribution_version-$distribution_build-$distribution_architectures.pkg"
productbuild --distribution "$distribution_work/Distribution.xml" --package-path "$distribution_work" \
    --sign "$distribution_identity" --timestamp "$distribution_pkg"
distribution_pkg_signature="$(pkgutil --check-signature "$distribution_pkg")"
printf '%s\n' "$distribution_pkg_signature"
printf '%s\n' "$distribution_pkg_signature" | grep -F "$distribution_identity" >/dev/null
printf 'Signed user-only package (not yet notarized): %s\n' "$distribution_pkg"
