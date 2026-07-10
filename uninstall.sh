#!/usr/bin/env bash
#
# uninstall.sh — reverse claude-ctx-guard's settings.json changes.
#
# Removes ONLY what we added:
#   * the three hook entries whose command references ctx-guard.sh (Stop,
#     UserPromptSubmit, PreCompact) — any other hooks you have are left intact;
#   * the statusLine ONLY if it points at our ctx-guard-bridge.sh (a statusline
#     you configured yourself is never touched).
#
# It does NOT delete the copied scripts or the ctx-state directory (they are
# harmless and may be shared); it just tells you where they are.
#
# Every write is atomic + JSON-validated, and settings.json is backed up to
# settings.json.bak first. Works on macOS (bash 3.2) and Linux.
#
# Env:
#   CLAUDE_CONFIG_DIR   relocate the Claude config dir (default ~/.claude)

set -u

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

command -v jq >/dev/null 2>&1 || die "jq is required to safely edit settings.json. Install jq and re-run."

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG_DIR/settings.json"
HOOKS_DIR="$CONFIG_DIR/hooks"
STATE_DIR="$CONFIG_DIR/ctx-state"
SL_DIR="$CONFIG_DIR/statusline"
GUARD_DST="$HOOKS_DIR/ctx-guard.sh"
SL_DST="$SL_DIR/ctx-guard-bridge.sh"

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

info "${C_B}claude-ctx-guard uninstaller${C_0}"
info "Config dir: $CONFIG_DIR"
info ""

if [ ! -f "$SETTINGS" ]; then
  warn "No settings.json at $SETTINGS — nothing to clean."
else
  if ! jq empty "$SETTINGS" >/dev/null 2>&1; then
    die "$SETTINGS is not valid JSON. Not modifying it."
  fi

  # For each event: drop hook entries whose command references ctx-guard.sh,
  # then drop any hook-group left empty, then drop the event if it's now empty,
  # then drop the .hooks object if it's now empty. Foreign hooks are preserved.
  # Finally remove statusLine ONLY when it points at our bridge script.
  CLEAN_JQ='
  def clean(event; needle):
    if ((.hooks[event]? | type) == "array") then
      .hooks[event] = ( .hooks[event]
        | map( if (.hooks | type) == "array"
               then .hooks = (.hooks | map(select((.command // "") | contains(needle) | not)))
               else . end )
        | map( select( ((.hooks | type) != "array") or ((.hooks | length) > 0) ) ) )
      | (if (.hooks[event] | length) == 0 then del(.hooks[event]) else . end)
    else . end;
  ( if (.hooks | type) == "object" then
      clean("Stop"; $needle)
      | clean("UserPromptSubmit"; $needle)
      | clean("PreCompact"; $needle)
      | (if (.hooks | length) == 0 then del(.hooks) else . end)
    else . end )
  | (if ((.statusLine.command? // "") | contains("ctx-guard-bridge.sh"))
     then del(.statusLine) else . end)
  '

  CURRENT=$(cat "$SETTINGS") || die "Could not read $SETTINGS"
  CANON=$(printf '%s' "$CURRENT" | jq .) || die "jq failed to normalize $SETTINGS."
  NEW=$(printf '%s' "$CURRENT" | jq --arg needle "/ctx-guard.sh" "$CLEAN_JQ") \
    || die "jq failed to compute the cleaned settings."

  if [ "$NEW" = "$CANON" ]; then
    ok "No claude-ctx-guard entries found in settings.json — already clean."
  else
    cp "$SETTINGS" "$SETTINGS.bak" || die "Could not back up $SETTINGS"
    info "Backed up settings to $SETTINGS.bak"
    printf '%s\n' "$NEW" | write_json "$SETTINGS" \
      || die "Failed to write cleaned settings.json (original left intact)."
    if printf '%s' "$CURRENT" | jq -e 'any((.hooks.Stop, .hooks.UserPromptSubmit, .hooks.PreCompact)[]?.hooks[]?; (.command // "") | contains("/ctx-guard.sh"))' >/dev/null 2>&1; then
      ok "Removed our hook entries (your other hooks are untouched)."
    fi
    if printf '%s' "$CURRENT" | jq -e '(.statusLine.command? // "") | contains("ctx-guard-bridge.sh")' >/dev/null 2>&1; then
      ok "Removed our statusLine wiring."
    fi
  fi
fi

# We deliberately leave the copied scripts and state dir in place.
info ""
info "${C_B}Left in place (delete manually if you want them gone):${C_0}"
[ -f "$GUARD_DST" ] && info "  guard script : $GUARD_DST"
[ -f "$SL_DST" ]    && info "  bridge script: $SL_DST"
[ -d "$STATE_DIR" ] && info "  state dir    : $STATE_DIR   (per-session token bridge files + guard-errors.log)"
info ""
info "  To remove them too:"
[ -f "$GUARD_DST" ] && info "    rm -f \"$GUARD_DST\""
[ -f "$SL_DST" ]    && info "    rm -f \"$SL_DST\""
[ -d "$STATE_DIR" ] && info "    rm -rf \"$STATE_DIR\""
info ""
ok "Uninstall complete."

