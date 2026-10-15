#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${PROJECT_DIR:h}"
TOOLS_DIR="${1:-$PROJECT_DIR/.build-tools}"
APP_DIR="${2:-$OUTPUT_DIR/VidTuck.app}"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/tools"
swiftc -swift-version 5 -O -target arm64-apple-macosx15.0 -framework Cocoa -framework WebKit "$PROJECT_DIR/Sources/Core.swift" "$PROJECT_DIR/Sources/Douyin.swift" "$PROJECT_DIR/Sources/CoverStore.swift" "$PROJECT_DIR/Sources/App.swift" "$PROJECT_DIR/Sources/main.swift" -o "$APP_DIR/Contents/MacOS/VidTuck"
cp "$PROJECT_DIR/Resources/"*.html "$PROJECT_DIR/Resources/"*.css "$PROJECT_DIR/Resources/"*.js "$PROJECT_DIR/Resources/"*.png "$APP_DIR/Contents/Resources/"
for tool in yt-dlp deno; do
  cp "$TOOLS_DIR/$tool" "$APP_DIR/Contents/Resources/tools/$tool"
done
if [[ -d "$TOOLS_DIR/yt-dlp-runtime" ]]; then
  ditto "$TOOLS_DIR/yt-dlp-runtime" "$APP_DIR/Contents/Resources/tools/yt-dlp-runtime"
fi
for tool in ffmpeg ffprobe; do
  cp "$TOOLS_DIR/ffmpeg-built/bin/$tool" "$APP_DIR/Contents/Resources/tools/$tool"
done
chmod +x "$APP_DIR/Contents/MacOS/VidTuck" "$APP_DIR/Contents/Resources/tools/"*
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VidTuck</string><key>CFBundleIdentifier</key><string>local.streamnest.mac</string><key>CFBundleName</key><string>VidTuck</string><key>CFBundleDisplayName</key><string>VidTuck</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>0.2.6</string><key>CFBundleVersion</key><string>9</string><key>LSMinimumSystemVersion</key><string>15.0</string><key>NSHighResolutionCapable</key><true/><key>NSPrincipalClass</key><string>NSApplication</string><key>CFBundleIconFile</key><string>AppIcon</string><key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
if [[ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"; fi
if [[ -d "$PROJECT_DIR/ThirdParty" ]]; then ditto "$PROJECT_DIR/ThirdParty" "$APP_DIR/Contents/Resources/ThirdParty"; fi
codesign --force --sign - "$APP_DIR/Contents/MacOS/VidTuck"
codesign --force --sign - "$APP_DIR"
echo "$APP_DIR"
