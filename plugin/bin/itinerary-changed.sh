#!/bin/bash
# Print the exact changed paths the trip-folder reminder recorded for one session (#341), for the
# itinerary-check skill. The reminder shows only display names; this is where the real paths are.
#
# Usage: itinerary-changed.sh <plugin data directory> <session id>
# stdout: the JSON {"trip_folder": ..., "files": [...], "complete": true|false}
# Exit: 0 printed, 1 no list for that session, 2 bad arguments. Reads one file; writes nothing.
set -u
data="${1:-}"
sid="${2:-}"
case "$data" in
  /*) ;;
  *) echo "itinerary-changed.sh: the data directory must be absolute" >&2; exit 2 ;;
esac
if ! printf '%s' "$sid" | grep -Eq '^[A-Za-z0-9_-]{1,128}$'; then
  echo "itinerary-changed.sh: bad session id" >&2
  exit 2
fi
file="$data/itinerary-sessions/$sid.changed.json"
if [ ! -f "$file" ] || [ -L "$file" ]; then
  echo "itinerary-changed.sh: no list for that session" >&2
  exit 1
fi
cat "$file"
