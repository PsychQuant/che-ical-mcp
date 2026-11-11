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
#   --previous            also list the latest period whose reset is not after --from, as period 0
#   --horizon-days N      instead of --count: every period whose due falls within N days of --from (at least one)
#   --local-tz ZONE       zone the reminders run in (default: the host zone)
#
# Numbers are decimal (08 is eight). A lead of one whole period or more is refused (weekly: 7 days, 10080
# minutes; monthly: 28 days, 40320 minutes, the shortest month). A reset time that daylight saving time skips
# reads as the time after the jump.
#
# stdout, one line each:
#   cycle <weekly-<weekday name>|monthly-<day>>   first: what sets the keys, canonical (weekly-monday, monthly-8)
#   period <n> key=<reset day YYYY-MM-DD> state=<past|current|future> reset=<ISO in reset zone, or YYYY-MM-DD>
#          due=<ISO local with offset, or YYYY-MM-DD> [alarm_minutes=<M>]
#   key is the period's identity: the reset day in the reset zone. state: past = period 0 (--previous), current =
#   period 1 (the first reset after --from), future = the rest.
#   rule weekly days_of_week=<w> due_time=<HH:MM|date-only> [alarm_minutes=<M>]
#   rule monthly days_of_month=<d> due_time=<HH:MM|date-only> [alarm_minutes=<M>]
#   rule none reason=<why>
# The rule line says whether ONE recurrence rule in the local zone reproduces every due (and alarm offset) over
# 104 weeks or 24 months from the first period. Exit codes: 0 ok, 2 bad arguments (message on stderr).
set -u

die() { echo "quota-dates.sh: $*" >&2; exit 2; }

cadence="" weekday="" day="" time="" reset_tz="UTC" lead_minutes=0 lead_days=0 notify_at=""
from="" count=3 horizon="" local_tz="" previous=0
while [ $# -gt 0 ]; do
  if [ "$1" = "--previous" ]; then previous=1; shift; continue; fi
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

is_int() {  # digits only, at most 6 (a longer number would wrap in 64-bit arithmetic)
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 6 ]
}
is_hhmm() {
  case "$1" in [0-2][0-9]:[0-5][0-9]) [ "${1%%:*}" -le 23 ] ;; *) return 1 ;; esac
}
zone_ok() {  # an IANA zone: a compiled zone file (TZif magic) under /usr/share/zoneinfo, no path escape
  case "$1" in ''|*..*|/*) return 1 ;; esac
  [ -f "/usr/share/zoneinfo/$1" ] && [ "$(head -c 4 "/usr/share/zoneinfo/$1" 2>/dev/null)" = "TZif" ]
}

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
# Validated above as digits only; from here on every number is read as decimal (08 is not octal).
[ -z "$weekday" ] || weekday=$((10#$weekday))
[ -z "$day" ] || day=$((10#$day))
lead_minutes=$((10#$lead_minutes)); lead_days=$((10#$lead_days)); count=$((10#$count))
[ -z "$horizon" ] || horizon=$((10#$horizon))
if [ "$cadence" = weekly ]; then max_days=7; else max_days=28; fi
[ "$lead_minutes" -lt $((max_days * 1440)) ] && [ "$lead_days" -lt "$max_days" ] \
  || die "a lead of one whole period or more is refused ($cadence: $max_days days)"
if [ -n "$time" ]; then
  [ "$lead_days" -eq 0 ] || die "--lead-days is for a date-only reset; use --lead-minutes with --time"
  [ -z "$notify_at" ] || is_hhmm "$notify_at" || die "--notify-at must be HH:MM"
else
  [ "$lead_minutes" -eq 0 ] || die "--lead-minutes needs --time (a date-only reset has no time)"
  [ -z "$notify_at" ] || die "--notify-at needs --time: a date-only reminder takes no alarm"
fi
# The cycle: what sets the period keys (cadence and weekday or day), nothing else. Time, zone, leads and alarms
# move dues, never keys, so they are not in it. One canonical token per key sequence (#499 r10).
if [ "$cadence" = weekly ]; then
  set -- sunday monday tuesday wednesday thursday friday saturday
  cycle="weekly-${!weekday}"
else
  cycle="monthly-$day"
fi
set --

# --- time helpers (BSD date) -------------------------------------------------------------------
in_local() { if [ -n "$local_tz" ]; then TZ="$local_tz" "$@"; else "$@"; fi; }
iso_offset() { sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/'; }
epoch_in() {  # zone "YYYY-MM-DD HH:MM:SS" -> epoch
  TZ="$1" date -j -f "%Y-%m-%d %H:%M:%S" "$2" +%s 2>/dev/null || die "cannot read time $2 in $1"
}
add_days() {  # YYYY-MM-DD N -> YYYY-MM-DD (calendar arithmetic, zone-free)
  TZ=UTC date -j -v"${2}"d -f "%Y-%m-%d %H:%M:%S" "$1 12:00:00" +%Y-%m-%d
}
weekday_of() {  # 1=Sunday ... 7=Saturday; fails (no output) when the day cannot be read
  local w; w="$(TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "$1 12:00:00" +%w 2>/dev/null)" || return 1
  [ -n "$w" ] || return 1
  echo $(( w + 1 ))
}
month_len() { TZ=UTC date -j -v1d -v+1m -v-1d -f "%Y-%m-%d %H:%M:%S" "$1-01 12:00:00" +%d; }
add_months() { TZ=UTC date -j -v"${2}"m -f "%Y-%m-%d %H:%M:%S" "$1-01 12:00:00" +%Y-%m; }

if [ -z "$from" ]; then
  from_epoch="$(date +%s)"
elif case "$from" in ''|*[!0-9]*) false ;; *) [ "${#from}" -le 12 ] ;; esac; then
  from_epoch=$((10#$from))
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
start_day="$(add_days "$start_day" -35)"   # far enough back for the previous period of a month

# Set RD to the n-th reset day (n = 0, 1, ...) at or after start_day. Runs in the main shell (no command
# substitution), so the weekly anchor is found once and a failure stops the script.
first_weekly=""
nth_reset_day() {
  if [ "$cadence" = weekly ]; then
    if [ -z "$first_weekly" ]; then
      local d="$start_day" w i=0
      while :; do
        w="$(weekday_of "$d")" || die "cannot read the weekday of $d"
        [ "$w" -ne "$weekday" ] || break
        d="$(add_days "$d" +1)" || die "cannot step from $d"
        i=$((i + 1)); [ "$i" -lt 8 ] || die "no weekday $weekday found"
      done
      first_weekly="$d"
    fi
    RD="$(add_days "$first_weekly" "+$(( $1 * 7 ))")" || die "cannot step the week"
  else
    local ym len dd
    ym="$(add_months "${start_day%-*}" "+$1")" || die "cannot step the month"
    len="$(month_len "$ym")" || die "cannot read the length of $ym"
    dd="$day"; [ "$dd" -le "$((10#$len))" ] || dd="$((10#$len))"
    RD="$(printf '%s-%02d' "$ym" "$dd")"
  fi
}

# Fill: RESET_TXT DUE_TXT DUE_EPOCH (sort key) ALARM DUE_KEY for reset day $1.
compute() {
  local rd="$1"
  ALARM=""
  if [ -n "$time" ]; then
    local re due ld cand
    re="$(epoch_in "$reset_tz" "$rd $time:00")" || exit 2
    RESET_EPOCH="$re"
    RESET_TXT="$(TZ="$reset_tz" date -r "$re" +%Y-%m-%dT%H:%M:%S%z | iso_offset)"
    [ -n "$RESET_TXT" ] || die "cannot format the reset of $rd"
    due=$(( re - lead_minutes * 60 ))
    DUE_EPOCH="$due"
    DUE_TXT="$(in_local date -r "$due" +%Y-%m-%dT%H:%M:%S%z | iso_offset)"
    [ -n "$DUE_TXT" ] || die "cannot format the due of $rd"
    if [ -n "$notify_at" ]; then
      ld="$(in_local date -r "$due" +%Y-%m-%d)" || die "cannot read the due day of $rd"
      cand="$(in_local date -j -f "%Y-%m-%d %H:%M:%S" "$ld $notify_at:00" +%s)" || die "cannot read $notify_at on $ld"
      if [ "$cand" -ge "$due" ]; then
        cand="$(in_local date -j -f "%Y-%m-%d %H:%M:%S" "$(add_days "$ld" -1) $notify_at:00" +%s)" || die "cannot read $notify_at before $ld"
      fi
      ALARM=$(( (due - cand) / 60 ))
    fi
    if [ "$cadence" = weekly ]; then
      DUE_KEY="$(in_local date -r "$due" +"%w %H:%M")" || die "cannot read the due of $rd"
    else
      DUE_KEY="$(in_local date -r "$due" +"%d %H:%M")" || die "cannot read the due of $rd"
    fi
  else
    RESET_EPOCH="$(in_local date -j -f "%Y-%m-%d %H:%M:%S" "$rd 23:59:59" +%s)" || die "cannot read the reset day $rd"
    RESET_TXT="$rd"
    local dd
    dd="$(add_days "$rd" "-$lead_days")" || die "cannot step back from $rd"
    DUE_TXT="$dd"
    DUE_EPOCH="$(in_local date -j -f "%Y-%m-%d %H:%M:%S" "$dd 23:59:59" +%s)" || die "cannot read the due day $dd"
    if [ "$cadence" = weekly ]; then
      wd="$(weekday_of "$dd")" || die "cannot read the weekday of $dd"
      DUE_KEY="$(( wd - 1 )) date-only"
    else
      DUE_KEY="${dd##*-} date-only"
    fi
  fi
  DUE_KEY="$DUE_KEY $ALARM"
}

# --- list periods -------------------------------------------------------------------------------
limit_epoch=""
[ -z "$horizon" ] || limit_epoch=$(( from_epoch + horizon * 86400 ))
n=0 listed=0 first_n="" prev_line=""
echo "cycle $cycle"
period_line() {  # number state
  PLINE="period $1 key=$RD state=$2 reset=$RESET_TXT due=$DUE_TXT"
  [ -z "$ALARM" ] || PLINE="$PLINE alarm_minutes=$ALARM"
}
while :; do
  nth_reset_day "$n"; compute "$RD"
  if [ "$RESET_EPOCH" -le "$from_epoch" ]; then
    period_line 0 past; prev_line="$PLINE"
  else
    if [ -n "$limit_epoch" ]; then
      [ "$listed" -eq 0 ] || [ "$DUE_EPOCH" -le "$limit_epoch" ] || break
    else
      [ "$listed" -lt "$count" ] || break
    fi
    if [ -z "$first_n" ]; then
      first_n="$n"
      if [ "$previous" -eq 1 ]; then
        [ -n "$prev_line" ] || die "no previous period found"
        echo "$prev_line"
      fi
    fi
    listed=$((listed + 1))
    if [ "$listed" -eq 1 ]; then period_line 1 current; else period_line "$listed" future; fi
    echo "$PLINE"
  fi
  n=$((n + 1))
  [ "$n" -lt 2000 ] || die "no period found"
done

# --- does one recurrence rule fit? --------------------------------------------------------------
if [ "$cadence" = weekly ]; then span=104; else span=24; fi
nth_reset_day "$first_n"; compute "$RD"
key0="$DUE_KEY"
fits=1 reason=""
i=1
while [ "$i" -lt "$span" ]; do
  nth_reset_day $(( first_n + i )); compute "$RD"
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
