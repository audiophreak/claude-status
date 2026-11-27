#!/usr/bin/env bash
# Roll back (or forward) to a specific Claude Status build: a release zip or an .app bundle.
# Verifies the bundle (code signature, arm64, optional SHA-256), replaces the installed app
# (previous copy moved to the Trash), lets that app install its own bundled helpers and
# verify the hook registration, then relaunches it. Session state is kept: records stay
# readable by every 1.x version. ~/.claude/settings.json is never restored from a backup;
# the hook registration is identical across 1.x versions, so it is only verified.
#
# usage: scripts/rollback.sh PATH.zip|PATH.app [--sha256 HEX] [--no-launch]
source "$(dirname "$0")/lib.sh"

SRC="${1:-}"; shift || true
WANT_SHA="" LAUNCH=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha256) WANT_SHA="${2:-}"; shift 2 ;;
    --no-launch) LAUNCH=0; shift ;;
    *) die "unknown option $1" ;;
  esac
done
[[ -n "$SRC" && -e "$SRC" ]] || die "usage: scripts/rollback.sh PATH.zip|PATH.app [--sha256 HEX] [--no-launch]"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-status-rollback.XXXXXX")"
cleanup() { case "$WORK" in "${TMPDIR:-/tmp}"/claude-status-rollback.*) rm -r "$WORK" ;; esac; }
trap cleanup EXIT

case "$SRC" in
  *.zip)
    if [[ -n "$WANT_SHA" ]]; then
      got="$(shasum -a 256 "$SRC" | cut -d' ' -f1)"
      [[ "$got" == "$WANT_SHA" ]] || die "SHA-256 mismatch for $SRC (expected $WANT_SHA, got $got)"
      info "SHA-256 verified"
    fi
    ditto -x -k "$SRC" "$WORK/x"
    APP="$WORK/x/$APP_NAME.app"
    ;;
  *.app) APP="$SRC" ;;
  *) die "expected a .zip or .app: $SRC" ;;
esac
[[ -d "$APP" && ! -L "$APP" ]] || die "no '$APP_NAME.app' found in $SRC"
codesign --verify --strict "$APP" || die "code signature invalid: $APP"
[[ "$(lipo -archs "$APP/Contents/MacOS/ClaudeStatus")" == *arm64* ]] || die "not an arm64 build"
TARGET_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
TARGET_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$TARGET_ID" == "$BUNDLE_ID" ]] || die "unexpected bundle identifier $TARGET_ID"
CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALL_APP/Contents/Info.plist" 2>/dev/null || echo none)"
info "switching Claude Status $CURRENT_VERSION -> $TARGET_VERSION"

quit_app
mkdir -p "$HOME/Applications"
STAGED="$HOME/Applications/.$APP_NAME.app.new-$$"
ditto "$APP" "$STAGED"
trash_path "$INSTALL_APP"
mv "$STAGED" "$INSTALL_APP"

# The app installs its own bundled helpers (byte comparison, atomic replace) and verifies
# the hook registration; nothing else in settings.json is changed.
"$INSTALL_APP/Contents/MacOS/ClaudeStatus" --setup-hooks || die "hook setup by $TARGET_VERSION failed"
cmp -s "$INSTALL_APP/Contents/Helpers/claude-status-hook" "$BIN_DIR/claude-status-hook" || die "helpers were not replaced"
ctl verify-hooks
ctl selftest >/dev/null || warn "self-test of the $TARGET_VERSION hook reported failures (run: claude-status-ctl selftest)"

if [[ $LAUNCH == 1 ]]; then
  open -a "$INSTALL_APP"
  for _ in $(seq 1 20); do app_running && break; sleep 0.25; done
  app_running && info "Claude Status $TARGET_VERSION is running" || warn "Claude Status did not start"
fi
info "done. Undo: run scripts/rollback.sh again with the other version's zip, or scripts/install.sh from a checkout."
