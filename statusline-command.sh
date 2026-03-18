#!/usr/bin/env bash
#
# Claude Code Status Line — rainbow gradient with ccburn quota integration
# https://github.com/Matthew-IDKA/claude-code-statusline
#
# Displays: context% | dir@branch | session quota | weekly quota (time%) | sonnet quota
# Colors flow cool-to-warm (magenta → red) left to right.
#
# Requirements:
#   - ccburn (https://github.com/JuanjoFuchs/ccburn) for quota data
#   - jq for JSON parsing
#
# Configuration — edit these values to match your setup:

# Path to jq binary (leave as "jq" if it's on your PATH)
JQ="jq"

# Path to ccburn binary (leave as "ccburn" if it's on your PATH)
CCBURN="ccburn"

# ccburn cache location and refresh interval (seconds)
CACHE_FILE="$HOME/.claude/.ccburn-cache"
CACHE_MAX_AGE=900  # 15 minutes — see "Rate limit awareness" in README

# Rate limit sentinel file (created when ccburn refresh fails)
RL_FLAG="$HOME/.claude/.ccburn-ratelimited"

# Weekly budget reset: day of week (1=Monday .. 7=Sunday) and hour (0-23)
RESET_DAY=1   # Monday
RESET_HOUR=11  # 11:00 AM

# --- end of configuration ---

input=$(cat)

# Parse status line JSON for context window and cwd
used_pct=$(echo "$input" | grep -Eo '"used_percentage":[0-9]+' | cut -d: -f2)
cwd=$(echo "$input" | grep -Eo '"cwd":"[^"]+"' | cut -d'"' -f4 | sed 's/\\\\/\//g')

if [ -z "$cwd" ]; then
  cwd=$(echo "$input" | grep -Eo '"current_dir":"[^"]+"' | cut -d'"' -f4 | sed 's/\\\\/\//g')
fi

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

# --- ccburn quota (cached, refreshed every CACHE_MAX_AGE seconds) ---
need_refresh=1
cache_age=999999
if [ -f "$CACHE_FILE" ]; then
  cache_mtime=$(date -r "$CACHE_FILE" +%s 2>/dev/null || echo 0)
  cache_age=$(( $(date +%s) - cache_mtime ))
  if [ "$cache_age" -lt "$CACHE_MAX_AGE" ]; then
    need_refresh=0
  fi
fi

if [ "$need_refresh" -eq 1 ]; then
  quota=$("$CCBURN" --json --once 2>/dev/null)
  if [ -n "$quota" ]; then
    echo "$quota" > "$CACHE_FILE"
    rm -f "$RL_FLAG"
    cache_age=0
  else
    touch "$RL_FLAG"
  fi
fi

# --- ANSI colors (cool-to-warm gradient, left to right) ---
#     Position:  1:location  2:sess-title  3:sess-value  4:sess-reset
#                5:week-title  6:week-value  7:week-time%  8:sonn-title  9:sonn-value
MAGENTA=$'\033[35m'        # 1: location
BLUE=$'\033[34m'           # 2: session title
CYAN=$'\033[36m'           # 3: session value
TEAL=$'\033[38;5;30m'      # 4: session reset
GREEN=$'\033[32m'          # 5: weekly title
LIME=$'\033[38;5;148m'     # 6: weekly value
YELLOW=$'\033[33m'         # 7: weekly time%
ORANGE=$'\033[38;5;208m'   # 8: sonnet title
RED=$'\033[31m'            # 9: sonnet value
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'

# --- Parse ccburn JSON cache (single jq call) ---
quota_str=""
if [ -f "$CACHE_FILE" ]; then
  IFS='|' read -r sess_pct sess_status sess_reset sess_reset_hrs week_pct week_status week_reset_hrs sonn_pct sonn_status sonn_reset_hrs < <(
    "$JQ" -r '[
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
    ] | join("|")' "$CACHE_FILE" 2>/dev/null
  )

  # If a window has expired (negative time remaining), the API returned stale
  # data during a window rollover. Override to 0% until API catches up.
  case "$sess_reset_hrs" in -*) sess_pct=0 ;; esac
  case "$week_reset_hrs" in -*) week_pct=0 ;; esac
  case "$sonn_reset_hrs" in -*) sonn_pct=0 ;; esac

  # --- Interpolate session timer from local clock ---
  # Between API polls, subtract elapsed minutes so the timer ticks down live.
  elapsed_min=$(( cache_age / 60 ))
  if [ -n "$sess_reset" ] && [ "$sess_reset" -gt 0 ] 2>/dev/null; then
    sess_reset=$(( sess_reset - elapsed_min ))
    [ "$sess_reset" -lt 0 ] && sess_reset=0
  fi

  # Pace indicator: behind=~, on==, ahead=!
  pace_icon() {
    case "$1" in
      behind_pace) echo "~" ;;
      on_pace)     echo "=" ;;
      ahead_pace)  echo "!" ;;
      *)           echo "-" ;;
    esac
  }

  if [ -n "$sess_pct" ]; then
    si=$(pace_icon "$sess_status")
    wi=$(pace_icon "$week_status")
    ni=$(pace_icon "$sonn_status")

    reset_str=""
    if [ -n "$sess_reset" ]; then
      reset_str="${sess_reset}m"
    fi

    # Weekly time elapsed: % of reset-to-reset window
    reset_offset=$(( RESET_DAY * 86400 + RESET_HOUR * 3600 - 86400 ))
    dow=$(date +%u)  # 1=Mon..7=Sun
    h=$((10#$(date +%H))); m=$((10#$(date +%M)))
    secs_since_reset=$(( (dow - 1) * 86400 + h * 3600 + m * 60 - reset_offset ))
    if [ "$secs_since_reset" -lt 0 ]; then
      secs_since_reset=$(( secs_since_reset + 604800 ))
    fi
    time_pct=$(( secs_since_reset * 100 / 604800 ))

    reset_part=""
    if [ -n "$reset_str" ]; then
      reset_part=" ${TEAL}${reset_str}${RESET}"
    fi

    # Rate limit indicator (invisible unless flagged)
    rl_str=""
    if [ -f "$RL_FLAG" ]; then
      rl_str="    ${RED}${BOLD}[RL]${RESET}"
    fi

    quota_str="${BLUE}session: ${CYAN}${sess_pct}%_${si}${RESET}${reset_part}    ${GREEN}weekly: ${LIME}${week_pct}%_${wi}${RESET} ${YELLOW}(${time_pct}%)${RESET}    ${ORANGE}sonnet: ${RED}${sonn_pct}%_${ni}${RESET}${rl_str}"
  fi
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
