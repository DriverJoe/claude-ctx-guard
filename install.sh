#!/usr/bin/env bash
#
# install.sh — installer for "claude-ctx-guard"
#
# Installs:
#   1. hooks/ctx-guard.sh           -> $CONFIG/hooks/ctx-guard.sh   (chmod +x)
#   2. three hook entries (Stop, UserPromptSubmit, PreCompact) merged into
#      $CONFIG/settings.json WITHOUT clobbering any hooks you already have.
#   3. statusline/bridge.sh         -> $CONFIG/statusline/ctx-guard-bridge.sh
#      and wires it as your statusLine — ONLY if you don't already have one.
#      If you do, it prints the snippet to paste into your own statusline.
#
# where  $CONFIG = ${CLAUDE_CONFIG_DIR:-$HOME/.claude}
#
# Safe & idempotent: re-running makes no further changes. Every settings.json
# write goes through a temp file, is validated as JSON, and the original is
# backed up to settings.json.bak first. Works on macOS (bash 3.2) and Linux.
#
# Flags / env:
#   -y | --yes            assume "yes" to prompts (non-interactive install)
#   --no-statusline       never touch statusLine (skip the bridge wiring)
#   CTX_GUARD_YES=1       same as --yes
#   CLAUDE_CONFIG_DIR     relocate the Claude config dir (default ~/.claude)

set -u

# ----------------------------------------------------------------------------
# Small output helpers (colour only when stdout is a TTY).
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_B=$(printf '\033[1m'); C_G=$(printf '\033[32m'); C_Y=$(printf '\033[33m')
  C_R=$(printf '\033[31m'); C_0=$(printf '\033[0m')
else
  C_B=; C_G=; C_Y=; C_R=; C_0=
fi
info() { printf '%s\n' "$*"; }
ok()   { printf '%s%s%s\n' "$C_G" "$*" "$C_0"; }
warn() { printf '%s%s%s\n' "$C_Y" "$*" "$C_0" >&2; }
err()  { printf '%s%s%s\n' "$C_R" "$*" "$C_0" >&2; }
die()  { err "$*"; exit 1; }

# ----------------------------------------------------------------------------
# Parse args.
# ----------------------------------------------------------------------------
ASSUME_YES="${CTX_GUARD_YES:-0}"
DO_STATUSLINE=1
for arg in "$@"; do
  case "$arg" in
    -y|--yes)        ASSUME_YES=1 ;;
    --no-statusline) DO_STATUSLINE=0 ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown argument: $arg (try --help)" ;;
  esac
done

# ----------------------------------------------------------------------------
# 1. Require jq. Fail LOUD and early with a per-OS install hint.
# ----------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  err "Error: jq (>= 1.6) is required but was not found on PATH."
  os=$(uname -s 2>/dev/null || echo unknown)
  case "$os" in
    Darwin) err "  Install: brew install jq" ;;
    Linux)
      if   command -v apt-get >/dev/null 2>&1; then err "  Install: sudo apt-get update && sudo apt-get install -y jq"
      elif command -v dnf     >/dev/null 2>&1; then err "  Install: sudo dnf install -y jq"
      elif command -v yum     >/dev/null 2>&1; then err "  Install: sudo yum install -y jq"
      elif command -v pacman  >/dev/null 2>&1; then err "  Install: sudo pacman -S jq"
      elif command -v zypper  >/dev/null 2>&1; then err "  Install: sudo zypper install -y jq"
      elif command -v apk     >/dev/null 2>&1; then err "  Install: sudo apk add jq"
      else err "  Install jq via your distribution's package manager."; fi ;;
    *) err "  Install jq from https://jqlang.github.io/jq/" ;;
  esac
  exit 1
fi

# ----------------------------------------------------------------------------
# Resolve paths. Everything hangs off the (relocatable) Claude config dir.
# ----------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || die "Cannot resolve script directory."
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DIR="$CONFIG_DIR/hooks"
GUARD_SRC="$SCRIPT_DIR/hooks/ctx-guard.sh"
GUARD_DST="$HOOKS_DIR/ctx-guard.sh"
SETTINGS="$CONFIG_DIR/settings.json"
STATE_DIR="$CONFIG_DIR/ctx-state"
SL_DIR="$CONFIG_DIR/statusline"
SL_SRC="$SCRIPT_DIR/statusline/bridge.sh"
SL_DST="$SL_DIR/ctx-guard-bridge.sh"

[ -f "$GUARD_SRC" ] || die "Missing $GUARD_SRC — run this from the repo root."

# The command strings we write into settings.json.
#   - No CLAUDE_CONFIG_DIR set: keep the literal $HOME form so settings.json is
#     portable across machines (Claude Code expands $HOME when it runs the hook).
#   - CLAUDE_CONFIG_DIR set: bake the resolved absolute path (literal $HOME would
#     point at the wrong place).
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  GUARD_CMD_BASE="$GUARD_DST"
  SL_CMD="$SL_DST"
else
  GUARD_CMD_BASE='$HOME/.claude/hooks/ctx-guard.sh'
  SL_CMD='$HOME/.claude/statusline/ctx-guard-bridge.sh'
fi
CMD_STOP="$GUARD_CMD_BASE Stop"
CMD_UPS="$GUARD_CMD_BASE UserPromptSubmit"
CMD_PRE="$GUARD_CMD_BASE PreCompact"

# ----------------------------------------------------------------------------
# Helpers: atomic + validated JSON write, and a one-time backup per run.
# ----------------------------------------------------------------------------
# write_json <target>  — reads new content from stdin, validates it parses,
# then atomically replaces <target>. Leaves <target> untouched on any error.
write_json() {
  _t="$1.tmp.$$"
  cat > "$_t" || { rm -f "$_t"; return 1; }
  if jq empty "$_t" >/dev/null 2>&1; then
    mv -f "$_t" "$1" || { rm -f "$_t"; return 1; }
    return 0
  fi
  rm -f "$_t"
  return 1
}

BACKED_UP=0
backup_once() {
  if [ "$BACKED_UP" = 0 ] && [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak" || die "Could not back up $SETTINGS"
    info "Backed up existing settings to $SETTINGS.bak"
  fi
  BACKED_UP=1
}

confirm() { # confirm "Question?"  -> 0 for yes
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  if [ ! -t 0 ]; then return 0; fi   # non-interactive: default yes (additive)
  printf '%s [Y/n] ' "$1"
  read -r _r || return 1
  case "$_r" in [Nn]|[Nn][Oo]) return 1 ;; *) return 0 ;; esac
}

info "${C_B}claude-ctx-guard installer${C_0}"
info "Config dir: $CONFIG_DIR"
info ""

# ----------------------------------------------------------------------------
# 2. Install the guard script.
# ----------------------------------------------------------------------------
mkdir -p "$HOOKS_DIR" || die "Could not create $HOOKS_DIR"
cp "$GUARD_SRC" "$GUARD_DST" || die "Could not copy guard to $GUARD_DST"
chmod +x "$GUARD_DST" || die "Could not chmod +x $GUARD_DST"
ok "Installed guard  -> $GUARD_DST"

# ----------------------------------------------------------------------------
# 3. Merge the three hooks into settings.json WITHOUT clobbering.
#
# The jq program below, for each event:
#   * creates .hooks / .hooks[event] if absent,
#   * appends our command ONLY if no existing hook in that event already runs
#     the same command (so re-running is a true no-op),
#   * never removes or reorders any hook you already have.
# ----------------------------------------------------------------------------
if [ -f "$SETTINGS" ]; then
  CURRENT=$(cat "$SETTINGS") || die "Could not read $SETTINGS"
  # Refuse to touch a settings.json that doesn't parse — we won't clobber it.
  if ! printf '%s' "$CURRENT" | jq empty >/dev/null 2>&1; then
    die "$SETTINGS is not valid JSON. Fix or move it, then re-run. (Not modified.)"
  fi
else
  CURRENT='{}'
fi

MERGE_JQ='
def ensure(event; cmd):
  .hooks = (.hooks // {})
  | .hooks[event] = ((.hooks[event] // [])
      | if any(.[]?; [.hooks[]?.command] | index(cmd) != null) then .
        else . + [ {"hooks":[{"type":"command","command":cmd}]} ] end);
ensure("Stop"; $stop)
| ensure("UserPromptSubmit"; $ups)
| ensure("PreCompact"; $pre)
'

NEW=$(printf '%s' "$CURRENT" | jq \
        --arg stop "$CMD_STOP" --arg ups "$CMD_UPS" --arg pre "$CMD_PRE" \
        "$MERGE_JQ") || die "jq failed to compute the merged hooks."

if [ "$NEW" = "$CURRENT" ]; then
  ok "Hooks already present in settings.json — nothing to change."
else
  mkdir -p "$CONFIG_DIR" || die "Could not create $CONFIG_DIR"
  backup_once
  printf '%s\n' "$NEW" | write_json "$SETTINGS" \
    || die "Failed to write merged settings.json (original left intact)."
  ok "Merged hooks    -> Stop, UserPromptSubmit, PreCompact"
fi

# ----------------------------------------------------------------------------
# 4. statusLine / token bridge.
#
# The guard receives NO token count from Claude Code. It reads a per-session
# bridge file that a statusline writes: $CONFIG/ctx-state/<session>.json.
# The guard ALSO has a transcript-JSONL fallback, so the bridge is
# recommended-but-not-mandatory.
#
# Policy:
#   * No statusLine set  -> offer to install our minimal bridge statusline.
#   * statusLine exists  -> DO NOT touch it. Print the snippet to paste into
#                           the user's own statusline instead.
# ----------------------------------------------------------------------------
HAS_SL=$(jq -r 'if (.statusLine // null) == null then "no" else "yes" end' "$SETTINGS" 2>/dev/null || echo no)

print_bridge_snippet() {
  cat <<'SNIPPET'
------------------------------------------------------------------------------
Paste this into your own statusline script, AFTER you have `input=$(cat)`
(the session JSON on stdin). It writes the per-session token bridge the guard
reads. Requires jq.

tot=$(printf '%s' "$input" | jq -r '
  (.context_window.current_usage // null) as $cu
  | if $cu then (($cu.input_tokens // 0) + ($cu.cache_creation_input_tokens // 0)
                 + ($cu.cache_read_input_tokens // 0) + ($cu.output_tokens // 0))
    else ((.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0))
    end')
case "$tot" in ''|*[!0-9]*) tot=0 ;; esac

# Bridge for ctx-guard hooks (they receive no token data): per-session live count.
# Atomic write; only when current_usage is real, so a post-compact null never
# poisons the guard with cumulative totals.
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
has_cu=$(printf '%s' "$input" | jq -r 'if .context_window.current_usage then "y" else "n" end')
if [ -n "$sid" ] && [ "$has_cu" = "y" ]; then
  state_dir="${CTX_GUARD_STATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ctx-state}"
  mkdir -p "$state_dir" 2>/dev/null
  bridge_tmp="$state_dir/.$sid.json.tmp.$$"
  if printf '{"tokens":%s,"ts":%s}\n' "$tot" "$(date +%s)" > "$bridge_tmp" 2>/dev/null; then
    mv -f "$bridge_tmp" "$state_dir/$sid.json" 2>/dev/null
  fi
  # Occasional prune of week-old state (cheap no-op most runs)
  [ $(( $(date +%s) % 97 )) -eq 0 ] && find "$state_dir" \( -name '*.json' -o -name '.*.json.tmp.*' \) -mtime +7 -delete 2>/dev/null
fi
------------------------------------------------------------------------------
SNIPPET
}

if [ "$DO_STATUSLINE" = 0 ]; then
  info ""
  warn "Skipping statusLine (--no-statusline). The guard will use its"
  warn "transcript-JSONL fallback. For live accuracy, add the bridge later:"
  print_bridge_snippet
elif [ "$HAS_SL" = "no" ]; then
  info ""
  info "No statusLine is configured. The guard works best with the token bridge."
  if confirm "Install the minimal bridge statusline and wire it up?"; then
    [ -f "$SL_SRC" ] || die "Missing $SL_SRC — cannot install bridge statusline."
    mkdir -p "$SL_DIR" || die "Could not create $SL_DIR"
    cp "$SL_SRC" "$SL_DST" || die "Could not copy bridge to $SL_DST"
    chmod +x "$SL_DST" || die "Could not chmod +x $SL_DST"
    backup_once
    SLNEW=$(jq --arg cmd "$SL_CMD" \
              '.statusLine = {"type":"command","command":$cmd}' "$SETTINGS") \
      || die "jq failed to set statusLine."
    printf '%s\n' "$SLNEW" | write_json "$SETTINGS" \
      || die "Failed to write statusLine (original left intact)."
    ok "Installed bridge -> $SL_DST"
    ok "Wired statusLine -> ctx-guard-bridge.sh"
  else
    info "Skipped. The guard will use its transcript-JSONL fallback."
    info "To add the bridge to your own statusline later, use the snippet:"
    print_bridge_snippet
  fi
else
  info ""
  warn "You already have a statusLine — leaving it untouched."
  info "To feed the guard a live token count, paste the bridge block below into"
  info "your existing statusline. (Optional: the guard also falls back to the"
  info "session transcript JSONL, so this is recommended, not mandatory.)"
  print_bridge_snippet
fi

# ----------------------------------------------------------------------------
# 5. Success summary + how to verify + kill switch.
# ----------------------------------------------------------------------------
info ""
ok "Done."
info ""
info "${C_B}Verify:${C_0}"
info "  jq '.hooks' \"$SETTINGS\"        # shows Stop / UserPromptSubmit / PreCompact"
info "  test -x \"$GUARD_DST\" && echo 'guard executable'"
if [ "$HAS_SL" = "no" ] && [ "$DO_STATUSLINE" = 1 ]; then
  info "  ls \"$STATE_DIR\"/*.json           # bridge files appear after a render"
fi
info "  cat \"$STATE_DIR/guard-errors.log\"   # guard diagnostics (created on demand)"
info ""
info "${C_B}Kill switch / disable:${C_0}"
info "  The guard fails OPEN (never bricks a session). To turn it off:"
info "    - run  ./uninstall.sh              (removes only our entries), or"
info "    - delete the three ctx-guard hook groups from $SETTINGS."
info ""
info "Backup of your previous settings (if any): $SETTINGS.bak"

