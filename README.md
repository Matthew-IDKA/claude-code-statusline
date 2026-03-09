# Claude Code Status Line

A custom status line for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that displays context window usage, git branch, and API quota burn rates via [ccburn](https://github.com/JuanjoFuchs/ccburn) — with a cool-to-warm color gradient.

![Claude Code status line screenshot](screenshot.png)

## What it shows

| Section | Description |
|---------|-------------|
| **ctx** | Context window usage. Dynamic color: green (<60%), yellow (60-84%), red (85%+) |
| **location** | Current git branch, or folder name if not in a repo |
| **session** | Session quota utilization from ccburn |
| **reset timer** | Minutes until session quota resets (interpolated from local clock between API polls) |
| **weekly** | Weekly quota utilization from ccburn |
| **time elapsed** | % of your weekly budget window that has elapsed (see below) |
| **sonnet** | Weekly Sonnet-class model utilization from ccburn |
| **[RL]** | Rate limit indicator — only appears (in red) when ccburn API calls are being rate-limited |

Pace indicators after each quota value: `~` = behind pace (good), `=` = on pace, `!` = ahead of pace (watch it).

### Weekly time elapsed

Your Claude budget resets on a weekly cycle. The `(NN%)` value after the weekly quota shows how much of that cycle has passed. Compare it to the weekly quota percentage to quickly gauge whether you're burning faster or slower than the clock.

For example, `weekly: 30%_~ (50%)` means you've used 30% of your budget but 50% of the week has passed — you're pacing well.

### Rate limit awareness

The Anthropic usage API endpoint has an aggressive per-token rate limit (~5 requests before persistent HTTP 429). To avoid exhausting this budget, the script caches API responses for 15 minutes by default (`CACHE_MAX_AGE=900`).

Between API polls, the display stays live:
- **Session timer** counts down using the local clock (interpolated from the last known `resets_in_minutes` value)
- **Weekly time elapsed** is always calculated from the local clock (never stale)
- **Utilization percentages** hold at their last known values (only change when you actually use Claude)

If an API refresh fails (429 or other error), a red **[RL]** indicator appears at the right end of the status line. It clears automatically on the next successful refresh.

Multiple Claude Code terminal instances share the same cache file, so only one API call is made per cache interval regardless of how many terminals are open.

## Requirements

- [ccburn](https://github.com/JuanjoFuchs/ccburn) — CLI tool that reads Claude Code's OAuth token to query usage data
- [jq](https://jqlang.github.io/jq/) — JSON processor (most systems have this already)
- A terminal that supports ANSI colors and 256-color mode (Windows Terminal, iTerm2, most Linux terminals)

## Installation

1. **Install ccburn** if you haven't already:
   ```bash
   pip install ccburn
   ```

2. **Copy the script** to your Claude Code config directory:
   ```bash
   cp statusline-command.sh ~/.claude/statusline-command.sh
   chmod +x ~/.claude/statusline-command.sh
   ```

3. **Configure Claude Code** to use it. Add this to `~/.claude/settings.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash ~/.claude/statusline-command.sh"
     }
   }
   ```

4. **Restart Claude Code** to pick up the new status line.

## Configuration

Edit the variables at the top of `statusline-command.sh`:

### Paths

If `jq` and `ccburn` are on your PATH, the defaults work. Otherwise, set full paths:

```bash
JQ="/usr/local/bin/jq"
CCBURN="/usr/local/bin/ccburn"
```

### Weekly reset schedule

Set these to match when your Claude budget resets:

```bash
RESET_DAY=1    # Day of week: 1=Monday, 2=Tuesday, ..., 7=Sunday
RESET_HOUR=11  # Hour in 24h format: 0-23
```

The default is Monday at 11:00 AM. The time elapsed percentage adjusts automatically.

### Cache interval

ccburn is called at most once every `CACHE_MAX_AGE` seconds (default: 900 — 15 minutes). The Anthropic usage API has an aggressive rate limit (~5 requests per OAuth token before returning persistent 429 errors), so a long cache interval is recommended:

```bash
CACHE_MAX_AGE=900   # 15 minutes (default, recommended)
CACHE_MAX_AGE=1800  # 30 minutes (more conservative)
CACHE_MAX_AGE=120   # 2 minutes (risks rate limiting with multiple sessions)
```

The session timer interpolates from the local clock between polls, so longer cache intervals don't make the display feel stale.

## Customizing colors

The color assignments are in the `ANSI colors` section. Each position in the gradient maps to a UI element:

```bash
MAGENTA=$'\033[35m'        # 1: location
BLUE=$'\033[34m'           # 2: session title
CYAN=$'\033[36m'           # 3: session value
TEAL=$'\033[38;5;30m'      # 4: session reset
GREEN=$'\033[32m'          # 5: weekly title
LIME=$'\033[38;5;148m'     # 6: weekly value
YELLOW=$'\033[33m'         # 7: weekly time%
ORANGE=$'\033[38;5;208m'   # 8: sonnet title
RED=$'\033[31m'            # 9: sonnet value
```

Standard ANSI colors (codes 30-37) work everywhere. The three 256-color values (Teal, Lime, Orange) use `38;5;N` codes — these work in any modern terminal but may not render in very old terminal emulators.

For true color terminals, you can use `38;2;R;G;B` for exact RGB values.

## Without ccburn

The script degrades gracefully. If ccburn isn't installed or the cache is empty, the status line shows only the context percentage and git branch:

```
ctx:42%    main
```

## How it works

Claude Code pipes JSON to the status line command via stdin on each render. The JSON includes `used_percentage` (context window) and `cwd` (working directory). This script parses that, runs `git rev-parse` for the branch name, and reads cached ccburn output for quota data.

The ccburn cache refreshes every 15 minutes by default (configurable). Between API polls, the session countdown timer is interpolated from the local clock so it ticks down on every render. The weekly time-elapsed percentage is always computed from the local clock and is never stale.

### Expired window handling

When the Anthropic API returns stale data during a weekly window rollover (utilization still showing last week's value after `resets_at` has passed), the script detects negative `resets_in_hours` values in ccburn's JSON output and overrides the display to 0%. This prevents showing misleading high-usage numbers at the start of a fresh window.

### Rate limit handling

When a ccburn API refresh fails (typically due to HTTP 429 rate limiting), the script:
1. Creates a sentinel file (`~/.claude/.ccburn-ratelimited`) to flag the condition
2. Continues displaying cached data with the session timer interpolating from the local clock
3. Shows a red `[RL]` indicator at the right end of the status line
4. Clears the flag and indicator on the next successful refresh

## License

MIT
