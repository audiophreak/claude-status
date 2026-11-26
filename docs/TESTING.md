# Testing

`scripts/test.sh` runs everything automated. No test writes to the real
`~/.claude/settings.json` or the installed state; destructive and negative cases use unique
temporary directories.

## Unit tests (`swift test`, 86 tests)

| Suite | Covers |
|---|---|
| `HookEventParserTests` | Documented field extraction; sensitive fields never retained; malformed / non-object / missing / invalid input rejection; session-ID path traversal; invalid optional fields dropped; unknown events; oversized payload prefix scan |
| `StateMachineTests` | Full turns, multiple turns, permission → waiting → resume, permission denied, AskUserQuestion / ExitPlanMode, elicitation, non-terminal tool failure, interrupt, StopFailure, subagent Stop never completing the parent, background subagents after Stop, Stop-hook continuation, duplicates, out-of-order, clock jumps, missing SessionStart, Unknown until evidence, idle_prompt semantics, SessionEnd / resume, compaction, concurrent sessions, context/worktree identity, bounds |
| `PresentationTests` | Aggregate precedence (exhaustive pairs), counts, ended sessions, long-running tool not stale, silent turn → Unknown (never Complete), sleep not counted, Waiting never stale, process exit, retention never removing active sessions, elapsed / time text, formatting, ordering |
| `StoreAndRunnerTests` | Atomic save/load with 0600/0700 modes, corrupt / renamed / oversized records, temp-file filtering, rejected input writes nothing, 400 concurrent events with no lost updates, lock timeout fails open, bounded stdin drain, client detection, PID-reuse-safe liveness, retention scenario, git repo / worktree detection, worktree sessions stay distinct |
| `HookConfiguratorTests` | Install into missing / empty / unrelated / existing-hooks configs; exact preservation (incl. sleep-prevention hook, number text, key order); schema of the added handler; idempotence (byte-identical); duplicate collapse; moved hook path repair; partial install; selective uninstall restoring original bytes; later changes kept; mixed groups; invalid JSON / structure refused and untouched; concurrent modification detected; dry run; symlinked settings; backup + rollback |
| `HelperInstallerTests`, `ClaudePathsTests` | Helper install modes, idempotence, updates, refusal of missing/symlinked sources; settings path resolution (`CLAUDE_CONFIG_DIR`, `HOME`) |
| `OrderedJSONTests` | Byte-exact round trip of `JSON.stringify` format, escapes and surrogates, invalid input, depth limit, key order and duplicates |

## Integration tests (`scripts/integration-test.sh`, 58 checks)

Run the real signed executables from `.build/dist`:

* **Hook**: exit 0 and silent for valid, empty, garbage, non-object, traversal, missing-field
  and injection-shaped input; prompt text never stored; record/directory modes; 6 MB payload;
  unwritable state root; lock held by another process (bounded < 2 s); corrupt record
  recovery; 60 concurrent hook processes; latency (100 runs).
* **Settings**: install / verify / preserve / idempotent / uninstall-to-original-bytes for
  each fixture in `Tests/Fixtures/settings`; missing file; sleep-prevention hook preserved;
  6 concurrent installers; uninstall keeping later changes and hooks; guarded restore refusal;
  invalid files refused and untouched; a **read-only copy of the real settings file**
  (install is purely additive, preserved, install+uninstall byte-identical); backup modes.
* **Diagnostics**: missing hook executable detected (exit 2) and recovery.
* **App** (isolated instance with its own state root): start-up, retention at launch
  (old finished removed, old waiting kept), Waiting aggregate, approval → Working,
  event-to-indicator latency, 13 concurrent sessions listed, Error-over-Working precedence
  with working count, restart recovery including events received while the app was down,
  missing-hook health, watcher re-arm after the state directory is replaced.

## Installer round trip (`scripts/installer-roundtrip-test.sh`, 24 checks)

Runs the real `install.sh`, a re-install (update) and `uninstall.sh` (with and without
`--purge-backups`) against a temporary fake `HOME` whose settings already contain unrelated hooks.
It checks the bundle signature, helpers, hook health, preservation, file mode, backup bytes,
that a re-install doesn't rewrite settings, byte-identical restoration and state purge. It also
hashes the real user's settings file before and after to prove it was not touched. A second fake
`HOME` exercises the downloaded-app flow: `ClaudeStatus --setup-hooks` / `--remove-hooks` run the
same code as the in-app buttons (helpers copied from the bundle, hooks registered and preserved,
idempotent, removal byte-identical).

## Real-world acceptance

`python3 scripts/acceptance/cli_acceptance.py` drives a dedicated interactive `claude` CLI
session in a pseudo-terminal (clean environment, this project folder, `--permission-mode
default`) and records the states Claude Status observes. See the results table below.

Desktop acceptance used this project's own Desktop Code session (started before installation
and picked up live) and an isolated one-reply Desktop Code session.

## Results (2026-11-26, v1.0.0, macOS 27.2, Claude Code CLI 2.1.325, Claude Desktop with bundled Claude Code 2.1.330)

### Automated

| Suite | Result |
|---|---|
| Unit (`swift test`) | 86 / 86 passed |
| Integration (`scripts/integration-test.sh`) | 58 / 58 passed |
| Installer round trip (`scripts/installer-roundtrip-test.sh`) | 24 / 24 passed |

### Real Claude Code CLI (`scripts/acceptance/cli_acceptance.py`, final run 12 / 12, 1 skipped)

| Scenario | Observed |
|---|---|
| Session start, prompt, completion | `SessionStart` → Idle, `UserPromptSubmit` → Working, `Stop` → Complete (2.3 s turn recorded); client `cli` |
| Permission | `PreToolUse` → `PermissionRequest` → **Waiting (approval required)** → approved in the TUI → `PostToolUse` → Working → `Stop` → Complete; the tool really ran |
| Interrupt during text generation (Esc) | **No hook event for 80 s**; shown Working (never Complete). Platform limitation, documented |
| Interrupt during a tool | Skipped: the model declined to run the test command in three runs |
| `/exit` | `SessionEnd` (`prompt_input_exit`) → ended |
| SIGTERM | `SessionEnd` (graceful) |
| SIGKILL mid-turn | No `SessionEnd`; Claude Status shows **Unknown — Claude process exited without ending the session** |
| API error (`claude -p --model <nonexistent>`) | `StopFailure` with `error: model_not_found` → Error, then `SessionEnd` |
| Print mode client | entrypoint `sdk-cli` → mapped to CLI |

### Real Claude Desktop (Code tab)

| Scenario | Observed |
|---|---|
| A Desktop session started **before** installation | Picked up live via the settings file watcher (no restart); tool events tracked; client Desktop |
| Isolated one-reply Desktop session | `UserPromptSubmit` → Working → `Stop` → **Complete** (took 3 s); client Desktop |
| Isolated Desktop session asked to run a command needing approval | `PreToolUse` → `PermissionRequest` → **Waiting (approval required)** → approved → `PostToolUse` → Working → `Stop` → Complete (7 s) |
| Another pre-existing Desktop session (another project) | Observed passively from its next event; Working → Complete |
| Concurrent sessions | Up to 3 live sessions (Desktop + CLI + Desktop) tracked individually |
| Existing hooks | Keep-awake hook still created/removed its per-session PID files for new sessions; all pre-existing handlers byte-identical |

### Installation lifecycle (real system)

| Step | Result |
|---|---|
| Install | Settings diff purely additive (0 lines removed, 112 added); mode 0600 kept; `verify-preserved` PASS; backup written |
| Update (`scripts/update.sh`) | Hooks already installed → **no write** to settings |
| Uninstall (`scripts/uninstall.sh`) | Settings **byte-identical** to the pre-install file; app moved to Trash; helpers removed; login item disabled; state kept |
| Reinstall | Healthy; preserved; login item enabled |

### Measurements (Apple silicon MacBook Pro, release build)

| Metric | Value |
|---|---|
| Idle CPU (120 s window, 2 hook events) | 0.07 s CPU = **0.06 %** average |
| Memory | 19 MB physical footprint (RSS 75 MB incl. shared frameworks) |
| Hook end-to-end, process spawn to exit (100 runs) | median 5.3 ms, p95 6.3 ms, max 9.9 ms |
| Hook internal processing, real events (n = 135) | median 2.5 ms, p95 3.7 ms, max 4.6 ms; 0 failures |
| Event → indicator update (10 runs) | median 64 ms, max 67 ms (includes 50 ms debounce) |
| App bundle | 2.1 MB (arm64 only; helpers 0.55 MB and 0.61 MB) |


## Visual review

`ClaudeStatus --render-snapshots DIR` renders the menu bar label for every aggregate state and
the dashboard with sample sessions in light and dark appearance (`docs/images/`). AppKit
buttons render as placeholders in `ImageRenderer`; the live menu needs a human look
(see the README's indicator guide).
