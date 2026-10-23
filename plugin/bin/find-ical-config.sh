#!/usr/bin/env bash
# Find the .claude/.ical/config.yaml that applies to a directory.
#
# Usage: find-ical-config.sh [start_dir]      (default: the current directory)
#
# Lookup order (the contract is plugin/rules/calendar-routing.md):
#   1. From start_dir upward, the first .claude/.ical/config.yaml found wins. Files are never merged.
#      The walk checks a directory, then stops if that directory holds a .git entry (file or
#      directory: worktrees and submodules use a file), or is the filesystem root. It stops before
#      $HOME without checking it: the config in $HOME is the user-level one below.
#   2. ~/.claude/.ical/config.yaml.
#
# stdout: the absolute (physical) path of the config, then a newline. Exit codes:
#   0 found    1 none applies (stdout empty)    2 start_dir is not a directory (message on stderr)
# Only paths are looked up; the file's content is never read. A config not owned by the current
# user, or whose file, .ical directory or .claude directory is writable by group or others, is ignored
# (stderr warning) so a file planted in or swapped within a shared directory cannot redirect events.
set -u

start="${1:-$PWD}"
if [ ! -d "$start" ]; then
  echo "find-ical-config.sh: not a directory: $start" >&2
  exit 2
fi

dir="$(cd "$start" && pwd -P)"
home=""
if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
  home="$(cd "$HOME" && pwd -P)"
fi

# Trust check for a candidate config. The .ical directory is resolved to its physical path first, so
# every test below looks at the real object (a symlinked .ical is judged by where it leads). The file,
# its .ical directory and .claude must all be the user's own and not writable by group or others,
# or the file could be swapped after this check. On success the checked path is left in $accepted.
accepted=""
accept() {
  [ -f "$1" ] || return 1
  local ical claude file p
  ical="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 1
  claude="$(dirname "$ical")"
  file="$ical/$(basename "$1")"
  for p in "$file" "$ical" "$claude"; do
    if [ ! -O "$p" ]; then
      echo "find-ical-config.sh: ignoring $file ($p is not owned by the current user)" >&2
      return 1
    fi
    if [ -n "$(find -L "$p" -maxdepth 0 \( -perm -020 -o -perm -002 \) 2>/dev/null)" ]; then
      echo "find-ical-config.sh: ignoring $file ($p is writable by group or others)" >&2
      return 1
    fi
  done
  accepted="$file"
}

while [ "$dir" != "$home" ]; do
  candidate="$dir/.claude/.ical/config.yaml"
  if accept "$candidate"; then
    printf '%s\n' "$accepted"
    exit 0
  fi
  if [ -e "$dir/.git" ] || [ "$dir" = "/" ]; then
    break
  fi
  dir="$(dirname "$dir")"
done

if [ -n "$home" ] && accept "$home/.claude/.ical/config.yaml"; then
  printf '%s\n' "$accepted"
  exit 0
fi
exit 1
