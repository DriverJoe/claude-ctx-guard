#!/usr/bin/env bash
# ctx-guard.sh <stop|prompt|precompact>   — GLOBAL, all projects
# Hard-enforcement guard: this session's durable notes must be flushed to the
# project's "flush target" before context compaction can summarize the session away.
#
# Wired once in ~/.claude/settings.json (Stop / UserPromptSubmit / PreCompact) so it
# runs on EVERY project. Each project decides WHERE its flush lands:
#   * default              -> <project>/SESSION.md  (root; NOT .claude/, which Claude
#                             Code hard-guards as a sensitive path even in bypass mode)
#   * per-project override  -> first non-comment line of <project>/.claude/ctx-guard.target
#   * test/explicit override-> $CTX_GUARD_TARGET env (highest precedence)
# (e.g. a project can point its target at an out-of-tree notes file — a shared
#  docs/ log, a project journal, an external knowledge base — via ctx-guard.target.)
#
# Invariants (see README.md):
#  1. Never blocks when context is under the arm threshold.
#  2. Always unblocks after a genuine write to the target (mtime advances past arming).
#  3. A MISSING target counts as "never flushed" (stale) -> blocks and asks to create it.
#  4. Anti-loop: max 3 consecutive stop-blocks per arm-cycle, then fails OPEN loudly.
#  5. Works without the statusline bridge (transcript-usage fallback is first-class).
#  6. Multi-session safe: all state keyed by session_id.
#  7. Fails OPEN on any error/missing dependency — never bricks a session.
#  8. PreCompact keeps its reminder role; blocks auto-compact at most ONCE per arm-cycle.

# Accept BOTH Claude Code's canonical event names (Stop / UserPromptSubmit /
# PreCompact — the arg install.sh wires) and the short lowercase forms (stop /
# prompt / precompact — used by the tests and by hand-wired setups). Normalise
# to lowercase (explicit A-Z ranges, not `tr A-Z a-z`, to dodge locale quirks)
# and alias userpromptsubmit -> prompt, so the case statement below matches either.
EVENT="$(printf '%s' "${1:-}" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')"
[ "$EVENT" = "userpromptsubmit" ] && EVENT="prompt"

STATE_DIR="${CTX_GUARD_STATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ctx-state}"
ARM="${CTX_GUARD_ARM:-100000}"            # tokens used: guard arms above this
DISARM="${CTX_GUARD_DISARM:-80000}"       # tokens used: guard fully resets below this (post-compaction)
REARM_DELTA="${CTX_GUARD_REARM_DELTA:-40000}"  # re-demand a flush after this much growth past the last one
MAX_BLOCKS="${CTX_GUARD_MAX_BLOCKS:-3}"   # consecutive stop-blocks before failing open
BRIDGE_MAX_AGE="${CTX_GUARD_BRIDGE_MAX_AGE:-600}"  # seconds a statusline bridge reading stays trusted
ARM_GRACE="${CTX_GUARD_ARM_GRACE:-900}"   # a flush within this many seconds BEFORE arming still counts

NOW="${CTX_GUARD_NOW:-$(date +%s 2>/dev/null || echo 0)}"

log_err() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s [%s] %s\n' "$(date '+%F %T' 2>/dev/null)" "$EVENT" "$*" >> "$STATE_DIR/guard-errors.log" 2>/dev/null
}

# Fail-open preconditions
command -v jq >/dev/null 2>&1 || { log_err "jq missing"; exit 0; }
[ "$NOW" -gt 0 ] 2>/dev/null || { log_err "no clock"; exit 0; }

INPUT="$(cat 2>/dev/null || true)"
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$SID" ] || { log_err "no session_id in stdin"; exit 0; }
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"

mkdir -p "$STATE_DIR" 2>/dev/null || { log_err "cannot create state dir"; exit 0; }

# ---------- resolve this project's flush target ----------
PROJ="${CLAUDE_PROJECT_DIR:-}"
[ -n "$PROJ" ] || PROJ="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
if [ -n "$CTX_GUARD_TARGET" ]; then
  TARGET="$CTX_GUARD_TARGET"                                   # explicit/test override
elif [ -n "$PROJ" ] && [ -f "$PROJ/.claude/ctx-guard.target" ]; then
  # Trim surrounding whitespace: an indented or trailing-space path would make
  # us stat a name nobody ever writes -> permanent-stale block until fail-open.
  TARGET="$(grep -vE '^[[:space:]]*(#|$)' "$PROJ/.claude/ctx-guard.target" 2>/dev/null | head -n 1 \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$TARGET" ] || TARGET="$PROJ/SESSION.md"                # empty override file -> default
  case "$TARGET" in /*) ;; *) TARGET="$PROJ/$TARGET" ;; esac   # relative -> project-rooted, not cwd-dependent
elif [ -n "$PROJ" ]; then
  TARGET="$PROJ/SESSION.md"                                    # default per-project log (root; .claude/ is a gated path)
else
  log_err "no project dir / cwd — cannot resolve flush target"; exit 0
fi

# ---------- current context tokens: statusline bridge first, transcript fallback ----------
tokens=""
BRIDGE="$STATE_DIR/$SID.json"
if [ -f "$BRIDGE" ]; then
  b_ts="$(jq -r '.ts // 0' "$BRIDGE" 2>/dev/null)"
  b_tok="$(jq -r '.tokens // 0' "$BRIDGE" 2>/dev/null)"
  case "$b_ts" in ''|*[!0-9]*) b_ts=0 ;; esac
  case "$b_tok" in ''|*[!0-9]*) b_tok=0 ;; esac
  if [ "$b_ts" -gt 0 ] && [ $(( NOW - b_ts )) -lt "$BRIDGE_MAX_AGE" ] && [ "$b_tok" -gt 0 ]; then
    tokens="$b_tok"
  fi
fi
if [ -z "$tokens" ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  # Last main-chain context size. Handles: partial first line from tail -c (fromjson?),
  # subagent sidechains (isSidechain), and compaction boundaries (postTokens resets the count).
  tokens="$(tail -c 300000 "$TRANSCRIPT" 2>/dev/null | jq -R -s '
    [ split("\n")[]
      | fromjson?
      | select(.isSidechain != true)
      | if (.type == "system" and .subtype == "compact_boundary")
        then (.compactMetadata.postTokens // 0)
        else (.message.usage? // empty
              | select(.input_tokens != null)
              | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0)
                 + (.cache_read_input_tokens // 0) + (.output_tokens // 0)))
        end
    ] | if length == 0 then empty else last end' 2>/dev/null)"
fi
case "$tokens" in ''|*[!0-9]*) log_err "tokens undeterminable sid=$SID"; exit 0 ;; esac

# ---------- per-session guard state ----------
STATE_FILE="$STATE_DIR/$SID.guard.json"
armed_at=0; flush_ack_tokens=0; block_count=0; pc_blocked=0
if [ -f "$STATE_FILE" ]; then
  armed_at="$(jq -r '.armed_at // 0' "$STATE_FILE" 2>/dev/null)"
  flush_ack_tokens="$(jq -r '.flush_ack_tokens // 0' "$STATE_FILE" 2>/dev/null)"
  block_count="$(jq -r '.block_count // 0' "$STATE_FILE" 2>/dev/null)"
  pc_blocked="$(jq -r '.pc_blocked // 0' "$STATE_FILE" 2>/dev/null)"
  case "$armed_at" in ''|*[!0-9]*) armed_at=0 ;; esac
  case "$flush_ack_tokens" in ''|*[!0-9]*) flush_ack_tokens=0 ;; esac
  case "$block_count" in ''|*[!0-9]*) block_count=0 ;; esac
  case "$pc_blocked" in ''|*[!0-9]*) pc_blocked=0 ;; esac
fi

save_state() {
  tmp="$STATE_FILE.tmp.$$"
  printf '{"armed_at":%s,"flush_ack_tokens":%s,"block_count":%s,"pc_blocked":%s}\n' \
    "$armed_at" "$flush_ack_tokens" "$block_count" "$pc_blocked" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$STATE_FILE" 2>/dev/null
}

# Below disarm floor (fresh session or just compacted): reset everything, allow.
if [ "$tokens" -lt "$DISARM" ]; then
  rm -f "$STATE_FILE" 2>/dev/null
  exit 0
fi
# Between floors and never armed: allow (hysteresis).
if [ "$tokens" -lt "$ARM" ] && [ "$armed_at" -eq 0 ]; then
  exit 0
fi

# Arm on first crossing. Grace window: a flush shortly BEFORE crossing still counts as fresh.
if [ "$armed_at" -eq 0 ]; then
  armed_at=$(( NOW - ARM_GRACE ))
  flush_ack_tokens=0; block_count=0; pc_blocked=0
  save_state
fi

# ---------- target freshness (missing target = never flushed = stale) ----------
if [ -e "$TARGET" ]; then
  # GNU form FIRST: on Linux `stat -c %Y` succeeds numerically; on macOS/BSD `-c`
  # is an unknown flag → errors → the `||` runs BSD `stat -f %m`. (The reverse order
  # is broken: GNU `stat -f %m` does NOT error, it prints "%m" literally and exits 0,
  # so the fallback never fires and the guard silently fails open on all Linux.)
  target_mtime="$(stat -c %Y "$TARGET" 2>/dev/null || stat -f %m "$TARGET" 2>/dev/null)"
  case "$target_mtime" in ''|*[!0-9]*) log_err "cannot stat existing target: $TARGET"; exit 0 ;; esac
else
  target_mtime=0
fi

fresh=0
[ "$target_mtime" -gt "$armed_at" ] && fresh=1

# Re-arm: flushed once, but context has grown REARM_DELTA past that flush — demand a new one.
if [ "$fresh" -eq 1 ] && [ "$flush_ack_tokens" -gt 0 ] && [ "$tokens" -gt $(( flush_ack_tokens + REARM_DELTA )) ]; then
  armed_at="$NOW"; flush_ack_tokens=0; block_count=0; pc_blocked=0
  save_state
  fresh=0
fi

tokens_k=$(( tokens / 1000 ))
if [ "$target_mtime" -gt 0 ]; then
  target_age_min=$(( (NOW - target_mtime) / 60 ))
  stale_desc="last write ${target_age_min} min ago, before this session crossed the threshold"
else
  stale_desc="the file does not exist yet — nothing has been flushed"
fi

if [ "$fresh" -eq 1 ]; then
  # Acknowledge the flush once (records the token level it covered; resets block counter).
  if [ "$flush_ack_tokens" -eq 0 ]; then
    flush_ack_tokens="$tokens"; block_count=0
    save_state
  fi
  if [ "$EVENT" = "precompact" ]; then
    printf '{"systemMessage":"✅ ctx-guard: flush target is fresh — compaction proceeding safely at ~%sk used."}\n' "$tokens_k"
  fi
  exit 0
fi

# ---------- STALE and over threshold: enforce per event ----------
case "$EVENT" in
  stop)
    if [ "$block_count" -ge "$MAX_BLOCKS" ]; then
      printf '{"systemMessage":"⚠️ ctx-guard: flush target STILL stale after %s stop-blocks (~%sk used) — failing open to avoid a loop. Flush it manually."}\n' "$MAX_BLOCKS" "$tokens_k"
      exit 0
    fi
    block_count=$(( block_count + 1 ))
    save_state
    jq -cn --arg r "[ctx-guard] Context is ~${tokens_k}k tokens used (flush threshold ${ARM} tok) and the flush target is STALE: ${TARGET} (${stale_desc}). Before ending this turn, flush a dated summary of this session's decisions, fixes, corrections and open tasks to that file (create it — mkdir -p its directory — if it does not exist). If this project's CLAUDE.md defines a closing ritual, follow it. The guard clears automatically once the file's mtime advances — then end the turn normally. (Stop-block ${block_count}/${MAX_BLOCKS}.)" \
      '{"decision":"block","reason":$r}'
    exit 0
    ;;
  prompt)
    jq -cn --arg c "[ctx-guard] Context is ~${tokens_k}k tokens used (flush threshold ${ARM} tok) and the flush target ${TARGET} has NOT been updated since the threshold was crossed (${stale_desc}). FLUSH IT FIRST in this turn — write a dated session summary there (following this project's CLAUDE.md closing ritual if it has one) — then handle the user's request." \
      '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":$c}}'
    exit 0
    ;;
  precompact)
    trigger="$(printf '%s' "$INPUT" | jq -r '.trigger // "auto"' 2>/dev/null)"
    if [ "$trigger" = "auto" ] && [ "$pc_blocked" -eq 0 ]; then
      pc_blocked=1
      save_state
      jq -cn --arg m "⛔ ctx-guard BLOCKED auto-compact (~${tokens_k}k used): flush target ${TARGET} is stale (${stale_desc}). Claude must flush it now; compaction will be allowed on its next attempt (one block per cycle)." \
        '{"decision":"block","reason":$m,"systemMessage":"⛔ ctx-guard blocked auto-compact — flush your session notes first, then compaction proceeds."}'
      exit 0
    fi
    jq -cn --arg m "⚠️ ctx-guard: compaction proceeding with a STALE flush target (~${tokens_k}k used, ${TARGET}) — the flush was missed. Full history remains in the session transcript JSONL." \
      '{"systemMessage":$m}'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
