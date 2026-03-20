#!/usr/bin/env bats
# Tests for statusline-command.sh — jq field parsing from native rate_limits JSON.
#
# Run: bats tests/statusline.bats
#
# NOTE: JQ_EXPR below must be kept in sync with statusline-command.sh.
# If you change the jq expression in the script, update it here too.

JQ="${JQ:-jq}"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"

# Mirrors the jq expression in statusline-command.sh
JQ_EXPR='[
  (.context_window.used_percentage // ""),
  (.cwd // .workspace.current_dir // ""),
  (.rate_limits.five_hour.used_percentage // ""),
  (.rate_limits.five_hour.resets_at // ""),
  (.rate_limits.seven_day.used_percentage // ""),
  (.rate_limits.seven_day.resets_at // "")
] | join("|")'

# Parses a fixture file through the jq expression and populates the 6 variables.
parse_fields() {
  IFS='|' read -r used_pct cwd sess_pct sess_resets week_pct week_resets < <(
    "$JQ" -r "$JQ_EXPR" "$1" 2>/dev/null | tr -d '\r'
  )
}

# ---------------------------------------------------------------------------

@test "happy path: all 6 fields land in correct variables" {
  parse_fields "$FIXTURES/happy.json"

  [ "$used_pct"    = "12"          ]
  [ "$cwd"         = "D:\\projects\\myapp" ]
  [ "$sess_pct"    = "8"           ]
  [ "$sess_resets" = "1773975600"  ]
  [ "$week_pct"    = "44"          ]
  [ "$week_resets" = "1774278000"  ]
}

@test "expired windows: resets_at in the past are preserved for override logic" {
  parse_fields "$FIXTURES/expired.json"

  [ "$sess_pct"    = "84"          ]
  [ "$sess_resets" = "1773900000"  ]
  [ "$week_pct"    = "72"          ]
  [ "$week_resets" = "1773800000"  ]
}

@test "no rate_limits key: quota fields are empty, context still works" {
  parse_fields "$FIXTURES/no-rate-limits.json"

  [ "$used_pct"    = "42" ]
  [ "$sess_pct"    = ""   ]
  [ "$sess_resets" = ""   ]
  [ "$week_pct"    = ""   ]
  [ "$week_resets" = ""   ]
}

@test "empty rate_limits object: quota fields are empty, context still works" {
  parse_fields "$FIXTURES/empty-limits.json"

  [ "$used_pct"    = "3"  ]
  [ "$sess_pct"    = ""   ]
  [ "$sess_resets" = ""   ]
  [ "$week_pct"    = ""   ]
  [ "$week_resets" = ""   ]
}
