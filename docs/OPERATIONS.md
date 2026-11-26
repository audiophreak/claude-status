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

**Rollback** of a failed or unwanted installation is the same selective uninstall. Old
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
| `…/ClaudeStatus/sessions/<session_id>.json` | One record per session | 0600 / 0700 dir |
| `…/ClaudeStatus/logs/hook.log` (+ `.1`) | Event name, session-ID prefix, result, duration; rotates at 256 KB | 0600 |
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
running background task, continuation, Stop with none, Stop without a report) in an isolated
temporary store, and the derived states are checked. Machine-readable:
`claude-status-ctl diagnose --json`.

| Symptom | Check / fix |
|---|---|
| Menu shows "Hook executable missing" | `scripts/install.sh --skip-build` |
| "Hooks partially installed" / "command points to a different location" | `claude-status-ctl install-hooks` repairs idempotently |
| "Claude settings could not be parsed" | `~/.claude/settings.json` is not valid JSON; Claude Status will not edit it. Fix the file, then re-run install. |
| A session shows "Unknown — Not observed" | Its process is running but it has not fired a hook since Claude Status started watching (idle, or waiting on a background command). It updates on its next prompt, tool call or turn end; no restart needed. `diagnose` lists it as `UNOBSERVED`. Interactive sessions in an untrusted folder hold back all hooks until the trust dialog is accepted. |
| A session shows "Working — Background" for a long time | Claude Code reported running background tasks at the end of the last response and has not resumed yet. Check the session's Background tasks pane. After 8 h without an event it turns Unknown. |
| "Background tasks not reported by this Claude Code version" | `Stop` events carry no `background_tasks`; finished responses show as Unknown instead of Complete. Update Claude Code. |
| Session stuck on Working after pressing Esc | Claude Code emits no hook for an interrupt outside a tool (see README › Known limitations). The next prompt corrects it; otherwise it turns Unknown after 20 min. |
| Session shows Unknown "process exited" | The Claude process ended without `SessionEnd` (crash/kill). Use Clear Finished. |
| Login item "requires approval" | System Settings › General › Login Items, or Preferences › Open. |
| Hook appears slow | `tail ~/Library/Application\ Support/ClaudeStatus/logs/hook.log` shows per-event microseconds. |
