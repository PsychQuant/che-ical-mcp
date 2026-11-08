#!/usr/bin/env bash
# Compute the reminder dates of one use-it-or-lose-it quota (the contract is plugin/skills/quota/SKILL.md, #327).
#
# Usage:
#   quota-dates.sh --cadence weekly  --weekday <1-7> [options]     1=Sunday ... 7=Saturday (EventKit numbering)
#   quota-dates.sh --cadence monthly --day <1-31>    [options]     29-31 are clamped to the month's last day
# Options:
#   --time HH:MM          reset time in --reset-tz; without it the reset is a date-only day (no zone conversion)
#   --reset-tz ZONE       IANA zone of --time (default UTC)
#   --lead-minutes N      timed reset: due = reset - N minutes (default 0)
#   --lead-days N         date-only reset: due day = reset day - N days (default 0)
#   --notify-at HH:MM     timed reset only: an alarm at the latest local HH:MM strictly before the due
#   --from WHEN           list periods whose reset is after WHEN (epoch seconds or YYYY-MM-DDTHH:MM:SS±HH:MM; default now)
#   --count N             periods to list (default 3)
#   --horizon-days N      instead of --count: every period whose due falls within N days of --from (at least one)
#   --local-tz ZONE       zone the reminders run in (default: the host zone)
#
# stdout, one line each:
#   period <n> reset=<ISO in reset zone, or YYYY-MM-DD> due=<ISO local with offset, or YYYY-MM-DD> [alarm_minutes=<M>]
#   rule weekly days_of_week=<w> due_time=<HH:MM|date-only> [alarm_minutes=<M>]
#   rule monthly days_of_month=<d> due_time=<HH:MM|date-only> [alarm_minutes=<M>]
#   rule none reason=<why>
# The rule line says whether ONE recurrence rule in the local zone reproduces every due (and alarm offset) over
# 104 weeks or 24 months from the first period. Exit codes: 0 ok, 2 bad arguments (message on stderr).
set -u

die() { echo "quota-dates.sh: $*" >&2; exit 2; }

cadence="" weekday="" day="" time="" reset_tz="UTC" lead_minutes=0 lead_days=0 notify_at=""
from="" count=3 horizon="" local_tz=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "missing value for $1"
  case "$1" in
    --cadence) cadence="$2" ;;
    --weekday) weekday="$2" ;;
    --day) day="$2" ;;
    --time) time="$2" ;;
    --reset-tz) reset_tz="$2" ;;
    --lead-minutes) lead_minutes="$2" ;;
    --lead-days) lead_days="$2" ;;
    --notify-at) notify_at="$2" ;;
    --from) from="$2" ;;
    --count) count="$2" ;;
    --horizon-days) horizon="$2" ;;
    --local-tz) local_tz="$2" ;;
    *) die "unknown option $1" ;;
  esac
  shift 2
done

is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_hhmm() {
  case "$1" in [0-2][0-9]:[0-5][0-9]) [ "${1%%:*}" -le 23 ] ;; *) return 1 ;; esac
}
zone_ok() { [ -f "/usr/share/zoneinfo/$1" ] && case "$1" in *..*|/*) return 1 ;; *) return 0 ;; esac; }

case "$cadence" in
  weekly) is_int "$weekday" && [ "$weekday" -ge 1 ] && [ "$weekday" -le 7 ] || die "--weekday must be 1-7 (1=Sunday)"
          [ -z "$day" ] || die "--day is for monthly quotas" ;;
  monthly) is_int "$day" && [ "$day" -ge 1 ] && [ "$day" -le 31 ] || die "--day must be 1-31"
           [ -z "$weekday" ] || die "--weekday is for weekly quotas" ;;
  *) die "--cadence must be weekly or monthly" ;;
esac
[ -z "$time" ] || is_hhmm "$time" || die "--time must be HH:MM"
zone_ok "$reset_tz" || die "unknown --reset-tz: $reset_tz"
[ -z "$local_tz" ] || zone_ok "$local_tz" || die "unknown --local-tz: $local_tz"
is_int "$lead_minutes" || die "--lead-minutes must be a whole number"
is_int "$lead_days" || die "--lead-days must be a whole number"
is_int "$count" && [ "$count" -ge 1 ] || die "--count must be 1 or more"
[ -z "$horizon" ] || { is_int "$horizon" && [ "$horizon" -ge 1 ]; } || die "--horizon-days must be 1 or more"
if [ -n "$time" ]; then
  [ "$lead_days" -eq 0 ] || die "--lead-days is for a date-only reset; use --lead-minutes with --time"
  [ -z "$notify_at" ] || is_hhmm "$notify_at" || die "--notify-at must be HH:MM"
else
  [ "$lead_minutes" -eq 0 ] || die "--lead-minutes needs --time (a date-only reset has no time)"
  [ -z "$notify_at" ] || die "--notify-at needs --time: a date-only reminder takes no alarm"
fi

# --- time helpers (BSD date) -------------------------------------------------------------------
in_local() { if [ -n "$local_tz" ]; then TZ="$local_tz" "$@"; else "$@"; fi; }
iso_offset() { sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/'; }
epoch_in() {  # zone "YYYY-MM-DD HH:MM:SS" -> epoch
  TZ="$1" date -j -f "%Y-%m-%d %H:%M:%S" "$2" +%s 2>/dev/null || die "cannot read time $2 in $1"
}
add_days() {  # YYYY-MM-DD N -> YYYY-MM-DD (calendar arithmetic, zone-free)
  TZ=UTC date -j -v"${2}"d -f "%Y-%m-%d %H:%M:%S" "$1 12:00:00" +%Y-%m-%d
}
weekday_of() { echo $(( $(TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "$1 12:00:00" +%w) + 1 )); }
month_len() { TZ=UTC date -j -v1d -v+1m -v-1d -f "%Y-%m-%d %H:%M:%S" "$1-01 12:00:00" +%d; }
add_months() { TZ=UTC date -j -v"${2}"m -f "%Y-%m-%d %H:%M:%S" "$1-01 12:00:00" +%Y-%m; }

if [ -z "$from" ]; then
  from_epoch="$(date +%s)"
elif is_int "$from"; then
  from_epoch="$from"
else
  f="$(printf '%s' "$from" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/; s/Z$/+0000/')"
  from_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$f" +%s 2>/dev/null)" || die "cannot read --from $from"
fi

# Start scanning from the --from day (in the reset zone for a timed reset, else in the local zone), minus a margin.
if [ -n "$time" ]; then
  start_day="$(TZ="$reset_tz" date -r "$from_epoch" +%Y-%m-%d)"
else
  start_day="$(in_local date -r "$from_epoch" +%Y-%m-%d)"
fi
start_day="$(add_days "$start_day" -1)"

# The n-th reset day (n = 0, 1, ...) at or after start_day.
first_weekly=""
nth_reset_day() {
  if [ "$cadence" = weekly ]; then
    if [ -z "$first_weekly" ]; then
      local d="$start_day" i=0
      while [ "$(weekday_of "$d")" -ne "$weekday" ]; do d="$(add_days "$d" +1)"; i=$((i + 1)); done
      first_weekly="$d"
    fi
    add_days "$first_weekly" "+$(( $1 * 7 ))"
  else
    local ym len dd
    ym="$(add_months "${start_day%-*}" "+$1")"
    len="$(month_len "$ym")"
    dd="$day"; [ "$dd" -le "$len" ] || dd="$len"
    printf '%s-%02d\n' "$ym" "$dd"
  fi
}

# Fill: RESET_TXT DUE_TXT DUE_EPOCH (sort key) ALARM DUE_KEY for reset day $1.
compute() {
  local rd="$1"
  ALARM=""
  if [ -n "$time" ]; then
    local re due ld cand
    re="$(epoch_in "$reset_tz" "$rd $time:00")"
    RESET_EPOCH="$re"
    RESET_TXT="$(TZ="$reset_tz" date -r "$re" +%Y-%m-%dT%H:%M:%S%z | iso_offset)"
    due=$(( re - lead_minutes * 60 ))
    DUE_EPOCH="$due"
    DUE_TXT="$(in_local date -r "$due" +%Y-%m-%dT%H:%M:%S%z | iso_offset)"
    if [ -n "$notify_at" ]; then
      ld="$(in_local date -r "$due" +%Y-%m-%d)"
      cand="$(in_local date -j -f "%Y-%m-%d %H:%M:%S" "$ld $notify_at:00" +%s)"
      if [ "$cand" -ge "$due" ]; then
        cand="$(in_local date -j -f "%Y-%m-%d %H:%M:%S" "$(add_days "$ld" -1) $notify_at:00" +%s)"
      fi
      ALARM=$(( (due - cand) / 60 ))
    fi
    if [ "$cadence" = weekly ]; then
      DUE_KEY="$(in_local date -r "$due" +"%w %H:%M")"
    else
      DUE_KEY="$(in_local date -r "$due" +"%d %H:%M")"
    fi
  else
    RESET_EPOCH="$(in_local date -j -f "%Y-%m-%d %H:%M:%S" "$rd 23:59:59" +%s)"
    RESET_TXT="$rd"
    local dd
    dd="$(add_days "$rd" "-$lead_days")"
    DUE_TXT="$dd"
    DUE_EPOCH="$(in_local date -j -f "%Y-%m-%d %H:%M:%S" "$dd 23:59:59" +%s)"
    if [ "$cadence" = weekly ]; then
      DUE_KEY="$(( $(weekday_of "$dd") - 1 )) date-only"
    else
      DUE_KEY="${dd##*-} date-only"
    fi
  fi
  DUE_KEY="$DUE_KEY $ALARM"
}

# --- list periods -------------------------------------------------------------------------------
limit_epoch=""
[ -z "$horizon" ] || limit_epoch=$(( from_epoch + horizon * 86400 ))
n=0 listed=0 first_n=""
while :; do
  compute "$(nth_reset_day "$n")"
  if [ "$RESET_EPOCH" -gt "$from_epoch" ]; then
    if [ -n "$limit_epoch" ]; then
      [ "$listed" -eq 0 ] || [ "$DUE_EPOCH" -le "$limit_epoch" ] || break
    else
      [ "$listed" -lt "$count" ] || break
    fi
    [ -n "$first_n" ] || first_n="$n"
    listed=$((listed + 1))
    line="period $listed reset=$RESET_TXT due=$DUE_TXT"
    [ -z "$ALARM" ] || line="$line alarm_minutes=$ALARM"
    echo "$line"
  fi
  n=$((n + 1))
  [ "$n" -lt 2000 ] || die "no period found"
done

# --- does one recurrence rule fit? --------------------------------------------------------------
if [ "$cadence" = weekly ]; then span=104; else span=24; fi
compute "$(nth_reset_day "$first_n")"
key0="$DUE_KEY"
fits=1 reason=""
i=1
while [ "$i" -lt "$span" ]; do
  compute "$(nth_reset_day $(( first_n + i )))"
  if [ "$DUE_KEY" != "$key0" ]; then
    fits=0
    reason="the local due or alarm changes (period $((i + 1)) of the next $span: ${DUE_TXT})"
    break
  fi
  i=$((i + 1))
done

if [ "$fits" -eq 1 ]; then
  set -- $key0
  if [ "$cadence" = weekly ]; then
    out="rule weekly days_of_week=$(( $1 + 1 ))"
  else
    out="rule monthly days_of_month=$((10#$1))"
  fi
  out="$out due_time=$2"
  [ -z "${3:-}" ] || out="$out alarm_minutes=$3"
  echo "$out"
else
  echo "rule none reason=$reason"
fi
