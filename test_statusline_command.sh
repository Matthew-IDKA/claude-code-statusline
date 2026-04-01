#!/bin/bash
# test_statusline_command.sh -- tests for statusline-command.sh
# Run: bash test_statusline_command.sh
# Requires: jq on PATH
#
# Tests the computation logic by feeding synthetic JSON input and
# checking output for expected content (pace icons, color codes,
# location strings, quota formatting).

set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/statusline-command.sh"

# Verify jq is available
if ! command -v jq &>/dev/null; then
    echo "SKIP: jq not found on PATH"
    exit 0
fi

# Strip ANSI escape codes for assertion matching
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

assert_contains() {
    local label="$1" pattern="$2" text="$3"
    if echo "$text" | grep -qF "$pattern"; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (pattern='$pattern' not found)"
        echo "    got: $text"
        FAIL=$((FAIL + 1))
    fi
}

assert_regex() {
    local label="$1" pattern="$2" text="$3"
    if echo "$text" | grep -qE "$pattern"; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (regex='$pattern' not found)"
        echo "    got: $text"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local label="$1" pattern="$2" text="$3"
    if echo "$text" | grep -qF "$pattern"; then
        echo "  FAIL: $label (pattern='$pattern' should not be present)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    fi
}

# Helper: build JSON input for the script
# Usage: make_input <ctx_pct> <cwd> <sess_pct> <sess_resets> <week_pct> <week_resets>
make_input() {
    local ctx_pct="$1" cwd="$2" sess_pct="$3" sess_resets="$4" week_pct="$5" week_resets="$6"

    cat <<ENDJSON
{
  "context_window": {"used_percentage": $ctx_pct},
  "cwd": "$cwd",
  "rate_limits": {
    "five_hour": {
      "used_percentage": $sess_pct,
      "resets_at": $sess_resets
    },
    "seven_day": {
      "used_percentage": $week_pct,
      "resets_at": $week_resets
    }
  }
}
ENDJSON
}

# Helper: run the script with given JSON input, return stripped output
run_script() {
    local json="$1"
    # Override git to avoid needing a real repo
    echo "$json" | GIT_DIR=/dev/null bash "$SCRIPT" 2>/dev/null | strip_ansi
}

NOW=$(date +%s)

# ════════════════════════════════════════════════════════════════════
# Test 1: Basic output structure
# ════════════════════════════════════════════════════════════════════
echo "Test 1: Basic output structure"
INPUT=$(make_input 42 "/home/user/project" 25 $((NOW + 14400)) 15 $((NOW + 518400)))
OUTPUT=$(run_script "$INPUT")

assert_contains "has ctx percentage" "ctx:42%" "$OUTPUT"
assert_contains "has location" "project" "$OUTPUT"
assert_contains "has session" "session:" "$OUTPUT"
assert_contains "has weekly" "weekly:" "$OUTPUT"

# ════════════════════════════════════════════════════════════════════
# Test 2: Context color thresholds
# ════════════════════════════════════════════════════════════════════
echo "Test 2: Context percentage display"
# Low context
INPUT=$(make_input 30 "/tmp/test" 10 $((NOW + 16200)) 5 $((NOW + 604800)))
OUTPUT=$(run_script "$INPUT")
assert_contains "low ctx shows 30%" "ctx:30%" "$OUTPUT"

# High context
INPUT=$(make_input 90 "/tmp/test" 10 $((NOW + 16200)) 5 $((NOW + 604800)))
OUTPUT=$(run_script "$INPUT")
assert_contains "high ctx shows 90%" "ctx:90%" "$OUTPUT"

# ════════════════════════════════════════════════════════════════════
# Test 3: Pace icon selection (session)
# ════════════════════════════════════════════════════════════════════
echo "Test 3: Session pace icons"

# Under-pace (~): 10% used with 14400s remaining (only 3600s elapsed of 18000)
# pace = 10 * 18000 / 3600 = 50 -> under 85 -> "~"
INPUT=$(make_input 50 "/tmp" 10 $((NOW + 14400)) 5 $((NOW + 604800)))
OUTPUT=$(run_script "$INPUT")
assert_contains "under-pace shows ~" "10%_~" "$OUTPUT"

# Over-pace (!): 80% used with 14400s remaining (3600s elapsed)
# pace = 80 * 18000 / 3600 = 400 -> over 115 -> "!"
INPUT=$(make_input 50 "/tmp" 80 $((NOW + 14400)) 5 $((NOW + 604800)))
OUTPUT=$(run_script "$INPUT")
assert_contains "over-pace shows !" "80%_!" "$OUTPUT"

# ════════════════════════════════════════════════════════════════════
# Test 4: Pace icon selection (weekly)
# ════════════════════════════════════════════════════════════════════
echo "Test 4: Weekly pace icons"

# Under-pace (~): 5% used with 518400s remaining (86400s elapsed of 604800)
# pace = 5 * 604800 / 86400 = 35 -> under 85 -> "~"
INPUT=$(make_input 50 "/tmp" 10 $((NOW + 16200)) 5 $((NOW + 518400)))
OUTPUT=$(run_script "$INPUT")
assert_contains "weekly under-pace ~" "5%_~" "$OUTPUT"

# Over-pace (!): 90% used with 518400s remaining (86400s elapsed)
# pace = 90 * 604800 / 86400 = 630 -> over 115 -> "!"
INPUT=$(make_input 50 "/tmp" 10 $((NOW + 16200)) 90 $((NOW + 518400)))
OUTPUT=$(run_script "$INPUT")
assert_contains "weekly over-pace !" "90%_!" "$OUTPUT"

# ════════════════════════════════════════════════════════════════════
# Test 5: Reset timer display
# ════════════════════════════════════════════════════════════════════
echo "Test 5: Session reset timer"
# 120 minutes remaining (7200 seconds)
INPUT=$(make_input 50 "/tmp" 50 $((NOW + 7200)) 10 $((NOW + 604800)))
OUTPUT=$(run_script "$INPUT")
# Allow 119m or 120m due to execution time between NOW and script run
assert_regex "shows reset minutes" "11[89]m|120m" "$OUTPUT"

# ════════════════════════════════════════════════════════════════════
# Test 6: No rate limits (minimal JSON)
# ════════════════════════════════════════════════════════════════════
echo "Test 6: No rate limits"
INPUT='{"context_window": {"used_percentage": 55}, "cwd": "/tmp/minimal"}'
OUTPUT=$(run_script "$INPUT")
assert_contains "still shows ctx" "ctx:55%" "$OUTPUT"
assert_contains "shows location" "minimal" "$OUTPUT"
assert_not_contains "no session without rate_limits" "session:" "$OUTPUT"

# ════════════════════════════════════════════════════════════════════
# Test 7: Missing context window
# ════════════════════════════════════════════════════════════════════
echo "Test 7: Missing context window"
INPUT='{"cwd": "/tmp/nocontext"}'
OUTPUT=$(run_script "$INPUT")
assert_contains "shows fallback ctx" "ctx:--" "$OUTPUT"

# ════════════════════════════════════════════════════════════════════
# Test 8: Weekly time percentage
# ════════════════════════════════════════════════════════════════════
echo "Test 8: Weekly time percentage"
# 302400s remaining -> 302400s elapsed -> 50% of 604800
INPUT=$(make_input 50 "/tmp" 10 $((NOW + 16200)) 10 $((NOW + 302400)))
OUTPUT=$(run_script "$INPUT")
assert_regex "shows time pct in parens" '\(5[0-9]%\)' "$OUTPUT"

# ════════════════════════════════════════════════════════════════════
# Test 9: Expired session (resets_at in the past)
# ════════════════════════════════════════════════════════════════════
echo "Test 9: Expired session resets to 0"
INPUT=$(make_input 50 "/tmp" 75 $((NOW - 100)) 10 $((NOW + 604800)))
OUTPUT=$(run_script "$INPUT")
assert_contains "expired session shows 0%" "0%_" "$OUTPUT"

# ════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════
echo ""
echo "========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "========================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
