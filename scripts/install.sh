#!/usr/bin/env bash
# Build, install and activate Claude Status. Idempotent; no sudo.
# usage: scripts/install.sh [--skip-build] [--no-launch] [--no-login-item] [--no-hooks]
source "$(dirname "$0")/lib.sh"
require_prereqs

SKIP_BUILD=0 LAUNCH=1 LOGIN=1 HOOKS=1
for a in "$@"; do
  case "$a" in
    --skip-build) SKIP_BUILD=1 ;;
    --no-launch) LAUNCH=0 ;;
    --no-login-item) LOGIN=0 ;;
    --no-hooks) HOOKS=0 ;;
    *) die "unknown option $a" ;;
  esac
done

[[ $SKIP_BUILD == 1 ]] || "$REPO_ROOT/scripts/build.sh"
[[ -d "$APP_BUNDLE" ]] || die "no built bundle at $APP_BUNDLE (run scripts/build.sh)"
codesign --verify --strict "$APP_BUNDLE" || die "bundle signature invalid"

# 1. Helpers to a stable location independent of this checkout (atomic replace).
info "installing helpers to $BIN_DIR"
"$APP_BUNDLE/Contents/Helpers/claude-status-ctl" install-helpers --from "$APP_BUNDLE/Contents/Helpers" --home "$STATE_ROOT"
# The hook must work before it is registered.
echo '{"session_id":"install-selftest","hook_event_name":"PostToolBatch"}' \
  | CLAUDE_STATUS_HOME="$(mktemp -d)/selftest" "$BIN_DIR/claude-status-hook" \
  || die "hook self-test failed"

# 2. Application bundle.
quit_app
mkdir -p "$HOME/Applications"
STAGED="$HOME/Applications/.$APP_NAME.app.new-$$"
ditto "$APP_BUNDLE" "$STAGED"
trash_path "$INSTALL_APP"
mv "$STAGED" "$INSTALL_APP"
info "installed $INSTALL_APP"

# 3. Hooks (structured, verified, backed up, concurrency-checked edit).
if [[ $HOOKS == 1 ]]; then
  info "registering hooks in $SETTINGS"
  if ! ctl install-hooks; then
    warn "hook registration failed; settings.json was not modified by the failed attempt."
    warn "rollback: run scripts/uninstall.sh (removes only Claude Status components)."
    exit 1
  fi
  ctl verify-hooks
fi

# 4. Launch (+ login item via SMAppService, registered by the app itself).
if [[ $LAUNCH == 1 ]]; then
  if [[ $LOGIN == 1 ]]; then
    open -a "$INSTALL_APP" --args --register-login-item
  else
    open -a "$INSTALL_APP"
  fi
  for _ in $(seq 1 20); do app_running && break; sleep 0.25; done
  app_running && info "Claude Status is running" || warn "Claude Status did not start"
fi

# 5. Health.
ctl diagnose || true
cat <<EOF

Installed Claude Status $VERSION.
  app:        $INSTALL_APP
  helpers:    $BIN_DIR
  diagnose:   scripts/diagnose.sh
  uninstall:  scripts/uninstall.sh   (add --purge-state to delete history)
EOF
