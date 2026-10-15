#!/bin/sh
# Explicit submission command; credentials stay in a notarytool Keychain profile.
set -eu
if [ "$#" -ne 2 ]; then
    echo "Usage: sh $0 /absolute/path/Sumibi.pkg keychain-profile" >&2
    exit 1
fi
distribution_pkg="$1"
distribution_profile="$2"
case "$distribution_pkg" in
    /*.pkg) ;;
    *) echo 'Provide an absolute .pkg path.' >&2; exit 1 ;;
esac
if [ ! -f "$distribution_pkg" ] || [ -z "$distribution_profile" ]; then
    echo 'Package or Keychain profile is missing.' >&2
    exit 1
fi
distribution_signature="$(pkgutil --check-signature "$distribution_pkg")"
printf '%s\n' "$distribution_signature"
if ! printf '%s\n' "$distribution_signature" | grep -F 'Developer ID Installer:' >/dev/null; then
    echo 'Package must be signed with Developer ID Installer.' >&2
    exit 1
fi
distribution_receipts="$(mktemp -d "${distribution_pkg%.pkg}.notary.XXXXXX")"
printf 'Notarization receipts: %s\n' "$distribution_receipts"
xcrun notarytool submit "$distribution_pkg" --keychain-profile "$distribution_profile" \
    --wait --output-format plist > "$distribution_receipts/submission.plist"
distribution_status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$distribution_receipts/submission.plist")"
distribution_submission="$(/usr/libexec/PlistBuddy -c 'Print :id' "$distribution_receipts/submission.plist")"
xcrun notarytool log "$distribution_submission" --keychain-profile "$distribution_profile" \
    "$distribution_receipts/log.json"
if [ "$distribution_status" != 'Accepted' ]; then
    printf 'Notarization not accepted: %s. Inspect %s/log.json\n' "$distribution_status" "$distribution_receipts" >&2
    exit 1
fi
xcrun stapler staple "$distribution_pkg"
xcrun stapler validate "$distribution_pkg"
spctl --assess --type install --verbose=2 "$distribution_pkg"
shasum -a 256 "$distribution_pkg" > "$distribution_receipts/SHA256.txt"
printf 'Notarized package: %s\n' "$distribution_pkg"
