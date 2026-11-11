#!/bin/zsh
# Builds "T90ABC Flasher.app" (Apple Silicon + Intel) and dist/T90ABC-Flasher-macOS.zip
# Requires Xcode Command Line Tools:  xcode-select --install
set -e

# ---- Edit these before publishing ----
VERSION="1.0.1"   # GitHub release tag must match, e.g. v1.0.0
GITHUB_REPO="flashbench/t90abc-flasher-mac"   # used for update checks
PROJECT_URL="https://github.com/$GITHUB_REPO"
SUPPORT_URL="https://github.com/$GITHUB_REPO#support"
# --------------------------------------

HERE="${0:A:h}"
BUILD="$HERE/.build"
DIST="$HERE/dist"
APP="$DIST/T90ABC Flasher.app"
MIN_OS="13.0"

rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=("$HERE"/Sources/*.swift)
for ARCH in arm64 x86_64; do
  echo "Compiling $ARCH…"
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$ARCH-apple-macos$MIN_OS" \
    -o "$BUILD/T90Flasher-$ARCH" "${SOURCES[@]}"
done
lipo -create -output "$APP/Contents/MacOS/T90Flasher" "$BUILD"/T90Flasher-arm64 "$BUILD"/T90Flasher-x86_64

echo "Icon…"
swiftc -O -swift-version 5 -o "$BUILD/mkicon" "$HERE/Tools/mkicon.swift"
"$BUILD/mkicon" "$BUILD/icon.png"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>T90ABC Flasher</string>
  <key>CFBundleDisplayName</key><string>T90ABC Flasher</string>
  <key>CFBundleIdentifier</key><string>io.github.t90abcflasher</string>
  <key>CFBundleExecutable</key><string>T90Flasher</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array><string>en</string><string>ru</string><string>uk</string><string>es</string><string>pt</string><string>de</string><string>zh-Hans</string></array>
  <key>T90GitHubRepo</key><string>$GITHUB_REPO</string>
  <key>T90ProjectURL</key><string>$PROJECT_URL</string>
  <key>T90SupportURL</key><string>$SUPPORT_URL</string>
</dict></plist>
EOF

# Ad-hoc signature with the hardened runtime (needed to run on Apple Silicon).
# With an Apple Developer account, sign with your "Developer ID Application: …"
# identity instead of "-", drop --timestamp=none, then notarize the ZIP.
codesign --force --options runtime --timestamp=none --sign - "$APP"

rm -f "$DIST/T90ABC-Flasher-macOS.zip"
ditto -c -k --keepParent "$APP" "$DIST/T90ABC-Flasher-macOS.zip"
rm -rf "$BUILD"
echo "Done:"
echo "  $APP"
echo "  $DIST/T90ABC-Flasher-macOS.zip"
