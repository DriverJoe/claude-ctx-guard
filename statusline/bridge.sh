#!/usr/bin/env bash
# bridge.sh — a MINIMAL Claude Code statusline whose real job is the ctx-guard
# "token bridge".
#
# Claude Code hooks receive NO token count. So every render this writes the
# session's live context size to:
#     ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ctx-state/<session_id>.json
# which the ctx-guard hook reads to know how full context is. It also prints a
# tiny status line (a coloured dot + "<N>k ctx") so it's a valid statusline.
#
# Already have a statusline you like? DON'T replace it with this — instead graft
# the bridge block (printed by install.sh, or copy the middle of this file) into
# your own statusline script. The guard also has a transcript-JSONL fallback, so
# the bridge is recommended, not mandatory.
#
# Requires jq. Portable across macOS (bash 3.2) and Linux.

input=$(cat)

# --- token count -------------------------------------------------------------
# Prefer live current_usage = input + cache_creation + cache_read + output.
# cache_read is RESIDENT context and must be counted. current_usage is null
# before the first API call and right after /compact; there we fall back to the
# cumulative totals for display only (see the persist gate below).
tot=$(printf '%s' "$input" | jq -r '
  (.context_window.current_usage // null) as $cu
  | if $cu then (($cu.input_tokens // 0) + ($cu.cache_creation_input_tokens // 0)
                 + ($cu.cache_read_input_tokens // 0) + ($cu.output_tokens // 0))
    else ((.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0))
    end' 2>/dev/null)
case "$tot" in ''|*[!0-9]*) tot=0 ;; esac

# --- the bridge --------------------------------------------------------------
# Persist the count ONLY when current_usage is real. On some CLI versions the
# cumulative totals grow all session and never drop after a compaction; writing
# those would convince the guard that context is huge forever.
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
has_cu=$(printf '%s' "$input" | jq -r 'if .context_window.current_usage then "y" else "n" end' 2>/dev/null)
if [ -n "$sid" ] && [ "$has_cu" = "y" ]; then
  state_dir="${CTX_GUARD_STATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ctx-state}"
  mkdir -p "$state_dir" 2>/dev/null
  tmp="$state_dir/.$sid.json.tmp.$$"
  if printf '{"tokens":%s,"ts":%s}\n' "$tot" "$(date +%s)" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$state_dir/$sid.json" 2>/dev/null   # atomic same-dir replace
  fi
  # occasional prune of week-old state files (cheap; skipped on most renders)
  [ $(( $(date +%s) % 97 )) -eq 0 ] && find "$state_dir" \( -name '*.json' -o -name '.*.json.tmp.*' \) -mtime +7 -delete 2>/dev/null
fi

# --- minimal visible status line ---------------------------------------------
k=$(( tot / 1000 ))
if   [ "$tot" -ge 200000 ]; then dot='🔴'
elif [ "$tot" -ge 150000 ]; then dot='🟡'
else                             dot='🟢'
fi
printf '%s %sk ctx' "$dot" "$k"
