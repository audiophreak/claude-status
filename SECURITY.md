# Security and privacy

## Modifying a user's global Claude Code configuration

Installing hooks edits the user-scope settings file (`~/.claude/settings.json`, or
`$CLAUDE_CONFIG_DIR/settings.json`), which affects every Claude Code session for that user.
Claude Status limits the risk:

- It only ever adds or removes its own handlers, recognised by the `claude-status-hook` command.
- The handler fails open (exit 0, no output, 5 s timeout, about 1 s maximum lock wait), so a bug or
  missing file cannot block prompts, tools, permissions or stopping.
- Each edit is preceded by a 0600 backup and verified (non-Claude-Status content must be
  identical). It is abandoned on concurrent modification, verified after writing, idempotent and
  reversible. Old backups are never restored automatically.
- Hooks registered in user settings run for every project. Claude Code holds back hooks in an
  untrusted folder until its trust dialog is accepted.

Claude Status is a local, single-user utility. It has no network code, opens no listening
ports, sends no telemetry and uses no cloud service. It needs no Accessibility, Screen
Recording, Full Disk Access or administrator privileges, and does not modify the Claude
Desktop bundle or use private APIs.

## Threat model

| Input | Trust | Controls |
|---|---|---|
| Hook payload (stdin JSON from Claude Code) | Untrusted | Bounded read (4 MiB retained, remainder drained), `JSONSerialization` only, strict allow-list of fields, session-ID charset `[A-Za-z0-9_-]{1,128}` (no path traversal), token validation for enums/tool IDs, absolute-path validation without control characters for `cwd`. Invalid optional fields are dropped; invalid required fields reject the event. |
| Hook environment | Semi-trusted | Only `HOME`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_DESKTOP_APP_VERSION`, `CLAUDE_PROJECT_DIR`, `CLAUDE_PID` (validated against a same-user `claude` process) and `CLAUDE_STATUS_HOME` (absolute path, tests only) are read. |
| Session records on disk | Untrusted on read | Size-bounded, `O_NOFOLLOW`, schema- and ID-checked; corrupt records are ignored by the app and replaced by the next event. |
| `~/.claude/settings.json` | User data | Edited only through `HookConfigurator` (used by `claude-status-ctl` and, after an explicit confirmation, by the app's hook setup/removal), with the safeguards below. Otherwise read-only. |

Nothing derived from a payload is ever executed or passed to a shell. The hook never writes
to stdout or stderr and always exits 0, so it cannot block a prompt, alter a permission
decision, add context, or make Claude continue.

## Data minimisation

Stored per session: identifiers, timestamps, state, working directory, project / git
repository / worktree name, client type, Claude PID and start time, opaque in-flight
tool-use IDs, counts, and the documented enum values listed in `docs/ARCHITECTURE.md`.
Never stored: prompts, responses, tool names, tool inputs or outputs, transcript paths,
session titles, error details, credentials or any other Claude configuration. The hook log
contains event names, 8-character session-ID prefixes, results and timings only.

## Filesystem safety

* State root `~/Library/Application Support/ClaudeStatus` and subdirectories are 0700; all
  files 0600.
* Writes use a unique `O_EXCL | O_NOFOLLOW` temp file in the same directory, `fsync`, then
  `rename(2)`.
* All writers serialise on an advisory `flock`, with a 1 s bounded wait (fail open).
* Scripts delete only exact, expected paths; app bundles are moved to the Trash.

## Settings modification safeguards

Structured order-preserving edit; preservation proof (`normalized(new) == normalized(old)`)
before writing; timestamped 0600 backup; concurrent-modification detection by re-reading
immediately before `rename(2)`; post-write verification; idempotent install; selective
uninstall that keeps later changes; no blind restore of old backups. Residual risk: a write by
another program in the microseconds between the final re-read and `rename(2)` would be
overwritten. Claude Code writes this file rarely, and every edit leaves a backup.

## Code signing

Release archives are built by the GitHub Actions *Release* workflow from a tagged commit, signed
**ad-hoc** (no Apple Developer ID), with the hardened runtime and no entitlements, and are **not
notarized**. Each archive has a SHA-256 checksum and a GitHub build-provenance attestation
(`gh attestation verify <zip> --repo audiophreak/claude-status`). Local builds use a local Apple
Development identity if one exists, otherwise ad-hoc signing.

The app's **Set Up Claude Code Hooks…** action copies the two helper executables out of the
app bundle (as new files written by the app) to `~/Library/Application Support/ClaudeStatus/bin`,
so that Claude Code can run them from a stable path. It only does this after you confirm the
dialog, and it changes no system-wide security setting.

## Supported versions

Security fixes are made for the latest release only.

## Reporting a vulnerability

Please report privately via GitHub: **Security › Report a vulnerability**
(https://github.com/audiophreak/claude-status/security/advisories/new). Do not open a public
issue. Include the version, macOS version and reproduction steps, and do not include tokens,
prompts or settings files. This is a volunteer project: expect an acknowledgement within about a
week. Fixes are released as soon as practical, with credit if you would like it.
