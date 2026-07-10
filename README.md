# claude-ctx-guard

**A hook that makes "save your notes before compaction" non-optional in [Claude Code](https://docs.claude.com/en/docs/claude-code).**

Claude Code compacts your context when it grows too large — replacing the live transcript with a lossy summary. If your workflow relies on the model *voluntarily* flushing structured memory (a running log, a scratchpad, a decisions file) *before* that happens, it **will** eventually be missed. One forgotten flush and a session's worth of decisions, corrections, and hard-won context is gone — summarized away.

`ctx-guard` closes that gap. It blocks turn-end and auto-compaction until a dated summary has actually been written to a file you choose — then gets out of the way. No new discipline to remember; the enforcement is the hook.

---

## The problem

- Context grows → Claude Code auto-compacts at a threshold.
- Compaction is **lossy**: live context becomes a summary.
- A "remember to write your notes first" rule that depends on the model doing it every single time is a rule that fails silently, occasionally, and exactly when it costs the most.

## The solution

A single hook, wired into Claude Code's lifecycle, that:

1. **Watches** your live context size (via a tiny statusline "bridge").
2. **Blocks** your turn from ending — and blocks auto-compaction — once context is large *and* your flush target is stale.
3. **Unblocks** the moment you write a fresh dated summary to the target.
4. **Fails open** on any error and has a manual escape hatch, so it can never brick a session.

The flush stops being something you *remember* and becomes something the harness *enforces*.

---

## How it works

`ctx-guard` is a small state machine driven by three Claude Code hook events (`Stop`, `PreCompact`, `UserPromptSubmit`) plus a live token count.

**The bridge.** Claude Code hooks don't receive a token count. So a companion snippet in your **statusline** writes the current context size to `~/.claude/ctx-state/<session_id>.json` on every render (atomic write; only when the count is real — see below). The guard reads that file (with the session's JSONL transcript as a fallback) to know how full context is.

**The lifecycle:**

| State | Trigger | Behavior |
|-------|---------|----------|
| **ARM** | context crosses **~100k** used | guard becomes active for this session |
| **BLOCK** | `Stop` / `PreCompact` / `UserPromptSubmit` while armed **and** target is stale | turn-end / auto-compaction is refused with an instruction to flush |
| **ACK** | you write a fresh dated entry to the target | target mtime advances → guard steps aside |
| **RE-ARM** | context grows **+40k** beyond the last ACK | requires another flush (long sessions flush more than once) |
| **DISARM** | context drops below **~80k** (i.e. after a compaction) | guard goes quiet until it re-arms |

**Safety rails:**

- **3-block escape hatch** — if the guard blocks you three times in a row (you genuinely can't or won't flush), it lets the turn through rather than trapping you.
- **Fail-open on any error** — missing `jq`, an unresolvable target, a bad state file, a stat failure: every error path logs and exits `0`. The guard's failure mode is "does nothing," never "blocks you forever."

---

## Where it flushes — "the target"

The guard enforces freshness of exactly one file per project: **the target**. It's resolved in this order (first match wins):

1. **`$CTX_GUARD_TARGET`** — environment variable. Explicit override, highest precedence (also handy for testing).
2. **`<project>/.claude/ctx-guard.target`** — a one-line pointer file. First non-comment, non-blank line is read as the path to your real flush file. Lets you point the guard at an out-of-tree notes file (e.g. a shared `docs/` log, a project journal, an external knowledge base) without hardcoding it anywhere.
3. **`<project>/SESSION.md`** — the default, at the **project root**.

> ### Why the default lives at the project root, not inside `.claude/`
>
> Claude Code treats everything under `.claude/` as a **sensitive path** and hard-blocks writes there **even in `bypassPermissions` mode**. A flush target inside `.claude/` could therefore never be written unattended — the guard would demand a flush the model is structurally forbidden from performing, deadlocking the session against the escape hatch. So the default target is deliberately `SESSION.md` at the project root, where writes are always permitted. If you point `ctx-guard.target` somewhere, keep it **outside** `.claude/` for the same reason.

`<project>` is `$CLAUDE_PROJECT_DIR` if set, otherwise the `.cwd` from the hook's stdin JSON. If neither resolves, the guard logs and exits open.

---

## Install

```bash
git clone https://github.com/DriverJoe/claude-ctx-guard
cd claude-ctx-guard
./install.sh
```

`install.sh` places the hook, wires the `Stop` / `PreCompact` / `UserPromptSubmit` entries into your Claude Code `settings.json` (without disturbing any hooks you already have), and installs a minimal **bridge** statusline — *only* if you don't already have one. If you do, it prints the bridge snippet for you to paste into your own statusline. It is safe to re-run (idempotent) and backs up `settings.json` before any change.

### Prerequisites

- **[Claude Code](https://docs.claude.com/en/docs/claude-code)** with a configured **statusline** (the bridge rides on statusline renders).
- **`jq` ≥ 1.6** — required by both the hook and the bridge. Without it, both fail open and the guard silently does nothing.
  - macOS: `brew install jq`
  - Debian/Ubuntu: `apt-get install jq`
  - Fedora: `dnf install jq`

### Verify

After install, in a real session:

1. Run `ls ~/.claude/ctx-state/` — you should see a `<session_id>.json` appear and update as you work. That's the bridge; if it's missing, the statusline snippet isn't running or `jq` is absent.
2. Let context grow past ~100k and try to end a turn without flushing — the guard should block with a flush instruction.
3. Write a dated line to your target (`SESSION.md` by default) — the next turn-end should pass cleanly.

---

## Configuration

All optional; sensible defaults ship out of the box.

| Variable | Default | Purpose |
|----------|---------|---------|
| `CTX_GUARD_TARGET` | *(unset)* | Absolute path to the flush target. Highest-precedence override; wins over the `.target` file and the `SESSION.md` default. |
| `CTX_GUARD_STATE_DIR` | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ctx-state` | Where per-session state, the bridge file, and the error log live. Both the hook and the bridge resolve it identically — this variable if set, else `$CLAUDE_CONFIG_DIR/ctx-state`, else `$HOME/.claude/ctx-state`. **If you override it, set the same value in both environments**, or the guard can't find the token count. |

State files, for reference:

- `$STATE_DIR/<session>.json` — the bridge (live token count).
- `$STATE_DIR/<session>.guard.json` — per-session guard state (arm level, block count).
- `$STATE_DIR/guard-errors.log` — every fail-open path logs here. First place to look if enforcement seems off.

---

## Compatibility

- **macOS and Linux.** The mtime probe and shebang are written to run identically on BSD/GNU coreutils; the scripts are effectively POSIX `sh` (no bash-4 features), so they're safe on macOS's stock bash 3.2 too.
- **Headless (`claude -p`).** Works. The block is delivered as a normal hook decision, so batch/automated runs are enforced the same as interactive ones.
- **Editor extensions (VS Code, etc.).** Some front-ends don't render a custom statusline, so the bridge file may not update there. The guard falls back to reading the session's **JSONL transcript** on disk for a token estimate, so enforcement still works — just make sure `jq` is available to the environment the hook runs in.

### The token-count subtlety (why the bridge is careful)

The bridge computes live context as `current_usage.input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens`. **Cache-read tokens are resident context and must be counted** — omitting them badly undercounts.

It falls back to cumulative `total_input/output_tokens` *only* when `current_usage` is null (before the first API call and immediately after a `/compact`). Critically, the bridge **only persists a count when `current_usage` is real** — on some CLI versions the cumulative totals keep growing all session and never drop after a compaction, so writing them to the bridge would convince the guard that context is huge forever. The visible statusline may still show the fallback (better than a zero), but it never poisons the guard's state file.

---

## Kill switch / uninstall

- **Disable for one session:** hit the 3-block escape hatch (let it block three times and it fails open for the rest of the arm-cycle), or just flush the target so the guard steps aside. Note: deleting `$STATE_DIR/<session>.guard.json` does **not** disable the guard — it only resets the state, and the guard re-arms on the next event.
- **Disable globally, fast:** remove the three hook entries (`Stop`, `PreCompact`, `UserPromptSubmit`) from your Claude Code `settings.json`. The guard is inert the moment it isn't wired.
- **Full uninstall:** `./uninstall.sh` removes only our hook entries (leaving any other hooks intact) and removes the statusLine only if it points at our bridge. It leaves the copied scripts and `$STATE_DIR` in place and tells you how to delete them.

Because every error path fails open, even a half-removed install degrades to "does nothing" rather than blocking you.

---

## How it was tested

- **20 smoke cases (25 assertions)** covering the state machine: arm at ~100k, block on stale target across all three hook events, ACK on fresh write, re-arm at +40k, disarm below 80k, the 3-block escape hatch, target-resolution precedence (env > `.target` > default) including whitespace/relative-path handling in the `.target` file, the transcript-JSONL fallback, fail-open on malformed stdin / unresolvable project, the **canonical capitalized event names exactly as `install.sh` wires them** (`Stop` / `UserPromptSubmit` / `PreCompact`), and installer idempotency over pre-existing hand-wired entries.
- **An adversarial contract audit** (multi-agent): six independent auditors each attacked one install↔runtime contract (bridge path, bridge schema, uninstall matcher, installer idempotency, target resolution, event-name wiring), with every claimed finding then adversarially re-verified against the actual shell semantics before being accepted.
- **A live headless end-to-end** (`claude -p`) driving a real session past the arm threshold, confirming the block fires and clears against an actual flush.

---

## License

MIT. See [`LICENSE`](./LICENSE).

