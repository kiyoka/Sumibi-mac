#!/bin/sh
# Isolated fixture assembly; never compile, sign or launch a real application.
set -eu
printf 'app-build|sign=%s|args=%s\n' "${SUMIBI_SIGN_IDENTITY:-}" "$*" >> "$SUMIBI_TEST_TRACE"
mkdir -p .build/app
/usr/bin/ditto fixture/Sumibi.app .build/app/Sumibi.app
