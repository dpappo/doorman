#!/bin/bash
# Builds "Doorman.app", installs it in /Applications, and opens it.
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's free developer tools are needed. A window will pop up to install them."
  echo "When the install finishes, run this script again."
  xcode-select --install || true
  exit 1
fi

APP="Doorman.app"
echo "Building..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O main.swift Engine.swift History.swift Intelligence.swift HistoryUI.swift SettingsUI.swift Style.swift -o "$APP/Contents/MacOS/Doorman" -framework Cocoa -framework WebKit
cp Info.plist "$APP/Contents/Info.plist"
if [ -f nest-config.json ]; then
  cp nest-config.json "$APP/Contents/Resources/nest-config.json"
else
  echo "Note: no nest-config.json yet, so instant Nest alerts, recording and history are off."
  echo "      Copy nest-config.example.json to nest-config.json and fill it in (see README.md)."
fi
# App icon: turn AppIcon.png (1024x1024) into the .icns file macOS uses.
if [ -f AppIcon.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  echo "Icon: added"
fi
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

# Quit the running copy so the new one can replace it.
echo "Before: $(pgrep -lf 'Doorman.app|Doorbell PiP.app' || echo 'not running')"
pkill -f 'Doorman.app/Contents/MacOS/Doorman|Doorbell PiP.app/Contents/MacOS/DoorbellPiP' 2>/dev/null || true
for i in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -f 'Doorman.app/Contents/MacOS/Doorman|Doorbell PiP.app/Contents/MacOS/DoorbellPiP' >/dev/null || break
  sleep 0.5
done
pkill -9 -f 'Doorman.app/Contents/MacOS/Doorman|Doorbell PiP.app/Contents/MacOS/DoorbellPiP' 2>/dev/null || true
sleep 0.5

DEST="/Applications"
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
rm -rf "$DEST/$APP"
mv "$APP" "$DEST/"
touch "$DEST/$APP"   # nudges Finder and the Dock to pick up a new icon
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/$APP" || true
# Remove the copy earlier versions put in your personal Applications folder.
if [ "$DEST" = "/Applications" ]; then rm -rf "$HOME/Applications/$APP"; fi
# The app used to be called "Doorbell PiP"; remove old copies.
rm -rf "/Applications/Doorbell PiP.app" "$HOME/Applications/Doorbell PiP.app" 2>/dev/null || true

echo "Done! Installed to $DEST/$APP"
open "$DEST/$APP"
sleep 3
echo "After: $(pgrep -lf 'Doorman.app' || echo 'not running')"
echo "Other copies: $(mdfind 'kMDItemCFBundleIdentifier == com.dan.doorbellpip' | tr '\n' ';')"
