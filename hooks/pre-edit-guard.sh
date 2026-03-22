#!/usr/bin/env bash
# PreToolUse hook: Guard against editing sensitive files
# Exit code 2 = reject the tool call
#
# Protected paths (always):
# - .env files (secrets)
# - .git/ directory (git internals)
#
# Custom protected paths (optional):
# Set GUARD_EXTRA_PATTERNS to add project-specific patterns (pipe-separated regex)
# Example: GUARD_EXTRA_PATTERNS="src/locales/.*\.json$|generated/.*"
# WARNING: This env var is used as a grep regex. Only set by trusted project admin.

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

# Read stdin once and store it
stdin_data=$(cat)

file_path=$(printf '%s' "$stdin_data" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)

if [[ -z "$file_path" ]]; then
  exit 0
fi

# Security: Reject paths with shell metacharacters
if [[ "$file_path" =~ [\;\&\|\`] ]] || [[ "$file_path" =~ \$\( ]]; then
  echo "[Edit Guard] Rejected suspicious file path: contains shell metacharacters" >&2
  exit 2
fi

# Block sensitive paths
if echo "$file_path" | grep -Eq '(\.env|\.git/)'; then
  echo "[Edit Guard] Blocked sensitive file: $file_path" >&2
  exit 2
fi

# Block custom paths (project-specific, opt-in via env var)
if [[ -n "${GUARD_EXTRA_PATTERNS:-}" ]]; then
  if echo "" | grep -Eq "$GUARD_EXTRA_PATTERNS" 2>/dev/null || [[ $? -le 1 ]]; then
    if echo "$file_path" | grep -Eq "$GUARD_EXTRA_PATTERNS"; then
      echo "[Edit Guard] Blocked by custom pattern: $file_path" >&2
      exit 2
    fi
  else
    echo "[Edit Guard] Invalid GUARD_EXTRA_PATTERNS regex, skipping" >&2
  fi
fi

exit 0
