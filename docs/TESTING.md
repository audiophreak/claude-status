# Testing

`scripts/test.sh` runs everything automated. No test writes to the real
`~/.claude/settings.json` or the installed state; destructive and negative cases use unique
temporary directories.

## Unit tests (`swift test`, 151 tests)

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
| `RemediationV110Tests` | Permission tracking per tool call and thread (parallel tools, subagent requests, background activity, grant, denial by moving on, Esc denial), AskUserQuestion / plan approval through the permission flow, Desktop stop evidence (internal-agent SubagentStop), `/btw` self-correction, interrupt = cancellation not error, Esc silence bounds, Bash-bounded silence, background report provenance ("reported … ago", "at last report"), background subagent evidence, subagent never completing the parent, cron next-fire times, one-shot wakeup time without the prompt, overdue wakeups, scheduled + background overlap, sleep not counted (kernel wake time), concurrent sessions in one folder, PID reuse, PID-less records, restart reconciliation, storage bound, hidden session reappearing, sanitized diagnostic report (no ids, names, paths, e-mail), internal-agent parsing, rollback compatibility of records |
| `RecordedSequenceTests` | Replays 15 sanitized event sequences recorded live (Desktop and CLI) through the parser and state machine with invariants (never Complete while background work or a wakeup is reported, never Error without `StopFailure`) and the expected labels |

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

## Upgrade and rollback (`scripts/upgrade-rollback-test.sh`, 25 checks)

Downloads the previous public release (checksum-verified), installs it in a fake `HOME` with
its own `--setup-hooks`, records sessions with *its* hook, upgrades with this build's
`install.sh`, rolls back with `scripts/rollback.sh`, and upgrades again. Checks: settings
byte-identical throughout (the registration is the same in 1.x), no duplicate registrations,
unrelated settings preserved, helpers switched in both directions, records readable in both
directions, a background session still *Working — Background* and a mid-turn session still
*Working* after the upgrade, the upgraded hook ingesting new events, the self-test, the old
bundle moved to the Trash, and the real settings file untouched.

## Real-world acceptance

* `python3 scripts/acceptance/cli_acceptance.py` drives a dedicated interactive `claude` CLI
  session in a pseudo-terminal through the CLI matrix and checks the labels the installed
  Claude Status derives (`claude-status-ctl list --json`). It never approves a permission.
* `python3 scripts/acceptance/soak.py` is the extended-duration test (31 minutes by default,
  app restart included; see below).
* Desktop sessions are driven through dedicated, disposable Desktop Code sessions in a
  throwaway folder whose project settings pre-allow only a harmless test script;
  `scripts/acceptance/watch_session.py` records the labels Claude Status derives. A test-only
  probe hook in that folder recorded which events and fields Claude Code emits (names and
  structure only); the sanitized sequences are in `Tests/Fixtures/recorded/`.

## Results — v1.1.0 (2026-11-27, macOS 27.2, Apple silicon; Claude Code CLI 2.1.325; Claude Desktop with bundled Claude Code 2.1.330)

### Automated

| Suite | Result |
|---|---|
| Unit tests (`swift test`) | **151 / 151** passed (45 new: `RemediationV110Tests` 33, `RecordedSequenceTests` 12 replaying 15 recorded Desktop/CLI sequences) |
| Integration (`scripts/integration-test.sh`) | **65 / 65** |
| Installer round trip | **24 / 24** |
| Upgrade 1.0.2 → 1.1.0 → rollback → upgrade (`scripts/upgrade-rollback-test.sh`) | **25 / 25** |
| Installed hook self-test (`claude-status-ctl selftest`) | **12 / 12** |
| Static analysis (shellcheck, Python compile, JSON fixtures), gitleaks (tree + full history) | clean |

### Compatibility matrix (v1.1.0)

VERIFIED = exercised live against a real client with the installed 1.1.0 (or, where noted,
recorded live and replayed through the 1.1.0 state machine); PARTIAL = part of the scenario
cannot be exercised or is not reported by Claude Code; NOT TESTED = not run.

| Scenario | Desktop (Code tab, 2.1.330) | CLI (2.1.325) |
|---|---|---|
| Foreground working and completion | VERIFIED | VERIFIED |
| Background shell execution | VERIFIED | VERIFIED |
| Multiple background tasks | VERIFIED — 2 → Continuing → 1 → Continuing → Complete | VERIFIED — same |
| Automatic continuation | VERIFIED (`UserPromptSubmit`, shown *Working — Continuing*) | VERIFIED |
| Background task failure (`exit 3`) | VERIFIED | VERIFIED |
| Background task cancellation (`TaskStop`) | VERIFIED (same turn; recorded + replayed) | VERIFIED (next turn) |
| Foreground cancellation | PARTIAL — Stop button: no `Stop` event; internal-agent `SubagentStop` in 3 of 4 runs → *Unknown — Possibly interrupted*; otherwise time-bounded | PARTIAL — Esc fires no event during a tool or text; *Working* until the next prompt or the time bound (verified) |
| Background subagents | VERIFIED (incl. "subagent active" evidence) | VERIFIED (incl. two concurrent) |
| Background monitor | VERIFIED (type `monitor`) | VERIFIED (reported as `shell`) |
| Scheduled continuation (one-shot) | VERIFIED — *Continuation scheduled — continues at 11:43* → fired → Complete; cancellation with `CronDelete` | VERIFIED — same, incl. cancellation |
| Permission requests | PARTIAL — request → *Waiting — Approval required* (live on 1.1.0, kept after `permission_prompt`); approval by a person while a background task ran → Working → Complete (recorded live earlier the same day, replayed through 1.1.0); denial from the Desktop UI not exercised (the harness never answers prompts) | PARTIAL — request → Waiting; decline with Esc (no event, stays Waiting, next prompt resolves) verified; approval not exercised (never approved by the harness) |
| User-input requests (`AskUserQuestion`) | VERIFIED — *Waiting — Question for you* (kept after `permission_prompt`) → answered by a person in the Desktop UI → Working → Complete | VERIFIED — answer → Working → Complete; cancel with Esc (no event, stays Waiting) |
| Multiple concurrent sessions | VERIFIED (3 fixtures + 5 other sessions) | VERIFIED (two sessions in one folder, separate rows) |
| Existing session discovery | VERIFIED — sessions running before the upgrade/restart listed with their state; a Desktop process with no event listed as *Unknown — Not observed* | VERIFIED |
| Application restart and recovery | VERIFIED — SIGKILL + relaunch during the soak, states identical | VERIFIED — same |
| Clear Finished and retention | VERIFIED — see below | VERIFIED — see below |
| Extended-duration monitoring | VERIFIED — 24-minute background task during the soak | VERIFIED — 31-minute soak |
| MCP elicitation, agent teams | NOT TESTED | NOT TESTED |

### CLI acceptance (`cli_acceptance.py`, installed 1.1.0): **31 passed, 0 failed, 0 skipped**

basic (3), permission request / decline / next prompt / declined tool did not run (4),
question answer and cancel (3), two background tasks with one failing (4), background
cancellation (2), background subagent (2), monitor (2), scheduled wakeup with time, firing and
cancellation (3), Esc during a tool (2), Esc during text (2), two concurrent sessions in one
folder + SIGKILL mid-turn → *Unknown (process exited)* (3), `/exit` → ended (1).

### Desktop acceptance (dedicated sessions, installed 1.1.0)

| Scenario | Labels derived by Claude Status (live) |
|---|---|
| Two background tasks, one failing | Working → Working — Background (2) → Working — Continuing → Working — Background (1) → Working — Continuing → Complete |
| Stop during a foreground Bash call | Working — Running tool; no event followed (this run) → time-bounded (partial after 11 min) |
| Background subagent | Working — Background (subagent) → "subagent active" → Working — Continuing → Complete |
| Scheduled one-shot wakeup | Continuation scheduled — "Claude continues at 11:43" → (11:43:01) Working — Continuing → Complete |
| Monitor | Working — Background (monitor) → Working — Continuing → Complete |
| Stop during text generation | Working → Unknown — Possibly interrupted (1 s after the internal-agent event) |
| AskUserQuestion | Waiting — Question for you (kept after `permission_prompt`) → answered in the UI → Working → Complete |
| Permission request (`touch` outside the allow-list) | Waiting — Approval required (kept after `permission_prompt`) |
| Activity after Clear Finished | hidden session → shown again on its next event → Complete |

### Clear Finished on the real system (installed 1.1.0)

`claude-status-ctl clear-finished` (the same `SessionMaintenance` code as the dashboard
button) with 15 records: removed 8 (ended sessions and two CLI test sessions whose process had
exited), hid 3 finished Desktop test sessions whose processes were running, and kept every
running session untouched (a foreground turn, two CLI/Desktop sessions with background work —
one of them a long-running project session — and an already hidden one). A hidden test session
reappeared on its next event. Retention, the 200-record bound and Unknown/background
protection are covered by unit and integration tests.

Earlier runs in the same session (recorded, replayed by `RecordedSequenceTests`): background
cancellation in the same turn, schedule cancellation, Stop during a tool followed by the
internal-agent event, approval granted by a person while a background task ran.

### Extended-duration monitoring (`soak.py`, installed 1.1.0)

**PASS — 31.0 minutes, 0 failures** (installed 1.1.0, Desktop and CLI concurrently, five
other Claude sessions running). Sanitized transitions (`soak.jsonl`, id prefixes only):

| Time | Session | Derived status |
|---|---|---|
| 0 s | Desktop fixture A | Working — Background (24-minute background task started just before) |
| 0 s | Desktop fixture B | Complete (idle for the whole run) |
| 10 s → 16 s | CLI | Working → **Working — Background** (26-minute background task) |
| 65 s → 372 s | CLI | 5-minute foreground Bash call: Working (shown *Continuing*, because the prompt was typed while background work was pending — the documented ambiguity) for 300 s, never Unknown |
| 372 s | CLI | Working — Background |
| 485 s | — | Claude Status **SIGKILLed and relaunched**: all watched sessions identical before and after |
| 372 s → 1573 s | CLI | **Working — Background for 20 minutes without a single hook event**, report age growing |
| 1001 s → 1006 s | Desktop fixture A | background task exited → Working — Continuing → **Complete** |
| 1573 s → 1583 s | CLI | background task exited → Working — Continuing → **Complete** |
| 1860 s | CLI | `/exit` → ended |

Checks: never Complete while a background task ran, never Unknown or Error while the
processes ran, foreground tool shown Working for its full 300 s, state identical across the
restart, Complete after each background task, idle session Complete throughout, session ended
after `/exit`, harness processes and test tasks cleaned up. An earlier attempt was discarded
because of a harness bug (it compared a state sampled before its own prompt); it is not
counted.

Root cause of the 1.0.2 "25-minute recording exited 143": the read-only recorder was started
with a 25-minute duration and deliberately stopped with `kill` (SIGTERM → 143) after 19.6
minutes when that assignment finished. It never completed and is not counted as a soak test.

### Upgrade on the real system (1.0.2 → 1.1.0, eight Claude sessions running)

`scripts/install.sh --skip-build`: `~/.claude/settings.json` SHA-256 unchanged
(`c446e458…`), hooks healthy (12 events, no duplicates), helpers replaced atomically while
sessions ran, preferences unchanged (none customised), app 1.1.0 arm64, self-test 12/12;
every running session kept its state (including a long-running Desktop session that showed
*Working — Background · reported 20m ago* immediately).

### Measurements (Apple silicon, release build) — compared with 1.0.2

MEASUREMENTS

## Results — v1.0.1 / v1.0.2 (historical) (2026-11-26, macOS 27.2, Claude Code CLI 2.1.325, Claude Desktop with bundled Claude Code 2.1.330)

### Automated

| Suite | Result |
|---|---|
| Unit (`swift test`) | 106 / 106 passed (1.0.2) |
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
| The defect's own session, still waiting on its background command (observed passively, never prompted) | its first event after installing 1.0.1: `SubagentStop … bg=1(shell:running)` | 1.0.1: correlated (coverage 4 of 5) but Unknown; **1.0.2: Working — Background · foreground not yet observed** |

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
