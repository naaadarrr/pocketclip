#!/bin/sh
# Self-sign with a fixed local identity so Screen Recording permission survives rebuilds.
set -e
cd "$(dirname "$0")"
KC="$HOME/Library/Keychains/pocketclip-sign.keychain-db"

# Unlock the signing keychain. Prefer POCKETCLIP_SIGN_PASSWORD; otherwise prompt
# silently in a terminal. The value is never printed.
if [ -z "$POCKETCLIP_SIGN_PASSWORD" ]; then
  if [ -t 0 ]; then
    printf "Signing keychain password (input hidden): " >&2
    stty -echo
    trap 'stty echo' EXIT INT TERM
    IFS= read -r POCKETCLIP_SIGN_PASSWORD
    stty echo
    trap - EXIT INT TERM
    printf "\n" >&2
    if [ -z "$POCKETCLIP_SIGN_PASSWORD" ]; then
      echo "error: no password entered." >&2
      exit 1
    fi
  else
    echo "error: set POCKETCLIP_SIGN_PASSWORD or run ./build.sh from a terminal to unlock the signing keychain." >&2
    exit 1
  fi
fi

security unlock-keychain -p "$POCKETCLIP_SIGN_PASSWORD" "$KC"
unset POCKETCLIP_SIGN_PASSWORD

pkill -f Pocketclip.app/Contents/MacOS || true
cp -R loc/*.lproj ~/Applications/Pocketclip.app/Contents/Resources/
cp res/AppIcon.icns res/menubar.png ~/Applications/Pocketclip.app/Contents/Resources/
mkdir -p ~/Applications/Pocketclip.app/Contents/Resources/ext/icons
cp res/ext/icons/icon16.png res/ext/icons/icon48.png res/ext/icons/icon128.png ~/Applications/Pocketclip.app/Contents/Resources/ext/icons/
mkdir -p ~/Applications/Pocketclip.app/Contents/Resources/ext/editor
cp res/ext/editor/editor.js res/ext/editor/editor.html res/ext/editor/editor.css ~/Applications/Pocketclip.app/Contents/Resources/ext/editor/
# Optional ScreenParser Core ML (built by models/convert_screenparser.py)
rm -rf ~/Applications/Pocketclip.app/Contents/Resources/ScreenParser.mlmodelc \
       ~/Applications/Pocketclip.app/Contents/Resources/ScreenParser.mlpackage \
       ~/Applications/Pocketclip.app/Contents/Resources/screenparser_names.json
if [ -d models/ScreenParser.mlmodelc ]; then
  cp -R models/ScreenParser.mlmodelc ~/Applications/Pocketclip.app/Contents/Resources/
elif [ -d models/ScreenParser.mlpackage ]; then
  cp -R models/ScreenParser.mlpackage ~/Applications/Pocketclip.app/Contents/Resources/
fi
if [ -f models/screenparser_names.json ]; then
  cp models/screenparser_names.json ~/Applications/Pocketclip.app/Contents/Resources/
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" ~/Applications/Pocketclip.app/Contents/Info.plist 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" ~/Applications/Pocketclip.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :NSAccessibilityUsageDescription Pocketclip highlights buttons and blocks in the current window when you capture a region. / 框选截图时，Pocketclip 会高亮当前窗口中的按钮和区块。" ~/Applications/Pocketclip.app/Contents/Info.plist 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :NSAccessibilityUsageDescription string Pocketclip highlights buttons and blocks in the current window when you capture a region. / 框选截图时，Pocketclip 会高亮当前窗口中的按钮和区块。" ~/Applications/Pocketclip.app/Contents/Info.plist
swiftc -O -swift-version 5 \
  src/main.swift src/LayoutBoxTree.swift src/AXBoxCollector.swift src/VisualBoxDetector.swift src/RegionPicker.swift \
  -framework ScreenCaptureKit -framework ApplicationServices -framework CoreML \
  -o ~/Applications/Pocketclip.app/Contents/MacOS/Pocketclip
codesign -s "Pocketclip Local Signing" --keychain "$KC" --force --deep ~/Applications/Pocketclip.app
open ~/Applications/Pocketclip.app
