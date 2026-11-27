#!/usr/bin/env bash
# Upgrade and rollback test in an isolated fake HOME:
#   previous release (installed with its own --setup-hooks) -> sessions recorded by its hook
#   -> upgrade to this build (scripts/install.sh) -> rollback to the previous release
#   (scripts/rollback.sh) -> upgrade again.
# Checks: settings preserved byte-for-byte, no duplicate hook registrations, helpers switched,
# records readable in both directions, live state kept, hooks keep working.
# The previous release is downloaded from the public GitHub release and checksum-verified
# (or pass --previous-zip PATH --previous-sha256 HEX). The real user's settings are hashed
# before and after to prove they were not touched.
#
# usage: scripts/upgrade-rollback-test.sh [--previous-tag v1.0.2] [--previous-zip PATH --previous-sha256 HEX]
source "$(dirname "$0")/lib.sh"
set +e
cd "$REPO_ROOT" || exit 1
[[ -d "$APP_BUNDLE" ]] || "$REPO_ROOT/scripts/build.sh" >/dev/null

PREV_TAG="v1.0.2" PREV_ZIP="" PREV_SHA=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --previous-tag) PREV_TAG="$2"; shift 2 ;;
    --previous-zip) PREV_ZIP="$2"; shift 2 ;;
    --previous-sha256) PREV_SHA="$2"; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done

PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
check() { local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

REAL_SETTINGS="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')/.claude/settings.json"
real_before="$(sha "$REAL_SETTINGS")"

FAKE="$(mktemp -d "${TMPDIR:-/tmp}/claude-status-upgrade.XXXXXX")"
cleanup() { case "$FAKE" in "${TMPDIR:-/tmp}"/claude-status-upgrade.*) rm -r "$FAKE" ;; esac; }
trap cleanup EXIT
mkdir -p "$FAKE/.claude" "$FAKE/.Trash" "$FAKE/Applications" "$FAKE/dl"
cp "$REPO_ROOT/Tests/Fixtures/settings/existing-hooks.json" "$FAKE/.claude/settings.json"
chmod 600 "$FAKE/.claude/settings.json"

# --- previous release ---------------------------------------------------------------
if [[ -z "$PREV_ZIP" ]]; then
  base="https://github.com/audiophreak/claude-status/releases/download/$PREV_TAG"
  ver="${PREV_TAG#v}"
  curl -fsSL -o "$FAKE/dl/SHA256SUMS" "$base/SHA256SUMS.txt" || die "could not download $PREV_TAG checksums"
  zipname="$(awk '{print $2}' "$FAKE/dl/SHA256SUMS" | grep -E "\.zip$" | head -1)"
  [[ -n "$zipname" ]] || die "no zip listed in $PREV_TAG SHA256SUMS"
  curl -fsSL -o "$FAKE/dl/$zipname" "$base/$zipname" || die "could not download $zipname"
  PREV_ZIP="$FAKE/dl/$zipname"
  PREV_SHA="$(awk -v n="$zipname" '$2==n {print $1}' "$FAKE/dl/SHA256SUMS")"
  info "previous release $ver: $zipname"
fi
check "previous release checksum verified" test "$(sha "$PREV_ZIP")" = "$PREV_SHA"
ditto -x -k "$PREV_ZIP" "$FAKE/prev"
PREV_APP="$FAKE/prev/$APP_NAME.app"
check "previous release signature valid" codesign --verify --strict "$PREV_APP"
PREV_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PREV_APP/Contents/Info.plist")"

run() { env -u CLAUDE_CONFIG_DIR -u CLAUDE_STATUS_HOME HOME="$FAKE" "$@"; }
F_ROOT="$FAKE/Library/Application Support/ClaudeStatus"
F_CTL() { "$F_ROOT/bin/claude-status-ctl" "$@" --settings "$FAKE/.claude/settings.json" --home "$F_ROOT"; }
F_APP="$FAKE/Applications/$APP_NAME.app"
hook() { printf '%s' "$1" | env -u CLAUDE_CONFIG_DIR HOME="$FAKE" CLAUDE_STATUS_HOME="$F_ROOT" "$F_ROOT/bin/claude-status-hook"; }

echo "Install previous release $PREV_VERSION (its own --setup-hooks)"
ditto "$PREV_APP" "$F_APP"
run "$F_APP/Contents/MacOS/ClaudeStatus" --setup-hooks > "$FAKE/prev-setup.log" 2>&1
check "previous release registered healthy hooks" F_CTL verify-hooks
settings_after_prev="$(sha "$FAKE/.claude/settings.json")"
# Sessions recorded by the previous hook: one finished with background work, one mid-turn.
hook '{"session_id":"up-bg","hook_event_name":"UserPromptSubmit","cwd":"/tmp"}'
hook '{"session_id":"up-bg","hook_event_name":"Stop","cwd":"/tmp","background_tasks":[{"id":"t1","type":"shell","status":"running"}],"session_crons":[]}'
hook '{"session_id":"up-fg","hook_event_name":"UserPromptSubmit","cwd":"/tmp"}'
hook '{"session_id":"up-fg","hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Bash","tool_use_id":"x1"}'
check "previous hook recorded sessions" test -f "$F_ROOT/sessions/up-bg.json" -a -f "$F_ROOT/sessions/up-fg.json"
prev_list="$(F_CTL list)"

echo "Upgrade to $VERSION (scripts/install.sh)"
run "$REPO_ROOT/scripts/install.sh" --skip-build --no-launch --no-login-item > "$FAKE/upgrade.log" 2>&1
check "upgrade exits 0" test $? = 0
check "installed app is $VERSION" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$F_APP/Contents/Info.plist")" = "$VERSION"
check "helpers upgraded" cmp -s "$F_ROOT/bin/claude-status-hook" "$APP_BUNDLE/Contents/Helpers/claude-status-hook"
check "upgrade leaves settings byte-identical (same registration)" test "$(sha "$FAKE/.claude/settings.json")" = "$settings_after_prev"
check "no duplicate hook registrations after upgrade" bash -c "\"$F_ROOT/bin/claude-status-ctl\" verify-hooks --settings \"$FAKE/.claude/settings.json\" --home \"$F_ROOT\" | grep -qv duplicates"
check "unrelated settings preserved" F_CTL verify-preserved --backup "$REPO_ROOT/Tests/Fixtures/settings/existing-hooks.json"
list="$(F_CTL list)"
check "records from $PREV_VERSION readable (no unreadable records)" bash -c "! grep -q unreadable <<< \"$list\""
check "background session still Working — Background after upgrade" bash -c "grep '^up-bg' <<< \"$list\" | grep -q 'Working — Background'"
check "mid-turn session still Working after upgrade" bash -c "grep '^up-fg' <<< \"$list\" | grep -q 'Working'"
hook '{"session_id":"up-fg","hook_event_name":"PermissionRequest","cwd":"/tmp","tool_name":"Bash"}'
check "upgraded hook ingests new events" bash -c "\"$F_ROOT/bin/claude-status-ctl\" list --home \"$F_ROOT\" | grep '^up-fg' | grep -q Waiting"
check "upgraded selftest passes" F_CTL selftest

echo "Rollback to $PREV_VERSION (scripts/rollback.sh)"
run "$REPO_ROOT/scripts/rollback.sh" "$PREV_ZIP" --sha256 "$PREV_SHA" --no-launch > "$FAKE/rollback.log" 2>&1
check "rollback exits 0" test $? = 0
check "installed app is $PREV_VERSION again" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$F_APP/Contents/Info.plist")" = "$PREV_VERSION"
check "helpers rolled back" cmp -s "$F_ROOT/bin/claude-status-hook" "$PREV_APP/Contents/Helpers/claude-status-hook"
check "rollback leaves settings byte-identical" test "$(sha "$FAKE/.claude/settings.json")" = "$settings_after_prev"
list="$(F_CTL list)"
check "records written by $VERSION readable by $PREV_VERSION" bash -c "! grep -q unreadable <<< \"$list\" && grep -q '^up-bg' <<< \"$list\" && grep -q '^up-fg' <<< \"$list\""
check "previous version shows the waiting session" bash -c "grep '^up-fg' <<< \"$list\" | grep -q Waiting"
check "upgraded build moved to (fake) Trash, not deleted" bash -c "ls '$FAKE/.Trash' | grep -q 'Claude Status'"

echo "Upgrade again"
run "$REPO_ROOT/scripts/install.sh" --skip-build --no-launch --no-login-item > "$FAKE/upgrade2.log" 2>&1
check "re-upgrade exits 0 and hooks healthy" F_CTL verify-hooks
check "settings still byte-identical" test "$(sha "$FAKE/.claude/settings.json")" = "$settings_after_prev"

echo "Isolation"
check "real user settings untouched" test "$(sha "$REAL_SETTINGS")" = "$real_before"
: "$prev_list"

echo
echo "Upgrade/rollback: $PASS passed, $FAIL failed"
if [[ $FAIL != 0 ]]; then for f in "$FAKE"/*.log; do echo "--- $f"; cat "$f"; done; fi
[[ $FAIL == 0 ]]
