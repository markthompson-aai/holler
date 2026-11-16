#!/bin/sh
# Runs the test suite. With only the Command Line Tools installed (no Xcode),
# SwiftPM can't find Swift Testing on its own, so point it at the CLT copy.
set -e
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)"
case "$DEV" in
  */CommandLineTools)
    LIB="$DEV/Library/Developer"
    exec swift test -Xswiftc -F -Xswiftc "$LIB/Frameworks" \
      -Xlinker -rpath -Xlinker "$LIB/Frameworks" -Xlinker -rpath -Xlinker "$LIB/usr/lib" "$@"
    ;;
  *) exec swift test "$@" ;;
esac
