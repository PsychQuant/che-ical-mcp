#!/usr/bin/env bash
# Plan what to write for one quota, from its periods and its reminders (the contract is
# plugin/skills/quota/SKILL.md section 5, #327). Reads stdin, writes nothing anywhere else.
#
# Usage: quota-plan.sh --now WHEN --written-mode rule|per-period|unknown [--local-tz ZONE] [--through KEY] [--replace] < input
#   --now           the reference time: the same value given to quota-dates.sh as --from (epoch or ISO with offset)
#   --written-mode  the mode the existing reminders were written in: the entry's stored `mode` (`unknown` when the
#                   entry has none: nothing is planned but repair-needed)
#   --local-tz      the zone of a due given without an offset (tests; the skill passes dues with an offset)
#   --through       per-period: the entry's per_period_through, the highest period the skill ever created
#   --replace       a schedule change (an update that changes dates or mode, or a yes in sync): delete the open
#                   reminders of periods not yet reset and create the new schedule. Needs the OLD periods too.
# Input lines (any order):
#   the output of quota-dates.sh --previous for the entry as it is now (period lines and the rule line)
#   with --replace, also the OLD entry's output, each line prefixed with `old ` (`old period ...`, `old rule ...`).
#   Without them (the old entry is not known: a hand edit), an open reminder whose due has passed is a record.
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
#   action keep <id> <n> due=<D> | rewrite <id> <n> due=<D> | create <n> due=<D> | missing <n> | beyond <id> |
#          restart <id> <n> due=<D> | record <id> | hold <n> <why> | list <id> <why> | repair-needed <why> |
#          delete <id> | replace-blocked <why>
#   Without --replace nothing is ever moved or deleted; `rewrite` is a finding (listed), never a write on its own.
# Exit codes: 0 ok, 2 bad input (message on stderr).
set -u
set -f                       # fields come from user-editable notes: never glob-expand them
die() { echo "quota-plan.sh: $*" >&2; exit 2; }

now="" wmode="" local_tz="" through="" replace=0
while [ $# -gt 0 ]; do
  case "$1" in
    --replace) replace=1; shift; continue ;;
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

to_epoch() {  # a due as epoch seconds; a date-only value as 12:00 UTC of that day (zone-free, for distances)
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
# Period sets: the current entry (prefix N_) and, with --replace, the old one (prefix O_).
N_KEY=() N_STATE=() N_DUE=() N_AL=() N_TXT=() N_MODE=""
O_KEY=() O_STATE=() O_DUE=() O_AL=() O_TXT=() O_MODE=""
R_ID=() R_ST=() R_DUE=() R_KEY=() R_AL=() R_OUT=()
add_period() {  # set-prefix, fields...
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
    O_KEY+=("$key"); O_STATE+=("$state"); O_DUE+=("$e"); O_AL+=("$(alarms_norm "$exp")"); O_TXT+=("$due")
  fi
}
while IFS=$' \t' read -r -a f || [ "${#f[@]}" -gt 0 ]; do
  [ "${#f[@]}" -gt 0 ] || continue
  set_=N
  if [ "${f[0]}" = old ]; then set_=O; f=("${f[@]:1}"); [ "${#f[@]}" -gt 0 ] || die "empty old line"; fi
  case "${f[0]}" in
    period) add_period "$set_" "${f[@]:1}" ;;
    rule)
      if [ "${f[1]:-}" = none ]; then m=per-period; else m=rule; fi
      if [ "$set_" = N ]; then N_MODE="$m"; else O_MODE="$m"; fi ;;
    reminder)
      [ "$set_" = N ] || die "a reminder line has no old form"
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
[ -n "$N_MODE" ] || die "no rule line"
[ "${#N_KEY[@]}" -ge 2 ] || die "need period 0 (--previous) and period 1"
if [ "$replace" -eq 1 ] && { [ -n "$O_MODE" ] || [ "${#O_KEY[@]}" -gt 0 ]; }; then
  [ -n "$O_MODE" ] || die "--replace: old periods given without the old rule line"
  [ "${#O_KEY[@]}" -ge 2 ] || die "--replace: the old entry's periods 0 and 1 are needed (old period ...)"
fi
mode="$N_MODE"
echo "mode $mode"
echo "written-mode $wmode"
if [ "$wmode" = unknown ]; then echo "action repair-needed written-mode-unknown"; exit 0; fi

nr=${#R_ID[@]}
ORDER=()   # reminder indexes in due order, then id: every list below follows it, never input order
if [ "$nr" -gt 0 ]; then
  ORDER=($(for ((r = 0; r < nr; r++)); do printf '%s %s %s\n' "${R_DUE[$r]}" "${R_ID[$r]}" "$r"; done | sort -k1,1n -k2,2 | awk '{print $3}'))
fi
abs() { local v=$1; [ "$v" -lt 0 ] && v=$(( -v )); echo "$v"; }

# --- classify each reminder against one period set (section 5) ---------------------------------------
# Sets C_KEY/C_STATE/C_DUE/C_AL to the set to use, then fills R_CLASS, R_P (period index; the number of periods
# for `beyond`), R_P2 (the second period of a tie) and R_DATES.
classify() {
  local np=${#C_KEY[@]} r i p cls best bestd second d half_lo half_hi
  half_lo=$(( (C_DUE[1] - C_DUE[0]) / 2 ))
  half_hi=$(( (C_DUE[np - 1] - C_DUE[np - 2]) / 2 ))
  R_CLASS=() R_P=() R_P2=() R_DATES=()
  for ((r = 0; r < nr; r++)); do R_CLASS+=(""); R_P+=("-"); R_P2+=("-"); R_DATES+=("-"); done
  for r in "${ORDER[@]+"${ORDER[@]}"}"; do
    cls="" p=""
    if [ "$wmode" = per-period ] && [ "${R_KEY[$r]}" != "-" ]; then
      for ((i = 0; i < np; i++)); do [ "${C_KEY[$i]}" = "${R_KEY[$r]}" ] && p="$i"; done
    else   # rule mode reads a reminder's period from its due; a leftover Period: line is ignored
      for ((i = 0; i < np; i++)); do [ "${C_DUE[$i]}" = "${R_DUE[$r]}" ] && p="$i"; done
    fi
    if [ -n "$p" ]; then
      if [ "${C_STATE[$p]}" = past ]; then
        if [ "${R_ST[$r]}" = open ]; then cls=past-record; else cls=history; fi
      else
        cls=matched
      fi
      if [ "${R_ST[$r]}" = open ]; then
        if [ "${R_DUE[$r]}" = "${C_DUE[$p]}" ] && { [ "${R_AL[$r]}" = "-" ] || [ "${R_AL[$r]}" = "${C_AL[$p]}" ]; }; then
          R_DATES[$r]=ok; else R_DATES[$r]=differ; fi
      fi
    elif [ "${R_DUE[$r]}" -lt $(( C_DUE[0] - half_lo )) ]; then
      if [ "${R_ST[$r]}" = open ]; then cls=past-record; else cls=older; fi
    elif [ "${R_DUE[$r]}" -gt $(( C_DUE[np - 1] + half_hi )) ]; then
      cls=beyond; p=$np     # after every listed period: the series rolled past all of them
    else
      best="" bestd="" second=""
      for ((i = 0; i < np; i++)); do
        d="$(abs $(( R_DUE[r] - C_DUE[i] )))"
        if [ -z "$bestd" ] || [ "$d" -lt "$bestd" ]; then best="$i" bestd="$d" second=""
        elif [ "$d" -eq "$bestd" ]; then second="$i"; fi
      done
      p="$best"
      if [ -n "$second" ]; then cls=ambiguous; R_P2[$r]="$second"      # open or completed: never guessed
      elif [ "${R_ST[$r]}" = completed ]; then cls=history
      elif [ "${C_STATE[$p]}" = past ] && [ "${R_DUE[$r]}" -lt "$now_e" ]; then cls=past-record
      else cls=off-schedule; R_DATES[$r]=differ; fi
    fi
    R_CLASS[$r]="$cls"; R_P[$r]="${p:--}"
  done
}

# --- --replace: identify records with the OLD periods, delete the rest, create the new schedule ------------
if [ "$replace" -eq 1 ]; then
  blocked=""
  if [ -n "$O_MODE" ]; then
    C_KEY=("${O_KEY[@]}"); C_STATE=("${O_STATE[@]}"); C_DUE=("${O_DUE[@]}"); C_AL=("${O_AL[@]}")
    classify
    for r in "${ORDER[@]+"${ORDER[@]}"}"; do
      echo "reminder ${R_ID[$r]} class=${R_CLASS[$r]} period=${R_P[$r]} dates=${R_DATES[$r]} (old periods)"
    done
  else
    # No old entry (the file was edited by hand, sync): an open reminder whose due has passed is kept as a record,
    # because its period may have reset under the old dates; the others are replaced.
    R_CLASS=() R_P=() R_DATES=()
    for ((r = 0; r < nr; r++)); do
      if [ "${R_ST[$r]}" = completed ]; then R_CLASS+=(history)
      elif [ "${R_DUE[$r]}" -lt "$now_e" ]; then R_CLASS+=(past-record)
      else R_CLASS+=(off-schedule); fi
      R_P+=("-"); R_DATES+=("-")
    done
    for r in "${ORDER[@]+"${ORDER[@]}"}"; do
      echo "reminder ${R_ID[$r]} class=${R_CLASS[$r]} period=- dates=- (no old periods: due before now is a record)"
    done
  fi
  for r in "${ORDER[@]+"${ORDER[@]}"}"; do
    [ "${R_ST[$r]}" = open ] || continue
    if [ "${R_CLASS[$r]}" = ambiguous ]; then echo "action list ${R_ID[$r]} ambiguous"; blocked="${blocked:-ambiguous}"; fi
    if [ "${R_OUT[$r]}" = other ] && [ "${R_CLASS[$r]}" != past-record ]; then
      echo "action list ${R_ID[$r]} outside-list"; blocked="${blocked:-outside-list}"; fi
  done
  if [ -n "$blocked" ]; then echo "action replace-blocked $blocked"; exit 0; fi
  for r in "${ORDER[@]+"${ORDER[@]}"}"; do
    [ "${R_ST[$r]}" = open ] || continue
    case "${R_CLASS[$r]}" in
      past-record)
        if [ "${R_OUT[$r]}" = other ]; then echo "action list ${R_ID[$r]} outside-list"
        elif [ "$wmode" = rule ]; then echo "action record ${R_ID[$r]}"; fi ;;
      *) echo "action delete ${R_ID[$r]}" ;;
    esac
  done
  np=${#N_KEY[@]}
  for ((i = 1; i < np; i++)); do
    echo "action create $i due=${N_TXT[$i]}"
    [ "$mode" = rule ] && break
  done
  exit 0
fi

# --- list / sync: one period set; nothing is moved or deleted -------------------------------------------
C_KEY=("${N_KEY[@]}"); C_STATE=("${N_STATE[@]}"); C_DUE=("${N_DUE[@]}"); C_AL=("${N_AL[@]}")
classify
np=${#N_KEY[@]}
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  echo "reminder ${R_ID[$r]} class=${R_CLASS[$r]} period=${R_P[$r]} dates=${R_DATES[$r]}"
done

if [ "$wmode" != "$mode" ]; then echo "action repair-needed dates-changed"; exit 0; fi

USED=()
for ((i = 0; i < np; i++)); do USED+=(0); done
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  if [ "${R_ST[$r]}" = completed ] && [ "${R_P[$r]}" != "-" ]; then
    case "${R_CLASS[$r]}" in matched|history) USED[${R_P[$r]}]=1 ;; esac
  fi
done
LIVE=()   # open reminders holding a period whose reset is ahead, in due order
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  if [ "${R_ST[$r]}" = open ]; then
    case "${R_CLASS[$r]}" in matched|off-schedule|beyond|ambiguous) LIVE+=("$r") ;; esac
  fi
done
# Rolled past: only the earliest non-ambiguous live reminder of a rule-mode series is evidence (round 4).
series=""
if [ "$wmode" = rule ]; then
  for r in "${LIVE[@]+"${LIVE[@]}"}"; do [ "${R_CLASS[$r]}" = ambiguous ] && continue; series="$r"; break; done
  if [ -n "$series" ]; then for ((m = 1; m < R_P[series] && m < np; m++)); do USED[$m]=1; done; fi
fi
used_list="" boundary=none
for ((i = 0; i < np; i++)); do
  if [ "${USED[$i]}" = 1 ]; then used_list="$used_list $i"; boundary="$i"; fi
done
echo "used${used_list:- none}"
echo "boundary $boundary"

# Holds: periods an ambiguous reminder (open or completed) may belong to, and periods a reminder in another
# list sits on. In rule mode an ambiguous open reminder may be the series, so it holds every period.
HOLD=" " amb_open=0
for r in "${ORDER[@]+"${ORDER[@]}"}"; do
  if [ "${R_CLASS[$r]}" = ambiguous ]; then
    echo "action list ${R_ID[$r]} ambiguous"
    HOLD="$HOLD${R_P[$r]} ${R_P2[$r]} "
    [ "${R_ST[$r]}" = open ] && amb_open=1
  fi
done
held() { { [ "$mode" = rule ] && [ "$amb_open" -eq 1 ]; } || [[ "$HOLD" == *" $1 "* ]]; }
hold_why() { if [[ "$HOLD" == *" $1 "* ]] || [ "$amb_open" -eq 1 ]; then echo ambiguous; else echo outside-list; fi; }

changed=0
for r in "${LIVE[@]+"${LIVE[@]}"}"; do
  [ "${R_OUT[$r]}" = other ] && continue
  case "${R_CLASS[$r]}" in
    off-schedule) changed=1 ;;
    matched) if [ "${R_DATES[$r]}" = differ ]; then changed=1; echo "action rewrite ${R_ID[$r]} ${R_P[$r]} due=${N_TXT[${R_P[$r]}]}"; fi ;;
  esac
done
if [ "$changed" -eq 1 ]; then echo "action repair-needed dates-changed"; exit 0; fi

free_period() {  # a period no reminder holds
  local t="$1"
  if held "$t"; then echo "action hold $t $(hold_why "$t")"; return; fi
  if [ -n "$through" ] && [ "$wmode" = per-period ] && [[ ! "${N_KEY[$t]}" > "$through" ]]; then echo "action missing $t"; return; fi
  echo "action create $t due=${N_TXT[$t]}"
}

if [ "$mode" = rule ]; then
  done_=""
  for r in "${LIVE[@]+"${LIVE[@]}"}"; do
    [ "${R_CLASS[$r]}" = ambiguous ] && continue
    if [ -z "$done_" ]; then
      done_=1
      if [ "${R_OUT[$r]}" = other ]; then echo "action list ${R_ID[$r]} outside-list"
      elif [ "${R_CLASS[$r]}" = beyond ]; then echo "action beyond ${R_ID[$r]}"
      else echo "action keep ${R_ID[$r]} ${R_P[$r]} due=${N_TXT[${R_P[$r]}]}"; fi
    else
      echo "action list ${R_ID[$r]} two-open-reminders"
    fi
  done
  stopped=""
  for r in "${ORDER[@]+"${ORDER[@]}"}"; do
    [ "${R_ST[$r]}" = open ] && [ "${R_CLASS[$r]}" = past-record ] && stopped="$r"
  done
  if [ -z "$done_" ]; then
    t=""
    for ((i = 1; i < np; i++)); do [ "${USED[$i]}" = 1 ] || { t="$i"; break; }; done
    if [ -n "$t" ]; then
      if held "$t"; then echo "action hold $t $(hold_why "$t")"
      elif [ -n "$stopped" ] && [ "${R_OUT[$stopped]}" = other ]; then
        echo "action list ${R_ID[$stopped]} outside-list"; echo "action hold $t outside-list"
      elif [ -n "$stopped" ]; then echo "action restart ${R_ID[$stopped]} $t due=${N_TXT[$t]}"
      else free_period "$t"; fi
    fi
  fi
  for r in "${ORDER[@]+"${ORDER[@]}"}"; do
    if [ "${R_ST[$r]}" = open ] && [ "${R_CLASS[$r]}" = past-record ] && [ "$r" != "${stopped:-x}" ]; then
      if [ "${R_OUT[$r]}" = other ]; then echo "action list ${R_ID[$r]} outside-list"; else echo "action record ${R_ID[$r]}"; fi
    fi
  done
  exit 0
fi

# per-period: each live reminder keeps its own period (the earliest one, when two share it); a period with no
# reminder is created, missing (not after --through) or held. A reminder in another list holds its own period.
TAKEN=" "
for r in "${LIVE[@]+"${LIVE[@]}"}"; do
  [ "${R_CLASS[$r]}" = ambiguous ] && continue
  if [ "${R_CLASS[$r]}" = beyond ]; then
    if [ "${R_OUT[$r]}" = other ]; then echo "action list ${R_ID[$r]} outside-list"; else echo "action beyond ${R_ID[$r]}"; fi
    continue
  fi
  own="${R_P[$r]}"
  if [[ "$TAKEN" == *" $own "* ]] || [ "${USED[$own]}" = 1 ]; then echo "action list ${R_ID[$r]} two-open-reminders"; continue; fi
  TAKEN="$TAKEN$own "
  if [ "${R_OUT[$r]}" = other ]; then echo "action list ${R_ID[$r]} outside-list"
  else echo "action keep ${R_ID[$r]} $own due=${N_TXT[$own]}"; fi
done
for ((t = 1; t < np; t++)); do
  [ "${USED[$t]}" = 1 ] && continue
  [[ "$TAKEN" == *" $t "* ]] && continue
  free_period "$t"
done
