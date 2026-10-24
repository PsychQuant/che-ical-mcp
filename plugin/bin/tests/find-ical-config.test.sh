#!/usr/bin/env bash
# Tests for plugin/bin/find-ical-config.sh (openspec change add-calendar-routing, #337).
# Run: bash plugin/bin/tests/find-ical-config.test.sh   (exit 0 = all pass)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HELPER="$HERE/../find-ical-config.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
ROOT="$(cd "$ROOT" && pwd -P)"   # physical path: /var vs /private/var on macOS

HOME_DIR="$ROOT/home"
cfg() { mkdir -p "$1/.claude/.ical" && : > "$1/.claude/.ical/config.yaml"; }

# Tree:
#   home/.claude/.ical/config.yaml                 user-level
#   home/Conf/.claude/.ical/config.yaml            parent config
#   home/Conf/2026/sub                             no config of its own
#   home/Conf/2026/talk/.claude/.ical/config.yaml  closer config
#   home/outer/.claude/.ical/config.yaml           outside the repo boundary
#   home/outer/repo/.git/ + src/                   repo without config
#   home/outer/repo2/.git (file) + src/            repo with config at its root
#   home/empty/x                                   nothing above but home
#   other/.claude/.ical/config.yaml                outside $HOME
mkdir -p "$HOME_DIR" "$HOME_DIR/Conf/2026/sub" "$HOME_DIR/Conf/2026/talk" \
  "$HOME_DIR/outer/repo/.git" "$HOME_DIR/outer/repo/src" \
  "$HOME_DIR/outer/repo2/src" "$HOME_DIR/empty/x" "$ROOT/other/deep"
cfg "$HOME_DIR"
cfg "$HOME_DIR/Conf"
cfg "$HOME_DIR/Conf/2026/talk"
cfg "$HOME_DIR/outer"
cfg "$HOME_DIR/outer/repo2"
: > "$HOME_DIR/outer/repo2/.git"
cfg "$ROOT/other"
ln -s "$HOME_DIR/Conf/2026" "$HOME_DIR/link"
# A config whose .ical directory anyone can write to is not trusted (it could be swapped after the check).
mkdir -p "$HOME_DIR/wide/x"
cfg "$HOME_DIR/wide"
chmod 777 "$HOME_DIR/wide/.claude/.ical"
# ...also when the directory is reached through a symlink, when the file itself is writable by
# others, and when .claude is.
mkdir -p "$HOME_DIR/symd/.claude" "$HOME_DIR/symd/x"
ln -s "$HOME_DIR/wide/.claude/.ical" "$HOME_DIR/symd/.claude/.ical"
mkdir -p "$HOME_DIR/filew/x"
cfg "$HOME_DIR/filew"
chmod 666 "$HOME_DIR/filew/.claude/.ical/config.yaml"
mkdir -p "$HOME_DIR/clw/x"
cfg "$HOME_DIR/clw"
chmod 777 "$HOME_DIR/clw/.claude"
mkdir -p "$HOME_DIR/groupw/x"
cfg "$HOME_DIR/groupw"
chmod 775 "$HOME_DIR/groupw/.claude/.ical"

pass=0
fail=0
run() { HOME="$HOME_DIR" bash "$HELPER" "$@" 2>/dev/null; }

check() { # name expected-stdout expected-status start_dir
  local name="$1" want="$2" want_rc="$3" start="$4" got rc
  got="$(run "$start")"; rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = "$want_rc" ]; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'FAIL %s\n     want [%s] rc=%s\n     got  [%s] rc=%s\n' "$name" "$want" "$want_rc" "$got" "$rc"
  fi
}

CONF="$HOME_DIR/Conf/.claude/.ical/config.yaml"
USER_CFG="$HOME_DIR/.claude/.ical/config.yaml"

check "a parent folder's config covers a subfolder" "$CONF" 0 "$HOME_DIR/Conf/2026/sub"
check "the closest config wins, no merging" "$HOME_DIR/Conf/2026/talk/.claude/.ical/config.yaml" 0 "$HOME_DIR/Conf/2026/talk"
check "the starting directory's own config counts" "$CONF" 0 "$HOME_DIR/Conf"
check "the walk stops at a repository boundary, then the user-level config" "$USER_CFG" 0 "$HOME_DIR/outer/repo/src"
check "the repository root's own config is still found" "$HOME_DIR/outer/repo2/.claude/.ical/config.yaml" 0 "$HOME_DIR/outer/repo2/src"
check "a .git file (worktree or submodule) is a boundary too" "$HOME_DIR/outer/repo2/.claude/.ical/config.yaml" 0 "$HOME_DIR/outer/repo2"
check "the walk stops before \$HOME, then the user-level config" "$USER_CFG" 0 "$HOME_DIR/empty/x"
check "a symlinked start directory is resolved to its physical path" "$CONF" 0 "$HOME_DIR/link/sub"
check "a config in a world-writable .ical directory is ignored" "$USER_CFG" 0 "$HOME_DIR/wide/x"
check "a config in a group-writable .ical directory is ignored" "$USER_CFG" 0 "$HOME_DIR/groupw/x"
check "a .ical symlink to a world-writable directory is ignored" "$USER_CFG" 0 "$HOME_DIR/symd/x"
check "a config file writable by others is ignored" "$USER_CFG" 0 "$HOME_DIR/filew/x"
check "a world-writable .claude directory is ignored" "$USER_CFG" 0 "$HOME_DIR/clw/x"
check "a start directory outside \$HOME walks to the root" "$ROOT/other/.claude/.ical/config.yaml" 0 "$ROOT/other/deep"

# Default start directory is the current directory.
got="$(cd "$HOME_DIR/Conf/2026/sub" && HOME="$HOME_DIR" bash "$HELPER" 2>/dev/null)"; rc=$?
if [ "$got" = "$CONF" ] && [ "$rc" = 0 ]; then
  pass=$((pass + 1)); echo "ok   no argument starts from the current directory"
else
  fail=$((fail + 1)); printf 'FAIL no argument starts from the current directory\n     got [%s] rc=%s\n' "$got" "$rc"
fi

# Nothing anywhere: remove the user-level config.
rm "$USER_CFG"
check "no config anywhere prints nothing and exits 1" "" 1 "$HOME_DIR/empty/x"
check "outside \$HOME with no config anywhere exits 1" "" 1 "$ROOT"

# Bad start directory.
got="$(run "$ROOT/does-not-exist")"; rc=$?
if [ -z "$got" ] && [ "$rc" = 2 ]; then
  pass=$((pass + 1)); echo "ok   a missing start directory exits 2"
else
  fail=$((fail + 1)); printf 'FAIL a missing start directory exits 2\n     got [%s] rc=%s\n' "$got" "$rc"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
