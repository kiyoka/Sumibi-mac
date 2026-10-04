#!/bin/sh
# Compatibility for issue #15 and existing local build commands. Always production.
set -eu
cd "$(dirname "$0")/.."
[ "$#" -eq 0 ] || { echo 'Use Development/build.sh for development features.' >&2; exit 1; }
sh App/build.sh
mkdir -p .build/prototype
ditto --norsrc --noextattr --noacl .build/app/Sumibi.app .build/prototype/Sumibi.app
printf '%s\n' .build/prototype/Sumibi.app
