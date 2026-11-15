#!/bin/sh
# Builds Zoomies.app (ad-hoc signed) into .build/, and with --dmg also a disk image.
# Needs only the Xcode Command Line Tools. The app expects llama.cpp to be installed
# separately (brew install llama.cpp); it never bundles or downloads models.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^public let zoomiesVersion = "\(.*\)"/\1/p' Sources/ZoomiesKit/Bench/BenchmarkRunner.swift)
swift build -c release --product ZoomiesApp
swift build -c release --product zoomies
APP=.build/Zoomies.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ZoomiesApp "$APP/Contents/MacOS/Zoomies"
cp .build/release/zoomies "$APP/Contents/Resources/zoomies"
if [ ! -f .build/AppIcon.icns ]; then
  rm -rf .build/AppIcon.iconset
  swift scripts/make-icon.swift .build/AppIcon.iconset >/dev/null
  iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns
fi
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Zoomies</string>
  <key>CFBundleDisplayName</key><string>Zoomies</string>
  <key>CFBundleIdentifier</key><string>io.github.andrewkernel.zoomies</string>
  <key>CFBundleExecutable</key><string>Zoomies</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION%%-*}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP ($VERSION)"
if [ "${1:-}" = "--dmg" ]; then
  DMG=".build/Zoomies-${VERSION}.dmg"
  STAGE=.build/dmg-stage
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname Zoomies -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "Built $DMG"
fi
