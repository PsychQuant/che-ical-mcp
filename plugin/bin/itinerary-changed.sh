#!/bin/bash
# Print the exact changed paths the trip-folder reminder recorded for one session (#341), for the
# itinerary-check skill. The reminder shows only display names; this is where the real paths are.
#
# Usage: itinerary-changed.sh <plugin data directory> <session id>
# stdout: UTF-8 JSON {"trip_folder": ..., "complete": bool, "total": n, "unreadable": n,
#         "files": [...at most 200]}. A stored name holding a character of the categories the reminder's
#         display names drop (Cc, Cf, Zl, Zp, Cs, Co: a newline, a bidi override, a zero-width space,
#         a lone surrogate from an undecodable byte, a private-use character) is never printed, raw
#         or escaped: it is counted in "unreadable" (#500 r4 #4 and its security review).
# Exit: 0 printed, 1 no list for that session (or a trip folder whose name holds such a character), 2 bad
#       arguments, a symlink or a non-regular file on the way, a list with another hard link, 3 no usable
#       python3. "complete" is always a bool and "total" a non-negative int (stored values of another
#       type are replaced by false and the number of stored paths).
# Reads one file and writes nothing. The allowed root is ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/
# (#500 r5 #8: CLAUDE_CONFIG_DIR is how several accounts run side by side). The data directory must be
# absolute, lie under that root by at least one component, and hold no `.` or `..` component (#500 r5
# #7). Below the root, every directory down to the list is opened through the one above it with
# O_NOFOLLOW, and the list is read through its own descriptor, so a symlink anywhere on that part of
# the way is refused and nothing can be swapped in between a check and the open (#500 r5 #1). The root
# itself is opened normally: it is the user's own configuration directory.
set -u
data="${1:-}"
sid="${2:-}"
case "$data" in
  /*) ;;
  *) echo "itinerary-changed.sh: the data directory must be absolute" >&2; exit 2 ;;
esac
root="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/plugins/data"
case "$root" in
  /*) ;;
  *) echo "itinerary-changed.sh: CLAUDE_CONFIG_DIR (or HOME) must be absolute" >&2; exit 2 ;;
esac
if [[ ! "$sid" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
  echo "itinerary-changed.sh: bad session id" >&2
  exit 2
fi
# The same python3 rule as the hook: /usr/bin/python3 is a stub that opens the Command Line Tools
# installer when they are missing, so it is run only when `xcode-select -p` answers.
py="$(command -v python3 2>/dev/null)" || { echo "itinerary-changed.sh: python3 is needed" >&2; exit 3; }
if [ "$py" = /usr/bin/python3 ] && ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
  echo "itinerary-changed.sh: python3 is needed (the Command Line Tools are not installed)" >&2
  exit 3
fi
"$py" -I - "$root" "$data" "$sid" <<'PY'
import errno, json, os, sys, unicodedata
DROPPED = ("Cc", "Cf", "Zl", "Zp", "Cs", "Co")   # the same categories as the hook's DROPPED_CATEGORIES
def fail(code, message):
    sys.stderr.write("itinerary-changed.sh: " + message + "\n")
    sys.exit(code)
def text(s):
    return isinstance(s, str) and not any(unicodedata.category(c) in DROPPED for c in s)
root, data, sid = sys.argv[1], sys.argv[2], sys.argv[3]
def parts(path):
    p = path.split("/")[1:]
    return p[:-1] if p and p[-1] == "" else p   # one trailing slash is allowed
root_parts, data_parts = [c for c in root.split("/") if c], parts(data)
if any(c in ("", ".", "..") for c in data_parts):
    fail(2, "the data directory must not contain an empty, . or .. component")
if data_parts[: len(root_parts)] != root_parts or len(data_parts) <= len(root_parts):
    fail(2, "the data directory must be a directory under " + root + "/")
def opened(dfd, name, flags):
    try:
        return os.open(name, flags | os.O_NOFOLLOW, dir_fd=dfd)
    except FileNotFoundError:
        fail(1, "no list for that session")
    except OSError as e:
        if e.errno in (errno.ELOOP, errno.ENOTDIR):
            fail(2, "a symlink or a non-directory on the way to the list")
        fail(1, "the list cannot be opened")
try:
    dfd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
except OSError:
    fail(1, "no list for that session")
for name in data_parts[len(root_parts):] + ["itinerary-sessions"]:
    nxt = opened(dfd, name, os.O_RDONLY | os.O_DIRECTORY)
    os.close(dfd)
    dfd = nxt
fd = opened(dfd, sid + ".changed.json", os.O_RDONLY | os.O_NONBLOCK)
os.close(dfd)
st = os.fstat(fd)
if (st.st_mode & 0o170000) != 0o100000:
    fail(2, "the list is not a regular file")
if st.st_nlink != 1:   # #500 r6 #4: the hook never writes a list with another hard link
    fail(2, "the list has another hard link")
try:
    with os.fdopen(fd, encoding="ascii") as f:
        d = json.load(f)
except (ValueError, OSError):
    fail(1, "the list cannot be read")
if not isinstance(d, dict) or not text(d.get("trip_folder")):
    fail(1, "the trip folder's name holds a control or format character")
files = d.get("files", [])
files = files if isinstance(files, list) else []
readable = [p for p in files if text(p)]
# The counts come before the paths, so they stay in a cut preview of a long output (#500 r5 #11).
# #500 r6 #5: `complete` is printed only as a bool and `total` only as a non-negative int (a bool is
# not taken as one); anything else is replaced, so no stored string reaches the output through them.
complete = d.get("complete") if isinstance(d.get("complete"), bool) else False
total = d.get("total")
total = total if isinstance(total, int) and not isinstance(total, bool) and total >= 0 else len(files)
out = {"trip_folder": d["trip_folder"], "complete": complete,
       "total": total, "unreadable": len(files) - len(readable), "files": readable}
sys.stdout.buffer.write((json.dumps(out, ensure_ascii=False) + "\n").encode("utf-8"))
PY
