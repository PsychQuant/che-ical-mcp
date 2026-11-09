#!/usr/bin/env bash
# Plan what to write for one quota, from its periods and its reminders (the contract is
# plugin/skills/quota/SKILL.md section 5, #327). v1 is per-period only: every period is its own one-off reminder
# carrying `Period: <key>`, and a record is written down as `Record: <key>`, never inferred from a date.
# Reads stdin, writes nothing anywhere else.
#
# Usage: quota-plan.sh --now WHEN [--local-tz ZONE] [--through KEY] [--create-days N] [--replace [--delete-passed ID]...]
#   --now       the reference time: the same value given to quota-dates.sh as --from (epoch or ISO with offset)
#   --local-tz  the entry's local_tz: the zone of a date-only due's end of day, and of a due given without an offset
#   --through   the entry's per_period_through: the highest period the skill created under the current schedule.
#               A value the current schedule does not produce (inside the listed periods, not one of them) was
#               written under other dates: it is ignored, and `keys-changed` is printed.
#   --create-days  create only the periods whose due is within N days of --now (period 1 always). The helper may
#               list more (a wider --horizon-days): those periods are judged, never created, so a reminder on a
#               period just past the creation window is not taken for an off-schedule one.
#   --replace   a schedule change: keep the records and the reminders already on the new dates, delete the
#               other open reminders, create the rest of the new schedule
#   --delete-passed ID   with --replace, after the user's yes: delete this due-passed reminder and create its
#               period anew instead of waiting for its reset (repeat for several; an id the plan does not list
#               as due-passed is an error)
# Input lines (any order):
#   the output of quota-dates.sh --previous for the entry as it is now (period lines, then its rule line; v1 does
#   not use the rule, but the helper prints it last, so an input without it is a helper that stopped early)
#   reminder <id> open|completed <due> <period-key|-> <record-key|-> <alarms|-> list|other
#     <due>        YYYY-MM-DD (date-only), or YYYY-MM-DDTHH:MM:SS with an offset or Z (or without, read in --local-tz)
#     <period-key>, <record-key>  the `Period:` and `Record:` lines' keys, real days YYYY-MM-DD, or -
#     <alarms>     the relative alarms read back, minutes before, digits joined by `,` (`330,0`), `none`, or `-`
#     list|other   whether it is in the quota's list or in another list (found by the marker search)
#   Each id appears once: the open reminders are searched first, so one ticked between the two searches appears
#   twice, and the input is refused.
# Every class is judged by the CURRENT (new) schedule only. A record is a reminder whose period reset under it
# (its key is period 0's or earlier) or one that carries `Record:`; nothing else is ever one.
# Output lines:
#   reminder <id> class=<matched|record|past-record|off-schedule|history|older|no-period> period=<n|->
#            dates=<ok|differ|-> place=<list|other>
#   used <n ...|none>
#   without --replace (list, sync): nothing is deleted or moved
#     action keep <id> <n> due=<D> | rewrite <id> <n> due=<D> | create <n> due=<D> | missing <n> |
#            hold <n> outside-list|record-on-open-period | list <id> <why> | repair-needed dates-changed |
#            keys-changed | through <key> (only when it is above --through, or --through was ignored)
#   with --replace (a schedule change)
#     action record <id> | mark-record <id> <key> | keep <id> <n> due=<D> | realarm <id> <n> due=<D> alarms=<A> |
#            delete <id> | create <n> due=<D> | missing <n> | used <n> | list <id> <why> | replace-blocked <why> |
#            keys-changed | through <key>
#   keys-changed: the period keys changed (an open reminder is off schedule, or --through is stale); --through is
#            not read, and per_period_through is replaced, not raised. Without it, --through holds: a period not
#            after it and without a reminder is `missing`, in a replacement as in sync.
#   <why> (closed list): two-open-reminders, period-used, outside-list, no-period, due-passed, record-on-open-period.
#            A due-passed line also carries due=<the reminder's due> resets=<the reset that makes it a record>.
#   realarm: the reminder's due is its period's and only its alarms differ; <A> is the minutes to write (`none`: [])
# Exit codes: 0 ok, 2 bad input (message on stderr).
set -u
set -f                       # fields come from user-editable notes: never glob-expand them
die() { echo "quota-plan.sh: $*" >&2; exit 2; }

now="" local_tz="" through="" replace=0 create_days=""
DELP=()
while [ $# -gt 0 ]; do
  case "$1" in
    --replace) replace=1; shift; continue ;;
    --now|--local-tz|--through|--create-days|--delete-passed) [ $# -ge 2 ] || die "missing value for $1" ;;
    *) die "unknown option $1" ;;
  esac
  case "$1" in --now) now="$2" ;; --local-tz) local_tz="$2" ;; --through) through="$2" ;; --create-days) create_days="$2" ;;
    --delete-passed) case "$2" in ''|*[!A-Za-z0-9:/._=-]*) die "bad --delete-passed id: $2" ;; esac; DELP+=("$2") ;;
  esac
  shift 2
done
[ -n "$now" ] || die "--now is required"
[ "${#DELP[@]}" -eq 0 ] || [ "$replace" -eq 1 ] || die "--delete-passed is only read with --replace"
is_day() {  # YYYY-MM-DD and a real calendar day (2026-02-30, 0000-00-00 and 9999-99-99 are not)
  case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 1 ;; esac
  [ "$(date -j -f "%Y-%m-%d" "$1" +%Y-%m-%d 2>/dev/null)" = "$1" ]
}
[ -z "$through" ] || is_day "$through" || die "--through must be YYYY-MM-DD"
case "$create_days" in '') ;; *[!0-9]*|0*) die "--create-days must be a whole number from 1" ;; esac
[ "${#create_days}" -le 4 ] || die "--create-days must be a whole number from 1"
if [ -n "$local_tz" ]; then
  case "$local_tz" in *..*|/*) die "unknown --local-tz" ;; esac
  [ "$(head -c 4 "/usr/share/zoneinfo/$local_tz" 2>/dev/null)" = "TZif" ] || die "unknown --local-tz: $local_tz"
fi

to_epoch() {  # a due as epoch seconds; a date-only value as the end of that day in --local-tz (or the host's)
  local v="$1" f
  case "$v" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
      if [ -n "$local_tz" ]; then TZ="$local_tz" date -j -f "%Y-%m-%d %H:%M:%S" "$v 23:59:59" +%s 2>/dev/null
      else date -j -f "%Y-%m-%d %H:%M:%S" "$v 23:59:59" +%s 2>/dev/null; fi ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][+-][0-9][0-9]:[0-9][0-9]|\
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
      f="$(printf '%s' "$v" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/; s/Z$/+0000/')"
      date -j -f "%Y-%m-%dT%H:%M:%S%z" "$f" +%s 2>/dev/null ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9])
      if [ -n "$local_tz" ]; then TZ="$local_tz" date -j -f "%Y-%m-%dT%H:%M:%S" "$v" +%s 2>/dev/null
      else date -j -f "%Y-%m-%dT%H:%M:%S" "$v" +%s 2>/dev/null; fi ;;
    *) return 1 ;;
  esac
}
case "$now" in
  ''|*[!0-9]*) now_e="$(to_epoch "$now")" || die "cannot read --now $now"; [ -n "$now_e" ] || die "cannot read --now $now" ;;
  *) [ "${#now}" -le 12 ] || die "cannot read --now $now"; now_e="$now" ;;
esac
alarms_norm() {  # digits joined by `,`, sorted, or none / - ; anything else (`,`, `5-3`, `0---`) fails
  case "$1" in none|-) echo "$1"; return 0 ;; esac
  [[ "$1" =~ ^[0-9]{1,6}(,[0-9]{1,6})*$ ]] || return 1
  printf '%s\n' "${1//,/ }" | tr ' ' '\n' | grep -v '^$' | sort -n | paste -sd, -
}

# --- read the input ------------------------------------------------------------------------------
N_KEY=() N_STATE=() N_DUE=() N_AL=() N_TXT=() N_RESET=() N_RTXT=()
R_ID=() R_ST=() R_DUE=() R_KEY=() R_REC=() R_AL=() R_OUT=() R_DTXT=()
seen_rule=0
add_period() {  # fields after "period"
  local n="${1:-}" key="" state="" due="" al="" reset="" kv e re exp
  shift || true
  [ "$seen_rule" -eq 0 ] || die "a period line after the rule line: the date helper's output is out of order"
  case "$n" in ''|*[!0-9]*) die "bad period number: $n" ;; esac
  [ "${#n}" -le 4 ] || die "bad period number: $n"
  for kv in "$@"; do
    case "$kv" in key=*) key="${kv#key=}" ;; state=*) state="${kv#state=}" ;; due=*) due="${kv#due=}" ;;
      reset=*) reset="${kv#reset=}" ;; alarm_minutes=*) al="${kv#alarm_minutes=}" ;; esac
  done
  is_day "$key" || die "bad period key: $key"
  case "$state" in past|current|future) ;; *) die "bad period state: $state" ;; esac
  case "$al" in *[!0-9]*) die "bad alarm_minutes: $al" ;; esac
  e="$(to_epoch "$due")" && [ -n "$e" ] || die "bad period due: $due"
  re="$(to_epoch "$reset")" && [ -n "$re" ] || die "bad period reset: $reset"
  if is_day "$due"; then exp=none; elif [ -n "$al" ]; then exp="0,$al"; else exp=0; fi
  [ "$((10#$n))" -eq "${#N_KEY[@]}" ] || die "period lines must be numbered 0, 1, 2, ... in order"
  N_KEY+=("$key"); N_STATE+=("$state"); N_DUE+=("$e"); N_AL+=("$(alarms_norm "$exp")"); N_TXT+=("$due")
  N_RESET+=("$re"); N_RTXT+=("$reset")
}
while IFS=$' \t' read -r -a f || [ "${#f[@]}" -gt 0 ]; do
  [ "${#f[@]}" -gt 0 ] || continue
  case "${f[0]}" in
    period) add_period "${f[@]:1}" ;;
    rule) seen_rule=1 ;;   # v1 is per-period only: the rule is not used, only its presence (the helper's last line)
    reminder)
      [ "${#f[@]}" -eq 8 ] || die "bad reminder line (want 8 fields): ${f[*]}"
      case "${f[1]}" in *[!A-Za-z0-9:/._=-]*) die "bad reminder id: ${f[1]}" ;; esac
      case "${f[2]}" in open|completed) ;; *) die "bad reminder state: ${f[*]}" ;; esac
      e="$(to_epoch "${f[3]}")" && [ -n "$e" ] || die "bad due in: ${f[*]}"
      [ "${f[4]}" = "-" ] || is_day "${f[4]}" || die "bad period key: ${f[*]}"
      [ "${f[5]}" = "-" ] || is_day "${f[5]}" || die "bad record key: ${f[*]}"
      a="$(alarms_norm "${f[6]}")" || die "bad alarms: ${f[*]}"
      case "${f[7]}" in list|other) ;; *) die "bad list field: ${f[*]}" ;; esac
      for x in "${R_ID[@]+"${R_ID[@]}"}"; do
        [ "$x" != "${f[1]}" ] || die "reminder ${f[1]} appears twice (ticked between the two searches?): search again"
      done
      R_ID+=("${f[1]}"); R_ST+=("${f[2]}"); R_DUE+=("$e"); R_KEY+=("${f[4]}"); R_REC+=("${f[5]}"); R_AL+=("$a"); R_OUT+=("${f[7]}")
      R_DTXT+=("${f[3]}") ;;
    *) die "unknown input line: ${f[*]}" ;;
  esac
done
np=${#N_KEY[@]}
[ "$np" -ge 2 ] || die "need period 0 (--previous) and period 1"
[ "${N_STATE[0]}" = past ] || die "period 0 must be the past period (run quota-dates.sh with --previous)"
[ "$seen_rule" -eq 1 ] || die "no rule line: the date helper's output stopped early (did quota-dates.sh exit 2?); nothing is planned"

nr=${#R_ID[@]}
ORDER=()   # reminder indexes in due order, then id: every list below follows it, never input order
if [ "$nr" -gt 0 ]; then
  ORDER=($(for ((r = 0; r < nr; r++)); do printf '%s %s %s\n' "${R_DUE[$r]}" "${R_ID[$r]}" "$r"; done | sort -k1,1n -k2,2 | awk '{print $3}'))
fi
idx_of_key() { local i; for ((i = 0; i < np; i++)); do [ "${N_KEY[$i]}" = "$1" ] && { echo "$i"; return; }; done; }
in_window() {  # period $1 is created only within --create-days (period 1 always)
  [ -z "$create_days" ] || [ "$1" -le 1 ] || [ "${N_DUE[$1]}" -le $(( now_e + create_days * 86400 )) ]
}
# The open periods (n >= 1) a record holds: the period of its Record: key and of its Period: key, when still open.
record_holds() {
  local r="$1" k t seen=" "
  for k in "${R_REC[$r]}" "${R_KEY[$r]}"; do
    [ "$k" != "-" ] || continue
    t="$(idx_of_key "$k")"
    [ -n "$t" ] && [ "$t" -ge 1 ] && [[ "$seen" != *" $t "* ]] && { seen="$seen$t "; echo "$t"; }
  done
}

# --- classify each reminder by its keys (section 5); a date never makes a record ---------------------------
R_CLASS=() R_P=() R_DATES=() R_ALONLY=()
for ((r = 0; r < nr; r++)); do R_CLASS+=(""); R_P+=("-"); R_DATES+=("-"); R_ALONLY+=(0); done
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  cls="" p="" dates="-"
  if [ "${R_ST[$r]}" = completed ]; then
    if [ "${R_KEY[$r]}" = "-" ]; then cls=older
    else cls=history; p="$(idx_of_key "${R_KEY[$r]}")"; fi
  elif [ "${R_REC[$r]}" != "-" ]; then
    cls=record                               # written down by a replacement: a record whatever its date
  elif [ "${R_KEY[$r]}" = "-" ]; then
    cls=no-period
  else
    p="$(idx_of_key "${R_KEY[$r]}")"
    if [ -n "$p" ]; then
      if [ "${N_STATE[$p]}" = past ]; then cls=past-record
      else
        cls=matched
        if [ "${R_DUE[$r]}" = "${N_DUE[$p]}" ] && { [ "${R_AL[$r]}" = "-" ] || [ "${R_AL[$r]}" = "${N_AL[$p]}" ]; }; then dates=ok; else dates=differ; fi
        [ "$dates" = differ ] && [ "${R_DUE[$r]}" = "${N_DUE[$p]}" ] && R_ALONLY[$r]=1   # same due, other alarms
      fi
    elif [[ "${R_KEY[$r]}" < "${N_KEY[0]}" ]]; then
      cls=past-record                        # older than period 0 under the current schedule
    else
      cls=off-schedule                       # its key is not a period of the current schedule: the dates changed
    fi
  fi
  R_CLASS[$r]="$cls"; R_P[$r]="${p:--}"; R_DATES[$r]="$dates"
  echo "reminder ${R_ID[$r]} class=$cls period=${p:--} dates=$dates place=${R_OUT[$r]}"
done

USED=()
for ((i = 0; i < np; i++)); do USED+=(0); done
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  [ "${R_CLASS[$r]}" = history ] && [ "${R_P[$r]}" != "-" ] && USED[${R_P[$r]}]=1
done
used_list=""
for ((i = 0; i < np; i++)); do [ "${USED[$i]}" = 1 ] && used_list="$used_list $i"; done
echo "used${used_list:- none}"

# per_period_through is a key of the schedule that wrote it. One inside the listed periods that is not one of them
# was written under other dates: the keys changed, even with no reminder left open (#499 r8).
kc=0
if [ -n "$through" ] && [[ ! "$through" < "${N_KEY[0]}" ]] && [[ ! "$through" > "${N_KEY[$((np - 1))]}" ]] \
   && [ -z "$(idx_of_key "$through")" ]; then kc=1; fi

# --- --replace: keep the records and what already matches, delete the rest, create the new schedule -----------
# Every decision is by the NEW schedule. A record is never deleted or offered for deletion; a reminder whose
# period has not reset under the new dates is never made a record (no mark-record on an open period).
if [ "$replace" -eq 1 ]; then
  blocked=""
  block() { echo "action list $1 $2${3:+ $3}"; blocked="${blocked:-$2}"; }
  in_delp() { local x; for x in "${DELP[@]+"${DELP[@]}"}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
  # A reminder this replacement would delete (in the quota's list, off schedule, or on its period with another due)
  # becomes a record only at the first new reset at or after its key. It can block a run (due-passed) from its due
  # until that reset. W holds every such reminder whose due has passed or comes before that reset, so the question
  # names them all at once; the replacement waits only while one of them has actually passed (anyp).
  W=() WRS=() anyp=0
  for ((r = 0; r < nr; r++)); do W+=(0); WRS+=("-"); done
  for r in "${ORDER[@]+"${ORDER[@]}"}"; do
    [ "${R_ST[$r]}" = open ] && [ "${R_OUT[$r]}" = list ] || continue
    case "${R_CLASS[$r]}" in
      off-schedule) t=""; for ((i = 1; i < np; i++)); do [[ "${N_KEY[$i]}" < "${R_KEY[$r]}" ]] || { t="$i"; break; }; done ;;
      matched) [ "${R_DATES[$r]}" = differ ] && [ "${R_ALONLY[$r]}" = 0 ] && [ "${USED[${R_P[$r]}]}" = 0 ] || continue
               t="${R_P[$r]}" ;;
      *) continue ;;
    esac
    if [ "${R_DUE[$r]}" -lt "$now_e" ]; then W[$r]=1; anyp=1
    elif [ -n "$t" ] && [ "${R_DUE[$r]}" -lt "${N_RESET[$t]}" ]; then W[$r]=1; fi
    [ -z "$t" ] || WRS[$r]="${N_RTXT[$t]}"
  done
  ACT=() KEPT=" " DELP_USED=" "
  for r in "${ORDER[@]+"${ORDER[@]}"}"; do
    [ "${R_ST[$r]}" = open ] || continue
    id="${R_ID[$r]}"
    # A record stays wherever it is: never written but for its Record: line, so another list does not block. A
    # past-record in another list stays too, unwritten: the skill never writes there (#499 r8 #3).
    if [ "${R_CLASS[$r]}" = record ]; then ACT+=("action record $id"); continue; fi   # its open periods: below
    if [ "${R_CLASS[$r]}" = past-record ] && [ "${R_OUT[$r]}" = other ]; then ACT+=("action record $id"); continue; fi
    [ "${R_CLASS[$r]}" = off-schedule ] && kc=1
    if [ "${R_OUT[$r]}" = other ]; then block "$id" outside-list; continue; fi
    case "${R_CLASS[$r]}" in
      past-record) ACT+=("action mark-record $id ${R_KEY[$r]}"); continue ;;
      no-period) block "$id" no-period; continue ;;
      matched)
        own="${R_P[$r]}"
        if [ "${USED[$own]}" = 1 ]; then block "$id" period-used; continue; fi
        if [ "${R_DATES[$r]}" = ok ] || [ "${R_ALONLY[$r]}" = 1 ]; then   # on the new due: kept, not recreated
          if [[ "$KEPT" == *" $own "* ]]; then block "$id" two-open-reminders; continue; fi
          KEPT="$KEPT$own "
          if [ "${R_DATES[$r]}" = ok ]; then ACT+=("action keep $id $own due=${N_TXT[$own]}")
          else ACT+=("action realarm $id $own due=${N_TXT[$own]} alarms=${N_AL[$own]}"); fi   # #499 r7 #1
          continue
        fi ;;
    esac
    # off-schedule, or matched with another due: its period has not reset under the new dates
    if [ "${W[$r]}" = 1 ] && [ "$anyp" -eq 1 ]; then
      if in_delp "$id"; then ACT+=("action delete $id"); DELP_USED="$DELP_USED$id "
      else block "$id" due-passed "due=${R_DTXT[$r]} resets=${WRS[$r]}"; fi   # delete after a yes, or wait
    else ACT+=("action delete $id"); fi
  done
  for x in "${DELP[@]+"${DELP[@]}"}"; do
    [[ "$DELP_USED" == *" $x "* ]] || die "--delete-passed $x: the plan does not list that reminder as due-passed"
  done
  # A new period whose key a completed reminder carries is not created again; one kept is not created either.
  # through counts every period created, kept or used (#499 r7 #11), so a used one later cleaned up stays missing.
  HELD=" "
  for r in "${ORDER[@]+"${ORDER[@]}"}"; do
    [ "${R_ST[$r]}" = open ] && [ "${R_CLASS[$r]}" = record ] || continue
    for t in $(record_holds "$r"); do
      [[ "$HELD" == *" $t "* ]] || [ "${USED[$t]}" = 1 ] && continue   # a used period is not created anyway
      HELD="$HELD$t "; block "${R_ID[$r]}" record-on-open-period
    done
  done
  # When the keys did not change (only dues or alarms did), per_period_through still describes these periods: a
  # period the user deleted stays missing (#499 r8 #2). When they changed, it is not read.
  thr="$through"; [ "$kc" -eq 0 ] || thr=""
  last=""
  for ((i = 1; i < np; i++)); do
    if [ "${USED[$i]}" = 1 ]; then ACT+=("action used $i"); last="${N_KEY[$i]}"; continue; fi
    [[ "$HELD" == *" $i "* ]] && continue
    if [[ "$KEPT" == *" $i "* ]]; then last="${N_KEY[$i]}"; continue; fi
    if [ -n "$thr" ] && [[ ! "${N_KEY[$i]}" > "$thr" ]]; then ACT+=("action missing $i"); continue; fi
    in_window "$i" || continue
    last="${N_KEY[$i]}"
    ACT+=("action create $i due=${N_TXT[$i]}")
  done
  if [ -n "$blocked" ]; then echo "action replace-blocked $blocked"; exit 0; fi
  for a in "${ACT[@]+"${ACT[@]}"}"; do echo "$a"; done
  [ "$kc" -eq 0 ] || echo "action keys-changed"
  if [ -n "$thr" ] && { [ -z "$last" ] || [[ "$thr" > "$last" ]]; }; then last="$thr"; fi
  [ -z "$last" ] || echo "action through $last"
  exit 0
fi

# --- list / sync: nothing is deleted or moved ------------------------------------------------------------
# A reminder in another list is only listed, but it still counts: off schedule or on other dates, it means the
# dates changed, the same as in the quota's list.
changed=0
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  [ "${R_ST[$r]}" = open ] || continue
  if [ "${R_OUT[$r]}" = other ]; then
    echo "action list ${R_ID[$r]} outside-list"
    case "${R_CLASS[$r]}" in
      off-schedule) changed=1 ;;
      matched) [ "${R_DATES[$r]}" = differ ] && changed=1 ;;
    esac
    continue
  fi
  case "${R_CLASS[$r]}" in
    off-schedule) changed=1 ;;
    matched) if [ "${R_DATES[$r]}" = differ ]; then changed=1; echo "action rewrite ${R_ID[$r]} ${R_P[$r]} due=${N_TXT[${R_P[$r]}]}"; fi ;;
    no-period) echo "action list ${R_ID[$r]} no-period" ;;
  esac
done
if [ "$changed" -eq 1 ]; then echo "action repair-needed dates-changed"; exit 0; fi
if [ "$kc" -eq 1 ]; then echo "action keys-changed"; through=""; fi

# Holds first (records in any list, reminders in another list), then the quota's list, so the plan does not
# depend on the order of the ids (#499 r8).
TAKEN=" "
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  [ "${R_ST[$r]}" = open ] || continue
  # The same hold as --replace: a record on an open period (its Record: or Period: key), in any list (#499 r7 #2).
  if [ "${R_CLASS[$r]}" = record ]; then
    h=0
    for t in $(record_holds "$r"); do TAKEN="$TAKEN$t:rec "; h=1; done
    [ "$h" -eq 0 ] || echo "action list ${R_ID[$r]} record-on-open-period"
    continue
  fi
  [ "${R_OUT[$r]}" = other ] && [ "${R_P[$r]}" != "-" ] && TAKEN="$TAKEN${R_P[$r]}:hold "
done
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  [ "${R_ST[$r]}" = open ] && [ "${R_OUT[$r]}" = list ] && [ "${R_CLASS[$r]}" = matched ] || continue
  own="${R_P[$r]}"
  if [ "${USED[$own]}" = 1 ]; then echo "action list ${R_ID[$r]} period-used"; continue; fi
  if [[ "$TAKEN" == *" $own:keep "* ]] || [[ "$TAKEN" == *" $own:hold "* ]]; then
    echo "action list ${R_ID[$r]} two-open-reminders"; continue
  fi
  TAKEN="$TAKEN$own:keep "
  echo "action keep ${R_ID[$r]} $own due=${N_TXT[$own]}"
done
last=""   # the highest period used, kept or created: per_period_through after the creates (#499 r7 #11)
for ((t = 1; t < np; t++)); do
  [ "${USED[$t]}" = 1 ] && { last="${N_KEY[$t]}"; continue; }
  if [[ "$TAKEN" == *" $t:hold "* ]]; then echo "action hold $t outside-list"; continue; fi
  [[ "$TAKEN" == *" $t:keep "* ]] && { last="${N_KEY[$t]}"; continue; }
  if [[ "$TAKEN" == *" $t:rec "* ]]; then echo "action hold $t record-on-open-period"; continue; fi
  if [ -n "$through" ] && [[ ! "${N_KEY[$t]}" > "$through" ]]; then echo "action missing $t"; continue; fi
  in_window "$t" || continue
  echo "action create $t due=${N_TXT[$t]}"; last="${N_KEY[$t]}"
done
if [ -n "$last" ] && { [ -z "$through" ] || [[ "$last" > "$through" ]]; }; then echo "action through $last"; fi
