#!/usr/bin/env bash
# M16 Auto-Completion Runner
# Continously runs until all M16 test262 targets are at 100%.
set -euo pipefail

cd ~/JSZ || { echo "ERROR: JSZ directory not found"; exit 1; }

BRANCH="feature/mi16-phase4"
TARGETS=(
  "reserved-words:language/reserved-words"
  "await-using:await-using"
)
BUILD_CMD="rm -f zig-out/bin/test262-runner && zig build -Doptimize=ReleaseFast"
RUNNER="./zig-out/bin/test262-runner --full --filter"
LOG_DIR="/tmp/m16_runner"
mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

check_state() {
    local filter="$1"
    local result
    result=$($RUNNER "$filter" 2>&1 | grep -oP 'Test262 summary: \K\d+ pass, \d+ fail out of \d+')
    echo "$result"
}

build_and_test() {
    log "Building..."
    if ! eval "$BUILD_CMD" 2>&1 | tail -3; then
        log "BUILD FAILED"
        return 1
    fi
    log "Build OK"
    return 0
}

commit_progress() {
    local msg="$1"
    if git diff --quiet HEAD 2>/dev/null; then
        log "No changes to commit"
        git push origin "$BRANCH" 2>&1 || true
        return 0
    fi
    git add -A
    git commit -m "$msg"
    log "Committed: $msg"
    git push origin "$BRANCH" 2>&1 || log "Push failed (will retry)"
    log "Pushed to origin/$BRANCH"
}

# ---- Main loop ----
log "=== M16 AUTO-COMPLETION RUNNER STARTED ==="
log "Target: 100% on all M16 categories"
log "Working branch: $BRANCH"

MAX_ITERATIONS=20
iteration=0

while [ $iteration -lt $MAX_ITERATIONS ]; do
    iteration=$((iteration + 1))
    log "--- Iteration $iteration ---"
    
    # Check state - build list of remaining
    remaining=""
    for target_spec in "${TARGETS[@]}"; do
        name="${target_spec%%:*}"
        filter="${target_spec#*:}"
        state=$(check_state "$filter") || true
        if [ -z "$state" ]; then
            log "WARN: Could not get state for $name"
            continue
        fi
        pass=$(echo "$state" | grep -oP '^\d+')
        fail=$(echo "$state" | grep -oP '(\d+) fail' | grep -oP '^\d+')
        total=$(echo "$state" | grep -oP 'out of \K\d+')
        if [ "$fail" -gt 0 ]; then
            remaining="$remaining $name($fail/$total fails)"
        fi
    done
    
    if [ -z "$remaining" ]; then
        log "🎉 ALL M16 TARGETS AT 100%! Milestone 16 COMPLETE!"
        commit_progress "feat(esm): M16 complete — all categories at 100%"
        exit 0
    fi
    log "Remaining failures:$remaining"
    
    # Build first
    if ! build_and_test; then
        log "Build failed, retrying in 10s..."
        sleep 10
        continue
    fi
    
    # Pick first remaining target
    for target_spec in "${TARGETS[@]}"; do
        name="${target_spec%%:*}"
        filter="${target_spec#*:}"
        state=$(check_state "$filter") || true
        pass=$(echo "$state" | grep -oP '^\d+') 2>/dev/null || continue
        fail=$(echo "$state" | grep -oP '(\d+) fail' | grep -oP '^\d+') 2>/dev/null || continue
        total=$(echo "$state" | grep -oP 'out of \K\d+') 2>/dev/null || continue
        
        if [ "${fail:-0}" -gt 0 ] 2>/dev/null; then
            log "Targeting: $name ($fail failures remaining)"
            
            prompt_file="$LOG_DIR/prompt_${name}.md"
            log_file="$LOG_DIR/claude_${name}.log"
            
            # Build prompt
            cat > "$prompt_file" << PROMPT
Fix the remaining $fail test262 test failures in "$filter" for the JSZ JavaScript engine.

Working directory: ~/JSZ
Branch: $BRANCH
Build: zig build -Doptimize=ReleaseFast
Test: ./zig-out/bin/test262-runner --full --filter "$filter"

Current state: $pass pass, $fail fail out of $total

First read the failing test files to understand what they expect.
Then inspect the relevant source code to find gaps.
Fix each failure. Test after each fix.
Only modify source files in src/ — never modify test files.

When all pass, commit: fix(esm): $name — remaining failures fixed
PROMPT
            
            log "Launching Claude for $name..."
            # Write prompt to fixed file, use static proxy to avoid ALL quoting issues
            mkdir -p /tmp/m16_work
            cp "$prompt_file" /tmp/m16_work/current_prompt.md
            # The proxy reads the prompt file — no shell quoting ever touches prompt text
            script -q -c "bash /tmp/claude_proxy.sh" "$log_file" 2>&1
            claude_ok=$?
            if [ $claude_ok -eq 0 ]; then
                # Check if work was done
                if ! git diff --quiet HEAD 2>/dev/null; then
                    log "$name: Claude made changes, building..."
                    if build_and_test; then
                        new_state=$(check_state "$filter") || true
                        log "$name after fix: $new_state"
                        commit_progress "fix(esm): $name — automated fix pass $iteration"
                    else
                        log "$name: Build failed after Claude, resetting"
                        git checkout -- . 2>/dev/null || true
                    fi
                else
                    log "$name: Claude produced no changes"
                fi
            else
                log "$name: Claude command failed"
            fi
            break
        fi
    done
    
    sleep 2
done

log "Reached max iterations ($MAX_ITERATIONS) without completing."
remaining=""
for target_spec in "${TARGETS[@]}"; do
    name="${target_spec%%:*}"
    filter="${target_spec#*:}"
    state=$(check_state "$filter") || true
    fail=$(echo "$state" | grep -oP '(\d+) fail' | grep -oP '^\d+') 2>/dev/null || continue
    if [ "${fail:-0}" -gt 0 ] 2>/dev/null; then
        remaining="$remaining $name($fail fails)"
    fi
done
log "Still remaining:$remaining"
exit 1
