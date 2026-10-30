#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache"
app="$PWD/dist/Contour.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Contour "$app/Contents/MacOS/Contour"
cp docs/Guide.html "$app/Contents/Resources/Guide.html"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Contour</string>
<key>CFBundleDisplayName</key><string>Contour</string>
<key>CFBundleIdentifier</key><string>com.contourdj.desktop</string>
<key>CFBundleExecutable</key><string>Contour</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSHumanReadableCopyright</key><string>Contour — independent local development build</string>
</dict></plist>
PLIST
if [[ -f assets/AppIcon.icns ]]; then cp assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"; fi
codesign --force --sign - "$app"
printf 'Built %s\n' "$app"
