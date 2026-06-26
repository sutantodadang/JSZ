#!/bin/bash
# Cross-realm implementation — Claude Opus
# This script runs Claude Code in PTY mode for the cross-realm worktree.
# Source it to get the correct env in the PTY.

export WORKTREE="/home/sutanto/JSZ-wt-cross-realm"
cd "$WORKTREE" || exit 1

# Read the prompt from a file
PROMPT_FILE="$WORKTREE/.hermes/claude_prompt.md"

if [ ! -f "$PROMPT_FILE" ]; then
    echo "ERROR: Prompt file not found at $PROMPT_FILE"
    exit 1
fi

# Run Claude with the prompt
exec claude -p --model opus --dangerously-skip-permissions "$(cat "$PROMPT_FILE")" -w "$WORKTREE"
