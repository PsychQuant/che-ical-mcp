#!/usr/bin/env bash
# Plan what to write for one quota, from its periods and its reminders (the contract is
# plugin/skills/quota/SKILL.md section 5, #327). Reads stdin, writes nothing anywhere else.
#
# Usage: quota-plan.sh --now WHEN [--local-tz ZONE] [--through KEY] [--repair]  < input
#   --now       the reference time the helper used (--from): epoch seconds or YYYY-MM-DDTHH:MM:SS±HH:MM
#   --local-tz  the zone of reminder dues given without an offset (the entry's local_tz)
#   --through   per-period mode: the entry's per_period_through, the last period the skill created a reminder for
#   --repair    re-pair the open reminders with the periods after the history boundary (an update, or a yes in sync)
# Input lines (any order):
#   the output of quota-dates.sh --previous ...      (period lines and the rule line)
#   reminder <id> open|completed <due> <period-key|->
#     <due> is YYYY-MM-DD (date-only), YYYY-MM-DDTHH:MM:SS (in --local-tz) or with an offset.
# Output lines:
#   mode rule|per-period
#   reminder <id> class=<matched|off-schedule|past-record|history|older|ambiguous> period=<n|->
#   used <n ...|none>
#   boundary <n|none>      the latest used period: the history boundary
#   action keep <id> <n> | move <id> <n> | create <n> | missing <n> | leftover <id> | restart <id> <n> |
#          list <id> <why> | repair-needed
# Exit codes: 0 ok, 2 bad input (message on stderr).
set -u
die() { echo "quota-plan.sh: $*" >&2; exit 2; }

now="" local_tz="" through="" repair=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repair) repair=1; shift; continue ;;
    --now|--local-tz|--through) [ $# -ge 2 ] || die "missing value for $1" ;;
    *) die "unknown option $1" ;;
  esac
  case "$1" in --now) now="$2" ;; --local-tz) local_tz="$2" ;; --through) through="$2" ;; esac
  shift 2
done
[ -n "$now" ] || die "--now is required"
case "$through" in ''|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) die "--through must be YYYY-MM-DD" ;; esac
if [ -n "$local_tz" ]; then
  case "$local_tz" in *..*|/*) die "unknown --local-tz" ;; esac
  [ "$(head -c 4 "/usr/share/zoneinfo/$local_tz" 2>/dev/null)" = "TZif" ] || die "unknown --local-tz: $local_tz"
fi

# A due or time as epoch seconds; a date-only value as 12:00 UTC of that day (zone-free, for distances).
to_epoch() {
  local v="$1" f
  case "$v" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
      TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "$v 12:00:00" +%s 2>/dev/null ;;
    *T*[+-][0-9][0-9]:[0-9][0-9]|*Z)
      f="$(printf '%s' "$v" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/; s/Z$/+0000/')"
      date -j -f "%Y-%m-%dT%H:%M:%S%z" "$f" +%s 2>/dev/null ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9])
      if [ -n "$local_tz" ]; then TZ="$local_tz" date -j -f "%Y-%m-%dT%H:%M:%S" "$v" +%s 2>/dev/null
      else date -j -f "%Y-%m-%dT%H:%M:%S" "$v" +%s 2>/dev/null; fi ;;
    *) return 1 ;;
  esac
}
case "$now" in ''|*[!0-9]*) now_e="$(to_epoch "$now")" || die "cannot read --now $now" ;; *) now_e="$now" ;; esac

# --- read the input ------------------------------------------------------------------------------
P_N=() P_KEY=() P_STATE=() P_DUE=() mode="" R_ID=() R_ST=() R_DUE=() R_KEY=() R_RAW=()
while IFS= read -r line || [ -n "$line" ]; do
  set -- $line
  [ $# -gt 0 ] || continue
  case "$1" in
    period)
      n="$2" key="" state="" due=""
      for kv in "${@:3}"; do
        case "$kv" in key=*) key="${kv#key=}" ;; state=*) state="${kv#state=}" ;; due=*) due="${kv#due=}" ;; esac
      done
      [ -n "$key" ] && [ -n "$state" ] && [ -n "$due" ] || die "bad period line: $line"
      e="$(to_epoch "$due")" || die "bad due in: $line"
      P_N+=("$n"); P_KEY+=("$key"); P_STATE+=("$state"); P_DUE+=("$e") ;;
    rule)
      if [ "$2" = none ]; then mode=per-period; else mode=rule; fi ;;
    reminder)
      [ $# -eq 5 ] || die "bad reminder line: $line"
      case "$3" in open|completed) ;; *) die "bad reminder state: $line" ;; esac
      e="$(to_epoch "$4")" || die "bad due in: $line"
      R_ID+=("$2"); R_ST+=("$3"); R_DUE+=("$e"); R_RAW+=("$4"); R_KEY+=("$5") ;;
    *) die "unknown input line: $line" ;;
  esac
done
[ -n "$mode" ] || die "no rule line"
[ "${#P_N[@]}" -ge 2 ] || die "need period 0 (--previous) and period 1"
[ "${P_N[0]}" = 0 ] || die "the first period line must be period 0 (run quota-dates.sh with --previous)"
echo "mode $mode"

np=${#P_N[@]}
idx_of_n() { local i; for ((i = 0; i < np; i++)); do [ "${P_N[$i]}" = "$1" ] && { echo "$i"; return; }; done; }
abs() { local v=$1; [ "$v" -lt 0 ] && v=$(( -v )); echo "$v"; }

# --- classify each reminder (section 5) ----------------------------------------------------------
half=$(( (P_DUE[1] - P_DUE[0]) / 2 ))
R_CLASS=() R_P=()
nr=${#R_ID[@]}
for ((r = 0; r < nr; r++)); do
  cls="" p=""
  if [ "${R_KEY[$r]}" != "-" ]; then
    for ((i = 0; i < np; i++)); do [ "${P_KEY[$i]}" = "${R_KEY[$r]}" ] && p="${P_N[$i]}"; done
  else
    for ((i = 0; i < np; i++)); do [ "${P_DUE[$i]}" = "${R_DUE[$r]}" ] && p="${P_N[$i]}"; done
  fi
  if [ -n "$p" ]; then
    i="$(idx_of_n "$p")"
    if [ "${P_STATE[$i]}" = past ]; then
      if [ "${R_ST[$r]}" = open ]; then cls=past-record; else cls=history; fi
    else
      cls=matched
    fi
  elif [ "${R_DUE[$r]}" -lt $(( P_DUE[0] - half )) ]; then
    if [ "${R_ST[$r]}" = open ]; then cls=past-record; else cls=older; fi
  else
    best="" bestd="" tie=0
    for ((i = 0; i < np; i++)); do
      d="$(abs $(( R_DUE[r] - P_DUE[i] )))"
      if [ -z "$bestd" ] || [ "$d" -lt "$bestd" ]; then best="${P_N[$i]}" bestd="$d" tie=0
      elif [ "$d" -eq "$bestd" ]; then tie=1; fi
    done
    p="$best"
    if [ "$tie" -eq 1 ]; then cls=ambiguous
    elif [ "${R_ST[$r]}" = completed ]; then cls=history
    elif [ "${P_STATE[$(idx_of_n "$p")]}" = past ] && [ "${R_DUE[$r]}" -lt "$now_e" ]; then cls=past-record
    else cls=off-schedule; fi
  fi
  R_CLASS+=("$cls"); R_P+=("${p:--}")
  echo "reminder ${R_ID[$r]} class=$cls period=${p:--}"
done

# --- used periods and the history boundary --------------------------------------------------------
USED=()
for ((i = 0; i < np; i++)); do USED+=(0); done
mark_used() { local i; i="$(idx_of_n "$1")"; [ -n "$i" ] && USED[$i]=1; }
for ((r = 0; r < nr; r++)); do
  if [ "${R_ST[$r]}" = completed ] && [ "${R_P[$r]}" != "-" ] && [ "${R_CLASS[$r]}" != ambiguous ]; then mark_used "${R_P[$r]}"; fi
done
LIVE=()
for ((r = 0; r < nr; r++)); do
  if [ "${R_ST[$r]}" = open ]; then
    case "${R_CLASS[$r]}" in matched|off-schedule) LIVE+=("$r") ;; esac
  fi
done
if [ "$mode" = rule ]; then  # a recurring reminder rolled past every period before its own
  for r in "${LIVE[@]+"${LIVE[@]}"}"; do
    for ((m = 1; m < R_P[r]; m++)); do mark_used "$m"; done
  done
fi
used_list="" boundary=none
for ((i = 0; i < np; i++)); do
  if [ "${USED[$i]}" = 1 ]; then used_list="$used_list ${P_N[$i]}"; boundary="${P_N[$i]}"; fi
done
echo "used${used_list:- none}"
echo "boundary $boundary"

TARGETS=()
for ((i = 0; i < np; i++)); do
  [ "${P_N[$i]}" -ge 1 ] || continue
  [ "$boundary" = none ] || [ "${P_N[$i]}" -gt "$boundary" ] || continue
  TARGETS+=("${P_N[$i]}")
done
[ "$mode" = rule ] && [ "${#TARGETS[@]}" -gt 1 ] && TARGETS=("${TARGETS[0]}")

for ((r = 0; r < nr; r++)); do
  [ "${R_CLASS[$r]}" = ambiguous ] && echo "action list ${R_ID[$r]} ambiguous"
done

# --- plan ----------------------------------------------------------------------------------------
offsched=0
for r in "${LIVE[@]+"${LIVE[@]}"}"; do [ "${R_CLASS[$r]}" = off-schedule ] && offsched=1; done

if [ "$repair" -eq 0 ]; then
  if [ "$offsched" -eq 1 ]; then echo "action repair-needed"; exit 0; fi
  if [ "$mode" = rule ]; then
    if [ "${#LIVE[@]}" -gt 1 ]; then
      for r in "${LIVE[@]}"; do echo "action list ${R_ID[$r]} two-open-reminders"; done
    elif [ "${#LIVE[@]}" -eq 1 ]; then
      r="${LIVE[0]}"; echo "action keep ${R_ID[$r]} ${R_P[$r]}"
    else
      stopped=""
      for ((r = 0; r < nr; r++)); do
        [ "${R_ST[$r]}" = open ] && [ "${R_CLASS[$r]}" = past-record ] && stopped="$r"
      done
      if [ -n "$stopped" ]; then echo "action restart ${R_ID[$stopped]} ${TARGETS[0]}"
      else echo "action create ${TARGETS[0]}"; fi
    fi
  else
    for ((i = 0; i < np; i++)); do
      n="${P_N[$i]}"; [ "$n" -ge 1 ] || continue
      have="" open_r=""
      for ((r = 0; r < nr; r++)); do
        if [ "${R_P[$r]}" = "$n" ] && [ "${R_CLASS[$r]}" = matched ]; then
          have=1; [ "${R_ST[$r]}" = open ] && { [ -n "$open_r" ] && open_r="$open_r,$r" || open_r="$r"; }
        fi
      done
      case "$open_r" in
        *,*) for r in ${open_r//,/ }; do echo "action list ${R_ID[$r]} two-open-reminders"; done ;;
        ?*) echo "action keep ${R_ID[$open_r]} $n" ;;
        *) if [ -z "$have" ]; then
             if [ -n "$through" ] && [[ ! "${P_KEY[$i]}" > "$through" ]]; then echo "action missing $n"
             else echo "action create $n"; fi
           fi ;;
      esac
    done
  fi
  exit 0
fi

# --repair: keep live reminders already on a target, pair the rest with the free targets in due order.
FREE=()
taken=" "
KEEP_R=" "
for t in "${TARGETS[@]+"${TARGETS[@]}"}"; do
  for r in "${LIVE[@]+"${LIVE[@]}"}"; do
    if [ "${R_CLASS[$r]}" = matched ] && [ "${R_P[$r]}" = "$t" ] && [[ "$taken" != *" $t "* ]] && [[ "$KEEP_R" != *" $r "* ]]; then
      echo "action keep ${R_ID[$r]} $t"; taken="$taken$t "; KEEP_R="$KEEP_R$r "
    fi
  done
done
for t in "${TARGETS[@]+"${TARGETS[@]}"}"; do [[ "$taken" == *" $t "* ]] || FREE+=("$t"); done
REST=()
for r in "${LIVE[@]+"${LIVE[@]}"}"; do [[ "$KEEP_R" == *" $r "* ]] || REST+=("$r"); done
# sort the rest by due
if [ "${#REST[@]}" -gt 0 ]; then
  sorted=$(for r in "${REST[@]}"; do echo "${R_DUE[$r]} $r"; done | sort -n | awk '{print $2}')
  REST=($sorted)
fi
k=0
for r in "${REST[@]+"${REST[@]}"}"; do
  if [ "$k" -lt "${#FREE[@]}" ]; then echo "action move ${R_ID[$r]} ${FREE[$k]}"; k=$((k + 1))
  else echo "action leftover ${R_ID[$r]}"; fi
done
while [ "$k" -lt "${#FREE[@]}" ]; do
  if [ "$mode" = rule ] && [ "${#LIVE[@]}" -eq 0 ]; then
    stopped=""
    for ((r = 0; r < nr; r++)); do [ "${R_ST[$r]}" = open ] && [ "${R_CLASS[$r]}" = past-record ] && stopped="$r"; done
    if [ -n "$stopped" ]; then echo "action restart ${R_ID[$stopped]} ${FREE[$k]}"; k=$((k + 1)); continue; fi
  fi
  echo "action create ${FREE[$k]}"; k=$((k + 1))
done
