# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.1.0] — 2026-11-27

Monitoring accuracy and operational hardening. Every rule is backed by a documented hook
field or by event sequences recorded live from Claude Code Desktop 2.1.330 and CLI 2.1.325
(sanitized fixtures in `Tests/Fixtures/recorded/`).

### Fixed
- **Desktop Stop button / interrupted turns.** Stopping a turn in the Desktop app fires no
  `Stop` and no `PostToolUseFailure`; 1.0.x kept such a session *Working* (with a tool in
  flight, for up to two hours). The internal prompt-suggestion agent's `SubagentStop` (empty
  `agent_type`) that follows is now treated as evidence: **Unknown — Possibly interrupted**,
  never Complete; any later event resumes the session.
- **Questions shown as approvals.** `AskUserQuestion` / `ExitPlanMode` pass through
  `PermissionRequest`; they now stay *Question for you* / *Plan approval required*.
- **Waiting ended too early.** A parallel tool finishing, or background subagent activity,
  ended *Waiting* while a permission prompt was still open. Requests are now tracked per tool
  call and thread; Waiting ends when every open request is answered.
- **Interrupts shown as errors.** A tool aborted with `is_interrupt` is now *Idle —
  Interrupted* (gray), not *Error* (red). Red means a confirmed terminal failure.
- **`idle_prompt` shown as Waiting.** At the input prompt without a `Stop`, the turn is shown
  as ended (*Idle*), not as amber attention.
- **Background subagent events reopened a finished or interrupted turn.** They are now
  recorded as background evidence ("subagent active").
- **Background work went Unknown after 8 hours.** The arbitrary cut-off is removed: while the
  Claude process runs, reported background work stays *Working — Background* with its report
  age; confidence drops after an hour; process exit resolves it.
- **Sleep counted as silence in `claude-status-ctl`.** Staleness now uses the kernel wake time
  (`kern.waketime`) in the CLI as well as in the app, and the app rescans processes on wake.
- A record without a PID no longer absorbs a newer process in the same folder.
- The 1.0.x CLI acceptance driver approved its own test session's permission prompts; it now
  only declines them.

### Added
- **Background counts are labelled as last reported** ("1 task (shell) · reported 20m ago";
  during a later turn "… at last report · updated when this turn ends"), because Claude Code
  fires no event when an individual task exits.
- **Continuation scheduled** (teal clock) with the wakeup time computed from the documented
  `session_crons` cron expression ("Claude continues at 14:05"); overdue wakeups are flagged.
  Scheduled sessions are not counted as executing work.
- **Working — Continuing** for a new turn that starts while background work or a wakeup was
  pending.
- **Monitoring confidence** per session (confirmed / partial / unknown with the reason), a
  "Partly observed" hint and an evidence tooltip (foreground, background, last event).
- Health line "Hooks installed · last ran 12s ago · 0 rejected".
- `claude-status-ctl report` — sanitized Markdown diagnostic report for GitHub issues (no
  session ids, project names, paths or payload data; `--include-names` to opt in to names).
- `claude-status-ctl version`, `claude-status-ctl list --json`; `selftest` now also checks
  permission waiting, interrupt evidence and scheduled continuation (12 checks).
- `scripts/rollback.sh` (switch to any release zip or app, checksum-verified, settings never
  restored from a backup) and `scripts/upgrade-rollback-test.sh` (previous release → this
  build → previous release → this build in an isolated HOME; also in CI).
- `scripts/acceptance/soak.py` (30+ minute monitoring test with an app restart),
  `scripts/perf.sh` (reproducible performance measurements), rewritten
  `scripts/acceptance/cli_acceptance.py` (full CLI matrix; never approves a permission).
- Storage bound: at most 200 records (oldest ended or exited first).
- The hook log records notification types, interrupt flags, internal agents and wakeup times
  (labels only).

### Changed
- Records gain optional fields (tool names in flight, open permission requests, background
  activity time, next wakeup time). Schema and enum values are unchanged, so 1.0.x can read
  1.1.0 records (tested by rollback).

## [1.0.2] — 2026-11-26

### Fixed
- A session whose foreground turn has not been observed yet (for example, first seen through a
  `SubagentStop` while it waits for a background command) is shown as **Working — Background**
  when Claude Code reports running background tasks, instead of plain Unknown. Found while
  verifying 1.0.1 against the session that showed the original defect.

## [1.0.1] — 2026-11-26

Correctness fix: a session whose response had finished while background work was still running
was shown as **Complete**, and a running session that had not sent an event since Claude Status
started watching it was not shown at all ("No active sessions").

### Fixed
- A `Stop` no longer marks a session Complete while Claude Code reports running background work
  (the documented `background_tasks` array on `Stop` / `SubagentStop`). Such sessions show
  **Working — Background** with the number and type of tasks, and the menu bar stays Working.
- Claude resuming on its own after background work (observed as `UserPromptSubmit` or tool
  activity without a typed prompt) shows **Working — Continuing**. Complete requires a `Stop`
  that reports no running background work.
- A `Stop` without a background report is shown as **Unknown**, never assumed complete.
- Running Claude Code sessions without any event are listed as **Unknown — Not observed** and
  count towards the aggregate, instead of only being mentioned as a number under health.
- **Clear Finished** and retention hide, rather than delete, finished sessions whose Claude
  process is still running, so they never become untracked. Background, waiting and unknown
  sessions are never removed.
- Monitoring health no longer says "Monitoring active" when running sessions are not observed.

### Added
- Separate foreground and background lines in the dashboard; **Working — Continuation
  scheduled** for one-shot scheduled wakeups (`session_crons`); hourglass menu bar symbol when
  only background work is running.
- Health shows coverage ("3 of 4 running sessions observed"), whether hooks are executing
  (last run, recent rejected events), and whether Claude Code reports background tasks.
- `claude-status-ctl diagnose` prints coverage and the PID → session mapping;
  `claude-status-ctl selftest` runs the installed hook against an isolated store and checks
  ingestion and state derivation; `list` shows unobserved sessions and the two dimensions.
- The hook log records background-task counts, types and statuses for `Stop` / `SubagentStop`
  (never descriptions or commands).

### Changed
- Stored per session in addition: in-flight background tasks (opaque id, type label, status)
  and scheduled-wakeup counts. Records written by 1.0.0 remain readable; a session that 1.0.0
  last recorded as Complete shows Unknown until its next turn, because 1.0.0 did not keep the
  background report.

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
  The same actions are available non-interactively as `ClaudeStatus --setup-hooks` and
  `--remove-hooks`.
- Settings location follows Claude Code: `$CLAUDE_CONFIG_DIR/settings.json` or
  `$HOME/.claude/settings.json`.
- Build, test, install, update, diagnose, uninstall and release-packaging scripts; unit,
  integration, installer round-trip and real CLI acceptance tests; documentation.
- GitHub Actions: CI (macOS build and tests, shellcheck, gitleaks secret scan) and a tag-driven
  release workflow producing an ad-hoc-signed arm64 zip, SHA-256 checksums and a
  build-provenance attestation.
