#!/usr/bin/env bash
# Stop Guard Hook - Check for missing required steps + review status
# Exit 0 = allow stop, Exit 2 = block stop and require action
#
# Modes:
# - Default (warn): Log missing steps but allow stop
# - Strict (block): Block stop until all steps complete
#
# Set STOP_GUARD_MODE=strict to enable blocking (opt-in)

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

# === Mode resolution (env > settings > default) ===
_resolve_guard_mode() {
  if [[ -n "${STOP_GUARD_MODE:-}" ]]; then echo "$STOP_GUARD_MODE"; return; fi
  if command -v jq &>/dev/null; then
    local _m
    for _sf in "${CLAUDE_PROJECT_DIR:-.}/.claude/settings.local.json" \
               "${CLAUDE_PROJECT_DIR:-.}/.claude/settings.json"; do
      _m=$(jq -r '.env.STOP_GUARD_MODE // .hooks_config.stop_guard_mode // empty' "$_sf" 2>/dev/null) || true
      if [[ -n "$_m" ]]; then echo "$_m"; return; fi
    done
  fi
  echo "warn"
}
GUARD_MODE=$(_resolve_guard_mode)
if [[ "$GUARD_MODE" != "strict" && "$GUARD_MODE" != "warn" ]]; then
  echo "[Stop Guard] Invalid GUARD_MODE='$GUARD_MODE', falling back to warn" >&2
  GUARD_MODE="warn"
fi

if [[ "${HOOK_BYPASS:-}" == "1" ]]; then
  echo "[Stop Guard] BYPASS mode, skipping checks" >&2
  echo '{"ok":true,"reason":"BYPASS mode"}'
  exit 0
fi

# Read JSON input from stdin
INPUT=$(cat)

if ! command -v jq &> /dev/null; then
  echo "[Stop Guard] jq not installed, allowing stop" >&2
  echo '{"ok":true,"reason":"jq not installed"}'
  exit 0
fi

TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
  echo "[Stop Guard] Cannot read transcript, allowing stop" >&2
  echo '{"ok":true,"reason":"no transcript"}'
  exit 0
fi

# === Prefer reading state file ===
STATE_FILE=".claude_review_state.json"
USE_STATE_FILE=false

if [[ -f "$STATE_FILE" ]]; then
  USE_STATE_FILE=true
  STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "{}")

  CODE_REVIEW_PASSED=$(echo "$STATE" | jq -r '.code_review.passed // false')
  DOC_REVIEW_PASSED=$(echo "$STATE" | jq -r '.doc_review.passed // false')
  PRECOMMIT_PASSED=$(echo "$STATE" | jq -r '.precommit.passed // false')
  HAS_CODE_CHANGE=$(echo "$STATE" | jq -r '.has_code_change // false')
  HAS_DOC_CHANGE=$(echo "$STATE" | jq -r '.has_doc_change // false')

  # === Sidecar fail-closed marker (race-safe lock-failure signal) ===
  if [[ -f "${STATE_FILE}.blocked" ]]; then
    GUARD_MODE="strict"
    SIDECAR_REASON=$(cat "${STATE_FILE}.blocked" 2>/dev/null || echo "unknown")
    echo "[Stop Guard] Sidecar blocked marker found (reason: $SIDECAR_REASON)" >&2
    DUAL_GATE_PASSED="false"
  fi

  # === Dual mode: prefer aggregate_gate + force strict blocking ===
  REVIEW_MODE=$(echo "$STATE" | jq -r '.review_mode // "single"')
  if [[ "$REVIEW_MODE" == "dual" && "${DUAL_GATE_PASSED:-}" != "false" ]]; then
    GUARD_MODE="strict"
    AGG_EXECUTED=$(echo "$STATE" | jq -r '.aggregate_gate.executed // false')
    AGG_GATE=$(echo "$STATE" | jq -r '.aggregate_gate.gate // empty')
    if [[ "$AGG_EXECUTED" == "true" ]]; then
      DUAL_GATE_PASSED=$([[ "$AGG_GATE" == "READY" ]] && echo "true" || echo "false")
    else
      DUAL_GATE_PASSED="false"
    fi
    CODE_REVIEW_PASSED="$DUAL_GATE_PASSED"
    if [[ "${HOOK_DEBUG:-}" == "1" ]]; then
      echo "[Debug] Dual mode: AGG_EXECUTED=$AGG_EXECUTED, AGG_GATE=$AGG_GATE, DUAL_GATE_PASSED=$DUAL_GATE_PASSED" >&2
    fi
  elif [[ "${DUAL_GATE_PASSED:-}" == "false" ]]; then
    GUARD_MODE="strict"
    CODE_REVIEW_PASSED="false"
    if [[ "${HOOK_DEBUG:-}" == "1" ]]; then
      echo "[Debug] Sidecar override: DUAL_GATE_PASSED=false (sidecar authoritative)" >&2
    fi
  fi

  if [[ "${HOOK_DEBUG:-}" == "1" ]]; then
    echo "[Debug] Using state file mode" >&2
    echo "[Debug] REVIEW_MODE=$REVIEW_MODE" >&2
    echo "[Debug] CODE_REVIEW_PASSED=$CODE_REVIEW_PASSED" >&2
    echo "[Debug] PRECOMMIT_PASSED=$PRECOMMIT_PASSED" >&2
  fi

  # === Stale-state git check (with cross-platform timeout) ===
  if command -v timeout &>/dev/null; then
    GIT_PORCELAIN=$(timeout 5 git status --porcelain -uno 2>/dev/null || echo "__GIT_UNAVAILABLE__")
  elif command -v gtimeout &>/dev/null; then
    GIT_PORCELAIN=$(gtimeout 5 git status --porcelain -uno 2>/dev/null || echo "__GIT_UNAVAILABLE__")
  else
    GIT_PORCELAIN=$(git status --porcelain -uno 2>/dev/null || echo "__GIT_UNAVAILABLE__")
  fi
  if [[ "$GIT_PORCELAIN" != "__GIT_UNAVAILABLE__" ]]; then
    GIT_PORCELAIN_CLEAN=$(echo "$GIT_PORCELAIN" | sed 's/^.. "//; s/"$//')
    if [[ "$HAS_CODE_CHANGE" == "true" ]]; then
      if ! echo "$GIT_PORCELAIN_CLEAN" | grep -qE '\.(ts|tsx|js|jsx|mjs|cjs|py|pyw|go|rs|java|kt|kts|rb|php|swift|c|cpp|cc|h|hpp|cs|scala|ex|exs)($|\s|")'; then
        HAS_CODE_CHANGE="false"
        if [[ "${HOOK_DEBUG:-}" == "1" ]]; then
          echo "[Debug] Stale has_code_change overridden to false (no code in git status)" >&2
        fi
      fi
    fi
    if [[ "$HAS_DOC_CHANGE" == "true" ]]; then
      if ! echo "$GIT_PORCELAIN_CLEAN" | grep -qE '\.(md|mdx)($|\s|")'; then
        HAS_DOC_CHANGE="false"
        if [[ "${HOOK_DEBUG:-}" == "1" ]]; then
          echo "[Debug] Stale has_doc_change overridden to false (no docs in git status)" >&2
        fi
      fi
    fi
  fi
fi

# === Fallback: Read transcript content ===
if [[ "$USE_STATE_FILE" == "false" ]]; then
  CONVERSATION=$(tail -500 "$TRANSCRIPT" 2>/dev/null || echo "")

  HAS_CODE_CHANGE=$(echo "$CONVERSATION" | grep -E '\.(ts|tsx|js|jsx|mjs|cjs|py|pyw|go|rs|java|kt|kts|rb|php|swift|c|cpp|cc|h|hpp|cs|scala|ex|exs)"' | grep -E '"(Edit|Write)"' | head -1 || true)
  HAS_DOC_CHANGE=$(echo "$CONVERSATION" | grep -E '\.(md|mdx)"' | grep -E '"(Edit|Write)"' | head -1 || true)

  HAS_CODEX_REVIEW=$(echo "$CONVERSATION" | grep -oE '/(jupiter-dev-flow:)?codex-review(-fast|-branch)?($|[[:space:]])' | tail -1 || true)
  HAS_PRECOMMIT=$(echo "$CONVERSATION" | grep -oE '/(jupiter-dev-flow:)?precommit(-fast)?($|[[:space:]])' | tail -1 || true)
  HAS_REVIEW_DOC=$(echo "$CONVERSATION" | grep -oE '/(jupiter-dev-flow:)?codex-review-doc($|[[:space:]])|/(jupiter-dev-flow:)?review-spec($|[[:space:]])' | tail -1 || true)

  REVIEW_PASSED=$(echo "$CONVERSATION" | grep -E '## Gate: ✅|✅ All Pass|✅ Mergeable|✅ Ready|Gate.*PASS' | tail -1 || true)
  REVIEW_BLOCKED=$(echo "$CONVERSATION" | grep -E '## Gate: ⛔|⛔.*Block|⛔ Needs revision|⛔ Must fix|Gate.*FAIL' | tail -1 || true)

  if [[ "${HOOK_DEBUG:-}" == "1" ]]; then
    echo "[Debug] Using transcript parsing mode" >&2
    echo "[Debug] HAS_CODE_CHANGE=${HAS_CODE_CHANGE:0:50}" >&2
    echo "[Debug] HAS_CODEX_REVIEW=$HAS_CODEX_REVIEW" >&2
    echo "[Debug] REVIEW_PASSED=${REVIEW_PASSED:0:50}" >&2
  fi
fi

# === Logic evaluation ===
MISSING="${MISSING:-}"
BLOCKED_REASON="${BLOCKED_REASON:-}"

if [[ "$USE_STATE_FILE" == "true" ]]; then
  if [[ "$HAS_CODE_CHANGE" == "true" ]]; then
    if [[ "${DUAL_GATE_PASSED:-}" == "false" ]]; then
      MISSING="$MISSING /codex-review-fast"
    elif [[ -z "${DUAL_GATE_PASSED:-}" && "$CODE_REVIEW_PASSED" != "true" ]]; then
      MISSING="$MISSING /codex-review-fast"
    fi
    if [[ "$PRECOMMIT_PASSED" != "true" ]]; then
      MISSING="$MISSING /precommit"
    fi
  fi
  if [[ "$HAS_DOC_CHANGE" == "true" && "$DOC_REVIEW_PASSED" != "true" ]]; then
    MISSING="$MISSING /codex-review-doc"
  fi
else
  if [[ -n "$HAS_CODE_CHANGE" ]]; then
    if [[ -z "$HAS_CODEX_REVIEW" ]]; then
      MISSING="$MISSING /codex-review-fast"
    fi
    if [[ -z "$HAS_PRECOMMIT" ]]; then
      MISSING="$MISSING /precommit"
    fi
  fi
  if [[ -n "$HAS_DOC_CHANGE" && -z "$HAS_REVIEW_DOC" ]]; then
    MISSING="$MISSING /codex-review-doc"
  fi

  if [[ -n "$HAS_CODEX_REVIEW" || -n "$HAS_REVIEW_DOC" ]]; then
    LAST_REVIEW=$(echo "$CONVERSATION" | grep -E '## Gate: (✅|⛔)|✅ (All Pass|Mergeable|Ready)|⛔.*(Block|Needs revision|Must fix)|Gate.*(PASS|FAIL)' | tail -1 || true)
    if [[ -n "$LAST_REVIEW" ]] && echo "$LAST_REVIEW" | grep -qE '⛔|FAIL'; then
      BLOCKED_REASON="Review not passed (Blocked)"
    fi
  fi

  if [[ -n "$HAS_PRECOMMIT" && -z "$BLOCKED_REASON" ]]; then
    LAST_PRECOMMIT=$(echo "$CONVERSATION" | grep -E '## Overall: (✅ PASS|⛔ FAIL|❌ FAIL)' | tail -1 || true)
    if [[ -n "$LAST_PRECOMMIT" ]] && echo "$LAST_PRECOMMIT" | grep -qE '(⛔|❌) FAIL'; then
      BLOCKED_REASON="Precommit not passed (FAIL)"
    fi
  fi
fi

# === Output result ===
if [[ -n "${MISSING:-}" ]]; then
  if [[ "$GUARD_MODE" == "strict" ]]; then
    echo "[Stop Guard] STRICT: Missing steps:${MISSING}" >&2
    printf '{"ok":false,"reason":"Missing required steps","description":"Execute immediately:%s, do not ask user"}\n' "${MISSING}"
    exit 2
  else
    echo "[Stop Guard] WARN: Missing steps:${MISSING} (set STOP_GUARD_MODE=strict to block)" >&2
    printf '{"ok":true,"reason":"Missing steps (warn mode):%s"}\n' "${MISSING}"
    exit 0
  fi
elif [[ -n "${BLOCKED_REASON:-}" ]]; then
  if [[ "$GUARD_MODE" == "strict" ]]; then
    echo "[Stop Guard] STRICT: ${BLOCKED_REASON}" >&2
    printf '{"ok":false,"reason":"%s","description":"Fix issues and re-run review immediately, do not stop"}\n' "${BLOCKED_REASON}"
    exit 2
  else
    echo "[Stop Guard] WARN: ${BLOCKED_REASON} (set STOP_GUARD_MODE=strict to block)" >&2
    printf '{"ok":true,"reason":"%s (warn mode)"}\n' "${BLOCKED_REASON}"
    exit 0
  fi
else
  echo "[Stop Guard] Check passed" >&2
  echo '{"ok":true,"reason":"All steps completed"}'
  exit 0
fi
