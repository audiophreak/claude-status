# Claude Status — project rules

Native macOS (Apple Silicon, macOS 14+) menu bar app showing local Claude Code session state
from lifecycle hooks. Swift Package; no third-party dependencies.

## Layout

- `Sources/ClaudeStatusCore` — all logic (parsing, state machine, store, settings editor,
  health). Keep it UI-free and unit-tested.
- `Sources/ClaudeStatusHook` — hook entry point; must stay fast, silent and exit 0.
- `Sources/ClaudeStatusCtl` — install/uninstall/verify/diagnose CLI.
- `Sources/ClaudeStatusApp` — SwiftUI `MenuBarExtra` app.
- `scripts/` — build, test, install, update, diagnose, uninstall, acceptance.

## Commands

- `swift build` / `swift test` — debug build, unit tests
- `scripts/test.sh` — unit + integration + installer round-trip tests (temporary fixtures only)
- `scripts/package-release.sh` — release zip, checksums and notes in `.build/release-assets/`
- `scripts/build.sh` — signed arm64 release bundle in `.build/dist/`
- `scripts/install.sh --skip-build` — install the built bundle and register hooks
- `.build/debug/ClaudeStatus --render-snapshots DIR` — offscreen PNGs of the UI for review

## Rules

- The hook must never write to stdout/stderr, never exit non-zero, never block longer than
  its bounded lock wait, and never execute anything derived from its input.
- Never store prompts, tool input/output, transcript paths, assistant text or session titles.
- `~/.claude/settings.json` is edited only through `HookConfigurator` (structured, verified,
  backed up, concurrency-checked). Never edit it textually, never restore backups blindly, and
  never run destructive or negative tests against the real file — use fixtures.
- No `rm -rf`; delete exact expected paths only, move app bundles to the Trash.
- Keep `VERSION` and `ClaudeStatusVersion.current` in sync (`scripts/build.sh` enforces it).
- Update `CHANGELOG.md` and `docs/` when behaviour changes. Work is not done until
  `scripts/test.sh` passes.
- Test locally first (`scripts/test.sh`). GitHub Actions workflows use least-privilege
  `permissions`, actions pinned to full commit SHAs, and no paid services; keep it that way.
- Public repository: never commit personal paths, private project names, session IDs, runtime
  state or settings backups. Screenshots come from `--render-snapshots` with demo data.
