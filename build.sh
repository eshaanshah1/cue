#!/bin/bash
# Builds build/Cue.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Cue.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Cue "$APP/Contents/MacOS/Cue"
strip -x "$APP/Contents/MacOS/Cue"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/Cue.icns "$APP/Contents/Resources/Cue.icns"
if [ -f google-oauth.json ]; then
  cp google-oauth.json "$APP/Contents/Resources/google-oauth.json"
else
  echo "warning: google-oauth.json not found; Google sign-in will be unavailable" >&2
fi
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
