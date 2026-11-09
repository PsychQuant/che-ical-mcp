#!/usr/bin/env bash
# Tests for plugin/bin/quota-plan.sh (#327; v1 is per-period only, records are written down as `Record:`).
# Periods come from quota-dates.sh with a fixed --from and --local-tz; reminders are fictional. Every case that
# writes asserts the due written (due=). Run: bash plugin/bin/tests/quota-plan.test.sh   (exit 0 = all pass)
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
M31="$(p --cadence monthly --day 31 --from "$NOW")"
M31T12="$(p --cadence monthly --day 31 --time 12:00 --from "$NOW")"
M28="$(p --cadence monthly --day 28 --from "$NOW")"
SUN="$(p --cadence weekly --weekday 1 --time 20:00 --lead-minutes 30 --from "$NOW")"
WED="$(p --cadence weekly --weekday 4 --time 20:00 --lead-minutes 30 --from "$NOW")"
A=(--now "$NOW" --local-tz "$TPE")

# --- list / sync: nothing is deleted or moved --------------------------------------------------------------
check "first run: every period of the 90 days" "action create 1 due=2026-11-30
action create 2 due=2026-12-31
action create 3 due=2027-01-31" "" -- "${A[@]}" <<EOF
$M31
EOF
check "nothing changed: kept" "action keep N 1 due=2026-11-30
action keep D 2 due=2026-12-31
action keep J 3 due=2027-01-31" "rewrite|create" -- "${A[@]}" <<EOF
$M31
reminder N open 2026-11-30 2026-11-30 - none list
reminder D open 2026-12-31 2026-12-31 - none list
reminder J open 2027-01-31 2027-01-31 - none list
EOF
check "time changed by hand, keys the same: findings, then dates changed" "action rewrite N 1 due=2026-11-30T20:00:00+08:00
action repair-needed dates-changed" "action keep|action create" -- "${A[@]}" <<EOF
$M31T12
reminder N open 2026-11-30T08:00:00+08:00 2026-11-30 - 0 list
EOF
check "weekday changed by hand: keys no longer listed" "reminder S class=off-schedule period=- dates=- place=list
action repair-needed dates-changed" "action create" -- "${A[@]}" <<EOF
$WED
reminder S open 2026-11-16T03:30:00+08:00 2026-11-15 - 0 list
EOF
check "a period ticked early is used" "used 2
action keep N 1 due=2026-11-30
action keep J 3 due=2027-01-31" "two-open|create" -- "${A[@]}" <<EOF
$M31
reminder N open 2026-11-30 2026-11-30 - none list
reminder D completed 2026-12-31 2026-12-31 - - list
reminder J open 2027-01-31 2027-01-31 - none list
EOF
check "a duplicate on one period pushes nothing" "action keep N 1 due=2026-11-30
action list N2 two-open-reminders
action keep D 2 due=2026-12-31" "move" -- "${A[@]}" <<EOF
$M31
reminder N open 2026-11-30 2026-11-30 - none list
reminder N2 open 2026-11-30 2026-11-30 - none list
reminder D open 2026-12-31 2026-12-31 - none list
EOF
check "another list: listed, holds its own period only" "action list O outside-list
action hold 2 outside-list
action create 1 due=2026-11-30
action create 3 due=2027-01-31" "action create 2 |action keep O" -- "${A[@]}" <<EOF
$M31
reminder O open 2026-12-31 2026-12-31 - none other
EOF
D5=2026-12-05T10:00:00+08:00
check "a period used and cleaned up is not recreated" "action missing 1
action keep J 2 due=2027-01-31
action create 3 due=2027-02-28" "action create 1 " -- --now "$D5" --local-tz "$TPE" --through 2027-01-31 <<EOF
$(bash "$DATES" --cadence monthly --day 31 --previous --horizon-days 90 --local-tz "$TPE" --from "$D5")
reminder J open 2027-01-31 2027-01-31 - none list
EOF
check "the last period deleted stays missing (high-water mark)" "action missing 3" "action create 3" -- "${A[@]}" --through 2027-01-31 <<EOF
$M31
reminder N open 2026-11-30 2026-11-30 - none list
reminder D open 2026-12-31 2026-12-31 - none list
EOF
# A period whose reset passed unticked is the record: by its key, never by its date.
check "natural record: period 0 unticked" "reminder R class=past-record period=0 dates=- place=list" "repair-needed|action create 0" -- "${A[@]}" <<EOF
$M31
reminder R open 2026-10-31 2026-10-31 - none list
EOF
# Round 5 MEDIUM 9: a key earlier than period 0's is a past period whatever its due's distance.
check "a key before period 0 is a record" "reminder R class=past-record period=- dates=- place=list" "off-schedule|repair-needed" -- "${A[@]}" <<EOF
$WED
reminder R open 2026-11-03T03:30:00+08:00 2026-11-02 - 0 list
EOF
# Round 5 HIGH: a record kept by a replacement carries `Record:` and stays a record on the next sync, even
# though its due lies near a new period.
check "a written-down record survives the next sync" "reminder R class=record period=- dates=- place=list
action keep S2 1 due=2026-11-12T03:30:00+08:00" "repair-needed|delete|off-schedule" -- "${A[@]}" <<EOF
$WED
reminder R open 2026-11-09T03:30:00+08:00 2026-11-08 2026-11-08 0 list
reminder S2 open 2026-11-12T03:30:00+08:00 2026-11-11 - 0 list
EOF
check "every period used: no crash" "used 1 2 3" "unbound" -- "${A[@]}" <<EOF
$M31
reminder N completed 2026-11-30 2026-11-30 - - list
reminder D completed 2026-12-31 2026-12-31 - - list
reminder J completed 2027-01-31 2027-01-31 - - list
EOF

# --- --replace: a schedule change ---------------------------------------------------------------------
# Round 6: every decision is by the NEW schedule; the old entry's periods are not read. A record is a reminder
# whose period reset under the new dates (key at or before new period 0) or one that carries `Record:`.
# Sunday's reset passed, the user changes it to Wednesday on Monday: under the new dates the Sunday reminder's
# period has not reset (its key is later than the new period 0), so it is not a record. Its due has passed: it is
# asked about (delete and recreate after a yes, or wait for the reset), never marked and never deleted unasked.
check "Sunday to Wednesday on Monday: the Sunday reminder is asked about, not marked" "action list R due-passed
action replace-blocked due-passed" "mark-record|action delete R|action create" -- "${A[@]}" --replace <<EOF
$WED
reminder R open 2026-11-09T03:30:00+08:00 2026-11-08 - 0 list
reminder S open 2026-11-16T03:30:00+08:00 2026-11-15 - 0 list
EOF
check "after a yes to delete it, it is deleted and its period created anew" "action delete R
action delete S
action create 1 due=2026-11-12T03:30:00+08:00
action through 2027-02-03" "mark-record|due-passed" -- "${A[@]}" --replace --delete-passed R <<EOF
$WED
reminder R open 2026-11-09T03:30:00+08:00 2026-11-08 - 0 list
reminder S open 2026-11-16T03:30:00+08:00 2026-11-15 - 0 list
EOF
W=2026-11-12T10:00:00+08:00
WEDW="$(p --cadence weekly --weekday 4 --time 20:00 --lead-minutes 30 --from "$W")"
check "after the new reset it is a record and gets its Record line" "reminder R class=past-record period=- dates=- place=list
action mark-record R 2026-11-08
action delete S
action create 1 due=2026-11-19T03:30:00+08:00" "action delete R|due-passed" -- --now "$W" --local-tz "$TPE" --replace <<EOF
$WEDW
reminder R open 2026-11-09T03:30:00+08:00 2026-11-08 - 0 list
reminder S open 2026-11-16T03:30:00+08:00 2026-11-15 - 0 list
EOF
check "replace, a recorded reminder stays" "action record R
action delete S" "action delete R|mark-record R" -- "${A[@]}" --replace <<EOF
$WED
reminder R open 2026-11-09T03:30:00+08:00 2026-11-08 2026-11-08 0 list
reminder S open 2026-11-16T03:30:00+08:00 2026-11-15 - 0 list
EOF
check "replace, time change writes the new dues" "action delete N
action create 1 due=2026-11-30T20:00:00+08:00
action create 2 due=2026-12-31T20:00:00+08:00
action create 3 due=2027-01-31T20:00:00+08:00
action through 2027-01-31" "rewrite|move" -- "${A[@]}" --replace <<EOF
$M31T12
reminder N open 2026-11-30 2026-11-30 - none list
EOF
# A period used under the old dates (same key) is not created again (round 5 LOW 10).
check "replace skips a period already used" "action used 2
action delete N
action create 1 due=2026-11-28
action create 3 due=2027-01-28" "action create 2 " -- "${A[@]}" --replace <<EOF
$M28
reminder N open 2026-11-30 2026-11-30 - none list
reminder D completed 2026-12-28 2026-12-28 - - list
EOF
# Round 5 MEDIUM 7: after a replacement the high-water mark is the last key the replacement created.
L3=2026-11-01T10:00:00+08:00
check "replace sets through to the last key it created" "action delete a
action delete b
action delete c
action create 1 due=2026-11-30
action through 2026-11-30" "action through 2027-01-31" -- --now "$L3" --local-tz "$TPE" --replace <<EOF
$(bash "$DATES" --cadence monthly --day 31 --previous --horizon-days 60 --local-tz "$TPE" --from "$L3")
reminder a open 2026-11-27 2026-11-30 - none list
reminder b open 2026-12-28 2026-12-31 - none list
reminder c open 2027-01-28 2027-01-31 - none list
EOF
# A passed due whose period has not reset under the new dates is asked about; after a yes it is deleted and
# its period created anew.
MON2="$(bash "$DATES" --cadence weekly --weekday 2 --time 20:00 --lead-minutes 60 --previous --horizon-days 90 --local-tz "$TPE" --from 2026-11-10T03:45:00+08:00)"
check "replace asks about a passed due" "action list A due-passed
action replace-blocked due-passed" "action delete|action create|mark-record" -- --now 2026-11-10T03:45:00+08:00 --local-tz "$TPE" --replace <<EOF
$MON2
reminder A open 2026-11-10T03:30:00+08:00 2026-11-09 - 0 list
EOF
check "replace, a passed due deleted after a yes" "action delete A
action create 1 due=2026-11-10T03:00:00+08:00" "due-passed|mark-record" -- --now 2026-11-10T03:45:00+08:00 --local-tz "$TPE" --replace --delete-passed A <<EOF
$MON2
reminder A open 2026-11-10T03:30:00+08:00 2026-11-09 - 0 list
EOF
check "replace deletes a due still ahead" "action delete A
action create 1 due=2026-11-10T03:00:00+08:00" "due-passed|mark-record" -- "${A[@]}" --replace <<EOF
$(p --cadence weekly --weekday 2 --time 20:00 --lead-minutes 60 --from "$NOW")
reminder A open 2026-11-10T03:30:00+08:00 2026-11-09 - 0 list
EOF
# Any open reminder in another list blocks the whole replacement, a record included (round 5 MEDIUM 8).
check "replace blocked by a reminder in another list" "action list O outside-list
action replace-blocked outside-list" "action delete|action create" -- "${A[@]}" --replace <<EOF
$WED
reminder O open 2026-11-09T03:30:00+08:00 2026-11-08 2026-11-08 0 other
EOF
# Round 6 #1: the reset moved earlier on the same weekday, run between the new reset and the old one. Under the
# new dates the period reset unticked: the reminder is the record, gets its Record line, and is not deleted.
E=2026-11-09T21:00:00Z
U() { bash "$DATES" "$@" --reset-tz UTC --previous --horizon-days 20 --local-tz UTC --from "$E"; }
check "reset moved earlier: the reminder of the period that reset is marked, not deleted" "reminder A class=past-record period=0 dates=- place=list
action mark-record A 2026-11-09
action create 1 due=2026-11-16T20:00:00+00:00" "action delete A|due-passed" -- --now "$E" --local-tz UTC --replace <<EOF
$(U --cadence weekly --weekday 2 --time 20:00)
reminder A open 2026-11-09T23:00:00Z 2026-11-09 - 0 list
EOF
# Round 6 #2: the reset moved later, run after the old reset time. The period is still open under the new dates:
# no Record line, no second reminder for that key. It is asked about; after a yes it is replaced.
check "reset moved later: a passed due on an open period is asked about, never marked" "reminder A class=matched period=1 dates=differ place=list
action list A due-passed
action replace-blocked due-passed" "mark-record|action create 1 " -- --now "$E" --local-tz UTC --replace <<EOF
$(U --cadence weekly --weekday 2 --time 23:00)
reminder A open 2026-11-09T20:00:00Z 2026-11-09 - 0 list
EOF
check "reset moved later, after a yes: deleted and created anew" "action delete A
action create 1 due=2026-11-09T23:00:00+00:00" "mark-record|due-passed" -- --now "$E" --local-tz UTC --replace --delete-passed A <<EOF
$(U --cadence weekly --weekday 2 --time 23:00)
reminder A open 2026-11-09T20:00:00Z 2026-11-09 - 0 list
EOF
# Round 6 #3: notify_at added between the due and the reset: the remedy is delete or wait, never a record.
E3=2026-11-09T19:45:00Z
check "notify_at added after the due: asked about, never marked" "action list A due-passed
action replace-blocked due-passed" "mark-record" -- --now "$E3" --local-tz UTC --replace <<EOF
$(bash "$DATES" --cadence weekly --weekday 2 --time 20:00 --lead-minutes 30 --notify-at 12:00 --reset-tz UTC --previous --horizon-days 20 --local-tz UTC --from "$E3")
reminder A open 2026-11-09T19:30:00Z 2026-11-09 - 0 list
EOF
check "replace blocked by a record on an open period" "action list X record-on-open-period
action replace-blocked record-on-open-period" "action create 1 |action delete X" -- "${A[@]}" --replace <<EOF
$M31
reminder X open 2026-11-30 2026-11-30 2026-11-30 none list
EOF
# Round 6 #5: recovery after a failed delete. The reminders already on the new dates are kept; only the
# leftover is deleted, and their periods are not created again.
check "replace keeps reminders already on the new dates; only the leftover goes" "action keep W1 1 due=2026-11-12T03:30:00+08:00
action keep W2 2 due=2026-11-19T03:30:00+08:00
action keep W3 3 due=2026-11-26T03:30:00+08:00
action delete S
action create 4 due=2026-12-03T03:30:00+08:00
action through 2027-02-03" "action delete W|action create 1 due|action create 2 due|action create 3 due" -- "${A[@]}" --replace <<EOF
$WED
reminder W1 open 2026-11-12T03:30:00+08:00 2026-11-11 - 0 list
reminder W2 open 2026-11-19T03:30:00+08:00 2026-11-18 - 0 list
reminder W3 open 2026-11-26T03:30:00+08:00 2026-11-25 - 0 list
reminder S open 2026-11-16T03:30:00+08:00 2026-11-15 - 0 list
EOF
check "replace: two reminders on the new dates for one period wait" "action list W1b two-open-reminders
action replace-blocked two-open-reminders" "action delete" -- "${A[@]}" --replace <<EOF
$WED
reminder W1 open 2026-11-12T03:30:00+08:00 2026-11-11 - 0 list
reminder W1b open 2026-11-12T03:30:00+08:00 2026-11-11 - 0 list
EOF
check "replace: an open reminder on a used period waits" "action list N period-used
action replace-blocked period-used" "action delete N" -- "${A[@]}" --replace <<EOF
$M31
reminder N open 2026-11-30 2026-11-30 - none list
reminder Nc completed 2026-11-30 2026-11-30 - - list
EOF
# Round 6 #3: sync holds a record on an open period too, the same as --replace, instead of creating next to it.
check "sync holds a record on an open period" "action list X record-on-open-period
action hold 1 record-on-open-period
action create 2 due=2026-12-31" "action create 1 " -- "${A[@]}" <<EOF
$M31
reminder X open 2026-11-30 2026-11-30 2026-11-30 none list
EOF
# Round 6 #8: a reminder in another list that is off schedule, or on other dates, means the dates changed.
check "sync: off schedule in another list is a date change" "reminder S class=off-schedule period=- dates=- place=other
action list S outside-list
action repair-needed dates-changed" "action create" -- "${A[@]}" <<EOF
$WED
reminder S open 2026-11-16T03:30:00+08:00 2026-11-15 - 0 other
EOF
check "sync: other dates in another list is a date change" "action list N outside-list
action repair-needed dates-changed" "action create|action rewrite" -- "${A[@]}" <<EOF
$M31T12
reminder N open 2026-11-30 2026-11-30 - none other
EOF
# Round 6 #10: an open reminder on a period a completed one used is its own reason.
check "sync: an open reminder on a used period" "action list N period-used" "two-open-reminders|action keep N" -- "${A[@]}" <<EOF
$M31
reminder N open 2026-11-30 2026-11-30 - none list
reminder Nc completed 2026-11-30 2026-11-30 - - list
EOF

# --- bad input -----------------------------------------------------------------------------------------
err() {
  local name="$1" want="$2" input="$3"; shift 3
  local out rc; out="$(printf '%s\n' "$input" | bash "$PLAN" "$@" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" -eq 2 ] && [[ "$out" == *"$want"* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL %s: rc=%s [%s]\n' "$name" "$rc" "$out"; fi
}
err "--now required" "--now is required" ""
err "bad --through" "--through must be YYYY-MM-DD" "" --now "$NOW" --through 2026-1-1
err "no input" "need period 0" "" --now "$NOW"
err "period number is not arithmetic" "bad period number" 'period R_DUE[$(touch${IFS}/tmp/quota-plan-x)0] key=2026-11-09 state=current due=2026-11-10' --now "$NOW"
err "glob in an id is refused, not expanded" "bad reminder id" "$M31
reminder quota-*.sh open 2026-11-30 2026-11-30 - none list" --now "$NOW"
err "bad record key" "bad record key" "$M31
reminder A open 2026-11-30 2026-11-30 find-*.sh none list" --now "$NOW"
err "old seven-field reminder line" "want 8 fields" "$M31
reminder A open 2026-11-30 2026-11-30 none list" --now "$NOW"
err "old lines are not read" "unknown input line" "$(printf '%s\n' "$M31" | sed 's/^/old /')
$M31" --now "$NOW"
err "an id twice (ticked between the searches)" "appears twice" "$M31
reminder X open 2026-11-30 2026-11-30 - none list
reminder X completed 2026-11-30 2026-11-30 - - list" --now "$NOW" --replace
err "a key that is not a real day" "bad period key" "$M31
reminder A open 2026-11-30 9999-99-99 - none list" --now "$NOW"
err "a record key that is not a real day" "bad record key" "$M31
reminder A open 2026-11-30 2026-11-30 2026-02-30 none list" --now "$NOW"
err "alarms out of form (5-3)" "bad alarms" "$M31
reminder A open 2026-11-30 2026-11-30 - 5-3 list" --now "$NOW"
err "alarms out of form (,)" "bad alarms" "$M31
reminder A open 2026-11-30 2026-11-30 - , list" --now "$NOW"
err "--delete-passed without --replace" "only read with --replace" "$M31" --now "$NOW" --delete-passed A
err "--delete-passed for a reminder that is not due-passed" "does not list that reminder as due-passed" "$M31
reminder N open 2026-11-30 2026-11-30 - none list" --now "$NOW" --local-tz "$TPE" --replace --delete-passed N
[ ! -e /tmp/quota-plan-x ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL the period number was evaluated"; rm -f /tmp/quota-plan-x; }

echo "quota-plan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
