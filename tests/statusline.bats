#!/usr/bin/env bats
# Tests for statusline-command.sh — jq field parsing and alignment.
#
# Run: bats tests/statusline.bats
#
# NOTE: JQ_EXPR below must be kept in sync with statusline-command.sh.
# If you change the jq expression in the script, update it here too.

JQ="${JQ:-jq}"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"

# Mirrors the jq expression in statusline-command.sh
JQ_EXPR='[
  (.limits.session.utilization // 0 | . * 100 | round),
  (.limits.session.status // "-"),
  (.limits.session.resets_in_minutes // ""),
  (.limits.session.resets_in_hours // 0),
  (.limits.weekly.utilization // 0 | . * 100 | round),
  (.limits.weekly.status // "-"),
  (.limits.weekly.resets_in_hours // 0),
  (.limits."weekly-sonnet".utilization // 0 | . * 100 | round),
  (.limits."weekly-sonnet".status // "-"),
  (.limits."weekly-sonnet".resets_in_hours // 0)
] | join("|")'

# Parses a fixture file through the jq expression and populates the 10 variables.
# Variables are set in global scope (no `local`) so callers can assert them directly.
parse_fields() {
  IFS='|' read -r sess_pct sess_status sess_reset sess_reset_hrs \
    week_pct week_status week_reset_hrs \
    sonn_pct sonn_status sonn_reset_hrs < <(
    "$JQ" -r "$JQ_EXPR" "$1" 2>/dev/null
  )
}

# ---------------------------------------------------------------------------

@test "happy path: all 10 fields land in correct variables" {
  parse_fields "$FIXTURES/happy.json"

  [ "$sess_pct"       = "4"           ]
  [ "$sess_status"    = "on_pace"     ]
  [ "$sess_reset"     = "279"         ]
  [ "$sess_reset_hrs" = "0"           ]
  [ "$week_pct"       = "41"          ]
  [ "$week_status"    = "on_pace"     ]
  [ "$sonn_pct"       = "37"          ]
  [ "$sonn_status"    = "behind_pace" ]
}

@test "regression: null resets_in_minutes must not shift week_pct to a status string" {
  parse_fields "$FIXTURES/null-resets-minutes.json"

  [ "$sess_pct"    = "0"           ]
  [ "$sess_status" = "-"           ]   # null status falls back to "-"
  [ "$sess_reset"  = ""            ]   # null resets_in_minutes -> empty, not "0"
  [ "$week_pct"    = "41"          ]   # must be a number — was "behind_pace" before the fix
  [ "$week_status" = "behind_pace" ]   # status in its correct variable
  [ "$sonn_pct"    = "37"          ]   # must be a number — was "on_pace" before the fix
  [ "$sonn_status" = "on_pace"     ]
}

@test "expired windows: negative resets_in_hours are preserved for override logic" {
  parse_fields "$FIXTURES/expired.json"

  # Negative values must survive jq // 0 (they are not null, so // doesn't fire)
  # and must reach the shell as strings starting with '-' so the case pattern matches.
  [[ "$sess_reset_hrs" == -* ]]
  [[ "$week_reset_hrs" == -* ]]
  [[ "$sonn_reset_hrs" == -* ]]
}

@test "empty limits object: all fields fall back to jq defaults" {
  parse_fields "$FIXTURES/empty-limits.json"

  [ "$sess_pct"    = "0" ]
  [ "$sess_status" = "-" ]
  [ "$sess_reset"  = ""  ]
  [ "$week_pct"    = "0" ]
  [ "$week_status" = "-" ]
  [ "$sonn_pct"    = "0" ]
  [ "$sonn_status" = "-" ]
}
