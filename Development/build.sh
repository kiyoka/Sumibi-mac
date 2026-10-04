#!/bin/sh
# Explicit opt-in. Builds only; never installs or changes input sources.
set -eu
cd "$(dirname "$0")/.."
[ "$#" -eq 0 ] || { echo 'Usage: sh Development/build.sh' >&2; exit 1; }
exec sh App/build.sh --development
