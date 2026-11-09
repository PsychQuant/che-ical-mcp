#!/bin/bash
# Print the exact changed paths the trip-folder reminder recorded for one session (#341), for the
# itinerary-check skill. The reminder shows only display names; this is where the real paths are.
#
# Usage: itinerary-changed.sh <plugin data directory> <session id>
# stdout: UTF-8 JSON {"trip_folder": ..., "files": [...at most 200], "unreadable": n, "total": n,
#         "complete": bool}. A stored name that is not text (an undecodable byte, kept by Python as a
#         lone surrogate) is not printed: it is counted in "unreadable" (#500 r4 #4).
# Exit: 0 printed, 1 no list for that session (or a trip folder whose name is not text), 2 bad
#       arguments or a symlink on the way, 3 no usable python3.
# Reads one file and writes nothing. The data directory must be absolute, have no `..` component,
# and lie under ~/.claude/plugins/data/ (#500 r4 #5); neither the itinerary-sessions directory nor
# the file may be a symlink.
set -u
data="${1:-}"
sid="${2:-}"
case "$data" in
  /*) ;;
  *) echo "itinerary-changed.sh: the data directory must be absolute" >&2; exit 2 ;;
esac
case "/$data/" in
  */../*) echo "itinerary-changed.sh: the data directory must not contain .." >&2; exit 2 ;;
esac
root="${HOME:-}/.claude/plugins/data/"
case "$data/" in
  "$root"?*) ;;
  *) echo "itinerary-changed.sh: the data directory must be under ~/.claude/plugins/data/" >&2; exit 2 ;;
esac
if [[ ! "$sid" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
  echo "itinerary-changed.sh: bad session id" >&2
  exit 2
fi
dir="$data/itinerary-sessions"
file="$dir/$sid.changed.json"
if [ -L "$dir" ] || [ -L "$file" ]; then
  echo "itinerary-changed.sh: a symlink on the way to the list" >&2
  exit 2
fi
if [ ! -f "$file" ]; then
  echo "itinerary-changed.sh: no list for that session" >&2
  exit 1
fi
# The same python3 rule as the hook: /usr/bin/python3 is a stub that opens the Command Line Tools
# installer when they are missing, so it is run only when `xcode-select -p` answers.
py="$(command -v python3 2>/dev/null)" || { echo "itinerary-changed.sh: python3 is needed" >&2; exit 3; }
if [ "$py" = /usr/bin/python3 ] && ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
  echo "itinerary-changed.sh: python3 is needed (the Command Line Tools are not installed)" >&2
  exit 3
fi
"$py" -I - "$file" <<'PY'
import json, sys
def text(s):
    return isinstance(s, str) and not any(0xD800 <= ord(c) <= 0xDFFF for c in s)
with open(sys.argv[1], encoding="ascii") as f:
    d = json.load(f)
if not text(d.get("trip_folder")):
    sys.stderr.write("itinerary-changed.sh: the trip folder's name is not text\n")
    sys.exit(1)
files = d.get("files", [])
readable = [p for p in files if text(p)]
out = {"trip_folder": d["trip_folder"], "files": readable, "unreadable": len(files) - len(readable),
       "total": d.get("total", len(files)), "complete": d.get("complete", False)}
sys.stdout.buffer.write((json.dumps(out, ensure_ascii=False) + "\n").encode("utf-8"))
PY
