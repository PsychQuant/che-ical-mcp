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

# --- list / sync (no --replace): nothing is moved or deleted --------------------------------------------
check "rule, running" "reminder A class=matched period=2 dates=ok
used 1
action keep A 2 due=2026-11-17T03:30:00+08:00" "action create|repair-needed|move" -- "${RULE[@]}" <<EOF
$W20
reminder C completed 2026-11-10T03:30:00+08:00 - - list
reminder A open 2026-11-17T03:30:00+08:00 - 330,0 list
EOF
# Alarms read back differ (notify_at edited by hand): a finding, then dates changed; never a silent keep.
check "rule, alarms differ" "action rewrite A 1 due=2026-11-10T03:30:00+08:00
action repair-needed dates-changed" "action keep" -- "${RULE[@]}" <<EOF
$W20
reminder A open 2026-11-10T03:30:00+08:00 - 0 list
EOF
check "off schedule (dates edited by hand)" "action repair-needed dates-changed" "action create|move" -- "${RULE[@]}" <<EOF
$W19
reminder A open 2026-11-10T03:30:00+08:00 - 330,0 list
EOF
check "written mode unknown" "action repair-needed written-mode-unknown" "action create|action keep" -- --now "$NOW" --written-mode unknown <<EOF
$W20
EOF
# A leftover Period: line on a running series is ignored in rule mode. On Nov 11 the week of Nov 9 has reset
# (period 0, ticked) and the series is on the current period.
check "rule, leftover Period line ignored" "reminder A class=matched period=1 dates=ok
action keep A 1 due=2026-11-17T03:30:00+08:00" "restart|past-record" -- --now 2026-11-11T10:00:00+08:00 --written-mode rule <<EOF
$(bash "$DATES" --cadence weekly --weekday 2 --time 20:00 --lead-minutes 30 --notify-at 22:00 --previous --horizon-days 90 --local-tz "$TPE" --from 2026-11-11T10:00:00+08:00)
reminder C completed 2026-11-10T03:30:00+08:00 2026-11-09 - list
reminder A open 2026-11-17T03:30:00+08:00 2026-11-09 330,0 list
EOF
# Two open series (round 4 MEDIUM 5): the later one is listed; it marks nothing used and nothing moves.
check "rule, two open series" "used none
action keep A 1 due=2026-11-10T03:30:00+08:00
action list B two-open-reminders" "move|used 1" -- "${RULE[@]}" <<EOF
$W20
reminder B open 2026-11-17T03:30:00+08:00 - 330,0 list
reminder A open 2026-11-10T03:30:00+08:00 - 330,0 list
EOF
D1=2026-12-01T10:00:00+08:00
P1D="$(bash "$DATES" --cadence weekly --weekday 2 --time 20:00 --lead-minutes 30 --notify-at 22:00 --previous --horizon-days 90 --local-tz "$TPE" --from "$D1")"
check "rule, stalled two periods" "reminder A class=past-record period=- dates=-
action restart A 1 due=2026-12-08T03:30:00+08:00" "restart A 0" -- --now "$D1" --written-mode rule <<EOF
$P1D
reminder A open 2026-11-17T03:30:00+08:00 - 330,0 list
EOF
# A stopped series moved to another list (round 4 MEDIUM 3, 6): listed, no restart, no new series beside it.
check "rule, stopped series in another list" "action list A outside-list
action hold 1 outside-list" "restart|action create" -- --now "$D1" --written-mode rule <<EOF
$P1D
reminder A open 2026-11-17T03:30:00+08:00 - 330,0 other
EOF
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
check "outside the list: listed, nothing created for it" "action list A outside-list" "action create|action keep" -- "${RULE[@]}" <<EOF
$W20
reminder A open 2026-11-10T03:30:00+08:00 - 330,0 other
EOF
# A series ticked past the 90 days (round 4 LOW 12, 16): its own action, every listed period used.
M21="$(p --cadence monthly --day 21 --lead-days 1 --count 3 --from "$NOW" | sed 's/^period [4-9].*//')"
check "a series beyond the horizon" "reminder A class=beyond period=4 dates=-
used 1 2 3
action beyond A" "repair-needed|leftover|action keep|action create" -- "${RULE[@]}" <<EOF
$M21
reminder C1 completed 2026-11-20 - - list
reminder A open 2027-03-20 - none list
EOF
check "a series beyond the horizon, in another list" "action list A outside-list" "action beyond|action keep|action create" -- "${RULE[@]}" <<EOF
$M21
reminder A open 2027-03-20 - none other
EOF
check "ambiguous series blocks a second series" "action list A ambiguous
action hold 1 ambiguous" "action create|restart" -- --now "$NOW" --written-mode rule <<EOF
$(p --cadence monthly --day 6 --count 3 --from "$NOW")
reminder A open 2026-11-21 - none list
EOF
# A completed reminder exactly between two periods is listed and holds both (round 4 LOW 10).
check "completed and ambiguous" "reminder C class=ambiguous period=0 dates=-
action list C ambiguous
action hold 1 ambiguous" "action create 1 " -- --now 2026-11-25T10:00:00+08:00 --written-mode rule <<EOF
$(bash "$DATES" --cadence monthly --day 6 --previous --horizon-days 90 --local-tz "$TPE" --from 2026-11-25T10:00:00+08:00)
reminder C completed 2026-11-21 - - list
EOF

# --- per-period, list / sync ---------------------------------------------------------------------
check "per-period, nothing changed: kept" "action keep N 1 due=2026-11-30
action keep D 2 due=2026-12-31
action keep J 3 due=2027-01-31" "rewrite|move|create" -- "${PER[@]}" <<EOF
$M31
reminder N open 2026-11-30 2026-11-30 none list
reminder D open 2026-12-31 2026-12-31 none list
reminder J open 2027-01-31 2027-01-31 none list
EOF
check "per-period, time changed by hand: finding, then dates changed" "action rewrite N 1 due=2026-11-30T20:00:00+08:00
action repair-needed dates-changed" "action keep|action create" -- "${PER[@]}" <<EOF
$M31T12
reminder N open 2026-11-30T08:00:00+08:00 2026-11-30 0 list
EOF
check "per-period, later period ticked early" "used 2
action keep N 1 due=2026-11-30
action keep J 3 due=2027-01-31" "two-open|create" -- "${PER[@]}" <<EOF
$M31
reminder N open 2026-11-30 2026-11-30 none list
reminder D completed 2026-12-31 2026-12-31 - list
reminder J open 2027-01-31 2027-01-31 none list
EOF
# A duplicate on one period never pushes the others (round 4 LOW 11).
check "per-period, duplicate on one period" "action keep N 1 due=2026-11-30
action list N2 two-open-reminders
action keep D 2 due=2026-12-31
action keep J 3 due=2027-01-31" "move|leftover" -- "${PER[@]}" <<EOF
$M31
reminder N open 2026-11-30 2026-11-30 none list
reminder N2 open 2026-11-30 2026-11-30 none list
reminder D open 2026-12-31 2026-12-31 none list
reminder J open 2027-01-31 2027-01-31 none list
EOF
# A reminder in another list holds its own period and only that one (round 4 MEDIUM 8).
check "per-period, outside reminder holds its own period" "action list O outside-list
action create 1 due=2026-11-30
action create 3 due=2027-01-31" "action create 2 |action keep O" -- "${PER[@]}" <<EOF
$M31
reminder O open 2026-12-31 2026-12-31 none other
EOF
check "per-period, outside beyond holds nothing listed" "action list A outside-list
action create 3 due=2027-01-31" "action keep|action beyond" -- "${PER[@]}" <<EOF
$M31
reminder A open 2027-03-31 2027-03-31 none other
EOF
D5=2026-12-05T10:00:00+08:00
check "per-period, cleaned-up period not recreated" "action missing 1
action keep J 2 due=2027-01-31
action create 3 due=2027-02-28" "action create 1 " -- --now "$D5" --written-mode per-period --through 2027-01-31 <<EOF
$(bash "$DATES" --cadence monthly --day 31 --previous --horizon-days 90 --local-tz "$TPE" --from "$D5")
reminder J open 2027-01-31 2027-01-31 none list
EOF
# per_period_through is a high-water mark (round 4 HIGH 2): the last period deleted stays missing.
check "per-period, last period deleted stays missing" "action keep N 1 due=2026-11-30
action keep D 2 due=2026-12-31
action missing 3" "action create 3" -- "${PER[@]}" --through 2027-01-31 <<EOF
$M31
reminder N open 2026-11-30 2026-11-30 none list
reminder D open 2026-12-31 2026-12-31 none list
EOF
check "per-period, first run" "action create 1 due=2026-11-30
action create 2 due=2026-12-31
action create 3 due=2027-01-31" "" -- "${PER[@]}" <<EOF
$M31
EOF
check "ambiguous blocks the periods it may hold" "reminder X class=ambiguous period=1 dates=-
action list X ambiguous
action hold 1 ambiguous
action hold 2 ambiguous" "action create 1 |action create 2 " -- "${PER[@]}" <<EOF
$M31
reminder X open 2026-12-16T00:00:00Z - none list
EOF
check "every period used: no target, no crash" "used 1 2 3" "unbound" -- "${PER[@]}" <<EOF
$M31
reminder N completed 2026-11-30 2026-11-30 - list
reminder D completed 2026-12-31 2026-12-31 - list
reminder J completed 2027-01-31 2027-01-31 - list
EOF

# --- --replace: a schedule change deletes the open reminders and creates the new schedule ---------------------
old() { sed 's/^/old /'; }
# Round 4 HIGH 1: Sunday's reset already passed, updated on Monday to Tuesday. Identified with the OLD periods,
# the unticked Sunday reminder is the record: it is not deleted, moved or paired.
SUN="$(p --cadence weekly --weekday 1 --time 20:00 --from "$NOW" | old)"
TUE="$(p --cadence weekly --weekday 3 --time 20:00 --from "$NOW")"
check "replace keeps the old record" "reminder A class=past-record period=0 dates=ok (old periods)
action create 1 due=2026-11-11T04:00:00+08:00" "action delete A|move|action record" -- --now "$NOW" --written-mode per-period --replace <<EOF
$SUN
$TUE
reminder A open 2026-11-09T04:00:00+08:00 2026-11-08 0 list
EOF
check "replace, rule: the series is deleted and recreated, the repeating record made one-off" "action record OLD
action delete A
action create 1 due=2026-11-10T02:30:00+08:00" "action delete OLD|action create 2 " -- "${RULE[@]}" --replace <<EOF
$(printf '%s\n' "$W20" | old)
$W19
reminder OLD open 2026-11-03T03:30:00+08:00 - 330,0 list
reminder C completed 2026-11-10T03:30:00+08:00 - - list
reminder A open 2026-11-17T03:30:00+08:00 - 330,0 list
EOF
check "replace, per-period to rule" "action delete N
action delete D
action delete J
action create 1 due=2026-11-28" "action create 2 |move|leftover" -- "${PER[@]}" --replace <<EOF
$(printf '%s\n' "$M31" | old)
$M28
reminder N open 2026-11-30 2026-11-30 none list
reminder D open 2026-12-31 2026-12-31 none list
reminder J open 2027-01-31 2027-01-31 none list
EOF
check "replace, per-period time change writes the new dues" "action delete N
action create 1 due=2026-11-30T20:00:00+08:00
action create 2 due=2026-12-31T20:00:00+08:00
action create 3 due=2027-01-31T20:00:00+08:00" "rewrite|move" -- "${PER[@]}" --replace <<EOF
$(printf '%s\n' "$M31" | old)
$M31T12
reminder N open 2026-11-30 2026-11-30 none list
EOF
check "replace blocked by a reminder in another list" "action list O outside-list
action replace-blocked outside-list" "action delete|action create" -- "${PER[@]}" --replace <<EOF
$(printf '%s\n' "$M31" | old)
$M28
reminder O open 2026-12-31 2026-12-31 none other
EOF
check "replace blocked by an ambiguous reminder" "action list X ambiguous
action replace-blocked ambiguous" "action delete|action create" -- "${PER[@]}" --replace <<EOF
$(printf '%s\n' "$M31" | old)
$M28
reminder X open 2026-12-16T00:00:00Z - none list
EOF

# Sync after a hand edit has no old entry: an open reminder whose due has passed stays as the record.
check "replace without old periods keeps a passed due as the record" "action record R
action delete A
action create 1 due=2026-11-10T02:30:00+08:00" "action delete R" -- "${RULE[@]}" --replace <<EOF
$W19
reminder R open 2026-11-03T03:30:00+08:00 - 330,0 list
reminder A open 2026-11-10T03:30:00+08:00 - 330,0 list
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
err "replace, old periods without the old rule" "old periods given without the old rule line" "old period 0 key=2026-11-02 state=past due=2026-11-03
$W20" --now "$NOW" --written-mode rule --replace
err "old six-field reminder line" "want 7 fields" "$W20
reminder A open 2026-11-10T03:30:00+08:00 - list" --now "$NOW" --written-mode rule
[ ! -e /tmp/quota-plan-x ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL the period number was evaluated"; rm -f /tmp/quota-plan-x; }

echo "quota-plan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
