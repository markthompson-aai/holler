#!/bin/sh
# The golden-image check: builds Holler.app, renders every note state as the
# app draws it, and compares each PNG with the golden image of the same name
# in Tests/Goldens/note. A change fails the check and leaves the fresh renders
# and a red-on-grey difference image per change in previews/check/.
#
#   scripts/check-previews.sh            check, before a push
#   scripts/check-previews.sh --update   re-record the golden images after a change you meant
#
# A local check for now: whether a CI runner draws the same pixels as a Mac
# with the fonts installed is still open.
set -e
cd "$(dirname "$0")/.."
GOLDENS=Tests/Goldens/note
APP=build/Holler.app/Contents/MacOS/Holler

# The build's own output only matters when it fails.
mkdir -p previews
if ! scripts/build-app.sh >previews/build.log 2>&1; then
  cat previews/build.log
  exit 1
fi

case "$1" in
  --update)
    rm -rf "$GOLDENS"
    "$APP" --render-previews "$GOLDENS" >/dev/null
    echo "Recorded $(ls "$GOLDENS" | wc -l | tr -d ' ') golden images in $GOLDENS. Review them, then commit."
    ;;
  "")
    exec "$APP" --check-previews "$GOLDENS" previews/check
    ;;
  *)
    echo "usage: scripts/check-previews.sh [--update]" >&2
    exit 2
    ;;
esac
