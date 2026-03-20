#!/usr/bin/env bash
#
# Claude Code Status Line — rainbow gradient with native rate limit display
# https://github.com/Matthew-IDKA/claude-code-statusline
#
# Displays: context% | dir@branch | session quota | weekly quota (time%)
# Colors flow cool-to-warm (magenta -> red) left to right.
#
# Requirements:
#   - Claude Code 2.1.80+ (provides rate_limits in status line JSON)
#   - jq for JSON parsing
#
# Configuration — edit these values to match your setup:

# Path to jq binary (leave as "jq" if it's on your PATH)
JQ="jq"

# --- end of configuration ---

input=$(cat)

# --- Parse all fields from status line JSON (single jq call) ---
# tr -d '\r' prevents Windows \r\n from poisoning the last read variable
IFS='|' read -r used_pct cwd sess_pct sess_resets week_pct week_resets < <(
  echo "$input" | "$JQ" -r '[
    (.context_window.used_percentage // ""),
    (.cwd // .workspace.current_dir // ""),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.seven_day.resets_at // "")
  ] | join("|")' 2>/dev/null | tr -d '\r'
)

# Fix Windows path separators for git
cwd=$(echo "$cwd" | sed 's/\\\\/\//g')

# --- Location: dir@branch (git) or dir name (non-git) ---
if [ -n "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
fi

dir_name=$(basename "${cwd:-$PWD}")
if [ -n "$branch" ]; then
  location="${dir_name}@${branch}"
else
  location="${dir_name}"
fi

# --- ANSI colors (cool-to-warm gradient, left to right) ---
#     Position:  1:location  2:sess-title  3:sess-value  4:sess-reset
#                5:week-title  6:week-value  7:week-time%
MAGENTA=$'\033[35m'        # 1: location
BLUE=$'\033[34m'           # 2: session title
CYAN=$'\033[36m'           # 3: session value
TEAL=$'\033[38;5;30m'      # 4: session reset timer
GREEN=$'\033[32m'          # 5: weekly title
LIME=$'\033[38;5;148m'     # 6: weekly value
YELLOW=$'\033[33m'         # 7: weekly time%
RED=$'\033[31m'
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'

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

  quota_str="${BLUE}session: ${CYAN}${sess_pct}%_${sess_icon}${RESET} ${TEAL}${sess_reset_min}m${RESET}    ${GREEN}weekly: ${LIME}${week_pct}%_${week_icon}${RESET} ${YELLOW}(${time_pct}%)${RESET}"
fi

# --- Color-code context usage ---
if [ -n "$used_pct" ]; then
  if [ "$used_pct" -ge 85 ] 2>/dev/null; then
    ctx_color="$RED"
  elif [ "$used_pct" -ge 60 ] 2>/dev/null; then
    ctx_color="$YELLOW"
  else
    ctx_color="$GREEN"
  fi
  ctx_str="${ctx_color}${BOLD}ctx:${used_pct}%${RESET}"
else
  ctx_str="${DIM}ctx:--${RESET}"
fi

# --- Assemble output ---
if [ -n "$quota_str" ]; then
  printf '%s\n' "${ctx_str}    ${MAGENTA}${location}${RESET}    ${quota_str}"
else
  printf '%s\n' "${ctx_str}    ${MAGENTA}${location}${RESET}"
fi
