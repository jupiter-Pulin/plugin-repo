#!/usr/bin/env bash
# PostToolUse Hook: Parse review command output, update state file
# Trigger condition: Bash tool executes review/precommit commands

set -euo pipefail

# === Plugin-defers-to-local arbitration ===
_SELF_NAME="$(basename "$0")"
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] \
   && [[ ! -f "${CLAUDE_PROJECT_DIR}/hooks/hooks.json" ]] \
   && [[ -x "${CLAUDE_PROJECT_DIR}/.claude/hooks/${_SELF_NAME}" ]]; then
  _SETTINGS_MATCH=false
  for _sf in "${CLAUDE_PROJECT_DIR}/.claude/settings.json" \
             "${CLAUDE_PROJECT_DIR}/.claude/settings.local.json"; do
    if [[ -f "$_sf" ]]; then
      if command -v jq &>/dev/null; then
        jq -e '.hooks // {} | .. | strings | select(contains(".claude/hooks/'"${_SELF_NAME}"'"))' "$_sf" >/dev/null 2>&1 \
          && _SETTINGS_MATCH=true && break
      else
        grep -q "\.claude/hooks/${_SELF_NAME}" "$_sf" 2>/dev/null \
          && _SETTINGS_MATCH=true && break
      fi
    fi
  done
  if [[ "$_SETTINGS_MATCH" == "true" ]]; then
    exit 0  # Defer to local hook
  fi
fi

STATE_FILE=".claude_review_state.json"

# === Portable mkdir locking (macOS has no flock) ===
LOCKDIR="${STATE_FILE}.lockdir"
LOCK_TIMEOUT=5
LOCK_TTL=30
HAVE_LOCK=0

_lock() {
  local start end
  start=$(date +%s)
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    end=$(date +%s)
    if [ $((end - start)) -ge $LOCK_TIMEOUT ]; then
      local lock_pid lock_ts now
      lock_pid=$(cat "$LOCKDIR/pid" 2>/dev/null || echo 0)
      lock_ts=$(cat "$LOCKDIR/ts" 2>/dev/null || echo 0)
      now=$(date +%s)
      if [ $((now - lock_ts)) -ge $LOCK_TTL ] || ! kill -0 "$lock_pid" 2>/dev/null; then
        rm -rf "$LOCKDIR" 2>/dev/null
        mkdir "$LOCKDIR" 2>/dev/null && break
      fi
      return 1
    fi
    sleep 0.1
  done
  echo "$$" > "$LOCKDIR/pid"
  date +%s > "$LOCKDIR/ts"
  HAVE_LOCK=1
}

_unlock() {
  [ "$HAVE_LOCK" -eq 1 ] && rm -rf "$LOCKDIR" 2>/dev/null
  HAVE_LOCK=0
}

trap '_unlock' EXIT

# Read JSON input from stdin
INPUT=$(cat)

# Check if jq is available
if ! command -v jq &> /dev/null; then
  exit 0
fi

# Extract tool info
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // empty' 2>/dev/null)
TOOL_OUTPUT=$(echo "$INPUT" | jq -r '.tool_output // empty' 2>/dev/null)

# Only process Bash and MCP Codex tools
if [[ "$TOOL_NAME" != "Bash" ]] && \
   [[ "$TOOL_NAME" != "mcp__codex__codex" ]] && \
   [[ "$TOOL_NAME" != "mcp__codex__codex-reply" ]]; then
  exit 0
fi

# Extract command (Bash) or output (MCP)
if [[ "$TOOL_NAME" == "Bash" ]]; then
  COMMAND=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
else
  COMMAND=""
  TOOL_OUTPUT=$(echo "$INPUT" | jq -r '
    if (.tool_output | type) == "object" then
      if (.tool_output.content | type) == "string" then .tool_output.content
      elif (.tool_output.content | type) == "array" then [.tool_output.content[] | select(.type == "text") | .text] | join("\n")
      else (.tool_output | tostring)
      end
    elif (.tool_output | type) == "string" then .tool_output
    else empty
    end // empty' 2>/dev/null)
fi

# Initialize state file (if not exists)
init_state_file() {
  if [[ ! -f "$STATE_FILE" ]]; then
    cat > "$STATE_FILE" << 'EOF'
{
  "session_id": "",
  "updated_at": "",
  "review_mode": "single",
  "has_code_change": false,
  "has_doc_change": false,
  "code_review": {"executed": false, "passed": false, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": false, "passed": false, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF
  fi
}

# Update state file (acquires lock for consistency)
update_state() {
  local key="$1"
  local executed="$2"
  local passed="$3"

  if _lock; then
    init_state_file
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local tmp
    tmp=$(mktemp)
    jq --arg key "$key" \
       --argjson executed "$executed" \
       --argjson passed "$passed" \
       --arg now "$now" \
       '.[$key].executed = $executed | .[$key].passed = $passed | .[$key].last_run = $now | .updated_at = $now' \
       "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    _unlock
  else
    # Fail-open for review state
    init_state_file
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local tmp
    tmp=$(mktemp)
    jq --arg key "$key" \
       --argjson executed "$executed" \
       --argjson passed "$passed" \
       --arg now "$now" \
       '.[$key].executed = $executed | .[$key].passed = $passed | .[$key].last_run = $now | .updated_at = $now' \
       "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE" 2>/dev/null || true
  fi
}

# Check for pass markers
check_passed() {
  local output="$1"
  if echo "$output" | grep -qE '^## Gate: ✅|^✅ All Pass|^## Overall: ✅ PASS'; then
    echo "true"
  elif echo "$output" | grep -E '## Gate: ✅|✅ All Pass' | grep -qvE 'Error|Failed|FAIL'; then
    echo "true"
  else
    echo "false"
  fi
}

# Update aggregate_gate in state file (call within lock)
update_aggregate_gate() {
  local gate_value="$1"
  init_state_file
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local tmp
  tmp=$(mktemp)
  case "$gate_value" in
    PENDING)
      jq --arg now "$now" \
         '.review_mode = "dual" | .aggregate_gate.executed = false | .aggregate_gate.gate = null | .aggregate_gate.source = null | .aggregate_gate.reason = null | .aggregate_gate.last_run = $now | .updated_at = $now' \
         "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
      ;;
    READY|BLOCKED)
      jq --arg gate "$gate_value" --arg now "$now" \
         '.aggregate_gate.executed = true | .aggregate_gate.gate = $gate | .aggregate_gate.reason = null | .aggregate_gate.last_run = $now | .updated_at = $now' \
         "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
      ;;
  esac
  rm -f "${STATE_FILE}.blocked" 2>/dev/null || true
}

# Best-effort blocked write (used when lock fails)
update_aggregate_blocked() {
  local reason="${1:-unknown}"
  echo "$reason" > "${STATE_FILE}.blocked" 2>/dev/null || true
  init_state_file
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local tmp
  tmp=$(mktemp)
  jq --arg reason "$reason" --arg now "$now" \
     '.review_mode = "dual" | .aggregate_gate.executed = true | .aggregate_gate.gate = "BLOCKED" | .aggregate_gate.reason = $reason | .aggregate_gate.last_run = $now | .updated_at = $now' \
     "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE" 2>/dev/null || true
}

# === Process different commands ===

# === emit-review-gate parse branch ===
if [[ "$TOOL_NAME" == "Bash" ]] && echo "$COMMAND" | grep -qE 'emit-review-gate'; then
  GATE_VALUE=$(echo "$TOOL_OUTPUT" | grep -oE '^REVIEW_GATE=(PENDING|READY|BLOCKED)' | tail -1 | cut -d= -f2)
  if [[ -n "$GATE_VALUE" ]]; then
    _lock || { update_aggregate_blocked "lock_failure"; echo "[Review State] Lock failed, fail-closed BLOCKED (reason: lock_failure)" >&2; exit 0; }
    update_aggregate_gate "$GATE_VALUE"
    _unlock
    echo "[Review State] aggregate_gate updated: gate=$GATE_VALUE" >&2
  fi
fi

# /codex-review-fast or /codex-review
if echo "$COMMAND" | grep -qE '/(jupiter-dev-flow:)?codex-review(-fast)?($|\s)'; then
  passed=$(check_passed "$TOOL_OUTPUT")
  update_state "code_review" "true" "$passed"
  echo "[Review State] code_review updated: passed=$passed" >&2
fi

# /codex-review-doc or /review-spec
if echo "$COMMAND" | grep -qE '/(jupiter-dev-flow:)?codex-review-doc($|[[:space:]])|/(jupiter-dev-flow:)?review-spec($|[[:space:]])'; then
  passed=$(check_passed "$TOOL_OUTPUT")
  update_state "doc_review" "true" "$passed"
  echo "[Review State] doc_review updated: passed=$passed" >&2
fi

# /precommit or /precommit-fast
if echo "$COMMAND" | grep -qE '/(jupiter-dev-flow:)?precommit(-fast)?($|\s)'; then
  passed=$(check_passed "$TOOL_OUTPUT")
  update_state "precommit" "true" "$passed"
  echo "[Review State] precommit updated: passed=$passed" >&2
fi

# === MCP sentinel routing ===
if [[ "$TOOL_NAME" == "mcp__codex__codex" || "$TOOL_NAME" == "mcp__codex__codex-reply" ]]; then
  if echo "$TOOL_OUTPUT" | grep -qE '## Document Review' && echo "$TOOL_OUTPUT" | grep -qE '✅ Mergeable'; then
    update_state "doc_review" "true" "true"
    echo "[Review State] doc_review updated (MCP): passed=true" >&2
  elif echo "$TOOL_OUTPUT" | grep -qE '## Document Review' && echo "$TOOL_OUTPUT" | grep -qE '⛔ Needs revision'; then
    update_state "doc_review" "true" "false"
    echo "[Review State] doc_review updated (MCP): passed=false" >&2
  elif echo "$TOOL_OUTPUT" | grep -qE '✅ Ready'; then
    update_state "code_review" "true" "true"
    echo "[Review State] code_review updated (MCP): passed=true" >&2
  elif echo "$TOOL_OUTPUT" | grep -qE '⛔ Blocked'; then
    update_state "code_review" "true" "false"
    echo "[Review State] code_review updated (MCP): passed=false" >&2
  elif echo "$TOOL_OUTPUT" | grep -qE '## Overall: ✅ PASS'; then
    update_state "precommit" "true" "true"
    echo "[Review State] precommit updated (MCP): passed=true" >&2
  elif echo "$TOOL_OUTPUT" | grep -qE '## Overall: (⛔ FAIL|❌ FAIL)'; then
    update_state "precommit" "true" "false"
    echo "[Review State] precommit updated (MCP): passed=false" >&2
  elif echo "$TOOL_OUTPUT" | grep -qE '✅ All Pass'; then
    update_state "code_review" "true" "true"
    echo "[Review State] code_review updated (MCP): passed=true" >&2
  fi
fi

exit 0
