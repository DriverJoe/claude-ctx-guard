#!/usr/bin/env bash
# smoke.sh — self-contained tests for hooks/ctx-guard.sh.
# No network, no personal paths; everything runs in a temp dir. Exercises the
# state machine and target-resolution via the CTX_GUARD_* env overrides.
#
# Usage: ./test/smoke.sh   (from anywhere; resolves the guard relative to itself)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GUARD="$HERE/../hooks/ctx-guard.sh"
[ -x "$GUARD" ] || { echo "guard not executable at $GUARD"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq required to run the smoke tests"; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ctxguard)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/state"
touch -t 202601010000 "$WORK/vault.md"       # deliberately stale
NOW=$(date +%s)
export CTX_GUARD_STATE_DIR="$WORK/state"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# run <event> <stdin-json>  [with CTX_GUARD_TARGET=vault.md, CTX_GUARD_NOW=NOW]
run() { printf '%s' "$2" | CTX_GUARD_TARGET="$WORK/vault.md" CTX_GUARD_NOW="$NOW" "$GUARD" "$1"; }
bridge() { printf '{"tokens":%s,"ts":%s}' "$2" "$NOW" > "$WORK/state/$1.json"; }

echo "1. under threshold (50k) -> silent allow"
bridge s1 50000
out=$(run stop '{"session_id":"s1","transcript_path":"/nonexistent"}')
[ -z "$out" ] && ok "silent" || bad "expected no output, got: $out"

echo "2. over + stale (130k) -> stop BLOCK"
bridge s2 130000
run stop '{"session_id":"s2","transcript_path":"/nonexistent"}' | grep -q '"decision":"block"' && ok "blocked" || bad "expected block"

echo "3. target flushed now -> same session allows"
touch "$WORK/vault.md"
out=$(run stop '{"session_id":"s2","transcript_path":"/nonexistent"}')
[ -z "$out" ] && ok "allowed after flush" || bad "expected allow, got: $out"

echo "4. escape hatch: 4 consecutive stops -> 3 blocks then fail-open"
touch -t 202601010000 "$WORK/vault.md"
bridge s3 140000
b=0
for i in 1 2 3 4; do run stop '{"session_id":"s3","transcript_path":"/nonexistent"}' | grep -q '"decision":"block"' && b=$((b+1)); done
[ "$b" -eq 3 ] && ok "exactly 3 blocks then open" || bad "expected 3 blocks, got $b"

echo "5. prompt event over+stale -> additionalContext, never blocks"
bridge s4 120000
o=$(run prompt '{"session_id":"s4","transcript_path":"/nonexistent"}')
{ printf '%s' "$o" | grep -q 'additionalContext' && ! printf '%s' "$o" | grep -q '"decision":"block"'; } && ok "context injected, no block" || bad "expected additionalContext, no block"

echo "6. precompact auto over+stale -> BLOCK first, warn second"
bridge s5 190000
run precompact '{"session_id":"s5","trigger":"auto","transcript_path":"/nonexistent"}' | grep -q '"decision":"block"' && ok "auto blocked once" || bad "expected block"
run precompact '{"session_id":"s5","trigger":"auto","transcript_path":"/nonexistent"}' | grep -q '"decision":"block"' && bad "should not block twice" || ok "second is warn-only"

echo "7. precompact manual -> never blocks"
bridge s6 190000
run precompact '{"session_id":"s6","trigger":"manual","transcript_path":"/nonexistent"}' | grep -q '"decision":"block"' && bad "manual must not block" || ok "manual allowed"

echo "8. malformed stdin -> fail open (exit 0, no block)"
o=$(printf 'not json' | CTX_GUARD_TARGET="$WORK/vault.md" CTX_GUARD_NOW="$NOW" "$GUARD" stop); rc=$?
{ [ "$rc" -eq 0 ] && ! printf '%s' "$o" | grep -q 'block'; } && ok "failed open" || bad "expected fail-open"

echo "9. transcript fallback (no bridge) -> reads usage from JSONL"
TR="$WORK/transcript.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user"}}'
  printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","usage":{"input_tokens":50000,"cache_creation_input_tokens":20000,"cache_read_input_tokens":60000,"output_tokens":5000}}}'
} > "$TR"     # sum = 135000, over threshold
touch -t 202601010000 "$WORK/vault.md"
printf '%s' "{\"session_id\":\"s7\",\"transcript_path\":\"$TR\"}" | CTX_GUARD_TARGET="$WORK/vault.md" CTX_GUARD_NOW="$NOW" "$GUARD" stop | grep -q '"decision":"block"' && ok "fallback armed + blocked" || bad "transcript fallback failed"

echo "10. disarm: tokens drop to 60k -> state cleared"
bridge s3 60000
run stop '{"session_id":"s3","transcript_path":"/nonexistent"}' >/dev/null
[ -f "$WORK/state/s3.guard.json" ] && bad "state should be cleared" || ok "state cleared below disarm"

echo "11. re-arm: acked 130k, grows +45k -> stale again, blocks"
bridge s8 130000
touch -t 202601010000 "$WORK/vault.md"
run stop '{"session_id":"s8","transcript_path":"/nonexistent"}' >/dev/null   # arm + block
touch "$WORK/vault.md"                                                        # flush -> ack
run stop '{"session_id":"s8","transcript_path":"/nonexistent"}' >/dev/null   # allow
bridge s8 175000
printf '%s' '{"session_id":"s8","transcript_path":"/nonexistent"}' | CTX_GUARD_TARGET="$WORK/vault.md" CTX_GUARD_NOW=$((NOW+5)) "$GUARD" stop | grep -q '"decision":"block"' && ok "re-armed at +45k" || bad "expected re-arm block"

echo "12. fresh precompact -> safe ✅ message, no block"
bridge s9 150000
touch "$WORK/vault.md"
o=$(printf '%s' '{"session_id":"s9","trigger":"auto","transcript_path":"/nonexistent"}' | CTX_GUARD_TARGET="$WORK/vault.md" CTX_GUARD_NOW=$((NOW+5)) "$GUARD" precompact)
{ ! printf '%s' "$o" | grep -q '"decision":"block"'; } && ok "fresh precompact allowed" || bad "fresh precompact should not block"

# ---- target resolution (no CTX_GUARD_TARGET; use CLAUDE_PROJECT_DIR) ----
PROJ="$WORK/proj"; mkdir -p "$PROJ/.claude"
runp() { printf '%s' "$3" | env -u CTX_GUARD_TARGET CLAUDE_PROJECT_DIR="$2" CTX_GUARD_NOW="$NOW" "$GUARD" "$1"; }

echo "13. override file present -> uses that target"
CUSTOM="$PROJ/mynotes.md"; printf '%s\n' "# comment" "$CUSTOM" > "$PROJ/.claude/ctx-guard.target"
touch -t 202601010000 "$CUSTOM"
bridge p1 130000
runp stop "$PROJ" '{"session_id":"p1","transcript_path":"/nonexistent"}' | grep -q 'mynotes.md' && ok "resolved override file" || bad "override file not used"

echo "14. no override, target missing -> defaults to root SESSION.md, missing = stale = block"
PROJ2="$WORK/proj2"; mkdir -p "$PROJ2/.claude"
bridge p2 130000
o=$(runp stop "$PROJ2" '{"session_id":"p2","transcript_path":"/nonexistent"}')
{ printf '%s' "$o" | grep -q 'SESSION.md' && printf '%s' "$o" | grep -q '"decision":"block"'; } && ok "root SESSION.md, blocked" || bad "expected root SESSION.md block"

echo "15. default SESSION.md created fresh -> allows"
: > "$PROJ2/SESSION.md"
bridge p3 130000
runp stop "$PROJ2" '{"session_id":"p3","transcript_path":"/nonexistent"}' >/dev/null
o=$(printf '%s' '{"session_id":"p3","transcript_path":"/nonexistent"}' | env -u CTX_GUARD_TARGET CLAUDE_PROJECT_DIR="$PROJ2" CTX_GUARD_NOW="$NOW" "$GUARD" stop)
[ -z "$o" ] && ok "fresh SESSION.md allows" || bad "expected allow, got: $o"

echo "16. no project dir and no override -> fail open"
o=$(printf '%s' '{"session_id":"p4","transcript_path":"/nonexistent"}' | env -u CTX_GUARD_TARGET -u CLAUDE_PROJECT_DIR CTX_GUARD_NOW="$NOW" "$GUARD" stop); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$o" ]; } && ok "failed open (no target resolvable)" || bad "expected silent fail-open"

echo "17. cwd from stdin used when CLAUDE_PROJECT_DIR unset"
PROJ3="$WORK/proj3"; mkdir -p "$PROJ3/.claude"
bridge p5 130000
printf '%s' "{\"session_id\":\"p5\",\"cwd\":\"$PROJ3\",\"transcript_path\":\"/nonexistent\"}" | env -u CTX_GUARD_TARGET -u CLAUDE_PROJECT_DIR CTX_GUARD_NOW="$NOW" "$GUARD" stop | grep -q 'SESSION.md' && ok "resolved via stdin cwd" || bad "stdin cwd not used"

# ---- REGRESSION: the guard MUST accept the canonical Claude Code event names.
# install.sh wires the argv as `Stop` / `UserPromptSubmit` / `PreCompact` (the
# capitalized names Claude Code uses as its hook-event keys), NOT the short
# lowercase forms the cases above use. An earlier build only matched lowercase,
# so an *installed* guard fell through to `*) exit 0` and never blocked — inert.
# These three assertions invoke with the EXACT strings install.sh writes.
echo "18. canonical Claude Code event names (exactly what install.sh wires)"
touch -t 202601010000 "$WORK/vault.md"
bridge cc1 130000
run Stop '{"session_id":"cc1","transcript_path":"/nonexistent"}' | grep -q '"decision":"block"' && ok "Stop blocks like stop" || bad "Stop must block (install.sh wires this name)"
bridge cc2 120000
o=$(run UserPromptSubmit '{"session_id":"cc2","transcript_path":"/nonexistent"}')
{ printf '%s' "$o" | grep -q 'additionalContext' && ! printf '%s' "$o" | grep -q '"decision":"block"'; } && ok "UserPromptSubmit injects context like prompt" || bad "UserPromptSubmit must behave like prompt"
bridge cc3 190000
run PreCompact '{"session_id":"cc3","trigger":"auto","transcript_path":"/nonexistent"}' | grep -q '"decision":"block"' && ok "PreCompact(auto) blocks like precompact" || bad "PreCompact must block (install.sh wires this name)"

# ---- REGRESSION: .target lines must be whitespace-trimmed and project-rooted.
# An indented/trailing-space path used to be stat'd verbatim -> a name nobody
# ever writes -> permanent-stale block until the escape hatch failed open.
echo "19. .target line with surrounding whitespace + relative path"
PROJ4="$WORK/proj4"; mkdir -p "$PROJ4/.claude"
: > "$PROJ4/notes.md"   # fresh right now
printf '   notes.md   \n' > "$PROJ4/.claude/ctx-guard.target"   # indented, trailing spaces, relative
bridge p6 130000
o=$(runp stop "$PROJ4" '{"session_id":"p6","transcript_path":"/nonexistent"}')
[ -z "$o" ] && ok "trimmed + project-rooted target seen as fresh (allow)" || bad "whitespace/relative target mishandled: $o"
touch -t 202601010000 "$PROJ4/notes.md"
runp stop "$PROJ4" '{"session_id":"p6","transcript_path":"/nonexistent"}' | grep -q 'notes.md' && ok "stale same target blocks and names it" || bad "expected block naming notes.md"

# ---- REGRESSION: install.sh must not double-wire over an EXISTING ctx-guard
# entry with a different arg spelling (e.g. a hand-wired lowercase setup). The
# old dedup was byte-exact on the full command, so it appended a second,
# double-firing entry per event.
echo "20. installer dedup: pre-existing lowercase wiring -> no second entry"
INSTALL="$HERE/../install.sh"
FAKE="$WORK/fake-config"; mkdir -p "$FAKE"
cat > "$FAKE/settings.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$HOME/.claude/hooks/ctx-guard.sh stop"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"$HOME/.claude/hooks/ctx-guard.sh prompt"}]}],"PreCompact":[{"hooks":[{"type":"command","command":"$HOME/.claude/hooks/ctx-guard.sh precompact"}]}]}}
EOF
CLAUDE_CONFIG_DIR="$FAKE" "$INSTALL" -y --no-statusline >/dev/null 2>&1
n=$(jq '[.hooks.Stop, .hooks.UserPromptSubmit, .hooks.PreCompact | length] | add' "$FAKE/settings.json")
[ "$n" = 3 ] && ok "still exactly one entry per event" || bad "double-wired: $n entries across the 3 events (want 3)"
CLAUDE_CONFIG_DIR="$FAKE" "$INSTALL" -y --no-statusline >/dev/null 2>&1
n2=$(jq '[.hooks.Stop, .hooks.UserPromptSubmit, .hooks.PreCompact | length] | add' "$FAKE/settings.json")
[ "$n2" = 3 ] && ok "re-run is a true no-op" || bad "re-run changed wiring: $n2 entries"

echo
echo "===== $pass passed, $fail failed ====="
[ "$fail" -eq 0 ]
