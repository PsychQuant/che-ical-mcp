#!/usr/bin/env bash
# Tests for plugin/bin/quota-plan.sh (#327 verify round 2). Periods come from quota-dates.sh with a fixed
# --from and --local-tz; reminders are fictional. Run: bash plugin/bin/tests/quota-plan.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DATES="$HERE/../quota-dates.sh"
PLAN="$HERE/../quota-plan.sh"
pass=0 fail=0
TPE=Asia/Taipei

# check <name> <expected lines (grep -x each)> <unexpected substring or ""> -- <plan args> ; stdin = input
check() {
  local name="$1" want="$2" unwanted="$3"; shift 4
  local got; got="$(bash "$PLAN" "$@" 2>&1)"
  local ok=1 line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s\n' "$got" | grep -qxF -- "$line" || ok=0
  done <<< "$want"
  [ -z "$unwanted" ] || ! printf '%s\n' "$got" | grep -qF -- "$unwanted" || ok=0
  if [ "$ok" -eq 1 ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL %s\n--- want\n%s\n--- not\n%s\n--- got\n%s\n' "$name" "$want" "$unwanted" "$got"; fi
}
periods() { bash "$DATES" "$@" --previous --local-tz "$TPE"; }
NOW=2026-11-09T10:00:00+08:00
W19=(--cadence weekly --weekday 2 --time 19:00 --lead-minutes 30 --horizon-days 90 --from "$NOW")
W20=(--cadence weekly --weekday 2 --time 20:00 --lead-minutes 30 --horizon-days 90 --from "$NOW")
W21=(--cadence weekly --weekday 2 --time 21:00 --lead-minutes 30 --horizon-days 90 --from "$NOW")

# The reset moves EARLIER (20:00 -> 19:00 UTC), this week not used: the open reminder goes to THIS week's new
# due (02:30), not to next week (round 2 HIGH 1-2: the open reminder's own period is not history).
check "rule, reset earlier, unticked" "reminder A class=off-schedule period=1
used none
boundary none
action move A 1" "action move A 2" -- --now "$NOW" --local-tz "$TPE" --repair <<EOF
$(periods "${W19[@]}")
reminder A open 2026-11-10T03:30:00 -
EOF

# Same change after the user ticked this week: the completed copy is history for period 1, so the open
# reminder (already on next week) goes to next week's new due, never back to this week.
check "rule, reset earlier, ticked" "reminder C class=history period=1
reminder A class=off-schedule period=2
used 1
boundary 1
action move A 2" "action move A 1" -- --now "$NOW" --local-tz "$TPE" --repair <<EOF
$(periods "${W19[@]}")
reminder C completed 2026-11-10T03:30:00 -
reminder A open 2026-11-17T03:30:00 -
EOF

# The reset moves LATER (20:00 -> 21:00 UTC): this week's reminder moves to 04:30 of the same week.
check "rule, reset later, unticked" "reminder A class=off-schedule period=1
action move A 1" "" -- --now "$NOW" --local-tz "$TPE" --repair <<EOF
$(periods "${W21[@]}")
reminder A open 2026-11-10T03:30:00 -
EOF

# Nothing changed: the series is running; a ticked period before it is used.
check "rule, running" "reminder C class=matched period=1
reminder A class=matched period=2
used 1
action keep A 2" "action create" -- --now "$NOW" --local-tz "$TPE" <<EOF
$(periods "${W20[@]}")
reminder C completed 2026-11-10T03:30:00 -
reminder A open 2026-11-17T03:30:00 -
EOF

# A stall of two periods (round 2 MEDIUM 6): the open reminder is older than period 0; the restart starts at
# the first period whose reset is ahead, never at period 0.
check "rule, stalled two periods" "reminder A class=past-record period=-
action restart A 1" "action restart A 0" -- --now 2026-12-01T10:00:00+08:00 --local-tz "$TPE" <<EOF
$(bash "$DATES" --cadence weekly --weekday 2 --time 20:00 --lead-minutes 30 --horizon-days 90 --previous --from 2026-12-01T10:00:00+08:00 --local-tz "$TPE")
reminder A open 2026-11-17T03:30:00 -
EOF

# Without --repair, an open reminder that matches no period (dates edited by hand) creates nothing (MEDIUM 8).
check "off schedule without repair" "action repair-needed" "action create" -- --now "$NOW" --local-tz "$TPE" <<EOF
$(periods "${W19[@]}")
reminder A open 2026-11-10T03:30:00 -
EOF

M31=(--cadence monthly --day 31 --horizon-days 90)
# Per-period, several future reminders, the time changes but not the day: each keeps its own period (key).
check "per-period, several future reminders, keys kept" "reminder N class=matched period=1
reminder D class=matched period=2
reminder J class=matched period=3
used none
action keep N 1
action keep D 2
action keep J 3" "action move" -- --now "$NOW" --local-tz "$TPE" --repair <<EOF
$(periods "${M31[@]}" --time 12:00 --from "$NOW")
reminder N open 2026-11-30T08:00:00 2026-11-30
reminder D open 2026-12-31T08:00:00 2026-12-31
reminder J open 2027-01-31T08:00:00 2027-01-31
EOF

# Per-period, the day changes (31 -> 30): November's key stays (both clamp to Nov 30) and is kept; the other
# keys change, and those reminders are re-paired in due order with the free periods, none skipped or doubled.
check "per-period, day changed, re-paired in order" "action keep N 1
action move D 2
action move J 3" "leftover" -- --now "$NOW" --local-tz "$TPE" --repair <<EOF
$(periods --cadence monthly --day 30 --horizon-days 90 --from "$NOW")
reminder N open 2026-11-30 2026-11-30
reminder D open 2026-12-31 2026-12-31
reminder J open 2027-01-31 2027-01-31
EOF

# Per-period, a period ticked early and then cleaned up: it is not recreated (MEDIUM 7); a period after the
# last one the skill created is.
check "per-period, cleaned-up period not recreated" "action missing 1
action keep J 2
action create 3" "action create 1" -- --now 2026-12-05T10:00:00+08:00 --local-tz "$TPE" --through 2027-01-31 <<EOF
$(bash "$DATES" "${M31[@]}" --previous --from 2026-12-05T10:00:00+08:00 --local-tz "$TPE")
reminder J open 2027-01-31 2027-01-31
EOF

# Per-period first run: every period of the 90 days is created.
check "per-period, first run" "action create 1
action create 2
action create 3" "" -- --now "$NOW" --local-tz "$TPE" <<EOF
$(periods "${M31[@]}" --from "$NOW")
EOF

# An open reminder exactly between two periods is not guessed.
check "ambiguous" "reminder X class=ambiguous period=1
action list X ambiguous" "" -- --now "$NOW" --local-tz "$TPE" --repair <<EOF
$(periods "${W20[@]}")
reminder X open 2026-11-13T15:30:00 -
EOF

err() {
  local name="$1" want="$2"; shift 2
  local out rc; out="$(bash "$PLAN" "$@" 2>&1 >/dev/null </dev/null)"; rc=$?
  if [ "$rc" -eq 2 ] && [[ "$out" == *"$want"* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL %s: rc=%s [%s]\n' "$name" "$rc" "$out"; fi
}
err "--now required" "--now is required"
err "bad --through" "--through must be YYYY-MM-DD" --now "$NOW" --through 2026-1-1
err "no input" "no rule line" --now "$NOW"

echo "quota-plan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
