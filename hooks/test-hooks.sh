#!/usr/bin/env bash
# Hook Integration Test Suite
# Usage: bash hooks/test-hooks.sh [test_name]
# Run all tests: bash hooks/test-hooks.sh
# Run one test:  bash hooks/test-hooks.sh test_post_edit_code_change

set -euo pipefail

# === Test Framework ===
PASS=0
FAIL=0
ERRORS=""
TEST_DIR=$(mktemp -d)
ORIG_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Set up isolated test environment
setup() {
  rm -f "$TEST_DIR/.claude_review_state.json"
  rm -f "$TEST_DIR/.claude_review_state.json.blocked"
  rm -rf "$TEST_DIR/.claude_review_state.json.lockdir"
  # Create minimal git repo so stop-guard's git check works
  if [[ ! -d "$TEST_DIR/.git" ]]; then
    git -C "$TEST_DIR" init -q 2>/dev/null || true
  fi
  # Create a minimal transcript for stop-guard
  echo '{}' > "$TEST_DIR/transcript.jsonl"
  # Create minimal settings for arbitration bypass (dev mode)
  mkdir -p "$TEST_DIR/hooks"
  echo '{}' > "$TEST_DIR/hooks/hooks.json"
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    return 0
  else
    echo "    FAIL: $label — expected '$expected', got '$actual'"
    return 1
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    return 0
  else
    echo "    FAIL: $label — '$needle' not found in output"
    return 1
  fi
}

run_test() {
  local name="$1"
  local filter="${2:-}"

  # If filter is set, skip non-matching tests
  if [[ -n "$filter" && "$name" != "$filter" ]]; then
    return 0
  fi

  setup
  echo "  [$name]"
  if "$name"; then
    PASS=$((PASS + 1))
    echo "    OK"
  else
    FAIL=$((FAIL + 1))
    ERRORS="$ERRORS\n  FAIL: $name"
  fi
}

# ============================================================
# post-edit-format.sh tests
# ============================================================

test_post_edit_code_change() {
  cd "$TEST_DIR"
  echo '{"tool_name":"Edit","tool_input":{"file_path":"src/app.ts","old_string":"a","new_string":"b"},"tool_response":{"success":true}}' \
    | HOOK_NO_FORMAT=1 bash "$ORIG_DIR/hooks/post-edit-format.sh" 2>/dev/null

  local state
  state=$(cat .claude_review_state.json)
  assert_eq "has_code_change" "true" "$(echo "$state" | jq -r '.has_code_change')" && \
  assert_eq "code_review.passed" "false" "$(echo "$state" | jq -r '.code_review.passed')" && \
  assert_eq "precommit.passed" "false" "$(echo "$state" | jq -r '.precommit.passed')"
}

test_post_edit_doc_change() {
  cd "$TEST_DIR"
  echo '{"tool_name":"Write","tool_input":{"file_path":"docs/readme.md","content":"# Hi"},"tool_response":{"success":true}}' \
    | HOOK_NO_FORMAT=1 bash "$ORIG_DIR/hooks/post-edit-format.sh" 2>/dev/null

  local state
  state=$(cat .claude_review_state.json)
  assert_eq "has_doc_change" "true" "$(echo "$state" | jq -r '.has_doc_change')" && \
  assert_eq "doc_review.passed" "false" "$(echo "$state" | jq -r '.doc_review.passed')"
}

test_post_edit_vendor_skip() {
  cd "$TEST_DIR"
  echo '{"tool_name":"Edit","tool_input":{"file_path":"node_modules/pkg/index.js","old_string":"a","new_string":"b"},"tool_response":{"success":true}}' \
    | HOOK_NO_FORMAT=1 bash "$ORIG_DIR/hooks/post-edit-format.sh" 2>/dev/null

  # State file should NOT be created for vendor paths
  [[ ! -f .claude_review_state.json ]]
}

test_post_edit_shell_injection_rejected() {
  cd "$TEST_DIR"
  echo '{"tool_name":"Edit","tool_input":{"file_path":"src/app.ts;rm -rf /","old_string":"a","new_string":"b"},"tool_response":{"success":true}}' \
    | HOOK_NO_FORMAT=1 bash "$ORIG_DIR/hooks/post-edit-format.sh" 2>/dev/null

  # State file should NOT be created for injection paths
  [[ ! -f .claude_review_state.json ]]
}

test_post_edit_aggregate_gate_invalidated() {
  cd "$TEST_DIR"
  # Pre-populate state with aggregate_gate READY
  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "dual",
  "has_code_change": false, "has_doc_change": false,
  "code_review": {"executed": true, "passed": true, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": false, "passed": false, "last_run": ""},
  "aggregate_gate": {"executed": true, "gate": "READY", "source": null, "reason": null, "last_run": ""}
}
EOF

  echo '{"tool_name":"Edit","tool_input":{"file_path":"src/fix.ts","old_string":"a","new_string":"b"},"tool_response":{"success":true}}' \
    | HOOK_NO_FORMAT=1 bash "$ORIG_DIR/hooks/post-edit-format.sh" 2>/dev/null

  local state
  state=$(cat .claude_review_state.json)
  assert_eq "aggregate_gate.executed" "false" "$(echo "$state" | jq -r '.aggregate_gate.executed')" && \
  assert_eq "aggregate_gate.gate" "null" "$(echo "$state" | jq -r '.aggregate_gate.gate')"
}

test_post_edit_empty_file_path() {
  cd "$TEST_DIR"
  local exit_code=0
  echo '{"tool_name":"Edit","tool_input":{},"tool_response":{"success":true}}' \
    | HOOK_NO_FORMAT=1 bash "$ORIG_DIR/hooks/post-edit-format.sh" 2>/dev/null || exit_code=$?

  assert_eq "exit_code" "0" "$exit_code" && \
  [[ ! -f .claude_review_state.json ]]
}

# ============================================================
# post-tool-review-state.sh tests
# ============================================================

test_review_state_code_review_pass() {
  cd "$TEST_DIR"
  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "single",
  "has_code_change": true, "has_doc_change": false,
  "code_review": {"executed": false, "passed": false, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": false, "passed": false, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF

  echo '{"tool_name":"Bash","tool_input":{"command":"/jupiter-dev-flow:codex-review-fast"},"tool_response":{"stdout":"## Gate: ✅\n✅ All Pass","stderr":"","interrupted":false}}' \
    | bash "$ORIG_DIR/hooks/post-tool-review-state.sh" 2>/dev/null

  local state
  state=$(cat .claude_review_state.json)
  assert_eq "code_review.executed" "true" "$(echo "$state" | jq -r '.code_review.executed')" && \
  assert_eq "code_review.passed" "true" "$(echo "$state" | jq -r '.code_review.passed')"
}

test_review_state_code_review_fail() {
  cd "$TEST_DIR"
  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "single",
  "has_code_change": true, "has_doc_change": false,
  "code_review": {"executed": false, "passed": false, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": false, "passed": false, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF

  echo '{"tool_name":"Bash","tool_input":{"command":"/codex-review-fast"},"tool_response":{"stdout":"## Gate: ⛔\n⛔ Blocked","stderr":"","interrupted":false}}' \
    | bash "$ORIG_DIR/hooks/post-tool-review-state.sh" 2>/dev/null

  local state
  state=$(cat .claude_review_state.json)
  assert_eq "code_review.executed" "true" "$(echo "$state" | jq -r '.code_review.executed')" && \
  assert_eq "code_review.passed" "false" "$(echo "$state" | jq -r '.code_review.passed')"
}

test_review_state_precommit_pass() {
  cd "$TEST_DIR"
  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "single",
  "has_code_change": true, "has_doc_change": false,
  "code_review": {"executed": true, "passed": true, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": false, "passed": false, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF

  echo '{"tool_name":"Bash","tool_input":{"command":"/precommit-fast"},"tool_response":{"stdout":"## Overall: ✅ PASS","stderr":"","interrupted":false}}' \
    | bash "$ORIG_DIR/hooks/post-tool-review-state.sh" 2>/dev/null

  local state
  state=$(cat .claude_review_state.json)
  assert_eq "precommit.passed" "true" "$(echo "$state" | jq -r '.precommit.passed')"
}

test_review_state_doc_review_pass() {
  cd "$TEST_DIR"
  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "single",
  "has_code_change": false, "has_doc_change": true,
  "code_review": {"executed": false, "passed": false, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": false, "passed": false, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF

  echo '{"tool_name":"Bash","tool_input":{"command":"/codex-review-doc"},"tool_response":{"stdout":"## Gate: ✅\n✅ All Pass","stderr":"","interrupted":false}}' \
    | bash "$ORIG_DIR/hooks/post-tool-review-state.sh" 2>/dev/null

  local state
  state=$(cat .claude_review_state.json)
  assert_eq "doc_review.passed" "true" "$(echo "$state" | jq -r '.doc_review.passed')"
}

test_review_state_mcp_code_pass() {
  cd "$TEST_DIR"
  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "single",
  "has_code_change": true, "has_doc_change": false,
  "code_review": {"executed": false, "passed": false, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": false, "passed": false, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF

  echo '{"tool_name":"mcp__codex__codex","tool_input":{},"tool_response":"{\"threadId\":\"test\",\"content\":\"Review complete\\n\\n✅ Ready to merge\"}"}' \
    | bash "$ORIG_DIR/hooks/post-tool-review-state.sh" 2>/dev/null

  local state
  state=$(cat .claude_review_state.json)
  assert_eq "code_review.passed" "true" "$(echo "$state" | jq -r '.code_review.passed')"
}

test_review_state_aggregate_gate_ready() {
  cd "$TEST_DIR"
  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "single",
  "has_code_change": true, "has_doc_change": false,
  "code_review": {"executed": true, "passed": true, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": false, "passed": false, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF

  echo '{"tool_name":"Bash","tool_input":{"command":"emit-review-gate"},"tool_response":{"stdout":"REVIEW_GATE=READY","stderr":"","interrupted":false}}' \
    | bash "$ORIG_DIR/hooks/post-tool-review-state.sh" 2>/dev/null

  local state
  state=$(cat .claude_review_state.json)
  assert_eq "aggregate_gate.executed" "true" "$(echo "$state" | jq -r '.aggregate_gate.executed')" && \
  assert_eq "aggregate_gate.gate" "READY" "$(echo "$state" | jq -r '.aggregate_gate.gate')"
}

test_review_state_unrelated_bash_ignored() {
  cd "$TEST_DIR"
  local exit_code=0
  echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_response":{"stdout":"total 0","stderr":"","interrupted":false}}' \
    | bash "$ORIG_DIR/hooks/post-tool-review-state.sh" 2>/dev/null || exit_code=$?

  assert_eq "exit_code" "0" "$exit_code" && \
  [[ ! -f .claude_review_state.json ]]
}

# ============================================================
# pre-edit-guard.sh tests
# ============================================================

test_pre_edit_guard_env_blocked() {
  cd "$TEST_DIR"
  local exit_code=0
  echo '{"tool_name":"Edit","tool_input":{"file_path":".env","old_string":"a","new_string":"b"}}' \
    | bash "$ORIG_DIR/hooks/pre-edit-guard.sh" 2>/dev/null || exit_code=$?

  assert_eq "exit_code" "2" "$exit_code"
}

test_pre_edit_guard_git_blocked() {
  cd "$TEST_DIR"
  local exit_code=0
  echo '{"tool_name":"Edit","tool_input":{"file_path":".git/config","old_string":"a","new_string":"b"}}' \
    | bash "$ORIG_DIR/hooks/pre-edit-guard.sh" 2>/dev/null || exit_code=$?

  assert_eq "exit_code" "2" "$exit_code"
}

test_pre_edit_guard_normal_allowed() {
  cd "$TEST_DIR"
  local exit_code=0
  echo '{"tool_name":"Edit","tool_input":{"file_path":"src/app.ts","old_string":"a","new_string":"b"}}' \
    | bash "$ORIG_DIR/hooks/pre-edit-guard.sh" 2>/dev/null || exit_code=$?

  assert_eq "exit_code" "0" "$exit_code"
}

test_pre_edit_guard_shell_injection_blocked() {
  cd "$TEST_DIR"
  local exit_code=0
  echo '{"tool_name":"Edit","tool_input":{"file_path":"src/app.ts;rm -rf /","old_string":"a","new_string":"b"}}' \
    | bash "$ORIG_DIR/hooks/pre-edit-guard.sh" 2>/dev/null || exit_code=$?

  assert_eq "exit_code" "2" "$exit_code"
}

test_pre_edit_guard_custom_pattern() {
  cd "$TEST_DIR"
  local exit_code=0
  echo '{"tool_name":"Edit","tool_input":{"file_path":"src/locales/en.json","old_string":"a","new_string":"b"}}' \
    | GUARD_EXTRA_PATTERNS='src/locales/.*\.json$' bash "$ORIG_DIR/hooks/pre-edit-guard.sh" 2>/dev/null || exit_code=$?

  assert_eq "exit_code" "2" "$exit_code"
}

# ============================================================
# stop-guard.sh tests
# ============================================================

test_stop_guard_no_changes_allow() {
  cd "$TEST_DIR"
  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "single",
  "has_code_change": false, "has_doc_change": false,
  "code_review": {"executed": false, "passed": false, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": false, "passed": false, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF

  local exit_code=0
  echo "{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TEST_DIR/transcript.jsonl\",\"stop_hook_active\":false}" \
    | STOP_GUARD_MODE=strict bash "$ORIG_DIR/hooks/stop-guard.sh" 2>/dev/null || exit_code=$?

  assert_eq "exit_code" "0" "$exit_code"
}

test_stop_guard_code_change_no_review_strict_blocks() {
  cd "$TEST_DIR"
  # Create a dirty file so git status shows something
  echo "x" > "$TEST_DIR/dirty.ts"
  git -C "$TEST_DIR" add dirty.ts 2>/dev/null || true

  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "single",
  "has_code_change": true, "has_doc_change": false,
  "code_review": {"executed": false, "passed": false, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": false, "passed": false, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF

  local exit_code=0
  echo "{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TEST_DIR/transcript.jsonl\",\"stop_hook_active\":false}" \
    | STOP_GUARD_MODE=strict bash "$ORIG_DIR/hooks/stop-guard.sh" 2>/dev/null || exit_code=$?

  assert_eq "exit_code" "2" "$exit_code"
}

test_stop_guard_all_passed_allow() {
  cd "$TEST_DIR"
  echo "x" > "$TEST_DIR/app.ts"
  git -C "$TEST_DIR" add app.ts 2>/dev/null || true

  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "single",
  "has_code_change": true, "has_doc_change": false,
  "code_review": {"executed": true, "passed": true, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": true, "passed": true, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF

  local exit_code=0
  echo "{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TEST_DIR/transcript.jsonl\",\"stop_hook_active\":false}" \
    | STOP_GUARD_MODE=strict bash "$ORIG_DIR/hooks/stop-guard.sh" 2>/dev/null || exit_code=$?

  assert_eq "exit_code" "0" "$exit_code"
}

test_stop_guard_warn_mode_allows() {
  cd "$TEST_DIR"
  echo "x" > "$TEST_DIR/dirty2.ts"
  git -C "$TEST_DIR" add dirty2.ts 2>/dev/null || true

  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "single",
  "has_code_change": true, "has_doc_change": false,
  "code_review": {"executed": false, "passed": false, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": false, "passed": false, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF

  local exit_code=0
  echo "{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TEST_DIR/transcript.jsonl\",\"stop_hook_active\":false}" \
    | STOP_GUARD_MODE=warn bash "$ORIG_DIR/hooks/stop-guard.sh" 2>/dev/null || exit_code=$?

  assert_eq "exit_code (warn allows)" "0" "$exit_code"
}

test_stop_guard_sidecar_forces_strict() {
  cd "$TEST_DIR"
  echo "x" > "$TEST_DIR/s.ts"
  git -C "$TEST_DIR" add s.ts 2>/dev/null || true

  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "single",
  "has_code_change": true, "has_doc_change": false,
  "code_review": {"executed": true, "passed": true, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": false, "passed": false, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF
  echo "edit_lock_contention" > .claude_review_state.json.blocked

  local exit_code=0
  echo "{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TEST_DIR/transcript.jsonl\",\"stop_hook_active\":false}" \
    | STOP_GUARD_MODE=warn bash "$ORIG_DIR/hooks/stop-guard.sh" 2>/dev/null || exit_code=$?

  # Sidecar should force strict mode and block
  assert_eq "exit_code (sidecar blocks)" "2" "$exit_code"
}

test_stop_guard_bypass() {
  cd "$TEST_DIR"
  local exit_code=0
  echo "{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TEST_DIR/transcript.jsonl\"}" \
    | HOOK_BYPASS=1 bash "$ORIG_DIR/hooks/stop-guard.sh" 2>/dev/null || exit_code=$?

  assert_eq "exit_code (bypass)" "0" "$exit_code"
}

test_stop_guard_stale_state_reconciliation() {
  cd "$TEST_DIR"
  # State says code changed, but git status is clean (no .ts files modified)
  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "single",
  "has_code_change": true, "has_doc_change": false,
  "code_review": {"executed": false, "passed": false, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": false, "passed": false, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF
  # Git status is clean — no .ts files
  git -C "$TEST_DIR" add -A 2>/dev/null || true
  git -C "$TEST_DIR" commit -m "clean" --allow-empty -q 2>/dev/null || true

  local exit_code=0
  echo "{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TEST_DIR/transcript.jsonl\",\"stop_hook_active\":false}" \
    | STOP_GUARD_MODE=strict bash "$ORIG_DIR/hooks/stop-guard.sh" 2>/dev/null || exit_code=$?

  # Stale has_code_change should be reconciled to false → allow stop
  assert_eq "exit_code (stale reconciled)" "0" "$exit_code"
}

# ============================================================
# post-compact-auto-loop.sh tests
# ============================================================

test_compact_pending_code_review() {
  cd "$TEST_DIR"
  echo "x" > "$TEST_DIR/c.ts"
  git -C "$TEST_DIR" add c.ts 2>/dev/null || true

  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "single",
  "has_code_change": true, "has_doc_change": false,
  "code_review": {"executed": false, "passed": false, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": false, "passed": false, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF

  local output
  output=$(echo '{"hook_event_name":"SessionStart","source":"compact"}' \
    | bash "$ORIG_DIR/hooks/post-compact-auto-loop.sh" 2>/dev/null)

  assert_contains "has AUTO_LOOP_RESUME" "$output" "AUTO_LOOP_RESUME" && \
  assert_contains "suggests codex-review-fast" "$output" "/codex-review-fast"
}

test_compact_pending_precommit() {
  cd "$TEST_DIR"
  echo "x" > "$TEST_DIR/d.ts"
  git -C "$TEST_DIR" add d.ts 2>/dev/null || true

  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "single",
  "has_code_change": true, "has_doc_change": false,
  "code_review": {"executed": true, "passed": true, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": false, "passed": false, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF

  local output
  output=$(echo '{"hook_event_name":"SessionStart","source":"compact"}' \
    | bash "$ORIG_DIR/hooks/post-compact-auto-loop.sh" 2>/dev/null)

  assert_contains "suggests precommit-fast" "$output" "/precommit-fast"
}

test_compact_all_passed_no_output() {
  cd "$TEST_DIR"
  cat > .claude_review_state.json << 'EOF'
{
  "session_id": "", "updated_at": "", "review_mode": "single",
  "has_code_change": true, "has_doc_change": false,
  "code_review": {"executed": true, "passed": true, "last_run": ""},
  "doc_review": {"executed": false, "passed": false, "last_run": ""},
  "precommit": {"executed": true, "passed": true, "last_run": ""},
  "aggregate_gate": {"executed": false, "gate": null, "source": null, "reason": null, "last_run": ""}
}
EOF

  local output
  output=$(echo '{"hook_event_name":"SessionStart","source":"compact"}' \
    | bash "$ORIG_DIR/hooks/post-compact-auto-loop.sh" 2>/dev/null)

  assert_eq "no output when all passed" "" "$output"
}

test_compact_no_state_file() {
  cd "$TEST_DIR"
  local exit_code=0
  local output
  output=$(echo '{"hook_event_name":"SessionStart","source":"compact"}' \
    | bash "$ORIG_DIR/hooks/post-compact-auto-loop.sh" 2>/dev/null) || exit_code=$?

  assert_eq "exit_code" "0" "$exit_code" && \
  assert_eq "no output" "" "$output"
}

# ============================================================
# Locking tests
# ============================================================

test_lock_cleanup_on_exit() {
  cd "$TEST_DIR"
  echo '{"tool_name":"Edit","tool_input":{"file_path":"src/x.ts","old_string":"a","new_string":"b"},"tool_response":{"success":true}}' \
    | HOOK_NO_FORMAT=1 bash "$ORIG_DIR/hooks/post-edit-format.sh" 2>/dev/null

  # Lock directory should be cleaned up after script exits
  [[ ! -d ".claude_review_state.json.lockdir" ]]
}

# ============================================================
# Run all tests
# ============================================================

FILTER="${1:-}"

echo ""
echo "=== Hook Integration Tests ==="
echo ""

echo "--- post-edit-format.sh ---"
run_test test_post_edit_code_change "$FILTER"
run_test test_post_edit_doc_change "$FILTER"
run_test test_post_edit_vendor_skip "$FILTER"
run_test test_post_edit_shell_injection_rejected "$FILTER"
run_test test_post_edit_aggregate_gate_invalidated "$FILTER"
run_test test_post_edit_empty_file_path "$FILTER"

echo ""
echo "--- post-tool-review-state.sh ---"
run_test test_review_state_code_review_pass "$FILTER"
run_test test_review_state_code_review_fail "$FILTER"
run_test test_review_state_precommit_pass "$FILTER"
run_test test_review_state_doc_review_pass "$FILTER"
run_test test_review_state_mcp_code_pass "$FILTER"
run_test test_review_state_aggregate_gate_ready "$FILTER"
run_test test_review_state_unrelated_bash_ignored "$FILTER"

echo ""
echo "--- pre-edit-guard.sh ---"
run_test test_pre_edit_guard_env_blocked "$FILTER"
run_test test_pre_edit_guard_git_blocked "$FILTER"
run_test test_pre_edit_guard_normal_allowed "$FILTER"
run_test test_pre_edit_guard_shell_injection_blocked "$FILTER"
run_test test_pre_edit_guard_custom_pattern "$FILTER"

echo ""
echo "--- stop-guard.sh ---"
run_test test_stop_guard_no_changes_allow "$FILTER"
run_test test_stop_guard_code_change_no_review_strict_blocks "$FILTER"
run_test test_stop_guard_all_passed_allow "$FILTER"
run_test test_stop_guard_warn_mode_allows "$FILTER"
run_test test_stop_guard_sidecar_forces_strict "$FILTER"
run_test test_stop_guard_bypass "$FILTER"
run_test test_stop_guard_stale_state_reconciliation "$FILTER"

echo ""
echo "--- post-compact-auto-loop.sh ---"
run_test test_compact_pending_code_review "$FILTER"
run_test test_compact_pending_precommit "$FILTER"
run_test test_compact_all_passed_no_output "$FILTER"
run_test test_compact_no_state_file "$FILTER"

echo ""
echo "--- locking ---"
run_test test_lock_cleanup_on_exit "$FILTER"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  echo -e "$ERRORS"
  exit 1
fi
