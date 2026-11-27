# Operations

This page covers source checkouts. If you installed a downloaded release, use the app's
**Set Up Claude Code Hooks…** / **Preferences › Remove Hooks…** buttons, which perform the
same verified settings edits as the scripts below.

All scripts run from the repository root, need no `sudo`, and refuse to run as root. They
resolve every location from `$HOME` (and `$CLAUDE_CONFIG_DIR` for the Claude settings file).

| Task | Command |
|---|---|
| Build signed arm64 bundle | `scripts/build.sh` → `.build/dist/Claude Status.app` |
| Run all automated tests | `scripts/test.sh` (unit + integration + installer round trip; fixtures only) |
| Package a release archive | `scripts/package-release.sh` (after `scripts/build.sh`) |
| Install / reinstall | `scripts/install.sh` |
| Update from current checkout | `scripts/update.sh` (unit tests, then install) |
| Health and diagnostics | `scripts/diagnose.sh` |
| Uninstall | `scripts/uninstall.sh` (`--purge-state`, `--purge-backups`) |
| Real CLI acceptance test | `python3 scripts/acceptance/cli_acceptance.py` |

## Prerequisites

macOS 14 or later on Apple Silicon, Xcode or the Command Line Tools (Swift 6 toolchain),
Claude Code (CLI and/or Claude Desktop). No other dependencies.

## Install

`scripts/install.sh [--skip-build] [--no-launch] [--no-login-item] [--no-hooks]`

1. Builds the release bundle (unless `--skip-build`) and verifies its signature.
2. Installs `claude-status-hook` and `claude-status-ctl` to
   `~/Library/Application Support/ClaudeStatus/bin/` (atomic replace) and self-tests the hook
   against a throwaway state directory.
3. Stops a running copy, installs `~/Applications/Claude Status.app` (a previous bundle is
   moved to the Trash, not deleted).
4. Registers hooks in `~/.claude/settings.json` with `claude-status-ctl install-hooks`
   (structured edit, backup, concurrency check, verification; idempotent).
5. Launches the app and registers it as a login item via `SMAppService.mainApp`
   (macOS may show a "Login item added" notice; disable with `--no-login-item` or in Preferences).
6. Prints `claude-status-ctl diagnose`.

Running sessions pick up hook changes through Claude Code's settings file watcher; nothing
needs restarting. A turn that was already running when hooks were installed is shown from its
next event, with "≥" on its elapsed time.

## Update

`scripts/update.sh` runs the unit tests and reinstalls. Session history and preferences are
kept; hook registration is only rewritten if it needs repair (for example a changed path).

Updating while Claude sessions run is safe: helpers are replaced as new files (`rename(2)`),
so a hook running at that moment completes with the old binary and the next one uses the new
one; the app is replaced after it quits (previous bundle to the Trash) and reads the same
records on start, so running work stays visible (verified on the real system 1.0.2 → 1.1.0
with eight running sessions, and by `scripts/upgrade-rollback-test.sh`).

## Rollback to another version

`scripts/rollback.sh PATH.zip|PATH.app [--sha256 HEX] [--no-launch]` switches to any 1.x build:
it verifies the checksum (optional), code signature, architecture and bundle identifier,
quits the app, moves the current bundle to the Trash, installs the chosen one, runs its own
`--setup-hooks` (installs *its* helpers, verifies the registration — identical in 1.x, so
`settings.json` is not rewritten), runs its self-test and relaunches it. Session records are
kept and remain readable in both directions (schema 1, optional fields only, no new enum
values). Tested by `scripts/upgrade-rollback-test.sh` (previous public release → this build →
previous release → this build, isolated `HOME`, settings byte-identical throughout).

## Uninstall and rollback

`scripts/uninstall.sh [--purge-state] [--purge-backups] [--keep-login-item]` removes, in order:

1. Claude Status hook handlers only (`claude-status-ctl uninstall-hooks`): unrelated hooks,
   settings changed after installation, and user handlers sharing a group are kept. The file
   is backed up first. Event keys and an empty `hooks` object are removed only if Claude
   Status emptied them.
2. The login item (`ClaudeStatus --unregister-login-item`), then the running app.
3. `--purge-state`: session records, logs and the install manifest (and with
   `--purge-backups` the settings backups) plus app preferences.
4. The app bundle (moved to the Trash) and the two helper executables.

**Removing** a failed or unwanted installation is the same selective uninstall. Old
backups are never restored blindly. `claude-status-ctl restore-backup --backup FILE` only
proceeds when the current settings differ from the backup in nothing but Claude Status hooks
and otherwise refuses.

## Verifying that global configuration was preserved

```bash
CTL="$HOME/Library/Application Support/ClaudeStatus/bin/claude-status-ctl"
BACKUP="$(ls "$HOME/Library/Application Support/ClaudeStatus/backups/"*.install.*.bak | head -1)"   # first install
"$CTL" verify-preserved --backup "$BACKUP"
diff "$BACKUP" ~/.claude/settings.json | grep -c '^<'   # 0 = nothing removed or changed
```

`verify-preserved` removes Claude Status handlers from both files and compares the rest
structurally. Changes you make after installation are reported as differences, by design.

## Runtime locations

| Path | Contents | Mode |
|---|---|---|
| `~/Applications/Claude Status.app` | Application (ad-hoc signed unless a local development identity exists) | |
| `~/Library/Application Support/ClaudeStatus/bin/` | `claude-status-hook`, `claude-status-ctl` | 0700 dir |
| `…/ClaudeStatus/sessions/<session_id>.json` | One record per session (at most 200; oldest ended first) | 0600 / 0700 dir |
| `…/ClaudeStatus/logs/hook.log` (+ `.1`) | Event name, session-ID prefix, result, duration, and type labels (background tasks, notification type, interrupt, wakeup time); rotates at 256 KB | 0600 |
| `…/ClaudeStatus/backups/` | `settings.json.<time>.<install\|uninstall>.<pid>.bak` | 0600 / 0700 dir |
| `…/ClaudeStatus/install-manifest.json` | Version, events, hook command, settings hash after install | 0600 |
| `~/Library/Preferences/io.github.audiophreak.ClaudeStatus.plist` | App preferences | |

`CLAUDE_STATUS_DISABLE=1` in a hook's environment makes it a no-op (emergency switch).

## Diagnostics and troubleshooting

`scripts/diagnose.sh` shows health, hook registration, helper presence, whether hooks are
executing (last run, rejected events), last valid event, coverage with the PID → session
mapping, background-task visibility, app memory/CPU, signature status, recent hook log lines
(with background-task counts for `Stop`), the session list, and runs
`claude-status-ctl selftest`: the installed hook is fed synthetic events (prompt, Stop with a
running background task, continuation, Stop with none, Stop without a report, permission
request and answer, interrupt evidence, scheduled wakeup) in an isolated temporary store, and
the derived states and the absence of content in the record and log are checked (12 checks).
Machine-readable: `claude-status-ctl diagnose --json`, `claude-status-ctl list --json`.

**For bug reports:** `claude-status-ctl report --output ~/Desktop/claude-status-report.md`
writes a sanitized Markdown report (versions, health, hooks, coverage, numbered sessions with
their derived state and confidence, Claude Code client versions, hook-log statistics). It
contains no session identifiers, project or repository names, paths, user name or payload
data (`--include-names` adds project names; paths are never included). Review it before
attaching it to an issue. No verbose logging is ever enabled by default.

| Symptom | Check / fix |
|---|---|
| Menu shows "Hook executable missing" | `scripts/install.sh --skip-build` |
| "Hooks partially installed" / "command points to a different location" | `claude-status-ctl install-hooks` repairs idempotently |
| "Claude settings could not be parsed" | `~/.claude/settings.json` is not valid JSON; Claude Status will not edit it. Fix the file, then re-run install. |
| A session shows "Unknown — Not observed" | Its process is running but it has not fired a hook since Claude Status started watching (idle, or waiting on a background command). It updates on its next prompt, tool call or turn end; no restart needed. `diagnose` lists it as `UNOBSERVED`. Interactive sessions in an untrusted folder hold back all hooks until the trust dialog is accepted. |
| A session shows "Working — Background" for a long time | Claude Code reported running background tasks at the end of the last response and has not resumed yet (the row says when it was reported). Check the session's Background tasks pane. It stays Working — Background while the Claude process runs; confidence drops after an hour; process exit turns it Unknown. |
| "Background tasks not reported by this Claude Code version" | `Stop` events carry no `background_tasks`; finished responses show as Unknown instead of Complete. Update Claude Code. |
| Session stuck on Working after pressing Esc or Stop | Claude Code emits no hook for an interrupt (see README › Known limitations). The next prompt corrects it; the row shows "no event for …" after 5 min and turns Unknown after 20 min (Bash running: 11 / 60 min; other tools: 30 min / 2 h). |
| "Unknown — Possibly interrupted" (Desktop) | The turn was stopped; Claude Code fired no `Stop`, only its internal suggestion agent's event. The next prompt corrects it. |
| Session stays Waiting after declining with Esc | No event follows an Esc decline; the next prompt corrects it. |
| Session shows Unknown "process exited" | The Claude process ended without `SessionEnd` (crash/kill). Use Clear Finished. |
| Login item "requires approval" | System Settings › General › Login Items, or Preferences › Open. |
| Hook appears slow | `tail ~/Library/Application\ Support/ClaudeStatus/logs/hook.log` shows per-event microseconds. |
