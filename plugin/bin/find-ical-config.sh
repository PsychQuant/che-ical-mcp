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
# Only paths are looked up; the file's content is never read.
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

while [ "$dir" != "$home" ]; do
  candidate="$dir/.claude/.ical/config.yaml"
  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
    exit 0
  fi
  if [ -e "$dir/.git" ] || [ "$dir" = "/" ]; then
    break
  fi
  dir="$(dirname "$dir")"
done

if [ -n "$home" ] && [ -f "$home/.claude/.ical/config.yaml" ]; then
  printf '%s\n' "$home/.claude/.ical/config.yaml"
  exit 0
fi
exit 1
