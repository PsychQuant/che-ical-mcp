#!/bin/bash
# Trip-folder reminder (#341). Registered twice in hooks.json:
#   itinerary-reminder.sh start   on SessionStart: record when the session started
#   itinerary-reminder.sh stop    on Stop: if files in the trip folder changed since then, add one
#                                 additionalContext asking Claude to run the itinerary-check skill
# The hook never blocks: it always exits 0 and prints nothing unless it has a reminder. All logic is
# in itinerary_reminder.py; without python3 the hook does nothing.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || exit 0
python3 -I "$here/itinerary_reminder.py" "${1:-}" 2>/dev/null
exit 0
