#!/usr/bin/env bash
# Plan what to write for one quota, from its periods and its reminders (the contract is
# plugin/skills/quota/SKILL.md section 5, #327). Reads stdin, writes nothing anywhere else.
#
# Usage: quota-plan.sh --now WHEN --written-mode rule|per-period|unknown [--local-tz ZONE] [--through KEY] [--repair] < input
#   --now           the reference time: the same value given to quota-dates.sh as --from (epoch or ISO with offset)
#   --written-mode  the mode the existing reminders were written in: the entry's stored `mode` (`unknown` when the
#                   entry has none: then nothing is planned but repair-needed)
#   --local-tz      the zone of a due given without an offset (tests; the skill passes dues with an offset)
#   --through       per-period: the entry's per_period_through, the last period the skill created a reminder for
#   --repair        re-pair the open reminders with the periods (an update, or a yes in sync)
# Input lines (any order):
#   the output of quota-dates.sh --previous ...      (period lines and the rule line: the mode to write in)
#   reminder <id> open|completed <due> <period-key|-> <alarms|-> list|other
#     <due>     YYYY-MM-DD (date-only), or YYYY-MM-DDTHH:MM:SS with an offset or Z (or without, read in --local-tz)
#     <alarms>  the relative alarms read back, minutes before, comma-separated (`330,0`), `none`, or `-` (not known)
#     list|other  whether it is in the quota's list or in another list (found by the marker search)
# Output lines:
#   mode rule|per-period            the mode to write in (from the rule line)
#   written-mode rule|per-period|unknown
#   reminder <id> class=<matched|off-schedule|beyond|past-record|history|older|ambiguous> period=<n|-> dates=<ok|differ|->
#   used <n ...|none>
#   boundary <n|none>               the latest used period
#   action keep <id> <n> due=<D> | rewrite <id> <n> due=<D> | move <id> <n> due=<D> | create <n> due=<D> | missing <n> |
#          leftover <id> | restart <id> <n> due=<D> | record <id> | hold <n> ambiguous | list <id> <why> | repair-needed <why>
# Exit codes: 0 ok, 2 bad input (message on stderr).
set -u
set -f                       # fields come from user-editable notes: never glob-expand them
die() { echo "quota-plan.sh: $*" >&2; exit 2; }

now="" wmode="" local_tz="" through="" repair=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repair) repair=1; shift; continue ;;
    --now|--written-mode|--local-tz|--through) [ $# -ge 2 ] || die "missing value for $1" ;;
    *) die "unknown option $1" ;;
  esac
  case "$1" in --now) now="$2" ;; --written-mode) wmode="$2" ;; --local-tz) local_tz="$2" ;; --through) through="$2" ;; esac
  shift 2
done
[ -n "$now" ] || die "--now is required"
case "$wmode" in rule|per-period|unknown) ;; *) die "--written-mode must be rule, per-period or unknown" ;; esac
is_day() { case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;; *) return 1 ;; esac; }
[ -z "$through" ] || is_day "$through" || die "--through must be YYYY-MM-DD"
if [ -n "$local_tz" ]; then
  case "$local_tz" in *..*|/*) die "unknown --local-tz" ;; esac
  [ "$(head -c 4 "/usr/share/zoneinfo/$local_tz" 2>/dev/null)" = "TZif" ] || die "unknown --local-tz: $local_tz"
fi

# A due as epoch seconds; a date-only value as 12:00 UTC of that day (zone-free, for distances).
to_epoch() {
  local v="$1" f
  case "$v" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
      TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "$v 12:00:00" +%s 2>/dev/null ;;
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
P_N=() P_KEY=() P_STATE=() P_DUE=() P_AL=() P_TXT=() mode="" dateonly=""
R_ID=() R_ST=() R_DUE=() R_KEY=() R_AL=() R_OUT=()
while IFS=$' \t' read -r -a f || [ "${#f[@]}" -gt 0 ]; do
  [ "${#f[@]}" -gt 0 ] || continue
  case "${f[0]}" in
    period)
      n="${f[1]:-}" key="" state="" due="" al=""
      case "$n" in ''|*[!0-9]*) die "bad period number: ${f[*]}" ;; esac
      [ "${#n}" -le 4 ] || die "bad period number: ${f[*]}"
      for kv in "${f[@]:2}"; do
        case "$kv" in key=*) key="${kv#key=}" ;; state=*) state="${kv#state=}" ;; due=*) due="${kv#due=}" ;;
          alarm_minutes=*) al="${kv#alarm_minutes=}" ;; esac
      done
      is_day "$key" || die "bad period key: ${f[*]}"
      case "$state" in past|current|future) ;; *) die "bad period state: ${f[*]}" ;; esac
      case "$al" in ''|[0-9]*) ;; *) die "bad alarm_minutes: ${f[*]}" ;; esac
      case "$al" in *[!0-9]*) die "bad alarm_minutes: ${f[*]}" ;; esac
      e="$(to_epoch "$due")" && [ -n "$e" ] || die "bad due in: ${f[*]}"
      if is_day "$due"; then dateonly=1; exp=none; elif [ -n "$al" ]; then exp="0,$al"; else exp=0; fi
      P_N+=("$((10#$n))"); P_KEY+=("$key"); P_STATE+=("$state"); P_DUE+=("$e"); P_AL+=("$(alarms_norm "$exp")"); P_TXT+=("$due") ;;
    rule)
      if [ "${f[1]:-}" = none ]; then mode=per-period; else mode=rule; fi ;;
    reminder)
      [ "${#f[@]}" -eq 7 ] || die "bad reminder line (want 7 fields): ${f[*]}"
      case "${f[1]}" in *[!A-Za-z0-9:/._=-]*) die "bad reminder id: ${f[1]}" ;; esac
      case "${f[2]}" in open|completed) ;; *) die "bad reminder state: ${f[*]}" ;; esac
      e="$(to_epoch "${f[3]}")" && [ -n "$e" ] || die "bad due in: ${f[*]}"
      [ "${f[4]}" = "-" ] || is_day "${f[4]}" || die "bad period key: ${f[*]}"
      a="$(alarms_norm "${f[5]}")" || die "bad alarms: ${f[*]}"
      case "${f[6]}" in list|other) ;; *) die "bad list field: ${f[*]}" ;; esac
      R_ID+=("${f[1]}"); R_ST+=("${f[2]}"); R_DUE+=("$e"); R_KEY+=("${f[4]}"); R_AL+=("$a"); R_OUT+=("${f[6]}") ;;
    *) die "unknown input line: ${f[*]}" ;;
  esac
done
[ -n "$mode" ] || die "no rule line"
np=${#P_N[@]}
[ "$np" -ge 2 ] || die "need period 0 (--previous) and period 1"
[ "${P_N[0]}" = 0 ] || die "the first period line must be period 0 (run quota-dates.sh with --previous)"
for ((i = 1; i < np; i++)); do [ "${P_N[$i]}" -eq "$i" ] || die "period lines must be numbered 0, 1, 2, ... in order"; done
echo "mode $mode"
echo "written-mode $wmode"
if [ "$wmode" = unknown ]; then echo "action repair-needed written-mode-unknown"; exit 0; fi

nr=${#R_ID[@]}
# Every list below is in due order (round 3): sort the reminder indexes once by due, then by id.
ORDER=()
if [ "$nr" -gt 0 ]; then
  ORDER=($(for ((r = 0; r < nr; r++)); do printf '%s %s %s\n' "${R_DUE[$r]}" "${R_ID[$r]}" "$r"; done | sort -k1,1n -k2,2 | awk '{print $3}'))
fi
abs() { local v=$1; [ "$v" -lt 0 ] && v=$(( -v )); echo "$v"; }

# --- classify each reminder (section 5) ----------------------------------------------------------
half_lo=$(( (P_DUE[1] - P_DUE[0]) / 2 ))
half_hi=$(( (P_DUE[np - 1] - P_DUE[np - 2]) / 2 ))
R_CLASS=() R_P=() R_P2=() R_DATES=()
for ((r = 0; r < nr; r++)); do R_CLASS+=(""); R_P+=("-"); R_P2+=("-"); R_DATES+=("-"); done
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  cls="" p=""
  use_key=0
  [ "$wmode" = per-period ] && [ "${R_KEY[$r]}" != "-" ] && use_key=1
  if [ "$use_key" -eq 1 ]; then
    for ((i = 0; i < np; i++)); do [ "${P_KEY[$i]}" = "${R_KEY[$r]}" ] && p="$i"; done
  else   # rule mode reads a reminder's period from its due; a leftover Period: line is ignored (round 3)
    for ((i = 0; i < np; i++)); do [ "${P_DUE[$i]}" = "${R_DUE[$r]}" ] && p="$i"; done
  fi
  if [ -n "$p" ]; then
    if [ "${P_STATE[$p]}" = past ]; then
      if [ "${R_ST[$r]}" = open ]; then cls=past-record; else cls=history; fi
    else
      cls=matched
    fi
    if [ "${R_ST[$r]}" = open ]; then
      if [ "${R_DUE[$r]}" = "${P_DUE[$p]}" ] && { [ "${R_AL[$r]}" = "-" ] || [ "${R_AL[$r]}" = "${P_AL[$p]}" ]; }; then
        R_DATES[$r]=ok; else R_DATES[$r]=differ; fi
    fi
  elif [ "${R_DUE[$r]}" -lt $(( P_DUE[0] - half_lo )) ]; then
    if [ "${R_ST[$r]}" = open ]; then cls=past-record; else cls=older; fi
  elif [ "${R_DUE[$r]}" -gt $(( P_DUE[np - 1] + half_hi )) ]; then
    cls=beyond; p=$((np - 1))     # after the last listed period: it holds a period beyond the horizon
  else
    best="" bestd="" second=""
    for ((i = 0; i < np; i++)); do
      d="$(abs $(( R_DUE[r] - P_DUE[i] )))"
      if [ -z "$bestd" ] || [ "$d" -lt "$bestd" ]; then best="$i" bestd="$d" second=""
      elif [ "$d" -eq "$bestd" ]; then second="$i"; fi
    done
    p="$best"
    if [ -n "$second" ]; then cls=ambiguous; R_P2[$r]="$second"
    elif [ "${R_ST[$r]}" = completed ]; then cls=history
    elif [ "${P_STATE[$p]}" = past ] && [ "${R_DUE[$r]}" -lt "$now_e" ]; then cls=past-record
    else cls=off-schedule; R_DATES[$r]=differ; fi
  fi
  R_CLASS[$r]="$cls"; R_P[$r]="${p:--}"
  echo "reminder ${R_ID[$r]} class=$cls period=${p:--} dates=${R_DATES[$r]}"
done

# --- used periods ----------------------------------------------------------------------------------
USED=()
for ((i = 0; i < np; i++)); do USED+=(0); done
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  if [ "${R_ST[$r]}" = completed ] && [ "${R_P[$r]}" != "-" ]; then
    case "${R_CLASS[$r]}" in matched|history) USED[${R_P[$r]}]=1 ;; esac
  fi
done
LIVE=()   # open reminders that hold a period whose reset is ahead, in due order
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  if [ "${R_ST[$r]}" = open ]; then
    case "${R_CLASS[$r]}" in matched|off-schedule|beyond|ambiguous) LIVE+=("$r") ;; esac
  fi
done
# A recurring reminder moves on only when ticked, so in rule mode it has rolled past every period before its own.
# Only reminders WRITTEN in rule mode are evidence of that; open one-off reminders roll past nothing (round 3).
if [ "$wmode" = rule ]; then
  for r in "${LIVE[@]+"${LIVE[@]}"}"; do
    [ "${R_CLASS[$r]}" = ambiguous ] && continue
    for ((m = 1; m < R_P[r]; m++)); do USED[$m]=1; done
  done
fi
used_list="" boundary=none
for ((i = 0; i < np; i++)); do
  if [ "${USED[$i]}" = 1 ]; then used_list="$used_list $i"; boundary="$i"; fi
done
echo "used${used_list:- none}"
echo "boundary $boundary"

# Targets: the periods whose reset is ahead and that are not used. Rule mode: the first one only.
TARGETS=()
for ((i = 1; i < np; i++)); do [ "${USED[$i]}" = 1 ] || TARGETS+=("$i"); done
if [ "$mode" = rule ] && [ "${#TARGETS[@]}" -gt 1 ]; then TARGETS=("${TARGETS[0]}"); fi

# Periods an ambiguous reminder may belong to; in rule mode it may be the series, so it holds every period.
HOLD=" "
amb=0
for r in "${LIVE[@]+"${LIVE[@]}"}"; do
  if [ "${R_CLASS[$r]}" = ambiguous ]; then
    amb=1; HOLD="$HOLD${R_P[$r]} ${R_P2[$r]} "
    echo "action list ${R_ID[$r]} ambiguous"
  fi
done
held() { [ "$mode" = rule ] && [ "$amb" -eq 1 ] && return 0; [[ "$HOLD" == *" $1 "* ]]; }

# Restart record: the open past-period record with the latest due (never input order, round 3).
stopped=""
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  [ "${R_ST[$r]}" = open ] && [ "${R_CLASS[$r]}" = past-record ] && stopped="$r"
done

emit_assign() {  # reminder index, period: keep / rewrite / move, or list when it is in another list
  local r="$1" t="$2"
  if [ "${R_OUT[$r]}" = other ]; then echo "action list ${R_ID[$r]} outside-list"; return; fi
  if [ "${R_P[$r]}" = "$t" ] && [ "${R_CLASS[$r]}" = matched ]; then
    if [ "${R_DATES[$r]}" = ok ]; then echo "action keep ${R_ID[$r]} $t due=${P_TXT[$t]}"; else echo "action rewrite ${R_ID[$r]} $t due=${P_TXT[$t]}"; fi
  else
    echo "action move ${R_ID[$r]} $t due=${P_TXT[$t]}"
  fi
}
emit_free() {  # a target no reminder holds
  local t="$1"
  if held "$t"; then echo "action hold $t ambiguous"; return; fi
  if [ -n "$through" ] && [ "$mode" = per-period ] && [[ ! "${P_KEY[$t]}" > "$through" ]]; then echo "action missing $t"; return; fi
  echo "action create $t due=${P_TXT[$t]}"
}

# --- plan without --repair: never move; anything whose dates differ is a dates change -------------------
if [ "$repair" -eq 0 ]; then
  changed=0
  for r in "${LIVE[@]+"${LIVE[@]}"}"; do
    case "${R_CLASS[$r]}" in off-schedule) changed=1 ;; matched) [ "${R_DATES[$r]}" = differ ] && changed=1 ;; esac
  done
  [ "$wmode" != "$mode" ] && changed=1
  if [ "$changed" -eq 1 ]; then echo "action repair-needed dates-changed"; exit 0; fi
fi

# --- assign live reminders to targets, in due order ------------------------------------------------
TAKEN=" "
LEFT=()
if [ "$mode" = rule ]; then
  first=""
  for r in "${LIVE[@]+"${LIVE[@]}"}"; do
    [ "${R_CLASS[$r]}" = ambiguous ] && continue
    if [ "${R_CLASS[$r]}" = beyond ]; then echo "action keep ${R_ID[$r]} beyond"; first=done; continue; fi
    if [ -z "$first" ] && [ "${#TARGETS[@]}" -gt 0 ]; then
      t="${TARGETS[0]}"
      if held "$t"; then echo "action hold $t ambiguous"; else emit_assign "$r" "$t"; fi
      TAKEN="$TAKEN$t "; first="$r"
    else
      LEFT+=("$r")
    fi
  done
  for r in "${LEFT[@]+"${LEFT[@]}"}"; do
    if [ "$repair" -eq 1 ]; then echo "action leftover ${R_ID[$r]}"; else echo "action list ${R_ID[$r]} two-open-reminders"; fi
  done
  if [ -z "$first" ] && [ "${#TARGETS[@]}" -gt 0 ] && [ "$amb" -eq 0 ]; then
    t="${TARGETS[0]}"
    if [ -n "$stopped" ]; then echo "action restart ${R_ID[$stopped]} $t due=${P_TXT[$t]}"; else emit_free "$t"; fi
  elif [ -z "$first" ] && [ "$amb" -eq 1 ] && [ "${#TARGETS[@]}" -gt 0 ]; then
    echo "action hold ${TARGETS[0]} ambiguous"
  fi
  for r in "${ORDER[@]+"${ORDER[@]}"}"; do
    [ "${R_ST[$r]}" = open ] && [ "${R_CLASS[$r]}" = past-record ] && [ "$r" != "${stopped:-x}" ] && echo "action record ${R_ID[$r]}"
  done
  exit 0
fi

# per-period: each live reminder takes its own period when that is a free target, else the first free target
# after its own period (never an earlier one); the free targets left are created, missing or held.
for r in "${LIVE[@]+"${LIVE[@]}"}"; do
  [ "${R_CLASS[$r]}" = ambiguous ] && continue
  if [ "${R_CLASS[$r]}" = beyond ]; then echo "action keep ${R_ID[$r]} beyond"; continue; fi
  own="${R_P[$r]}" got=""
  for t in "${TARGETS[@]+"${TARGETS[@]}"}"; do
    if [ "$t" = "$own" ] && [[ "$TAKEN" != *" $t "* ]]; then got="$t"; break; fi
  done
  if [ -z "$got" ] && [ "$repair" -eq 1 ]; then
    for t in "${TARGETS[@]+"${TARGETS[@]}"}"; do
      if [ "$t" -gt "$own" ] && [[ "$TAKEN" != *" $t "* ]] && ! held "$t"; then got="$t"; break; fi
    done
  fi
  if [ -n "$got" ]; then
    if held "$got"; then echo "action hold $got ambiguous"; else emit_assign "$r" "$got"; fi
    TAKEN="$TAKEN$got "
  elif [ "$repair" -eq 1 ]; then echo "action leftover ${R_ID[$r]}"
  else echo "action list ${R_ID[$r]} two-open-reminders"; fi
done
for t in "${TARGETS[@]+"${TARGETS[@]}"}"; do
  [[ "$TAKEN" == *" $t "* ]] && continue
  have=""
  for r in "${ORDER[@]+"${ORDER[@]}"}"; do   # a completed reminder on it means used (not a target); an outside one holds it
    [ "${R_P[$r]}" = "$t" ] && [ "${R_OUT[$r]}" = other ] && have=1
  done
  [ -z "$have" ] && emit_free "$t"
done
