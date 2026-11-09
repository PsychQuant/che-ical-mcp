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
old() { sed 's/^/old /'; }
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
check "weekday changed by hand: keys no longer listed" "reminder S class=off-schedule period=- dates=-
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
check "natural record: period 0 unticked" "reminder R class=past-record period=0 dates=-" "repair-needed|action create 0" -- "${A[@]}" <<EOF
$M31
reminder R open 2026-10-31 2026-10-31 - none list
EOF
# Round 5 MEDIUM 9: a key earlier than period 0's is a past period whatever its due's distance.
check "a key before period 0 is a record" "reminder R class=past-record period=- dates=-" "off-schedule|repair-needed" -- "${A[@]}" <<EOF
$WED
reminder R open 2026-11-03T03:30:00+08:00 2026-11-02 - 0 list
EOF
# Round 5 HIGH: a record kept by a replacement carries `Record:` and stays a record on the next sync, even
# though its due lies near a new period.
check "a written-down record survives the next sync" "reminder R class=record period=- dates=-
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
# Round 4 HIGH 1 / round 5 HIGH: Sunday's reset passed, the user changes it to Wednesday on Monday. With the old
# periods the Sunday reminder is the record and gets `Record:`; it is not deleted.
check "replace writes the Record line for the old record" "action mark-record R 2026-11-08
action delete S
action create 1 due=2026-11-12T03:30:00+08:00
action through 2027-02-03" "action delete R" -- "${A[@]}" --replace <<EOF
$(printf '%s\n' "$SUN" | old)
$WED
reminder R open 2026-11-09T03:30:00+08:00 2026-11-08 - 0 list
reminder S open 2026-11-16T03:30:00+08:00 2026-11-15 - 0 list
EOF
check "replace, a recorded reminder stays" "action record R
action delete S" "action delete R|mark-record R" -- "${A[@]}" --replace <<EOF
$(printf '%s\n' "$SUN" | old)
$WED
reminder R open 2026-11-09T03:30:00+08:00 2026-11-08 2026-11-08 0 list
reminder S open 2026-11-16T03:30:00+08:00 2026-11-15 - 0 list
EOF
check "replace, time change writes the new dues" "action delete N
action create 1 due=2026-11-30T20:00:00+08:00
action create 2 due=2026-12-31T20:00:00+08:00
action create 3 due=2027-01-31T20:00:00+08:00
action through 2027-01-31" "rewrite|move" -- "${A[@]}" --replace <<EOF
$(printf '%s\n' "$M31" | old)
$M31T12
reminder N open 2026-11-30 2026-11-30 - none list
EOF
# A period used under the old dates (same key) is not created again (round 5 LOW 10).
check "replace skips a period already used" "action used 2
action delete N
action create 1 due=2026-11-28
action create 3 due=2027-01-28" "action create 2 " -- "${A[@]}" --replace <<EOF
$(printf '%s\n' "$M31" | old)
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
$(bash "$DATES" --cadence monthly --day 31 --lead-days 3 --previous --horizon-days 90 --local-tz "$TPE" --from "$L3" | old)
$(bash "$DATES" --cadence monthly --day 31 --previous --horizon-days 60 --local-tz "$TPE" --from "$L3")
reminder a open 2026-11-27 2026-11-30 - none list
reminder b open 2026-12-28 2026-12-31 - none list
reminder c open 2027-01-28 2027-01-31 - none list
EOF
# Without the old periods (a hand edit), a passed due with no Record line is asked about, never kept or
# deleted; the replacement waits (round 5 MEDIUM 5).
check "replace without old periods asks about a passed due" "action list A due-passed
action replace-blocked due-passed" "action delete|action create|mark-record" -- --now 2026-11-10T03:45:00+08:00 --local-tz "$TPE" --replace <<EOF
$(bash "$DATES" --cadence weekly --weekday 2 --time 20:00 --lead-minutes 60 --previous --horizon-days 90 --local-tz "$TPE" --from 2026-11-10T03:45:00+08:00)
reminder A open 2026-11-10T03:30:00+08:00 2026-11-09 - 0 list
EOF
check "replace without old periods deletes a due still ahead" "action delete A
action create 1 due=2026-11-10T03:00:00+08:00" "due-passed|mark-record" -- "${A[@]}" --replace <<EOF
$(p --cadence weekly --weekday 2 --time 20:00 --lead-minutes 60 --from "$NOW")
reminder A open 2026-11-10T03:30:00+08:00 2026-11-09 - 0 list
EOF
# Any open reminder in another list blocks the whole replacement, a record included (round 5 MEDIUM 8).
check "replace blocked by a reminder in another list" "action list O outside-list
action replace-blocked outside-list" "action delete|action create" -- "${A[@]}" --replace <<EOF
$(printf '%s\n' "$SUN" | old)
$WED
reminder O open 2026-11-09T03:30:00+08:00 2026-11-08 2026-11-08 0 other
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
err "old lines without --replace" "only read with --replace" "$(printf '%s\n' "$M31" | old)
$M31" --now "$NOW"
[ ! -e /tmp/quota-plan-x ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL the period number was evaluated"; rm -f /tmp/quota-plan-x; }

echo "quota-plan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
