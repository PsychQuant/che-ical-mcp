#!/usr/bin/env bash
# Tests for plugin/bin/quota-dates.sh (#327). Every case pins --from and --local-tz, so the host zone
# and the clock do not matter. Run: bash plugin/bin/tests/quota-dates.test.sh   (exit 0 = all pass)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HELPER="$HERE/../quota-dates.sh"
fail=0 pass=0

# expect <name> <expected stdout> -- <args...>
expect() {
  local name="$1" want="$2"; shift 3
  local got
  got="$(bash "$HELPER" "$@" 2>&1)"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n--- want\n%s\n--- got\n%s\n' "$name" "$want" "$got"
  fi
}

# expect_error <name> <stderr substring> -- <args...>: exit 2, nothing on stdout.
expect_error() {
  local name="$1" want="$2"; shift 3
  local out err code
  err="$(bash "$HELPER" "$@" 2>&1 >/dev/null)"; code=$?
  out="$(bash "$HELPER" "$@" 2>/dev/null)"
  if [ "$code" -eq 2 ] && [ -z "$out" ] && [[ "$err" == *"$want"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s: exit %s, stdout [%s], stderr [%s], wanted [%s]\n' "$name" "$code" "$out" "$err" "$want"
  fi
}

TPE=(--local-tz Asia/Taipei)
FROM=(--from 2026-11-09T10:00:00+08:00)

# A weekly reset at night: the due stays at the deadline (reset minus lead) and the alarm is the
# evening before (decision record row 4, corrected 2026-10-20). Monday 20:00 UTC = Tuesday 04:00 local.
expect "weekly timed, lead, notify-at" "period 1 reset=2026-11-09T20:00:00+00:00 due=2026-11-10T03:30:00+08:00 alarm_minutes=330
period 2 reset=2026-11-16T20:00:00+00:00 due=2026-11-17T03:30:00+08:00 alarm_minutes=330
period 3 reset=2026-11-23T20:00:00+00:00 due=2026-11-24T03:30:00+08:00 alarm_minutes=330
rule weekly days_of_week=3 due_time=03:30 alarm_minutes=330" -- \
  --cadence weekly --weekday 2 --time 20:00 --reset-tz UTC --lead-minutes 30 --notify-at 22:00 "${FROM[@]}" "${TPE[@]}"

# notify-at later in the day than the due: the alarm is the day before, never after the due.
expect "notify-at after due time goes to the previous day" "period 1 reset=2026-11-10T09:00:00+08:00 due=2026-11-10T09:00:00+08:00 alarm_minutes=660
rule weekly days_of_week=3 due_time=09:00 alarm_minutes=660" -- \
  --cadence weekly --weekday 3 --time 09:00 --reset-tz Asia/Taipei --notify-at 22:00 --count 1 "${FROM[@]}" "${TPE[@]}"

# A monthly date-only credit expiry, reminded the day before: no zone conversion, no alarm.
expect "monthly date-only, lead-days" "period 1 reset=2026-11-18 due=2026-11-17
period 2 reset=2026-12-18 due=2026-12-17
period 3 reset=2027-01-18 due=2027-01-17
rule monthly days_of_month=17 due_time=date-only" -- \
  --cadence monthly --day 18 --lead-days 1 "${FROM[@]}" "${TPE[@]}"

# A monthly UTC reset whose local due keeps one day and time: one rule fits.
expect "monthly timed UTC, rule fits" "period 1 reset=2026-11-18T00:00:00+00:00 due=2026-11-18T07:30:00+08:00
rule monthly days_of_month=18 due_time=07:30" -- \
  --cadence monthly --day 18 --time 00:00 --lead-minutes 30 --count 1 "${FROM[@]}" "${TPE[@]}"

# Day 31 follows the clamp rule (last day of a shorter month, back to 31): no single rule fits.
expect "monthly day 31 clamps" "period 1 reset=2026-11-30T00:00:00+00:00 due=2026-11-30T08:00:00+08:00
period 2 reset=2026-12-31T00:00:00+00:00 due=2026-12-31T08:00:00+08:00
period 3 reset=2027-01-31T00:00:00+00:00 due=2027-01-31T08:00:00+08:00
period 4 reset=2027-02-28T00:00:00+00:00 due=2027-02-28T08:00:00+08:00
rule none reason=the local due or alarm changes (period 2 of the next 24: 2026-12-31T08:00:00+08:00)" -- \
  --cadence monthly --day 31 --time 00:00 --count 4 "${FROM[@]}" "${TPE[@]}"

# Leap year: day 30 lands on February 29.
expect "monthly day 30 in a leap February" "period 1 reset=2028-01-30 due=2028-01-30
period 2 reset=2028-02-29 due=2028-02-29
period 3 reset=2028-03-30 due=2028-03-30
rule none reason=the local due or alarm changes (period 2 of the next 24: 2028-02-29)" -- \
  --cadence monthly --day 30 --from 2028-01-15T00:00:00+08:00 "${TPE[@]}"

# A reset zone with daylight saving time against a local zone without it: the local due moves an hour.
expect "DST in the reset zone, horizon" "period 1 reset=2026-11-10T05:00:00-08:00 due=2026-11-10T20:30:00+08:00
period 2 reset=2026-11-17T05:00:00-08:00 due=2026-11-17T20:30:00+08:00
period 3 reset=2026-11-24T05:00:00-08:00 due=2026-11-24T20:30:00+08:00
period 4 reset=2026-12-01T05:00:00-08:00 due=2026-12-01T20:30:00+08:00
period 5 reset=2026-12-08T05:00:00-08:00 due=2026-12-08T20:30:00+08:00
rule none reason=the local due or alarm changes (period 19 of the next 104: 2027-03-16T19:30:00+08:00)" -- \
  --cadence weekly --weekday 3 --time 05:00 --reset-tz America/Los_Angeles --lead-minutes 30 --horizon-days 30 "${FROM[@]}" "${TPE[@]}"

# A lead time that crosses midnight into the previous month: the day of the month changes.
expect "lead crosses into the previous month" "period 1 reset=2026-12-01T00:10:00+00:00 due=2026-11-30T23:40:00+00:00
rule none reason=the local due or alarm changes (period 2 of the next 24: 2026-12-31T23:40:00+00:00)" -- \
  --cadence monthly --day 1 --time 00:10 --lead-minutes 30 --count 1 "${FROM[@]}" --local-tz UTC

# --from exactly at a reset: that period is over, the next one is listed.
expect "from at a reset lists the next period" "period 1 reset=2026-11-16T20:00:00+00:00 due=2026-11-17T04:00:00+08:00
rule weekly days_of_week=3 due_time=04:00" -- \
  --cadence weekly --weekday 2 --time 20:00 --count 1 --from 2026-11-09T20:00:00Z "${TPE[@]}"

# A reset that is past but whose due is today still counts while the reset is ahead.
expect "due passed, reset ahead" "period 1 reset=2026-11-09T20:00:00+00:00 due=2026-11-10T03:00:00+08:00
rule weekly days_of_week=3 due_time=03:00" -- \
  --cadence weekly --weekday 2 --time 20:00 --lead-minutes 60 --count 1 --from 2026-11-10T03:30:00+08:00 "${TPE[@]}"

expect_error "notify-at needs a time" "--notify-at needs --time" -- --cadence monthly --day 18 --notify-at 22:00 "${FROM[@]}"
expect_error "lead-minutes needs a time" "--lead-minutes needs --time" -- --cadence monthly --day 18 --lead-minutes 30 "${FROM[@]}"
expect_error "lead-days is date-only" "--lead-days is for a date-only reset" -- --cadence monthly --day 18 --time 00:00 --lead-days 1 "${FROM[@]}"
expect_error "weekday range" "--weekday must be 1-7" -- --cadence weekly --weekday 8 --time 00:00 "${FROM[@]}"
expect_error "day range" "--day must be 1-31" -- --cadence monthly --day 0 "${FROM[@]}"
expect_error "day on weekly" "--day is for monthly" -- --cadence weekly --weekday 2 --day 3 "${FROM[@]}"
expect_error "unknown zone" "unknown --reset-tz" -- --cadence weekly --weekday 2 --time 00:00 --reset-tz Mars/Base "${FROM[@]}"
expect_error "zone path escape" "unknown --reset-tz" -- --cadence weekly --weekday 2 --time 00:00 --reset-tz ../../etc/passwd "${FROM[@]}"
expect_error "bad time" "--time must be HH:MM" -- --cadence weekly --weekday 2 --time 24:00 "${FROM[@]}"
expect_error "bad cadence" "--cadence must be weekly or monthly" -- --cadence daily --day 1 "${FROM[@]}"
expect_error "unknown option" "unknown option --list" -- --cadence weekly --weekday 2 --list Quotas "${FROM[@]}"

echo "quota-dates: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
