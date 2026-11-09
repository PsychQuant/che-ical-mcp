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
check "Sunday to Wednesday on Monday: the Sunday reminder is asked about, not marked" "action list R due-passed due=2026-11-09T03:30:00+08:00 resets=2026-11-11T20:00:00+00:00
action list S due-passed due=2026-11-16T03:30:00+08:00 resets=2026-11-18T20:00:00+00:00
action replace-blocked due-passed" "mark-record|action delete R|action create" -- "${A[@]}" --replace <<EOF
$WED
reminder R open 2026-11-09T03:30:00+08:00 2026-11-08 - 0 list
reminder S open 2026-11-16T03:30:00+08:00 2026-11-15 - 0 list
EOF
check "after a yes to delete it, it is deleted and its period created anew" "action delete R
action delete S
action create 1 due=2026-11-12T03:30:00+08:00
action through 2027-02-03" "mark-record|due-passed" -- "${A[@]}" --replace --delete-passed R --delete-passed S <<EOF
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
check "replace asks about a passed due" "action list A due-passed due=2026-11-10T03:30:00+08:00 resets=2026-11-09T20:00:00+00:00
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
# An open reminder in another list blocks the whole replacement (round 5 MEDIUM 8); a record with a `Record:`
# line there does not (round 7 #8): the replacement never writes or deletes it.
check "replace blocked by a reminder in another list" "action list O outside-list
action replace-blocked outside-list" "action delete|action create" -- "${A[@]}" --replace <<EOF
$WED
reminder O open 2026-11-09T03:30:00+08:00 2026-11-08 - 0 other
EOF
check "replace: a record in another list stays and does not block" "reminder O class=record period=- dates=- place=other
action record O
action delete S
action create 1 due=2026-11-12T03:30:00+08:00" "replace-blocked|outside-list|action delete O" -- "${A[@]}" --replace <<EOF
$WED
reminder O open 2026-11-02T03:30:00+08:00 2026-11-01 2026-11-01 0 other
reminder S open 2026-11-23T03:30:00+08:00 2026-11-22 - 0 list
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
action list A due-passed due=2026-11-09T20:00:00Z resets=2026-11-09T23:00:00+00:00
action replace-blocked due-passed" "mark-record|action create 1 " -- --now "$E" --local-tz UTC --replace <<EOF
$(U --cadence weekly --weekday 2 --time 23:00)
reminder A open 2026-11-09T20:00:00Z 2026-11-09 - 0 list
EOF
check "reset moved later, after a yes: deleted and created anew" "action delete A
action create 1 due=2026-11-09T23:00:00+00:00" "mark-record|due-passed" -- --now "$E" --local-tz UTC --replace --delete-passed A <<EOF
$(U --cadence weekly --weekday 2 --time 23:00)
reminder A open 2026-11-09T20:00:00Z 2026-11-09 - 0 list
EOF
# Round 6 #3, round 7 #1: notify_at added between the due and the reset changes only the alarms. The reminder
# is never marked, and since its due is the period's, it is realarmed in place, not deleted and created again.
E3=2026-11-09T19:45:00Z
check "notify_at added after the due: realarmed in place, never marked" "action realarm A 1 due=2026-11-09T19:30:00+00:00 alarms=0,450" "mark-record|due-passed|action delete|action create 1 " -- --now "$E3" --local-tz UTC --replace <<EOF
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

# --- round 7 -------------------------------------------------------------------------------------------
# #1 (HIGH): only the alarms differ. create_reminder's duplicate check is title + due, so a create on the due of
# a reminder about to be deleted returns that reminder, and the delete then removes the only one. The alarms are
# rewritten in place instead (realarm); nothing is deleted or created for those periods.
MONN="$(p --cadence weekly --weekday 2 --time 20:00 --lead-minutes 30 --notify-at 22:00 --from "$NOW")"
MON0="$(p --cadence weekly --weekday 2 --time 20:00 --lead-minutes 30 --from "$NOW")"
check "replace, notify_at added: alarms rewritten in place" "reminder A class=matched period=1 dates=differ place=list
action realarm A 1 due=2026-11-10T03:30:00+08:00 alarms=0,330
action realarm B 2 due=2026-11-17T03:30:00+08:00 alarms=0,330
action realarm C 3 due=2026-11-24T03:30:00+08:00 alarms=0,330
action create 4 due=2026-12-01T03:30:00+08:00" "action delete|action create 1 |action create 2 |action create 3 |replace-blocked" -- "${A[@]}" --replace <<EOF
$MONN
reminder A open 2026-11-09T19:30:00Z 2026-11-09 - 0 list
reminder B open 2026-11-16T19:30:00Z 2026-11-16 - 0 list
reminder C open 2026-11-23T19:30:00Z 2026-11-23 - 0 list
EOF
check "replace, notify_at removed: alarms rewritten to the due alarm only" "action realarm A 1 due=2026-11-10T03:30:00+08:00 alarms=0" "action delete|action create 1 " -- "${A[@]}" --replace <<EOF
$MON0
reminder A open 2026-11-09T19:30:00Z 2026-11-09 - 330,0 list
EOF
check "replace, local_tz moved with notify_at: same dues, alarms rewritten in place" "action realarm A 1 due=2026-11-10T04:30:00+09:00 alarms=0,390" "action delete|action create 1 " -- --now "$NOW" --local-tz Asia/Tokyo --replace <<EOF
$(bash "$DATES" --cadence weekly --weekday 2 --time 20:00 --lead-minutes 30 --notify-at 22:00 --previous --horizon-days 90 --local-tz Asia/Tokyo --from "$NOW")
reminder A open 2026-11-09T19:30:00Z 2026-11-09 - 330,0 list
EOF
check "replace: two reminders realarmed on one period wait" "action list A2 two-open-reminders
action replace-blocked two-open-reminders" "action delete" -- "${A[@]}" --replace <<EOF
$MONN
reminder A open 2026-11-09T19:30:00Z 2026-11-09 - 0 list
reminder A2 open 2026-11-09T19:30:00Z 2026-11-09 - 0 list
EOF
# Round 8: the same-due guard is gone. The server skips a create only on an equal title, and a changed key always
# changes the title (it is built from the declared reset), so the same reset written in another reset_tz is an
# ordinary replacement. A skipped create still stops a replacement before any delete (SKILL section 8).
TUE="$(bash "$DATES" --cadence weekly --weekday 3 --time 04:00 --reset-tz Asia/Taipei --lead-minutes 30 --previous --horizon-days 90 --local-tz "$TPE" --from 2026-11-12T10:00:00+08:00)"
check "replace: the same reset in another reset_tz is replaced, not blocked" "action delete F
action delete G
action create 1 due=2026-11-17T03:30:00+08:00
action create 2 due=2026-11-24T03:30:00+08:00
action keys-changed" "same-due|replace-blocked" -- --now 2026-11-12T10:00:00+08:00 --local-tz "$TPE" --replace <<EOF
$TUE
reminder F open 2026-11-23T19:30:00Z 2026-11-23 - 0 list
reminder G open 2026-11-30T19:30:00Z 2026-11-30 - 0 list
EOF
# #2 and #6: a record in another list still holds the open period of its Record: key.
check "sync: a record in another list holds its open period" "action list X record-on-open-period
action hold 1 record-on-open-period
action create 2 due=2026-12-31" "action create 1 " -- "${A[@]}" <<EOF
$M31
reminder X open 2026-11-30 2026-11-30 2026-11-30 none other
EOF
check "sync: a timed record in another list holds its open period" "action hold 1 record-on-open-period" "action create 1 " -- "${A[@]}" <<EOF
$MON0
reminder R1 open 2026-11-09T19:30:00Z 2026-11-09 2026-11-09 0 other
EOF
# #12: a record whose Period: key is an open period holds that period too, whatever its Record: key.
check "sync: a record whose Period: is an open period holds it" "action list X record-on-open-period
action hold 1 record-on-open-period" "action create 1 " -- "${A[@]}" <<EOF
$M31
reminder X open 2026-11-30 2026-11-30 2026-10-31 none list
EOF
check "replace: a record whose Period: is an open period blocks" "action list X record-on-open-period
action replace-blocked record-on-open-period" "action create 1 " -- "${A[@]}" --replace <<EOF
$M31
reminder X open 2026-11-30 2026-11-30 2026-10-31 none list
EOF
# #5: Monday changed to Friday. Every old reminder that can block a later run while the user waits is listed with
# its due and the reset that turns it into a record, so one answer settles them all.
FRI="$(bash "$DATES" --cadence weekly --weekday 6 --time 20:00 --lead-minutes 30 --previous --horizon-days 90 --local-tz "$TPE" --from 2026-11-10T10:00:00+08:00)"
OLDMON="reminder R09 open 2026-11-09T19:30:00Z 2026-11-09 - 0 list
reminder R16 open 2026-11-16T19:30:00Z 2026-11-16 - 0 list
reminder R23 open 2026-11-23T19:30:00Z 2026-11-23 - 0 list
reminder R30 open 2026-11-30T19:30:00Z 2026-11-30 - 0 list"
check "due-passed lists every reminder that would block while waiting" "action list R09 due-passed due=2026-11-09T19:30:00Z resets=2026-11-13T20:00:00+00:00
action list R16 due-passed due=2026-11-16T19:30:00Z resets=2026-11-20T20:00:00+00:00
action list R23 due-passed due=2026-11-23T19:30:00Z resets=2026-11-27T20:00:00+00:00
action list R30 due-passed due=2026-11-30T19:30:00Z resets=2026-12-04T20:00:00+00:00
action replace-blocked due-passed" "action delete|action create" -- --now 2026-11-10T10:00:00+08:00 --local-tz "$TPE" --replace <<EOF
$FRI
$OLDMON
EOF
check "one yes for all of them goes through" "action delete R09
action delete R16
action delete R23
action delete R30
action create 1 due=2026-11-14T03:30:00+08:00" "due-passed|replace-blocked" -- --now 2026-11-10T10:00:00+08:00 --local-tz "$TPE" --replace --delete-passed R09 --delete-passed R16 --delete-passed R23 --delete-passed R30 <<EOF
$FRI
$OLDMON
EOF
check "a yes for only the passed one still waits on the others" "action list R16 due-passed due=2026-11-16T19:30:00Z resets=2026-11-20T20:00:00+00:00
action replace-blocked due-passed" "action create" -- --now 2026-11-10T10:00:00+08:00 --local-tz "$TPE" --replace --delete-passed R09 <<EOF
$FRI
$OLDMON
EOF
# #11: per_period_through counts a used period, in a replacement and in sync, so a used period that is later
# cleaned up is offered as missing, never recreated unasked.
check "replace: through counts the last period when it is used" "action used 3
action through 2027-01-28" "action through 2026-12-28|action create 3 " -- "${A[@]}" --replace <<EOF
$M28
reminder N open 2026-11-30 2026-11-30 - none list
reminder J completed 2027-01-28 2027-01-28 - - list
EOF
check "sync: through counts kept, created and used periods" "action keep N 1 due=2026-11-30
action create 2 due=2026-12-31
action through 2027-01-31" "" -- "${A[@]}" --through 2026-11-30 <<EOF
$M31
reminder N open 2026-11-30 2026-11-30 - none list
reminder J completed 2027-01-31 2027-01-31 - - list
EOF
check "sync: through is not printed when it would not rise" "action keep N 1 due=2026-11-30" "action through" -- "${A[@]}" --through 2027-01-31 <<EOF
$M31
reminder N open 2026-11-30 2026-11-30 - none list
reminder D open 2026-12-31 2026-12-31 - none list
reminder J open 2027-01-31 2027-01-31 - none list
EOF

# --- round 8 -------------------------------------------------------------------------------------------
# #1: a date-only due moved by a day is an ordinary replacement (lead_days 1->2, 2->1, 1->0).
ld() { p --cadence monthly --day 21 --lead-days "$1" --from "$NOW"; }
D21="reminder A open DA 2026-11-21 - none list
reminder B open DB 2026-12-21 - none list
reminder C open DC 2027-01-21 - none list"
d21() { printf '%s\n' "$D21" | sed "s/DA/$1/; s/DB/$2/; s/DC/$3/"; }
check "lead_days 1 to 2: replaced, no block" "action delete A
action delete B
action delete C
action create 1 due=2026-11-19" "same-due|replace-blocked" -- "${A[@]}" --replace <<EOF
$(ld 2)
$(d21 2026-11-20 2026-12-20 2027-01-20)
EOF
check "lead_days 2 to 1: replaced, no block" "action delete A
action create 1 due=2026-11-20" "same-due|replace-blocked" -- "${A[@]}" --replace <<EOF
$(ld 1)
$(d21 2026-11-19 2026-12-19 2027-01-19)
EOF
check "lead_days 1 to 0: replaced, no block" "action delete A
action create 1 due=2026-11-21" "same-due|replace-blocked" -- "${A[@]}" --replace <<EOF
$(ld 0)
$(d21 2026-11-20 2026-12-20 2027-01-20)
EOF
# #2: a replacement that keeps every key (notify_at added) honours per_period_through: the period the user deleted
# stays missing instead of being created again.
check "replace with the keys kept: a deleted period stays missing" "action realarm A 1 due=2026-11-10T03:30:00+08:00 alarms=0,330
action missing 2
action realarm C 3 due=2026-11-24T03:30:00+08:00 alarms=0,330
action create 5 due=2026-12-08T03:30:00+08:00" "action create 2 |keys-changed|replace-blocked" -- "${A[@]}" --replace --through 2026-11-30 <<EOF
$MONN
reminder A open 2026-11-09T19:30:00Z 2026-11-09 - 0 list
reminder C open 2026-11-23T19:30:00Z 2026-11-23 - 0 list
reminder D open 2026-11-30T19:30:00Z 2026-11-30 - 0 list
EOF
check "replace with the keys changed: the old through is not read" "action keys-changed
action create 1 due=2026-11-12T03:30:00+08:00" "action missing" -- "${A[@]}" --replace --through 2026-11-30 <<EOF
$WED
reminder S open 2026-11-16T03:30:00+08:00 2026-11-15 - 0 list
EOF
# The calibrated MEDIUM: a schedule change with no reminder left open. The old through names a key the new schedule
# does not have, so it is stale: the new periods are created, not reported missing. The skill lists 125 days and
# creates 90 (--create-days), so a high-water mark written under the old dates lies inside the listed periods.
M28W="$(bash "$DATES" --cadence monthly --day 28 --previous --horizon-days 125 --local-tz "$TPE" --from "$NOW")"
check "day 31 to 28, every reminder completed: created, not missing" "action keys-changed
action create 1 due=2026-11-28
action create 2 due=2026-12-28
action create 3 due=2027-01-28
action through 2027-01-28" "action missing|action create 4 " -- "${A[@]}" --create-days 90 --through 2027-01-31 <<EOF
$M28W
reminder N completed 2026-10-31 2026-10-31 - - list
EOF
check "day 31 to 28, every reminder cleaned up: created, not missing" "action keys-changed
action create 1 due=2026-11-28
action through 2027-01-28" "action missing" -- "${A[@]}" --create-days 90 --through 2027-01-31 <<EOF
$M28W
EOF
check "a through the schedule still has is not stale" "action missing 1" "keys-changed|action create 1 " -- "${A[@]}" --through 2026-12-31 <<EOF
$M31
reminder D open 2026-12-31 2026-12-31 - none list
EOF
# #3: a past-record in another list stays, like a record: no block, nothing written.
M30="$(p --cadence monthly --day 30 --from "$NOW")"
check "replace: a past-record in another list stays and does not block" "action record OLD
action delete N" "replace-blocked|outside-list|mark-record OLD|action delete OLD" -- "${A[@]}" --replace <<EOF
$M30
reminder OLD open 2026-09-30 2026-09-30 - none other
reminder N open 2026-11-29 2026-11-29 - none list
EOF
# #5: only local_tz moves west for a date-only weekly quota. The helper judges a wider window than the one that is
# created (--create-days), so the last reminder is matched, not off schedule, and nothing is offered.
LA=America/Los_Angeles
SAT13="$(for k in 11-14 11-21 11-28 12-05 12-12 12-19 12-26; do echo "reminder R$k open 2026-$k 2026-$k - none list"; done
for k in 01-02 01-09 01-16 01-23 01-30 02-06; do echo "reminder R$k open 2027-$k 2027-$k - none list"; done)"
check "local_tz moved west: the last reminder is still on its period" "action keep R02-06 13 due=2027-02-06" "off-schedule|repair-needed|action create" -- --now "$NOW" --local-tz "$LA" --create-days 90 <<EOF
$(bash "$DATES" --cadence weekly --weekday 7 --previous --horizon-days 125 --local-tz "$LA" --from "$NOW")
$SAT13
EOF
check "create-days limits creates, not judging" "action create 1 due=2026-11-14
action create 13 due=2027-02-06" "action create 14 |action create 17 " -- --now "$NOW" --local-tz "$TPE" --create-days 90 <<EOF
$(bash "$DATES" --cadence weekly --weekday 7 --previous --horizon-days 125 --local-tz "$TPE" --from "$NOW")
EOF
# INFO: one period with a reminder in the list and one in another list gives the same plan whatever the ids.
check "in list and in another list, in-list id first" "action list A two-open-reminders
action hold 1 outside-list" "action keep A" -- "${A[@]}" <<EOF
$M31
reminder A open 2026-11-30 2026-11-30 - none list
reminder B open 2026-11-30 2026-11-30 - none other
EOF
check "in list and in another list, in-list id last" "action list B two-open-reminders
action hold 1 outside-list" "action keep B" -- "${A[@]}" <<EOF
$M31
reminder A open 2026-11-30 2026-11-30 - none other
reminder B open 2026-11-30 2026-11-30 - none list
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
err "the date helper stopped before its rule line (round 7 #4)" "no rule line" "$(printf '%s\n' "$M31" | grep -v '^rule ')" --now "$NOW"
err "a period after the rule line" "after the rule line" "$M31
$(printf '%s\n' "$M31" | grep '^period 3 ')" --now "$NOW"
err "bad --create-days" "--create-days must be" "$M31" --now "$NOW" --create-days 0
err "--delete-passed without --replace" "only read with --replace" "$M31" --now "$NOW" --delete-passed A
err "--delete-passed for a reminder that is not due-passed" "does not list that reminder as due-passed" "$M31
reminder N open 2026-11-30 2026-11-30 - none list" --now "$NOW" --local-tz "$TPE" --replace --delete-passed N
[ ! -e /tmp/quota-plan-x ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL the period number was evaluated"; rm -f /tmp/quota-plan-x; }

echo "quota-plan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
