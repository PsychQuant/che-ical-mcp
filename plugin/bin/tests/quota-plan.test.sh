#!/usr/bin/env bash
# Tests for plugin/bin/quota-plan.sh (#327 verify rounds 2-3). Periods come from quota-dates.sh with a fixed
# --from and --local-tz; reminders are fictional. Every case that writes asserts the due written (due=).
# Run: bash plugin/bin/tests/quota-plan.test.sh   (exit 0 = all pass)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DATES="$HERE/../quota-dates.sh"
PLAN="$HERE/../quota-plan.sh"
pass=0 fail=0
TPE=Asia/Taipei

# check <name> <expected lines> <unwanted substrings, |-separated, or ""> -- <plan args> ; stdin = input
check() {
  local name="$1" want="$2" unwanted="$3"; shift 4
  local got; got="$(bash "$PLAN" "$@" 2>&1)"
  local ok=1 line u
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s\n' "$got" | grep -qxF -- "$line" || ok=0
  done <<< "$want"
  if [ -n "$unwanted" ]; then
    IFS='|' read -r -a us <<< "$unwanted"
    for u in "${us[@]}"; do printf '%s\n' "$got" | grep -qF -- "$u" && ok=0; done
  fi
  if [ "$ok" -eq 1 ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL %s\n--- want\n%s\n--- not\n%s\n--- got\n%s\n' "$name" "$want" "$unwanted" "$got"; fi
}
NOW=2026-11-09T10:00:00+08:00
p() { bash "$DATES" "$@" --previous --horizon-days 90 --local-tz "$TPE"; }
W19="$(p --cadence weekly --weekday 2 --time 19:00 --lead-minutes 30 --notify-at 22:00 --from "$NOW")"
W20="$(p --cadence weekly --weekday 2 --time 20:00 --lead-minutes 30 --notify-at 22:00 --from "$NOW")"
W21="$(p --cadence weekly --weekday 2 --time 21:00 --lead-minutes 30 --notify-at 22:00 --from "$NOW")"
M31="$(p --cadence monthly --day 31 --from "$NOW")"
M31T12="$(p --cadence monthly --day 31 --time 12:00 --from "$NOW")"
M30="$(p --cadence monthly --day 30 --from "$NOW")"
M28="$(p --cadence monthly --day 28 --from "$NOW")"
RULE=(--now "$NOW" --written-mode rule)
PER=(--now "$NOW" --written-mode per-period)

# --- rule mode, the reset time moves (round 2 HIGH 1-2) ------------------------------------------------
check "rule, reset earlier, unticked" "reminder A class=off-schedule period=1 dates=differ
used none
action move A 1 due=2026-11-10T02:30:00+08:00" "action move A 2" -- "${RULE[@]}" --repair <<EOF
$W19
reminder A open 2026-11-10T03:30:00+08:00 - 330,0 list
EOF
check "rule, reset earlier, ticked" "reminder C class=history period=1 dates=-
used 1
action move A 2 due=2026-11-17T02:30:00+08:00" "action move A 1" -- "${RULE[@]}" --repair <<EOF
$W19
reminder C completed 2026-11-10T03:30:00+08:00 - - list
reminder A open 2026-11-17T03:30:00+08:00 - 330,0 list
EOF
check "rule, reset later, unticked" "action move A 1 due=2026-11-10T04:30:00+08:00" "" -- "${RULE[@]}" --repair <<EOF
$W21
reminder A open 2026-11-10T03:30:00+08:00 - 330,0 list
EOF
check "rule, running" "reminder A class=matched period=2 dates=ok
used 1
action keep A 2 due=2026-11-17T03:30:00+08:00" "action create|repair-needed" -- "${RULE[@]}" <<EOF
$W20
reminder C completed 2026-11-10T03:30:00+08:00 - - list
reminder A open 2026-11-17T03:30:00+08:00 - 330,0 list
EOF
# Alarms read back differ from the file (notify_at edited): a dates change, never a silent keep (round 3).
check "rule, alarms differ without repair" "action repair-needed dates-changed" "action keep" -- "${RULE[@]}" <<EOF
$W20
reminder A open 2026-11-10T03:30:00+08:00 - 0 list
EOF
# A leftover Period: line on a running series is ignored in rule mode (MEDIUM 11). On Nov 11 the week of
# Nov 9 has reset (period 0, ticked) and the series is on the current period.
check "rule, leftover Period line ignored" "reminder A class=matched period=1 dates=ok
action keep A 1 due=2026-11-17T03:30:00+08:00" "restart|past-record" -- --now 2026-11-11T10:00:00+08:00 --written-mode rule <<EOF
$(bash "$DATES" --cadence weekly --weekday 2 --time 20:00 --lead-minutes 30 --notify-at 22:00 --previous --horizon-days 90 --local-tz "$TPE" --from 2026-11-11T10:00:00+08:00)
reminder C completed 2026-11-10T03:30:00+08:00 2026-11-09 - list
reminder A open 2026-11-17T03:30:00+08:00 2026-11-09 330,0 list
EOF
# A stall of two periods (round 2 MEDIUM 6) restarts at period 1, never at period 0.
D1=2026-12-01T10:00:00+08:00
check "rule, stalled two periods" "reminder A class=past-record period=- dates=-
action restart A 1 due=2026-12-08T03:30:00+08:00" "restart A 0" -- --now "$D1" --written-mode rule <<EOF
$(bash "$DATES" --cadence weekly --weekday 2 --time 20:00 --lead-minutes 30 --notify-at 22:00 --previous --horizon-days 90 --local-tz "$TPE" --from "$D1")
reminder A open 2026-11-17T03:30:00+08:00 - 330,0 list
EOF
# Two open records after a second stall: the restart takes the latest one in either input order (MEDIUM 9).
D8=2026-12-08T10:00:00+08:00
P8="$(bash "$DATES" --cadence weekly --weekday 2 --time 20:00 --lead-minutes 30 --notify-at 22:00 --previous --horizon-days 90 --local-tz "$TPE" --from "$D8")"
check "restart picks the latest record (new first)" "action restart NEW 1 due=2026-12-15T03:30:00+08:00
action record OLD" "restart OLD" -- --now "$D8" --written-mode rule <<EOF
$P8
reminder NEW open 2026-12-01T03:30:00+08:00 - 330,0 list
reminder OLD open 2026-11-17T03:30:00+08:00 - 330,0 list
EOF
check "restart picks the latest record (old first)" "action restart NEW 1 due=2026-12-15T03:30:00+08:00
action record OLD" "restart OLD" -- --now "$D8" --written-mode rule <<EOF
$P8
reminder OLD open 2026-11-17T03:30:00+08:00 - 330,0 list
reminder NEW open 2026-12-01T03:30:00+08:00 - 330,0 list
EOF
check "off schedule without repair" "action repair-needed dates-changed" "action create" -- "${RULE[@]}" <<EOF
$W19
reminder A open 2026-11-10T03:30:00+08:00 - 330,0 list
EOF
check "written mode unknown" "action repair-needed written-mode-unknown" "action create|action keep" -- --now "$NOW" --written-mode unknown <<EOF
$W20
EOF

# --- mode transitions (round 3 HIGH 1, 3, 4) -----------------------------------------------------------
# per-period -> rule, day 31 -> 28, three open one-offs: they rolled past nothing, so the series starts on the
# current period with the earliest reminder.
check "per-period to rule, all open" "used none
action move N 1 due=2026-11-28
action leftover D
action leftover J" "used 1|action move N 3" -- "${PER[@]}" --repair <<EOF
$M28
reminder N open 2026-11-30 2026-11-30 none list
reminder D open 2026-12-31 2026-12-31 none list
reminder J open 2027-01-31 2027-01-31 none list
EOF
# rule -> per-period (notify_at added in a DST zone; the series is on period 2 and period 1's copy was cleaned
# up): the series rolled past period 1, so period 1 is used and never created again.
LA=(--cadence weekly --weekday 2 --time 20:00 --lead-minutes 30 --previous --horizon-days 90 --local-tz America/Los_Angeles --from 2026-11-09T10:00:00-08:00)
check "rule to per-period, rolled-past period kept used" "mode per-period
used 1
action rewrite A 2 due=2026-11-16T11:30:00-08:00" "action create 1 " -- --now 2026-11-09T10:00:00-08:00 --written-mode rule --repair <<EOF
$(bash "$DATES" "${LA[@]}" --notify-at 22:00)
reminder A open 2026-11-16T11:30:00-08:00 - 0 list
EOF
# rule, monthly day 30 -> 31, series on Dec 30 (period 2): it moves to Dec 31, never back to November.
check "rule day 30 to 31, never moved back" "reminder A class=off-schedule period=2 dates=differ
action move A 2 due=2026-12-31" "action move A 1" -- "${RULE[@]}" --repair <<EOF
$(p --cadence monthly --day 31 --count 3 --from "$NOW" | sed 's/^rule none.*/rule monthly days_of_month=31 due_time=date-only/')
reminder A open 2026-12-30 - none list
EOF

# --- per-period: same key, other due (round 3 HIGH 2, 5) ----------------------------------------------
check "per-period, time changed, same keys: rewritten with the new due" "action rewrite N 1 due=2026-11-30T20:00:00+08:00
action rewrite D 2 due=2026-12-31T20:00:00+08:00
action rewrite J 3 due=2027-01-31T20:00:00+08:00" "action keep|action move" -- "${PER[@]}" --repair <<EOF
$M31T12
reminder N open 2026-11-30T08:00:00+08:00 2026-11-30 0 list
reminder D open 2026-12-31T08:00:00+08:00 2026-12-31 0 list
reminder J open 2027-01-31T08:00:00+08:00 2027-01-31 0 list
EOF
check "per-period, time changed by hand: sync asks" "action repair-needed dates-changed" "action keep|action create" -- "${PER[@]}" <<EOF
$M31T12
reminder N open 2026-11-30T08:00:00+08:00 2026-11-30 0 list
EOF
check "per-period, nothing changed: kept" "action keep N 1 due=2026-11-30
action keep D 2 due=2026-12-31
action keep J 3 due=2027-01-31" "rewrite|move|create" -- "${PER[@]}" <<EOF
$M31
reminder N open 2026-11-30 2026-11-30 none list
reminder D open 2026-12-31 2026-12-31 none list
reminder J open 2027-01-31 2027-01-31 none list
EOF
check "per-period, day 31 to 30, re-paired in order" "action keep N 1 due=2026-11-30
action move D 2 due=2026-12-30
action move J 3 due=2027-01-30" "leftover" -- "${PER[@]}" --repair <<EOF
$M30
reminder N open 2026-11-30 2026-11-30 none list
reminder D open 2026-12-31 2026-12-31 none list
reminder J open 2027-01-31 2027-01-31 none list
EOF
# A later period ticked before an earlier open one does not push the earlier one away (MEDIUM 8).
check "per-period, later period ticked early" "used 2
action keep N 1 due=2026-11-30
action keep J 3 due=2027-01-31" "leftover|action move" -- "${PER[@]}" --repair <<EOF
$M31
reminder N open 2026-11-30 2026-11-30 none list
reminder D completed 2026-12-31 2026-12-31 - list
reminder J open 2027-01-31 2027-01-31 none list
EOF
# --repair respects --through: December, used and cleaned up, is not created again (MEDIUM 12).
check "repair keeps a cleaned-up period missing" "action rewrite N 1 due=2026-11-30T20:00:00+08:00
action missing 2
action rewrite J 3 due=2027-01-31T20:00:00+08:00" "action create 2|action move" -- "${PER[@]}" --through 2027-01-31 --repair <<EOF
$M31T12
reminder N open 2026-11-30T08:00:00+08:00 2026-11-30 0 list
reminder J open 2027-01-31T08:00:00+08:00 2027-01-31 0 list
EOF
check "repair, day changed, cleaned-up period not filled from a later one" "action keep N 1 due=2026-11-30
action missing 2
action move J 3 due=2027-01-30" "action move J 2|action create 2" -- "${PER[@]}" --through 2027-01-31 --repair <<EOF
$M30
reminder N open 2026-11-30 2026-11-30 none list
reminder J open 2027-01-31 2027-01-31 none list
EOF
D5=2026-12-05T10:00:00+08:00
check "per-period, cleaned-up period not recreated" "action missing 1
action keep J 2 due=2027-01-31
action create 3 due=2027-02-28" "action create 1 " -- --now "$D5" --written-mode per-period --through 2027-01-31 <<EOF
$(bash "$DATES" --cadence monthly --day 31 --previous --horizon-days 90 --local-tz "$TPE" --from "$D5")
reminder J open 2027-01-31 2027-01-31 none list
EOF
check "per-period, first run" "action create 1 due=2026-11-30
action create 2 due=2026-12-31
action create 3 due=2027-01-31" "" -- "${PER[@]}" <<EOF
$M31
EOF

# --- ambiguous, outside the list, horizon edge (round 3 MEDIUM 6, 7, 10, LOW 16) ------------------------
check "ambiguous blocks the periods it may hold" "reminder X class=ambiguous period=1 dates=-
action list X ambiguous
action hold 1 ambiguous" "action create 1 |action create 2 " -- "${PER[@]}" <<EOF
$M31
reminder X open 2026-12-16T00:00:00Z - none list
EOF
check "ambiguous series blocks a second series" "action list A ambiguous
action hold 1 ambiguous" "action create|restart" -- --now "$NOW" --written-mode rule <<EOF
$(p --cadence monthly --day 6 --count 3 --from "$NOW")
reminder A open 2026-11-21 - none list
EOF
check "outside the list: listed, nothing created for it" "action list A outside-list" "action create|action keep" -- "${RULE[@]}" <<EOF
$W20
reminder A open 2026-11-10T03:30:00+08:00 - 330,0 other
EOF
check "a series beyond the horizon" "reminder A class=beyond period=3 dates=-
action keep A beyond" "repair-needed|leftover" -- "${RULE[@]}" <<EOF
$(p --cadence monthly --day 21 --lead-days 1 --count 3 --from "$NOW" | sed 's/^period [4-9].*//')
reminder C1 completed 2026-11-20 - - list
reminder C2 completed 2026-12-20 - - list
reminder C3 completed 2027-01-20 - - list
reminder A open 2027-03-20 - none list
EOF
check "every period used: no target, no crash" "used 1 2 3" "unbound" -- "${PER[@]}" <<EOF
$M31
reminder N completed 2026-11-30 2026-11-30 - list
reminder D completed 2026-12-31 2026-12-31 - list
reminder J completed 2027-01-31 2027-01-31 - list
EOF

# --- bad input (LOW 17, 19) -------------------------------------------------------------------------
err() {
  local name="$1" want="$2" input="$3"; shift 3
  local out rc; out="$(printf '%s\n' "$input" | bash "$PLAN" "$@" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" -eq 2 ] && [[ "$out" == *"$want"* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL %s: rc=%s [%s]\n' "$name" "$rc" "$out"; fi
}
err "--now required" "--now is required" ""
err "--written-mode required" "--written-mode must be" "" --now "$NOW"
err "bad --through" "--through must be YYYY-MM-DD" "" --now "$NOW" --written-mode rule --through 2026-1-1
err "no input" "no rule line" "" --now "$NOW" --written-mode rule
err "period number is not arithmetic" "bad period number" 'period R_DUE[$(touch${IFS}/tmp/quota-plan-x)0] key=2026-11-09 state=current due=2026-11-10' --now "$NOW" --written-mode rule
err "glob in an id is refused, not expanded" "bad reminder id" "$W20
reminder quota-*.sh open 2026-11-10T03:30:00+08:00 - 0 list" --now "$NOW" --written-mode rule
err "bad key" "bad period key" "$W20
reminder A open 2026-11-10T03:30:00+08:00 find-*.sh 0 list" --now "$NOW" --written-mode rule
err "old six-field reminder line" "want 7 fields" "$W20
reminder A open 2026-11-10T03:30:00+08:00 - list" --now "$NOW" --written-mode rule
[ ! -e /tmp/quota-plan-x ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL the period number was evaluated"; rm -f /tmp/quota-plan-x; }

echo "quota-plan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
