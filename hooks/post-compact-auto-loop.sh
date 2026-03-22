#!/usr/bin/env bash
# SessionStart (compact) Hook: Re-inject auto-loop rules after context compaction
# Registered as SessionStart with matcher "compact" — fires after compaction.
# stdout is injected into Claude's context (SessionStart stdout injection).
# Always exit 0 (non-blocking). Only outputs when there are pending review/precommit steps.

set -euo pipefail

# === Plugin-defers-to-local arbitration ===
# When running as a plugin hook, detect if identical local hook is installed
# and registered in project settings — if so, exit 0 to avoid double-fire.
# Dev-mode bypass: hooks/hooks.json at project root = plugin source repo (skip arbitration).
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

# Graceful degradation: no jq = no output
if ! command -v jq &>/dev/null; then
  exit 0
fi

# Graceful degradation: no state file = no output
if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

# Read state
HAS_CODE=$(jq -r '.has_code_change // false' "$STATE_FILE" 2>/dev/null || echo "false")
HAS_DOC=$(jq -r '.has_doc_change // false' "$STATE_FILE" 2>/dev/null || echo "false")
CODE_PASSED=$(jq -r '.code_review.passed // false' "$STATE_FILE" 2>/dev/null || echo "false")
DOC_PASSED=$(jq -r '.doc_review.passed // false' "$STATE_FILE" 2>/dev/null || echo "false")
PRE_PASSED=$(jq -r '.precommit.passed // false' "$STATE_FILE" 2>/dev/null || echo "false")

# Stale-state reconciliation (one-way: true->false only, same as stop-guard)
GIT_PORCELAIN=$(git status --porcelain -uno 2>/dev/null || echo "__GIT_UNAVAILABLE__")
if [[ "$GIT_PORCELAIN" != "__GIT_UNAVAILABLE__" ]]; then
  if [[ "$HAS_CODE" == "true" ]]; then
    if ! echo "$GIT_PORCELAIN" | grep -qE '\.(ts|tsx|js|jsx|mjs|cjs|py|pyw|go|rs|java|kt|kts|rb|php|swift|c|cpp|cc|h|hpp|cs|scala|ex|exs)($|\s|")'; then
      HAS_CODE="false"
    fi
  fi
  if [[ "$HAS_DOC" == "true" ]]; then
    if ! echo "$GIT_PORCELAIN" | grep -qE '\.(md|mdx)($|\s|")'; then
      HAS_DOC="false"
    fi
  fi
fi

# Derive next required command
NEXT=""
if [[ "$HAS_CODE" == "true" && "$CODE_PASSED" != "true" ]]; then
  NEXT="/codex-review-fast"
elif [[ "$HAS_CODE" == "true" && "$CODE_PASSED" == "true" && "$PRE_PASSED" != "true" ]]; then
  NEXT="/precommit-fast"
elif [[ "$HAS_DOC" == "true" && "$DOC_PASSED" != "true" ]]; then
  NEXT="/codex-review-doc"
fi

# Only inject if there is a pending step
if [[ -n "$NEXT" ]]; then
  cat <<EOF
[AUTO_LOOP_RESUME]
Context was compacted. Auto-loop state is still active.
Required next step: ${NEXT}
Core rules (re-injected):
1) Declaring != Executing: saying "need to run X" without invoking the tool is a violation
2) Summary != Completion: outputting a summary then stopping is a violation
3) Execute review in same reply after edit — do not stop, do not ask
Do not ask "should I continue" — execute ${NEXT} now.
EOF
fi

exit 0
