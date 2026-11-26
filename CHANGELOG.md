# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] — 2026-11-26

First public release.

### Added
- Native arm64 SwiftUI menu bar app with a colour- and symbol-coded aggregate indicator,
  working-session count, and a session dashboard (project, worktree, client, state, detail,
  elapsed time / time since completion, monitoring health).
- Preferences: launch at login (`SMAppService`), working-session count, elapsed duration in
  the menu bar, working directories, finished-session retention, optional completion /
  attention / error notifications (off by default; permission requested only when enabled).
- `claude-status-hook`: fail-open lifecycle hook for SessionStart, UserPromptSubmit,
  PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, Notification, Stop,
  StopFailure, SubagentStart, SubagentStop and SessionEnd.
- Deterministic session state machine with subagent, Stop-continuation, interrupt, API error,
  duplicate, out-of-order, clock-jump, resume and compaction handling; process-liveness and
  staleness evaluation that never infers Complete from silence.
- `claude-status-ctl`: idempotent hook install, selective uninstall, verification,
  preservation check, guarded restore, diagnostics, session list, state purge.
- Order-preserving `settings.json` editor with backups, preservation proof,
  concurrent-modification detection and post-write verification.
- In-app **Set Up Claude Code Hooks…** / **Remove Hooks…** (with confirmation), so a downloaded
  app works without a source checkout; helpers are refreshed automatically after app updates.
- Settings location follows Claude Code: `$CLAUDE_CONFIG_DIR/settings.json` or
  `$HOME/.claude/settings.json`.
- Build, test, install, update, diagnose, uninstall and release-packaging scripts; unit,
  integration, installer round-trip and real CLI acceptance tests; documentation.
- GitHub Actions: CI (macOS build and tests, shellcheck, gitleaks secret scan) and a tag-driven
  release workflow producing an ad-hoc-signed arm64 zip, SHA-256 checksums and a
  build-provenance attestation.
