#!/bin/bash
# Claude Code statusline script.
# Reads JSON from stdin and writes to temp file for Emacs polling.
# Requires: jq

input=$(cat)
if command -v shasum >/dev/null 2>&1; then
    SAFE_NAME=$(printf '%s' "$CLAUDE_BUFFER_NAME" | shasum -a 256 | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
    SAFE_NAME=$(printf '%s' "$CLAUDE_BUFFER_NAME" | sha256sum | awk '{print $1}')
else
    echo "agent: neither shasum nor sha256sum is available" >&2
    exit 1
fi
STATUS_DIR=${AGENT_CLAUDE_STATUS_DIR:-${TMPDIR:-/tmp}/claude-code-status}
mkdir -p "$STATUS_DIR"
printf '%s' "$input" > "$STATUS_DIR/${SAFE_NAME}.json"
