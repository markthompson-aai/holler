#!/bin/sh
# Builds "Holler.app" into build/. No Xcode needed.
#
#   scripts/build-app.sh            release build, signed with "Holler Dev" if present
#   SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
#
# Ad-hoc signing changes the app's identity on every build, so macOS asks for
# the microphone and Input Monitoring permissions again after a rebuild. A
# real signing identity keeps them. The script uses the self-signed
# "Holler Dev" certificate when it's in the keychain (see CONTRIBUTING.md), then
# falls back to ad hoc. SIGN_IDENTITY overrides both; "-" forces ad hoc.
set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/Holler.app"

swift build -c release --product HollerApp
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HollerApp" "$APP/Contents/MacOS/Holler"
cp Resources/Sounds/*.wav "$APP/Contents/Resources/"
cp Resources/Fonts/*.ttf "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # drawn by scripts/make-icon.swift
# Records this repo's .env, which the app prefers to ~/.config/holler/.env when it exists.
# plutil rather than sed, so a clone in a folder with &, # or < in its name still works.
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace HollerEnvFile -string "$ROOT/.env" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

# "Holler Dev" is self-signed, so it's untrusted and `find-identity -v` hides
# it. Sign by its hash so a second certificate with the same name can't make
# codesign fail as ambiguous.
CERT="Holler Dev"
if [ -z "$SIGN_IDENTITY" ]; then
  HASHES="$(security find-identity -p codesigning |
    awk -v name="\"$CERT\"" 'index($0, name) { print $2 }' | sort -u)"
  SIGN_IDENTITY="$(echo "$HASHES" | head -n 1)"
  if [ "$(echo "$HASHES" | wc -l)" -gt 1 ]; then
    echo "Warning: more than one $CERT certificate in the keychain. Delete all but one, or" \
      "the signing identity may change between builds and macOS will ask for permissions again."
  fi
  if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with $CERT ($SIGN_IDENTITY)"
  else
    SIGN_IDENTITY=-
    echo "No $CERT certificate in the keychain; signing ad hoc (permissions reset after each rebuild)"
  fi
fi
codesign --force --sign "$SIGN_IDENTITY" --identifier com.assemblyai.holler "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
