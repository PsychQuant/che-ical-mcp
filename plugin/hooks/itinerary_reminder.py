"""Trip-folder reminder for the che-ical-mcp plugin (#341).

Called by itinerary-reminder.sh with one argument, `start` or `stop`, and the hook's JSON on stdin.

start  Record the session's start time in $CLAUDE_PLUGIN_DATA/itinerary-sessions/<session>.start,
       once: a resume, /clear or compaction keeps the first record. Records older than 30 days are
       removed.
stop   When the working directory has a project-level .claude/.ical/config.yaml (the nearest one
       found by plugin/bin/find-ical-config.sh, not the user-level ~/.claude/.ical/config.yaml) and
       files in that folder changed since the session started, print one Stop additionalContext
       naming them and asking Claude to run the itinerary-check skill. At most once per session.

Never blocks and never fails loudly: every path returns normally and prints nothing it does not
mean. The hook reads only file names and modification times in the trip folder, and the two config
keys below; it never reads a file's content, a calendar, mail or reminders.

Config keys (top level of the config file):
  itinerary_check: off      off, "off", 'off' or false (any letter case) turns the reminder off
  itinerary_ignore: [...]   globs to skip, inline [a, b] or a block list of "- a" lines
"""

import fnmatch
import json
import os
import re
import subprocess
import sys
import time

LISTED = 20            # files named in the reminder; the rest are counted
WALK_SECONDS = 2.0     # stop walking the folder after this long
WALK_ENTRIES = 50000   # or after this many entries
KEEP_DAYS = 30         # session records older than this are removed on start
SKIPPED_DIRS = (".git", ".claude")
SESSION = re.compile(r"[A-Za-z0-9_-]{1,128}")


def sessions_dir():
    base = os.environ.get("CLAUDE_PLUGIN_DATA", "")
    if not base or not os.path.isabs(base) or not os.path.isdir(base):
        return None
    return os.path.join(base, "itinerary-sessions")


def read_input():
    try:
        data = json.loads(sys.stdin.read() or "null")
    except ValueError:
        return None
    if not isinstance(data, dict):
        return None
    sid = data.get("session_id")
    if not isinstance(sid, str) or not SESSION.fullmatch(sid):
        return None
    return data


def start(data, folder):
    os.makedirs(folder, mode=0o700, exist_ok=True)
    record = os.path.join(folder, data["session_id"] + ".start")
    if not os.path.exists(record):
        with open(record, "x") as f:
            f.write(repr(time.time()))
    cutoff = time.time() - KEEP_DAYS * 86400
    for name in os.listdir(folder):
        path = os.path.join(folder, name)
        try:
            if os.path.isfile(path) and os.path.getmtime(path) < cutoff:
                os.remove(path)
        except OSError:
            pass


def project_config(cwd):
    """The project-level config that applies to cwd, or None."""
    finder = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "find-ical-config.sh")
    try:
        out = subprocess.run(["/bin/bash", finder, cwd], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    path = out.stdout.strip()
    if out.returncode != 0 or not path:
        return None
    home = os.environ.get("HOME", "")
    if home and os.path.realpath(path) == os.path.realpath(os.path.join(home, ".claude", ".ical", "config.yaml")):
        return None
    return path


def scalar(text):
    text = re.sub(r"\s+#.*$", "", text).strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        text = text[1:-1]
    return text


def settings(config):
    """(enabled, ignore globs) from the config's two top-level keys."""
    try:
        with open(config, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeDecodeError):
        return True, []
    enabled, ignores, in_list = True, [], False
    for line in lines:
        top = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:(.*)$", line)
        if top:
            in_list = False
            key, rest = top.group(1), top.group(2)
            if key == "itinerary_check" and scalar(rest).lower() in ("off", "false"):
                enabled = False
            elif key == "itinerary_ignore":
                rest = scalar(rest)
                if rest.startswith("[") and rest.endswith("]"):
                    ignores += [scalar(p) for p in rest[1:-1].split(",") if scalar(p)]
                elif not rest:
                    in_list = True
            continue
        item = re.match(r"^\s+-\s*(.+)$", line)
        if in_list and item and scalar(item.group(1)):
            ignores.append(scalar(item.group(1)))
        elif line.strip() and not line.lstrip().startswith("#"):
            in_list = in_list and line.startswith((" ", "\t"))
    return enabled, ignores


def ignored(rel, ignores):
    """A pattern ending in / skips every file under a directory of that path (at any depth); a
    pattern without / is matched with the file name; any other pattern with the whole path."""
    name = rel.rsplit("/", 1)[-1]
    for pattern in ignores:
        if pattern.endswith("/"):
            d = pattern.rstrip("/")
            if rel.startswith(d + "/") or ("/" + d + "/") in ("/" + rel):
                return True
        elif "/" not in pattern:
            if fnmatch.fnmatchcase(name, pattern):
                return True
        elif fnmatch.fnmatchcase(rel, pattern.lstrip("/")):
            return True
    return False


def changed_files(trip, since, ignores):
    found, seen, cut_short = [], 0, False
    began = time.monotonic()
    for root, dirs, files in os.walk(trip):
        dirs[:] = sorted(d for d in dirs if d not in SKIPPED_DIRS and not os.path.islink(os.path.join(root, d)))
        for name in sorted(files):
            seen += 1
            if seen > WALK_ENTRIES or time.monotonic() - began > WALK_SECONDS:
                return found, True
            path = os.path.join(root, name)
            try:
                st = os.lstat(path)
            except OSError:
                continue
            if st.st_mtime <= since or not os.path.isfile(path) or os.path.islink(path):
                continue
            rel = os.path.relpath(path, trip).replace(os.sep, "/")
            if not ignored(rel, ignores):
                found.append(rel)
    return found, cut_short


def stop(data, folder):
    if data.get("stop_hook_active") is True:
        return
    sid = data["session_id"]
    record = os.path.join(folder, sid + ".start")
    reminded = os.path.join(folder, sid + ".reminded")
    if not os.path.isfile(record) or os.path.exists(reminded):
        return
    cwd = data.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR", "")
    if not isinstance(cwd, str) or not os.path.isdir(cwd):
        return
    config = project_config(cwd)
    if not config:
        return
    enabled, ignores = settings(config)
    if not enabled:
        return
    try:
        with open(record) as f:
            since = float(f.read().strip())
    except (OSError, ValueError):
        return
    trip = os.path.dirname(os.path.dirname(os.path.dirname(config)))
    files, cut_short = changed_files(trip, since, ignores)
    if not files:
        return
    try:
        with open(reminded, "x") as f:
            f.write(repr(time.time()))
    except OSError:
        return  # without the record it would remind again on every turn: stay silent instead
    shown = "; ".join(files[:LISTED])
    more = len(files) - LISTED
    if more > 0:
        shown += f"; and {more} more"
    if cut_short:
        shown += " (the listing stopped early; the folder is large)"
    message = (
        f"che-ical-mcp itinerary check (#341): files in the trip folder {trip} changed during this session: "
        f"{shown}. If any of them records a change to this trip (a registration, a payment, a revised program, "
        "lodging, or transport), run the itinerary-check skill with what changed: it compares the calendar with it, "
        "lists the differences, and changes nothing until the user agrees. If none of them does, say so in one line "
        "and stop. This reminder comes once per session; "
        f"`itinerary_check: off` in {config} turns it off, and `itinerary_ignore:` skips files."
    )
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "Stop", "additionalContext": message}}))


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in ("start", "stop"):
        return
    data = read_input()
    folder = sessions_dir()
    if data is None or folder is None:
        return
    try:
        if mode == "start":
            start(data, folder)
        else:
            stop(data, folder)
    except Exception:  # a hook must never fail loudly or block the session
        return


if __name__ == "__main__":
    main()
