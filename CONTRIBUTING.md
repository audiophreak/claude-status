# Contributing

Thanks for your interest in Claude Status. It is a small, independently maintained utility,
so focused changes with tests are the easiest to review.

## Development setup

Requirements: an Apple silicon Mac with macOS 14 or later and Xcode (or the Command Line Tools)
with Swift 6. There are no third-party dependencies.

```bash
git clone https://github.com/audiophreak/claude-status.git
cd claude-status
swift build
swift test
scripts/test.sh            # unit + integration tests, temporary fixtures only
```

`scripts/install.sh` installs your build and registers its hooks in your real
`~/.claude/settings.json` (with a backup). Use `scripts/uninstall.sh` to remove it again.

## Ground rules

- **The hook must fail open.** `claude-status-hook` never writes to stdout or stderr, always
  exits 0, waits at most about one second for its lock, and never executes anything derived
  from its input.
- **Privacy.** Do not store or log prompts, responses, tool names, tool input or output,
  transcript paths, session titles or error details.
- **Settings edits** go through `HookConfigurator` only (structured, verified, backed up,
  concurrency-checked). Tests that write settings use temporary fixture files, never the
  real `~/.claude/settings.json`.
- **State machine changes** need unit tests for the new transitions and must not infer
  *Complete* from silence.
- **No new dependencies** without discussion. No network access, telemetry or listening ports.
- Shell scripts pass `shellcheck`; Swift builds without warnings.
- Update `CHANGELOG.md` (under *Unreleased*) and the docs when behaviour changes.

## Pull requests

Open an issue first for larger changes. Fill in the pull request checklist. CI runs the build,
unit and integration tests, shellcheck and a secret scan on macOS and Linux runners.

## Releases

See [docs/RELEASING.md](docs/RELEASING.md).

By contributing you agree that your contributions are licensed under the MIT License and that
you will follow the [Code of Conduct](CODE_OF_CONDUCT.md).
