#!/usr/bin/env bash
#
# Claude Code Status Line -- rainbow gradient with native rate limit display
# https://github.com/Matthew-IDKA/claude-code-statusline
#
# Displays: ctx% | dir@branch | session quota | weekly quota | model [effort]
# Colors flow cool-to-warm (blue -> red) left to right across 11 stops.
#
# Requirements:
#   - Claude Code 2.1.80+ (provides rate_limits and model in status line JSON)
#   - jq for JSON parsing
#
# --- Configuration ---

# Path to jq binary (leave as "jq" if it's on your PATH)
JQ="jq"

# Optional: Prometheus Pushgateway URL (leave empty to disable metrics push)
# Example: PUSH_GATEWAY_URL="http://your-pushgateway:9091"
PUSH_GATEWAY_URL=""

# --- end of configuration ---

input=$(cat)

# --- Parse all fields from status line JSON (single jq call) ---
IFS='|' read -r used_pct cwd sess_pct sess_resets week_pct week_resets model_id < <(
  echo "$input" | "$JQ" -r '[
    (.context_window.used_percentage // ""),
    (.cwd // .workspace.current_dir // ""),
    ((.rate_limits.five_hour.used_percentage // 0) | round),
    (.rate_limits.five_hour.resets_at // ""),
    ((.rate_limits.seven_day.used_percentage // 0) | round),
    (.rate_limits.seven_day.resets_at // ""),
    (.model.id // "")
  ] | join("|")' 2>/dev/null | tr -d '\r'
)

# Fix Windows path separators for git
cwd=$(echo "$cwd" | sed 's/\\\\/\//g')

# --- Effort level from settings (not in statusline JSON) ---
effort=$("$JQ" -r '.effortLevel // ""' "$HOME/.claude/settings.json" 2>/dev/null | tr -d '\r')

# --- Location: git branch or basename of cwd ---
if [ -n "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
fi

dir_name=$(basename "${cwd:-$PWD}")
if [ -n "$branch" ]; then
  location="${dir_name}@${branch}"
else
  location="${dir_name}"
fi

# --- ANSI gradient: 11 stops, cool to warm (left to right) ---
C1=$'\033[38;5;63m'    # ctx label
C2=$'\033[38;5;69m'    # ctx value (default)
C3=$'\033[38;5;75m'    # location
C4=$'\033[38;5;80m'    # session label
C5=$'\033[38;5;43m'    # session value
C6=$'\033[38;5;114m'   # session timer
C7=$'\033[38;5;150m'   # weekly label
C8=$'\033[38;5;186m'   # weekly value
C9=$'\033[38;5;222m'   # weekly time%
C10=$'\033[38;5;209m'  # model
C11=$'\033[38;5;203m'  # effort
RESET=$'\033[0m'
BOLD=$'\033[1m'
CTX_YELLOW=$'\033[38;5;220m'  # ctx value: approaching limit
CTX_RED=$'\033[38;5;196m'     # ctx value: near limit

# --- Compute pace from native rate_limits ---
now=$(date +%s)
quota_str=""

if [ -n "$sess_pct" ] && [ -n "$sess_resets" ]; then
  # Session: 5-hour rolling window (18000 seconds)
  sess_remaining=$(( sess_resets - now ))
  if [ "$sess_remaining" -le 0 ]; then
    sess_pct=0
    sess_remaining=0
  fi
  sess_reset_min=$(( sess_remaining / 60 ))
  sess_elapsed=$(( 18000 - sess_remaining ))
  [ "$sess_elapsed" -lt 0 ] && sess_elapsed=0

  # Pace: ratio of usage to elapsed time (x100 for integer math)
  if [ "$sess_elapsed" -gt 0 ]; then
    sess_pace_x100=$(( sess_pct * 18000 / sess_elapsed ))
  else
    sess_pace_x100=0
  fi

  if [ "$sess_pace_x100" -lt 85 ]; then
    sess_icon="~"
  elif [ "$sess_pace_x100" -gt 115 ]; then
    sess_icon="!"
  else
    sess_icon="="
  fi

  # Weekly: 7-day rolling window (604800 seconds)
  week_remaining=$(( week_resets - now ))
  if [ "$week_remaining" -le 0 ]; then
    week_pct=0
    week_remaining=0
  fi
  week_elapsed=$(( 604800 - week_remaining ))
  [ "$week_elapsed" -lt 0 ] && week_elapsed=0
  time_pct=$(( week_elapsed * 100 / 604800 ))

  if [ "$week_elapsed" -gt 0 ]; then
    week_pace_x100=$(( week_pct * 604800 / week_elapsed ))
  else
    week_pace_x100=0
  fi

  if [ "$week_pace_x100" -lt 85 ]; then
    week_icon="~"
  elif [ "$week_pace_x100" -gt 115 ]; then
    week_icon="!"
  else
    week_icon="="
  fi

  quota_str="${C4}session: ${C5}${sess_pct}%_${sess_icon}${RESET} ${C6}${sess_reset_min}m${RESET}    ${C7}weekly: ${C8}${week_pct}%_${week_icon}${RESET} ${C9}(${time_pct}%)${RESET}"
fi

# --- Context usage with dynamic color ---
if [ -n "$used_pct" ]; then
  ctx_int=${used_pct%.*}
  if   [ "${ctx_int:-0}" -ge 85 ]; then ctx_val_color=$CTX_RED
  elif [ "${ctx_int:-0}" -ge 60 ]; then ctx_val_color=$CTX_YELLOW
  else ctx_val_color=$C2
  fi
  ctx_str="${C1}${BOLD}ctx:${RESET}${ctx_val_color}${used_pct}%${RESET}"
else
  ctx_str="${C1}ctx:--${RESET}"
fi

# --- Model + effort tag ---
model_str=""
if [ -n "$model_id" ]; then
  short_model="${model_id#claude-}"
  if [ -n "$effort" ]; then
    model_str="${C10}${short_model}${RESET} ${C11}[${effort}]${RESET}"
  else
    model_str="${C10}${short_model}${RESET}"
  fi
fi

# --- Assemble output ---
if [ -n "$quota_str" ]; then
  printf '%s\n' "${ctx_str}    ${C3}${location}${RESET}    ${quota_str}    ${model_str}"
else
  printf '%s\n' "${ctx_str}    ${C3}${location}${RESET}    ${model_str}"
fi

# --- Push metrics to Prometheus Pushgateway (throttled, background) ---
# Only runs if PUSH_GATEWAY_URL is set above. Throttled to once per 15 minutes.
PUSH_STAMP="$HOME/.claude/.ccburn-push-stamp"
PUSH_INTERVAL=900  # 15 minutes
if [ -n "$PUSH_GATEWAY_URL" ] && [ -n "$sess_pct" ]; then
  do_push=0
  if [ -f "$PUSH_STAMP" ]; then
    stamp_age=$(( now - $(date -r "$PUSH_STAMP" +%s 2>/dev/null || echo 0) ))
    [ "$stamp_age" -ge "$PUSH_INTERVAL" ] && do_push=1
  else
    do_push=1
  fi
  if [ "$do_push" -eq 1 ]; then
    touch "$PUSH_STAMP"
    {
      push_body="# TYPE ccburn_utilization gauge
ccburn_utilization{limit=\"session\"} $(awk "BEGIN{printf \"%.4f\", $sess_pct/100}")
ccburn_utilization{limit=\"weekly\"} $(awk "BEGIN{printf \"%.4f\", $week_pct/100}")
# TYPE ccburn_budget_pace gauge
ccburn_budget_pace{limit=\"session\"} $(awk "BEGIN{printf \"%.4f\", $sess_elapsed/18000}")
ccburn_budget_pace{limit=\"weekly\"} $(awk "BEGIN{printf \"%.4f\", $week_elapsed/604800}")"
      printf '%s\n' "$push_body" | tr -d '\r' | curl -s --connect-timeout 3 --max-time 5 --data-binary @- \
        "${PUSH_GATEWAY_URL}/metrics/job/ccburn/instance/$(uname -n)" >/dev/null 2>&1
    } &
  fi
fi
