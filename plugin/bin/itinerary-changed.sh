#!/bin/bash
# Print the exact changed paths the trip-folder reminder recorded for one session (#341), for the
# itinerary-check skill. The reminder shows only display names; this is where the real paths are.
#
# Usage: itinerary-changed.sh <plugin data directory> <session id>
# stdout: ASCII JSON {"trip_folder": ..., "files": [...at most 200], "total": n, "complete": bool}
# Exit: 0 printed, 1 no list for that session, 2 bad arguments or a symlink on the way.
# Reads one file and writes nothing. Neither the itinerary-sessions directory nor the file may be
# a symlink; the data directory itself is the caller's (the skill passes ${CLAUDE_PLUGIN_DATA}).
set -u
data="${1:-}"
sid="${2:-}"
case "$data" in
  /*) ;;
  *) echo "itinerary-changed.sh: the data directory must be absolute" >&2; exit 2 ;;
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
cat "$file"
