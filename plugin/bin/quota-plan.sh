#!/usr/bin/env bash
# Plan what to write for one quota, from its periods and its reminders (the contract is
# plugin/skills/quota/SKILL.md section 5, #327). v1 is per-period only: every period is its own one-off reminder
# carrying `Period: <key>`, and a record is written down as `Record: <key>`, never inferred from a date.
# Reads stdin, writes nothing anywhere else.
#
# Usage: quota-plan.sh --now WHEN [--local-tz ZONE] [--through KEY] [--replace] < input
#   --now       the reference time: the same value given to quota-dates.sh as --from (epoch or ISO with offset)
#   --local-tz  the zone of a due given without an offset (tests; the skill passes dues with an offset)
#   --through   the entry's per_period_through: the highest period the skill created under the current schedule
#   --replace   a schedule change: keep the records, delete the other open reminders, create the new schedule
# Input lines (any order):
#   the output of quota-dates.sh --previous for the entry as it is now (period lines; a rule line is ignored)
#   with --replace, optionally the OLD entry's output, each line prefixed with `old ` (`old period ...`)
#   reminder <id> open|completed <due> <period-key|-> <record-key|-> <alarms|-> list|other
#     <due>        YYYY-MM-DD (date-only), or YYYY-MM-DDTHH:MM:SS with an offset or Z (or without, read in --local-tz)
#     <record-key> the reminder's `Record:` line, or -
#     <alarms>     the relative alarms read back, minutes before, comma-separated (`330,0`), `none`, or `-` (not known)
#     list|other   whether it is in the quota's list or in another list (found by the marker search)
# Output lines:
#   reminder <id> class=<matched|record|past-record|off-schedule|history|older|no-period> period=<n|-> dates=<ok|differ|->
#   used <n ...|none>
#   without --replace (list, sync): nothing is deleted or moved
#     action keep <id> <n> due=<D> | rewrite <id> <n> due=<D> | create <n> due=<D> | missing <n> |
#            hold <n> outside-list | list <id> <why> | repair-needed dates-changed
#   with --replace (a schedule change)
#     action record <id> | mark-record <id> <key> | delete <id> | create <n> due=<D> | used <n> | list <id> <why> |
#            replace-blocked <why> | through <key>
# Exit codes: 0 ok, 2 bad input (message on stderr).
set -u
set -f                       # fields come from user-editable notes: never glob-expand them
die() { echo "quota-plan.sh: $*" >&2; exit 2; }

now="" local_tz="" through="" replace=0
while [ $# -gt 0 ]; do
  case "$1" in
    --replace) replace=1; shift; continue ;;
    --now|--local-tz|--through) [ $# -ge 2 ] || die "missing value for $1" ;;
    *) die "unknown option $1" ;;
  esac
  case "$1" in --now) now="$2" ;; --local-tz) local_tz="$2" ;; --through) through="$2" ;; esac
  shift 2
done
[ -n "$now" ] || die "--now is required"
is_day() { case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;; *) return 1 ;; esac; }
[ -z "$through" ] || is_day "$through" || die "--through must be YYYY-MM-DD"
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
alarms_norm() {  # a comma list of integers, sorted, or none / - ; anything else fails
  case "$1" in none|-) echo "$1"; return 0 ;; esac
  case "$1" in *[!0-9,-]*|'') return 1 ;; esac
  printf '%s\n' "${1//,/ }" | tr ' ' '\n' | grep -v '^$' | sort -n | paste -sd, -
}

# --- read the input ------------------------------------------------------------------------------
N_KEY=() N_STATE=() N_DUE=() N_AL=() N_TXT=()
O_KEY=() O_STATE=()
R_ID=() R_ST=() R_DUE=() R_KEY=() R_REC=() R_AL=() R_OUT=()
add_period() {  # N|O, fields after "period"
  local set="$1"; shift
  local n="${1:-}" key="" state="" due="" al="" kv e exp
  shift || true
  case "$n" in ''|*[!0-9]*) die "bad period number: $n" ;; esac
  [ "${#n}" -le 4 ] || die "bad period number: $n"
  for kv in "$@"; do
    case "$kv" in key=*) key="${kv#key=}" ;; state=*) state="${kv#state=}" ;; due=*) due="${kv#due=}" ;;
      alarm_minutes=*) al="${kv#alarm_minutes=}" ;; esac
  done
  is_day "$key" || die "bad period key: $key"
  case "$state" in past|current|future) ;; *) die "bad period state: $state" ;; esac
  case "$al" in *[!0-9]*) die "bad alarm_minutes: $al" ;; esac
  e="$(to_epoch "$due")" && [ -n "$e" ] || die "bad period due: $due"
  if is_day "$due"; then exp=none; elif [ -n "$al" ]; then exp="0,$al"; else exp=0; fi
  if [ "$set" = N ]; then
    [ "$((10#$n))" -eq "${#N_KEY[@]}" ] || die "period lines must be numbered 0, 1, 2, ... in order"
    N_KEY+=("$key"); N_STATE+=("$state"); N_DUE+=("$e"); N_AL+=("$(alarms_norm "$exp")"); N_TXT+=("$due")
  else
    [ "$((10#$n))" -eq "${#O_KEY[@]}" ] || die "old period lines must be numbered 0, 1, 2, ... in order"
    O_KEY+=("$key"); O_STATE+=("$state")
  fi
}
while IFS=$' \t' read -r -a f || [ "${#f[@]}" -gt 0 ]; do
  [ "${#f[@]}" -gt 0 ] || continue
  set_=N
  if [ "${f[0]}" = old ]; then set_=O; f=("${f[@]:1}"); [ "${#f[@]}" -gt 0 ] || die "empty old line"; fi
  case "${f[0]}" in
    period) add_period "$set_" "${f[@]:1}" ;;
    rule) ;;   # v1 is per-period only: the rule line is not used
    reminder)
      [ "$set_" = N ] || die "a reminder line has no old form"
      [ "${#f[@]}" -eq 8 ] || die "bad reminder line (want 8 fields): ${f[*]}"
      case "${f[1]}" in *[!A-Za-z0-9:/._=-]*) die "bad reminder id: ${f[1]}" ;; esac
      case "${f[2]}" in open|completed) ;; *) die "bad reminder state: ${f[*]}" ;; esac
      e="$(to_epoch "${f[3]}")" && [ -n "$e" ] || die "bad due in: ${f[*]}"
      [ "${f[4]}" = "-" ] || is_day "${f[4]}" || die "bad period key: ${f[*]}"
      [ "${f[5]}" = "-" ] || is_day "${f[5]}" || die "bad record key: ${f[*]}"
      a="$(alarms_norm "${f[6]}")" || die "bad alarms: ${f[*]}"
      case "${f[7]}" in list|other) ;; *) die "bad list field: ${f[*]}" ;; esac
      R_ID+=("${f[1]}"); R_ST+=("${f[2]}"); R_DUE+=("$e"); R_KEY+=("${f[4]}"); R_REC+=("${f[5]}"); R_AL+=("$a"); R_OUT+=("${f[7]}") ;;
    *) die "unknown input line: ${f[*]}" ;;
  esac
done
np=${#N_KEY[@]}
[ "$np" -ge 2 ] || die "need period 0 (--previous) and period 1"
[ "${N_STATE[0]}" = past ] || die "period 0 must be the past period (run quota-dates.sh with --previous)"
[ "${#O_KEY[@]}" -eq 0 ] || [ "$replace" -eq 1 ] || die "old period lines are only read with --replace"
[ "${#O_KEY[@]}" -eq 0 ] || [ "${#O_KEY[@]}" -ge 2 ] || die "the old entry's periods 0 and 1 are needed (old period ...)"

nr=${#R_ID[@]}
ORDER=()   # reminder indexes in due order, then id: every list below follows it, never input order
if [ "$nr" -gt 0 ]; then
  ORDER=($(for ((r = 0; r < nr; r++)); do printf '%s %s %s\n' "${R_DUE[$r]}" "${R_ID[$r]}" "$r"; done | sort -k1,1n -k2,2 | awk '{print $3}'))
fi
idx_of_key() { local i; for ((i = 0; i < np; i++)); do [ "${N_KEY[$i]}" = "$1" ] && { echo "$i"; return; }; done; }

# --- classify each reminder by its keys (section 5); a date never makes a record ---------------------------
R_CLASS=() R_P=() R_DATES=()
for ((r = 0; r < nr; r++)); do R_CLASS+=(""); R_P+=("-"); R_DATES+=("-"); done
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
      fi
    elif [[ "${R_KEY[$r]}" < "${N_KEY[0]}" ]]; then
      cls=past-record                        # older than period 0 under the current schedule
    else
      cls=off-schedule                       # its key is not a period of the current schedule: the dates changed
    fi
  fi
  R_CLASS[$r]="$cls"; R_P[$r]="${p:--}"; R_DATES[$r]="$dates"
  echo "reminder ${R_ID[$r]} class=$cls period=${p:--} dates=$dates"
done

USED=()
for ((i = 0; i < np; i++)); do USED+=(0); done
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  [ "${R_CLASS[$r]}" = history ] && [ "${R_P[$r]}" != "-" ] && USED[${R_P[$r]}]=1
done
used_list=""
for ((i = 0; i < np; i++)); do [ "${USED[$i]}" = 1 ] && used_list="$used_list $i"; done
echo "used${used_list:- none}"

# --- --replace: keep the records, delete the other open reminders, create the new schedule -------------------
if [ "$replace" -eq 1 ]; then
  blocked=""
  okey_state() { local i; for ((i = 0; i < ${#O_KEY[@]}; i++)); do [ "${O_KEY[$i]}" = "$1" ] && { echo "${O_STATE[$i]}"; return; }; done; }
  ACT=()
  for r in "${ORDER[@]+"${ORDER[@]}"}"; do
    [ "${R_ST[$r]}" = open ] || continue
    if [ "${R_OUT[$r]}" = other ]; then echo "action list ${R_ID[$r]} outside-list"; blocked="${blocked:-outside-list}"; continue; fi
    if [ "${R_CLASS[$r]}" = record ]; then ACT+=("action record ${R_ID[$r]}"); continue; fi
    if [ "${R_CLASS[$r]}" = no-period ]; then echo "action list ${R_ID[$r]} no-period"; blocked="${blocked:-no-period}"; continue; fi
    key="${R_KEY[$r]}" past=""
    if [ "${#O_KEY[@]}" -gt 0 ]; then
      st="$(okey_state "$key")"
      if [ "$st" = past ] || [[ "$key" < "${O_KEY[0]}" ]]; then past=1; fi
    fi   # without the old periods (a hand edit) nothing is a record unless it says so: a passed due is asked about
    if [ -n "$past" ]; then ACT+=("action mark-record ${R_ID[$r]} $key")
    elif [ "${R_DUE[$r]}" -lt "$now_e" ]; then
      echo "action list ${R_ID[$r]} due-passed"; blocked="${blocked:-due-passed}"      # never kept or deleted unasked
    else ACT+=("action delete ${R_ID[$r]}"); fi
  done
  # A new period whose key a completed reminder or a record already carries is not created again.
  last=""
  for ((i = 1; i < np; i++)); do
    if [ "${USED[$i]}" = 1 ]; then ACT+=("action used $i"); continue; fi
    rec=""
    for r in "${ORDER[@]+"${ORDER[@]}"}"; do
      [ "${R_ST[$r]}" = open ] && [ "${R_CLASS[$r]}" = record ] && [ "${R_REC[$r]}" = "${N_KEY[$i]}" ] && rec="$r"
    done
    if [ -n "$rec" ]; then echo "action list ${R_ID[$rec]} record-on-open-period"; blocked="${blocked:-record-on-open-period}"; continue; fi
    ACT+=("action create $i due=${N_TXT[$i]}"); last="${N_KEY[$i]}"
  done
  if [ -n "$blocked" ]; then echo "action replace-blocked $blocked"; exit 0; fi
  for a in "${ACT[@]+"${ACT[@]}"}"; do echo "$a"; done
  [ -z "$last" ] || echo "action through $last"
  exit 0
fi

# --- list / sync: nothing is deleted or moved ------------------------------------------------------------
changed=0
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  [ "${R_ST[$r]}" = open ] && [ "${R_OUT[$r]}" = list ] || continue
  case "${R_CLASS[$r]}" in
    off-schedule) changed=1 ;;
    matched) if [ "${R_DATES[$r]}" = differ ]; then changed=1; echo "action rewrite ${R_ID[$r]} ${R_P[$r]} due=${N_TXT[${R_P[$r]}]}"; fi ;;
    no-period) echo "action list ${R_ID[$r]} no-period" ;;
  esac
done
if [ "$changed" -eq 1 ]; then echo "action repair-needed dates-changed"; exit 0; fi

TAKEN=" "
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  [ "${R_ST[$r]}" = open ] || continue
  if [ "${R_OUT[$r]}" = other ]; then
    echo "action list ${R_ID[$r]} outside-list"
    [ "${R_P[$r]}" != "-" ] && TAKEN="$TAKEN${R_P[$r]}:hold "
    continue
  fi
  [ "${R_CLASS[$r]}" = matched ] || continue
  own="${R_P[$r]}"
  if [[ "$TAKEN" == *" $own:"* ]] || [ "${USED[$own]}" = 1 ]; then echo "action list ${R_ID[$r]} two-open-reminders"; continue; fi
  TAKEN="$TAKEN$own:keep "
  echo "action keep ${R_ID[$r]} $own due=${N_TXT[$own]}"
done
for ((t = 1; t < np; t++)); do
  [ "${USED[$t]}" = 1 ] && continue
  if [[ "$TAKEN" == *" $t:hold "* ]]; then echo "action hold $t outside-list"; continue; fi
  [[ "$TAKEN" == *" $t:"* ]] && continue
  if [ -n "$through" ] && [[ ! "${N_KEY[$t]}" > "$through" ]]; then echo "action missing $t"; continue; fi
  echo "action create $t due=${N_TXT[$t]}"
done
