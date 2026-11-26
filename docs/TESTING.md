# Testing

`scripts/test.sh` runs everything automated. No test writes to the real
`~/.claude/settings.json` or the installed state; destructive and negative cases use unique
temporary directories.

## Unit tests (`swift test`, 105 tests)

| Suite | Covers |
|---|---|
| `HookEventParserTests` | Documented field extraction; sensitive fields never retained; malformed / non-object / missing / invalid input rejection; session-ID path traversal; invalid optional fields dropped; unknown events; oversized payload prefix scan |
| `StateMachineTests` | Full turns, multiple turns, permission → waiting → resume, permission denied, AskUserQuestion / ExitPlanMode, elicitation, non-terminal tool failure, interrupt, StopFailure, subagent Stop never completing the parent, background subagents after Stop, Stop-hook continuation, duplicates, out-of-order, clock jumps, missing SessionStart, Unknown until evidence, idle_prompt semantics, SessionEnd / resume, compaction, concurrent sessions, context/worktree identity, bounds |
| `PresentationTests` | Aggregate precedence (exhaustive pairs), counts, ended sessions, long-running tool not stale, silent turn → Unknown (never Complete), sleep not counted, Waiting never stale, process exit, retention never removing active sessions, elapsed / time text, formatting, ordering |
| `StoreAndRunnerTests` | Atomic save/load with 0600/0700 modes, corrupt / renamed / oversized records, temp-file filtering, rejected input writes nothing, 400 concurrent events with no lost updates, lock timeout fails open, bounded stdin drain, client detection, PID-reuse-safe liveness, retention scenario, git repo / worktree detection, worktree sessions stay distinct |
| `HookConfiguratorTests` | Install into missing / empty / unrelated / existing-hooks configs; exact preservation (incl. sleep-prevention hook, number text, key order); schema of the added handler; idempotence (byte-identical); duplicate collapse; moved hook path repair; partial install; selective uninstall restoring original bytes; later changes kept; mixed groups; invalid JSON / structure refused and untouched; concurrent modification detected; dry run; symlinked settings; backup + rollback |
| `BackgroundAndDiscoveryTests` | The v1.0.0 defect step by step (foreground turn → background command → Stop with a running task → **Working — Background** → automatic continuation → Working — Continuing → Stop with none → Complete); continuation via `UserPromptSubmit`; Stop without a report → Unknown; cancelled / failed / unknown task statuses; API error with background work; concurrent Desktop background + CLI foreground; three tasks draining one by one; out-of-order Stop; missing continuation → Unknown after 8 h; process exit with background work; restart forgets old tasks; one-shot vs recurring wakeups; unobserved processes listed as Unknown and counted in the aggregate; discovery → observed on the next event without restart (PID + start time, PID reuse, cwd fallback); Clear Finished hides live sessions and never deletes background work; retention never deletes live sessions; health distinguishes coverage gaps, hook failures, unreported background work and genuine inactivity; parser keeps only id/type/status; 1.0.0 records still decode; Desktop/CLI process classification |
| `HelperInstallerTests`, `ClaudePathsTests` | Helper install modes, idempotence, updates, refusal of missing/symlinked sources; settings path resolution (`CLAUDE_CONFIG_DIR`, `HOME`) |
| `OrderedJSONTests` | Byte-exact round trip of `JSON.stringify` format, escapes and surrogates, invalid input, depth limit, key order and duplicates |

## Integration tests (`scripts/integration-test.sh`, 65 checks)

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

## Results — v1.0.1 (2026-11-26, macOS 27.2, Claude Code CLI 2.1.325, Claude Desktop with bundled Claude Code 2.1.330)

### Automated

| Suite | Result |
|---|---|
| Unit (`swift test`) | 105 / 105 passed |
| Integration (`scripts/integration-test.sh`) | 65 / 65 passed (adds real-hook + real-app background scenarios and unobserved-session discovery) |
| Installer round trip (`scripts/installer-roundtrip-test.sh`) | 24 / 24 passed |
| `claude-status-ctl selftest` against the installed hook | 8 / 8 passed |

### Reproducing the 1.0.0 defect

Observed with 1.0.0: a Desktop session's response finished (`Stop`) while a background command
it had started kept running; Claude Status showed it as Complete. After the finished sessions
were cleared, the still-running session had no record and fired no further event while waiting
for the command, so the dashboard said "No active sessions" and "Monitoring active" while
counting it only as an "unobserved process". The hook log showed the session's hooks had
executed normally (177 events, ending with `Stop` and `SubagentStop`); Claude Code's own
per-process registry also reported that session as `idle`.

### Real Claude Desktop (Code tab) — dedicated test session, v1.0.1

Harmless bounded commands only (`sleep 45`, `sleep 100; exit 3`, `sleep 600`). Hook-log
evidence lines are shown as recorded (type and status only).

| Step | Hook events (evidence) | Claude Status |
|---|---|---|
| Prompt; two Bash calls with `run_in_background` | `UserPromptSubmit`, 2 × `PreToolUse`/`PostToolUse` | Working |
| Response finishes, both commands running | `Stop bg=2(shell:running,shell:running)`, then `SubagentStop … bg=2` (internal agent) | **Working — Background** (1.0.0: Complete) |
| `sleep 45` exits; Claude resumes by itself | **`UserPromptSubmit`** (no prompt typed) | Working |
| Continuation reply ends | `Stop bg=1(shell:running)` | **Working — Background** |
| `sleep 100; exit 3` fails; Claude resumes | `UserPromptSubmit` | Working |
| Reply ends, nothing left | `Stop bg=0` | **Complete** |
| Cancellation: `sleep 600` in background, then stopped with TaskStop | `Stop bg=1` → `UserPromptSubmit`, `PreToolUse`/`PostToolUse`, `Stop bg=0` | Working — Background → Working → Complete |
| Concurrent with the CLI test below | both sessions `bg=1` at the same time | both Working — Background, tracked separately |
| Running sessions with no event since the app started (incl. the defect's session) | none | **Unknown — Not observed**, coverage "3 of 5 running sessions observed" |

### Real Claude Code CLI (`scripts/acceptance/cli_acceptance.py`, 16 / 16 passed, 1 skipped)

| Scenario | Observed |
|---|---|
| Session start, prompt, completion | `SessionStart` → Idle, `UserPromptSubmit` → Working, `Stop` → Complete; client `cli` |
| Permission | `PermissionRequest` → **Waiting** → approved → Working → Complete; the tool really ran |
| Background command | approval → `Stop` with `background_tasks=[{type: shell, status: running}]` → **Working — Background**; command exits → **`UserPromptSubmit`** → Working → `Stop bg=0` → **Complete** |
| Interrupt during text generation (Esc) | No hook event for 80 s; shown Working (never Complete). Platform limitation, documented |
| Interrupt during a tool | Skipped: the model did not start the test command |
| `/exit` | `SessionEnd` (`prompt_input_exit`) → ended |
| SIGKILL mid-turn | No `SessionEnd`; **Unknown — Claude process exited without ending the session** |
| From 1.0.0 (unchanged code paths) | SIGTERM → `SessionEnd`; `claude -p --model <nonexistent>` → `StopFailure` (`model_not_found`) → Error; print mode entrypoint `sdk-cli` → CLI |

### Real Claude Desktop — from 1.0.0 (unchanged code paths)

| Scenario | Observed |
|---|---|
| A Desktop session started **before** installation | Picked up live via the settings file watcher (no restart); confirmed again in 1.0.1 for a session started 17 h before installation |
| Permission request | Waiting → approved → Working → Complete |
| Existing hooks | Keep-awake hook still works; all pre-existing handlers byte-identical |

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
| Idle CPU (120 s window, incl. the periodic Claude process scan) | 0.04 s CPU = **0.03 %** average (1.0.1) |
| Memory | 18.5–20 MB physical footprint (1.0.1) |
| Hook end-to-end, process spawn to exit (100 runs) | median 5.3 ms, p95 6.3 ms, max 9.9 ms |
| Hook internal processing, real events (n = 135) | median 2.5 ms, p95 3.7 ms, max 4.6 ms; 0 failures |
| Event → indicator update (10 runs) | median 64 ms, max 67 ms (includes 50 ms debounce) |
| App bundle | 2.7 MB (arm64 only, 1.0.1) |


## Visual review

`ClaudeStatus --render-snapshots DIR` renders the menu bar label for every aggregate state and
the dashboard with sample sessions in light and dark appearance (`docs/images/`). AppKit
buttons render as placeholders in `ImageRenderer`; the live menu needs a human look
(see the README's indicator guide).
