#!/usr/bin/env bash
# Package the built bundle for a GitHub release:
#   .build/release-assets/ClaudeStatus-<version>-macos-arm64.zip
#   .build/release-assets/SHA256SUMS.txt
#   .build/release-assets/release-notes.md
# usage: scripts/package-release.sh   (after scripts/build.sh)
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT" || exit 1
[[ -d "$APP_BUNDLE" ]] || die "build first: scripts/build.sh"
codesign --verify --strict "$APP_BUNDLE" || die "bundle signature invalid"

OUT="$REPO_ROOT/.build/release-assets"
mkdir -p "$OUT"
ZIP="ClaudeStatus-$VERSION-macos-arm64.zip"
for f in "$OUT/$ZIP" "$OUT/SHA256SUMS.txt" "$OUT/release-notes.md"; do [[ -f "$f" ]] && rm -f "$f"; done

# ditto preserves the bundle structure, symlinks and code signature.
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$OUT/$ZIP"
(cd "$OUT" && shasum -a 256 "$ZIP" > SHA256SUMS.txt)
SUM="$(cut -d' ' -f1 "$OUT/SHA256SUMS.txt")"

COMMIT="$(git rev-parse HEAD)"
XCODE="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
SWIFT="$(swift --version 2>/dev/null | head -1)"
OS="$(sw_vers -productVersion)"
SIGN="$(codesign -dv "$APP_BUNDLE" 2>&1 | awk -F= '/^Signature=/{print $2}')"
NOTES_SECTION="$(awk -v v="$VERSION" '
  $0 ~ "^## \\[" v "\\]" {on=1; next}
  on && /^## \[/ {exit}
  on {print}' CHANGELOG.md)"

cat > "$OUT/release-notes.md" <<NOTES
$NOTES_SECTION

## Install

1. Download \`$ZIP\` and verify it (below).
2. Unzip it and move **Claude Status.app** to \`/Applications\` or \`~/Applications\`.
3. Open it. Because the app is **not notarized** (see *Signing* below), macOS blocks the first launch:
   choose **Done**, then open **System Settings › Privacy & Security**, find *"Claude Status" was blocked*
   and click **Open Anyway** (macOS asks for your password). This approves only this app; it does not
   change Gatekeeper for anything else. Prefer not to? Build from source instead (README › Install from source).
4. Click the menu bar icon › **Set Up Claude Code Hooks…** to register the hooks (a backup of
   \`~/.claude/settings.json\` is saved first).

## Upgrade or roll back

- **From 1.0.x:** quit Claude Status, replace the app with this one, open it. It refreshes its
  helpers; \`~/.claude/settings.json\` is not changed (same hook registration) and running
  sessions stay visible.
- **Roll back** to any earlier 1.x release (from a source checkout):
  \`scripts/rollback.sh ClaudeStatus-<version>-macos-arm64.zip --sha256 <checksum>\`. Without a
  checkout: quit, replace the app with the older one, open it and click **Set Up Claude Code
  Hooks…**. Session history is kept in both directions.

## Verify the download

\`\`\`bash
shasum -a 256 -c SHA256SUMS.txt
gh attestation verify $ZIP --repo audiophreak/claude-status
\`\`\`

- SHA-256: \`$SUM\`
- The archive is built by the GitHub Actions *Release* workflow from tag \`v$VERSION\`
  (commit \`$COMMIT\`) and carries a GitHub build-provenance attestation.
- Build environment: macOS $OS, $XCODE, $SWIFT, arm64.

## Signing

- Code signature: **$SIGN** (no Apple Developer ID), hardened runtime, no entitlements.
- **Not notarized by Apple.**
- Apple silicon (arm64) only, macOS 14 or later.

Claude Status is an independent, unofficial project. It is not affiliated with or endorsed by Anthropic.
NOTES

info "release assets in $OUT:"
ls -l "$OUT"
