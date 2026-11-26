#!/usr/bin/env bash
# Rebuild from the current checkout and reinstall in place (state and preferences kept).
# Hook registration is re-verified and repaired only if needed (idempotent).
source "$(dirname "$0")/lib.sh"
"$REPO_ROOT/scripts/test.sh" --unit-only
exec "$REPO_ROOT/scripts/install.sh" "$@"
