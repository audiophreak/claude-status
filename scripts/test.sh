#!/usr/bin/env bash
# Run the automated test suites. Never touches the real ~/.claude/settings.json or state.
# usage: scripts/test.sh [--unit-only]
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT" || exit 1
info "unit tests (swift test)"
swift test 2>&1 | tee "$REPO_ROOT/.build/unit-tests.log" | grep -E "Executed|error|failed" | sed -E 's/\x1b\[[0-9;]*m//g' | tail -3
grep -q "with 0 failures" "$REPO_ROOT/.build/unit-tests.log" || die "unit tests failed (see .build/unit-tests.log)"
[[ "${1:-}" == "--unit-only" ]] && exit 0
info "integration tests"
"$REPO_ROOT/scripts/integration-test.sh"
info "installer round-trip test (isolated HOME)"
"$REPO_ROOT/scripts/installer-roundtrip-test.sh"
