#!/bin/sh
# Used only through a private temporary PATH by test-distribution.rb.
set -eu
tool="$(basename "$0")"
printf '%s' "$tool" >> "$SUMIBI_TEST_TRACE"
for argument do printf '|%s' "$argument" >> "$SUMIBI_TEST_TRACE"; done
printf '\n' >> "$SUMIBI_TEST_TRACE"
case "$tool" in
    security) exit 0 ;; # No identities: never inspect the real Keychain.
    codesign)
        if [ "$1" = '--display' ]; then
            printf 'Authority=%s\nTeamIdentifier=%s\n' "${TEST_APP_AUTHORITY:-Developer ID Application: Test (TEST)}" "${TEST_APP_TEAM:-TEST}"
            if [ "${TEST_RUNTIME:-yes}" = yes ]; then printf 'CodeDirectory flags=0x10000(runtime)\n'; fi
            if [ "${TEST_TIMESTAMP:-yes}" = yes ]; then printf 'Timestamp=Test timestamp\n'; fi
        fi ;;
    lipo) printf '%s\n' arm64 ;;
    ditto) /usr/bin/ditto "$@" ;;
    pkgbuild|productbuild)
        for argument do output="$argument"; done
        printf 'FAKE TEST PACKAGE - NOT DISTRIBUTABLE\n' > "$output" ;;
    pkgutil) printf '%s\n' "${TEST_PKG_AUTHORITY:-Developer ID Installer: Test (TEST)}" ;;
    xcrun)
        case "$1 $2" in
            'notarytool submit')
                if [ "${TEST_SUBMIT_EXIT:-0}" -ne 0 ]; then exit "$TEST_SUBMIT_EXIT"; fi
                printf '<?xml version="1.0"?><plist version="1.0"><dict><key>id</key><string>test-submission</string><key>status</key><string>%s</string></dict></plist>\n' "${TEST_STATUS:-Accepted}" ;;
            'notarytool log')
                for argument do output="$argument"; done
                printf '{}\n' > "$output" ;;
            'stapler staple') exit "${TEST_STAPLE_EXIT:-0}" ;;
            'stapler validate') exit 0 ;;
            *) echo 'Unexpected xcrun command in isolated test' >&2; exit 99 ;;
        esac ;;
    spctl) exit "${TEST_SPCTL_EXIT:-0}" ;;
    shasum) printf 'mock-checksum (NOT A RELEASE CHECKSUM)\n' ;;
    *) echo 'Unexpected external tool in isolated test' >&2; exit 99 ;;
esac
