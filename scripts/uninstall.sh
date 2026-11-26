#!/usr/bin/env bash
# Remove Claude Status: its hooks (selectively), login item, app bundle and helpers.
# Unrelated hooks and any later settings changes are preserved. Never restores old backups.
# usage: scripts/uninstall.sh [--purge-state] [--purge-backups] [--keep-login-item]
source "$(dirname "$0")/lib.sh"

PURGE=0 PURGE_BACKUPS=0 LOGIN=1
for a in "$@"; do
  case "$a" in
    --purge-state) PURGE=1 ;;
    --purge-backups) PURGE=1; PURGE_BACKUPS=1 ;;
    --keep-login-item) LOGIN=0 ;;   # tests: do not touch the login item registration
    *) die "unknown option $a" ;;
  esac
done

CTL="$BIN_DIR/claude-status-ctl"
[[ -x "$CTL" ]] || CTL="$INSTALL_APP/Contents/Helpers/claude-status-ctl"
[[ -x "$CTL" ]] || CTL="$APP_BUNDLE/Contents/Helpers/claude-status-ctl"

# 1. Hooks first, so Claude stops invoking the helper before it disappears.
if [[ -x "$CTL" ]]; then
  info "removing Claude Status hooks from $SETTINGS"
  ctl uninstall-hooks
else
  warn "claude-status-ctl not found; hooks not removed. Re-run after scripts/build.sh."
  exit 1
fi

# 2. Login item (only the app itself can unregister SMAppService.mainApp).
if [[ $LOGIN == 1 && -x "$INSTALL_APP/Contents/MacOS/ClaudeStatus" ]]; then
  quit_app
  "$INSTALL_APP/Contents/MacOS/ClaudeStatus" --unregister-login-item || warn "login item unregister failed"
fi
quit_app

# 3. Optional state purge (needs ctl, before helpers are removed).
if [[ $PURGE == 1 ]]; then
  if [[ $PURGE_BACKUPS == 1 ]]; then ctl purge-state --yes --include-backups; else ctl purge-state --yes; fi
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

# 4. App bundle (to Trash) and helpers (exact files only).
trash_path "$INSTALL_APP"
for tool in claude-status-hook claude-status-ctl; do
  if [[ -f "$BIN_DIR/$tool" && ! -L "$BIN_DIR/$tool" ]]; then rm -f "$BIN_DIR/$tool"; fi
done
rmdir "$BIN_DIR" 2>/dev/null || true
[[ $PURGE == 1 ]] && { rmdir "$STATE_ROOT" 2>/dev/null || true; }

info "Claude Status uninstalled."
[[ $PURGE == 1 ]] || echo "State kept in $STATE_ROOT (sessions, logs, settings backups). Use --purge-state to remove."
