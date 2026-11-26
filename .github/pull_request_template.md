## What and why

<!-- What does this change, and which problem does it solve? -->

## Checklist

- [ ] `scripts/test.sh` passes locally (unit + integration tests)
- [ ] New behaviour has unit tests in `Tests/ClaudeStatusCoreTests`
- [ ] The hook stays silent, fast and fail-open (exit 0, no stdout/stderr)
- [ ] No prompts, tool input/output, transcripts or other sensitive data are stored or logged
- [ ] `~/.claude/settings.json` is only changed through `HookConfigurator`
- [ ] `CHANGELOG.md` and docs updated if behaviour changed
