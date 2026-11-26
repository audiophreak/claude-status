#!/usr/bin/env bash
# Print Claude Status health, resource use and recent hook log lines (no event contents).
source "$(dirname "$0")/lib.sh"

CTL="$BIN_DIR/claude-status-ctl"
[[ -x "$CTL" ]] || CTL="$APP_BUNDLE/Contents/Helpers/claude-status-ctl"
[[ -x "$CTL" ]] || die "claude-status-ctl not installed; run scripts/install.sh"

ctl diagnose "$@" || true
echo
if app_running; then
  pid="$(installed_app_pids | head -1)"
  ps -o pid=,rss=,%cpu=,etime= -p "$pid" | awk '{printf "  app process: pid %s, RSS %.1f MB, CPU %s%%, uptime %s\n", $1, $2/1024, $3, $4}'
  echo "  architecture: $(file "$INSTALL_APP/Contents/MacOS/ClaudeStatus" | sed 's/.*executable //')"
fi
[[ -d "$INSTALL_APP" ]] && echo "  bundle: $INSTALL_APP ($(du -sk "$INSTALL_APP" | cut -f1) KB), signature: $(codesign --verify --strict "$INSTALL_APP" 2>&1 && echo valid)"
echo
echo "Recent hook log ($STATE_ROOT/logs/hook.log):"
tail -n "${LINES_TO_SHOW:-10}" "$STATE_ROOT/logs/hook.log" 2>/dev/null | sed 's/^/  /' || echo "  (none)"
echo
echo "Sessions (tracked and detected-but-unobserved):"
ctl list | sed 's/^/  /'
echo
echo "End-to-end self-test of the installed hook (isolated temporary store):"
"$CTL" selftest | sed 's/^/  /'
