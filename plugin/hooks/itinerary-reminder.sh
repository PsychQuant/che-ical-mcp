#!/bin/bash
# Trip-folder reminder (#341). Registered twice in hooks.json:
#   itinerary-reminder.sh start   on SessionStart: record when the session started
#   itinerary-reminder.sh stop    on Stop: if files in the trip folder changed since then, add one
#                                 additionalContext asking Claude to run the itinerary-check skill
# The hook never blocks: it exits 0 (never 2) and prints nothing unless it has a reminder. All logic is
# in itinerary_reminder.py; without a working python3 the hook does nothing.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
py="$(command -v python3 2>/dev/null)" || exit 0
# /usr/bin/python3 is a stub that opens the Command Line Tools installer when they are missing;
# `xcode-select -p` answers without a dialog, so the stub is never run.
if [ "$py" = /usr/bin/python3 ] && ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
  exit 0
fi
# exec (#500 r7 #9): python is the hook's own process, so a timeout that kills the hook ends the walk
# too, instead of leaving an orphan that would record a reminder nobody reads. Its exit status is the
# hook's, and a Stop hook that exits 2 blocks the stop, again on every turn (#500 r8 #3). So python
# does not open the module itself (an unreadable file would make it exit 2 before any code ran): -c
# loads it with runpy inside a catch-all and always exits 0. A failed exec (a broken interpreter)
# exits 126 or 127, which does not block.
exec "$py" -I -c '
import runpy, sys
try:
    sys.argv = sys.argv[1:]
    runpy.run_path(sys.argv[0], run_name="__main__")
except BaseException:
    pass
sys.exit(0)
' "$here/itinerary_reminder.py" "${1:-}" 2>/dev/null
