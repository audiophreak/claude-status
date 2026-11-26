#!/usr/bin/env bash
# Build a signed, native arm64 release bundle at .build/dist/Claude Status.app
# usage: scripts/build.sh [--debug]
source "$(dirname "$0")/lib.sh"
require_prereqs

CONFIG=release
[[ "${1:-}" == "--debug" ]] && CONFIG=debug

src_version="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' "$REPO_ROOT/Sources/ClaudeStatusCore/Version.swift")"
[[ "$src_version" == "$VERSION" ]] || die "VERSION ($VERSION) does not match Version.swift ($src_version)"

cd "$REPO_ROOT" || exit 1
info "swift build -c $CONFIG --arch arm64"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

info "assembling $APP_NAME.app ($VERSION)"
mkdir -p "$DIST_DIR"
remove_build_artifact "$APP_BUNDLE"
STAGE="$DIST_DIR/.stage-$$"
mkdir -p "$STAGE/$APP_NAME.app/Contents/MacOS" "$STAGE/$APP_NAME.app/Contents/Helpers" "$STAGE/$APP_NAME.app/Contents/Resources"
C="$STAGE/$APP_NAME.app/Contents"
cp "$BIN/ClaudeStatus" "$C/MacOS/ClaudeStatus"
cp "$BIN/claude-status-hook" "$C/Helpers/claude-status-hook"
cp "$BIN/claude-status-ctl" "$C/Helpers/claude-status-ctl"
BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>ClaudeStatus</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>Personal utility. Not affiliated with Anthropic.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$C/PkgInfo"
plutil -lint "$C/Info.plist" >/dev/null

# Signing: a local "Apple Development"/"Developer ID" identity if one exists, otherwise
# ad-hoc. Hardened runtime on all code. No entitlements are needed.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
SIGN="${IDENTITY:--}"
info "codesign (${IDENTITY:-ad-hoc})"
for f in "$C/Helpers/claude-status-hook" "$C/Helpers/claude-status-ctl"; do
  codesign --force --options runtime --timestamp=none --sign "$SIGN" --identifier "$BUNDLE_ID.$(basename "$f")" "$f"
done
codesign --force --options runtime --timestamp=none --sign "$SIGN" "$STAGE/$APP_NAME.app"
codesign --verify --strict --deep "$STAGE/$APP_NAME.app"

mv "$STAGE/$APP_NAME.app" "$APP_BUNDLE"
rmdir "$STAGE"
for f in "$APP_BUNDLE/Contents/MacOS/ClaudeStatus" "$APP_BUNDLE/Contents/Helpers/"*; do
  arch="$(lipo -archs "$f")"
  [[ "$arch" == "arm64" ]] || die "$(basename "$f") is not arm64-only ($arch)"
done
info "built $APP_BUNDLE ($(du -sk "$APP_BUNDLE" | cut -f1) KB, arm64)"
