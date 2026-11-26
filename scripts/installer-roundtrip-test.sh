#!/usr/bin/env bash
# End-to-end test of scripts/install.sh, update (re-install) and scripts/uninstall.sh against an
# isolated fake HOME seeded with a settings file that already contains unrelated hooks.
# The real user's settings file is hashed before and after to prove it was not touched.
source "$(dirname "$0")/lib.sh"
set +e
cd "$REPO_ROOT" || exit 1
[[ -d "$APP_BUNDLE" ]] || "$REPO_ROOT/scripts/build.sh" >/dev/null

PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
check() { local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

REAL_SETTINGS="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')/.claude/settings.json"
real_before="$(sha "$REAL_SETTINGS")"

FAKE="$(mktemp -d "${TMPDIR:-/tmp}/claude-status-home.XXXXXX")"
cleanup() { case "$FAKE" in "${TMPDIR:-/tmp}"/claude-status-home.*) rm -r "$FAKE" ;; esac; }
trap cleanup EXIT
mkdir -p "$FAKE/.claude" "$FAKE/.Trash" "$FAKE/Applications"
cp "$REPO_ROOT/Tests/Fixtures/settings/existing-hooks.json" "$FAKE/.claude/settings.json"
chmod 600 "$FAKE/.claude/settings.json"
orig="$(sha "$FAKE/.claude/settings.json")"

run() { env -u CLAUDE_CONFIG_DIR HOME="$FAKE" "$@"; }
F_APP="$FAKE/Applications/$APP_NAME.app"
F_ROOT="$FAKE/Library/Application Support/ClaudeStatus"
F_CTL() { "$F_ROOT/bin/claude-status-ctl" "$@" --settings "$FAKE/.claude/settings.json" --home "$F_ROOT"; }

echo "Install"
run "$REPO_ROOT/scripts/install.sh" --skip-build --no-launch --no-login-item > "$FAKE/install.log" 2>&1
check "install.sh exits 0" test $? = 0
check "app bundle installed and signature valid" codesign --verify --strict "$F_APP"
check "helpers installed and executable" test -x "$F_ROOT/bin/claude-status-hook" -a -x "$F_ROOT/bin/claude-status-ctl"
check "hooks registered and healthy" F_CTL verify-hooks
check "unrelated settings and hooks preserved" F_CTL verify-preserved --backup "$REPO_ROOT/Tests/Fixtures/settings/existing-hooks.json"
check "settings mode stays 600" test "$(stat -f %Lp "$FAKE/.claude/settings.json")" = 600
check "pre-install backup equals original bytes" bash -c "f=\$(ls \"$F_ROOT/backups/\"*.install.*.bak | head -1); [ \"\$(shasum -a 256 \"\$f\" | cut -d' ' -f1)\" = '$orig' ]"
installed="$(sha "$FAKE/.claude/settings.json")"

echo "Update (re-install)"
run "$REPO_ROOT/scripts/install.sh" --skip-build --no-launch --no-login-item > "$FAKE/update.log" 2>&1
check "re-install exits 0" test $? = 0
check "re-install does not rewrite settings" test "$(sha "$FAKE/.claude/settings.json")" = "$installed"
check "previous bundle moved to (fake) Trash" bash -c "ls '$FAKE/.Trash' | grep -q 'Claude Status'"

echo "Uninstall"
run "$REPO_ROOT/scripts/uninstall.sh" --keep-login-item > "$FAKE/uninstall.log" 2>&1
check "uninstall.sh exits 0" test $? = 0
check "settings restored byte-identical" test "$(sha "$FAKE/.claude/settings.json")" = "$orig"
check "app bundle removed" test ! -e "$F_APP"
check "helpers removed" test ! -e "$F_ROOT/bin/claude-status-hook" -a ! -e "$F_ROOT/bin/claude-status-ctl"
check "state and backups kept without --purge-state" test -d "$F_ROOT/backups"

echo "Install + uninstall --purge-backups"
run "$REPO_ROOT/scripts/install.sh" --skip-build --no-launch --no-login-item > "$FAKE/install2.log" 2>&1
run "$REPO_ROOT/scripts/uninstall.sh" --keep-login-item --purge-backups > "$FAKE/uninstall2.log" 2>&1
check "purge removes all Claude Status state" test ! -e "$F_ROOT"
check "settings still byte-identical to original" test "$(sha "$FAKE/.claude/settings.json")" = "$orig"

echo "Downloaded-app flow (app's own setup/removal code, no source scripts)"
FAKE2="$FAKE/home2"; mkdir -p "$FAKE2/.claude" "$FAKE2/Applications"
cp "$REPO_ROOT/Tests/Fixtures/settings/existing-hooks.json" "$FAKE2/.claude/settings.json"
ditto "$APP_BUNDLE" "$FAKE2/Applications/$APP_NAME.app"
APPBIN2="$FAKE2/Applications/$APP_NAME.app/Contents/MacOS/ClaudeStatus"
F2_ROOT="$FAKE2/Library/Application Support/ClaudeStatus"
F2_CTL() { "$F2_ROOT/bin/claude-status-ctl" "$@" --settings "$FAKE2/.claude/settings.json" --home "$F2_ROOT"; }
env -u CLAUDE_CONFIG_DIR -u CLAUDE_STATUS_HOME HOME="$FAKE2" "$APPBIN2" --setup-hooks > "$FAKE/app-setup.log" 2>&1
check "app --setup-hooks exits 0" test $? = 0
check "app installed helpers from its bundle" cmp -s "$F2_ROOT/bin/claude-status-hook" "$APP_BUNDLE/Contents/Helpers/claude-status-hook"
check "app registered healthy hooks" F2_CTL verify-hooks
check "app setup preserved other settings" F2_CTL verify-preserved --backup "$REPO_ROOT/Tests/Fixtures/settings/existing-hooks.json"
env -u CLAUDE_CONFIG_DIR -u CLAUDE_STATUS_HOME HOME="$FAKE2" "$APPBIN2" --setup-hooks > "$FAKE/app-setup2.log" 2>&1
check "second app setup reports no change" grep -q "already installed" "$FAKE/app-setup2.log"
env -u CLAUDE_CONFIG_DIR -u CLAUDE_STATUS_HOME HOME="$FAKE2" "$APPBIN2" --remove-hooks > "$FAKE/app-remove.log" 2>&1
check "app --remove-hooks restores original bytes" test "$(sha "$FAKE2/.claude/settings.json")" = "$orig"

echo "Isolation"
check "real user settings untouched" test "$(sha "$REAL_SETTINGS")" = "$real_before"

echo
echo "Installer round trip: $PASS passed, $FAIL failed"
if [[ $FAIL != 0 ]]; then for f in "$FAKE"/*.log; do echo "--- $f"; cat "$f"; done; fi
[[ $FAIL == 0 ]]
