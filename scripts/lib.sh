# Shared helpers for Claude Status scripts. Sourced, not executed.
# shellcheck shell=bash
# Variables defined here are used by the scripts that source this file.
# shellcheck disable=SC2034

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Claude Status"
BUNDLE_ID="io.github.audiophreak.ClaudeStatus"
VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
DIST_DIR="$REPO_ROOT/.build/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALL_APP="$HOME/Applications/$APP_NAME.app"
STATE_ROOT="$HOME/Library/Application Support/ClaudeStatus"
BIN_DIR="$STATE_ROOT/bin"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
CTL="$BIN_DIR/claude-status-ctl"   # scripts may point this at a bundled copy

info()  { printf '==> %s\n' "$*"; }
warn()  { printf 'warning: %s\n' "$*" >&2; }
die()   { printf 'error: %s\n' "$*" >&2; exit 1; }

require_prereqs() {
  [[ "$(uname -s)" == "Darwin" ]] || die "macOS required"
  [[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon (arm64) required"
  [[ "$(id -u)" != "0" ]] || die "do not run as root; no sudo is needed"
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  (( major >= 14 )) || die "macOS 14 or later required (found $(sw_vers -productVersion))"
  command -v swift >/dev/null || die "Swift toolchain not found (install Xcode or the Command Line Tools)"
  command -v codesign >/dev/null || die "codesign not found"
}

# Move a path to the user's Trash (reversible) instead of deleting it. Refuses anything
# that is not exactly an expected Claude Status location.
trash_path() {
  local target="$1"
  case "$target" in
    "$INSTALL_APP") ;;
    *) die "refusing to trash unexpected path: $target" ;;
  esac
  [[ -e "$target" ]] || return 0
  [[ ! -L "$target" ]] || die "refusing to trash a symlink: $target"
  local stamp dest
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$HOME/.Trash/$APP_NAME $stamp-$$.app"
  mv "$target" "$dest"
  info "moved previous bundle to Trash: $(basename "$dest")"
}

# PIDs of the app running from exactly $INSTALL_APP (never other copies, e.g. a dev build).
installed_app_pids() {
  local pid exe
  for pid in $(pgrep -U "$(id -u)" -x ClaudeStatus 2>/dev/null); do
    exe="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    [[ "$exe" == "$INSTALL_APP/Contents/MacOS/ClaudeStatus" ]] && echo "$pid"
  done
  return 0
}

app_running() { [[ -n "$(installed_app_pids)" ]]; }

quit_app() {
  local pids
  pids="$(installed_app_pids)"
  [[ -n "$pids" ]] || return 0
  info "stopping running Claude Status"
  # shellcheck disable=SC2086  # word splitting of the PID list is intended
  kill $pids 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do app_running || return 0; sleep 0.3; done
  warn "Claude Status did not exit promptly"
}

# claude-status-ctl with explicit, $HOME-derived locations (scripts never rely on defaults).
ctl() { "$CTL" "$@" --settings "$SETTINGS" --home "$STATE_ROOT"; }

# Remove a build artifact, only directly inside .build/dist (never a symlink).
remove_build_artifact() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  case "$target" in
    "$DIST_DIR"/?*) ;;
    *) die "refusing to remove path outside $DIST_DIR: $target" ;;
  esac
  [[ "$target" != *"/../"* && ! -L "$target" ]] || die "refusing to remove $target"
  rm -r "$target"
}
