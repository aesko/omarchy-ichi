#!/usr/bin/env bash
# Installs Ichi's guarded `dofile` line into hyprland.lua without trusting a
# symlink or directory an untrusted local account may have planted along the
# way. hyprland.lua is often itself a symlink into a dotfiles repo (see the
# comment in Service.qml on why the write stays in-place rather than
# rename-over), so this resolves that symlink deliberately rather than
# refusing to follow it: it just requires everything resolution passes
# through to belong to the user Ichi runs as, and to sit under $HOME. That
# is the same ancestor check sshd's StrictModes applies to ~/.ssh.
#
# Usage: install-hyprland-loader.sh <hyprland-lua-path> <home> <new-content>
# Exits 0 only if the write happened.
set -euo pipefail

target=$1
home=$2
content=$3
me=$(id -u)

fail() {
  echo "ichi: $1" >&2
  exit 1
}

resolved=$(readlink -f -- "$target") || fail "cannot resolve $target"

case "$resolved" in
  "$home"/*) ;;
  *) fail "$target resolves outside \$HOME ($resolved), refusing to write" ;;
esac

# Every directory from $HOME down to the resolved file's own directory must
# belong to the current user and not be group- or world-writable. That is
# how a symlink, or a directory swapped in ahead of one, gets planted.
check_dir() {
  local dir=$1 owner mode perm
  owner=$(stat -c '%u' -- "$dir") || fail "cannot stat $dir"
  [ "$owner" = "$me" ] || fail "$dir is not owned by the current user"
  mode=$(stat -c '%a' -- "$dir") || fail "cannot stat $dir"
  perm=$((8#$mode))
  if (( perm & 0022 )); then
    fail "$dir is group- or world-writable"
  fi
}

rel=${resolved#"$home"/}
dir=$home
check_dir "$dir"
parent=$(dirname -- "$rel")
if [ "$parent" != "." ]; then
  IFS='/' read -ra parts <<< "$parent"
  for part in "${parts[@]}"; do
    dir="$dir/$part"
    check_dir "$dir"
  done
fi

# Only ever edit an existing hyprland.lua; a missing one is not this plugin's
# to create, and one that vanished mid-check is not this plugin's to guess at.
[ -e "$resolved" ] || fail "$resolved no longer exists, not creating it"
owner=$(stat -c '%u' -- "$resolved") || fail "cannot stat $resolved"
[ "$owner" = "$me" ] || fail "$resolved is not owned by the current user"

if command -v python3 >/dev/null 2>&1; then
  # A real O_NOFOLLOW open: refuses outright if $resolved was replaced by a
  # symlink in the instant since the checks above ran.
  printf '%s' "$content" | python3 -c '
import os, sys
path = sys.argv[1]
data = sys.stdin.buffer.read()
fd = os.open(path, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
try:
    os.write(fd, data)
finally:
    os.close(fd)
' "$resolved" || fail "write refused for $resolved (symlink swapped after the check?)"
else
  # No python3 to ask the kernel for O_NOFOLLOW: same checks, but this last
  # open can still follow a symlink swapped in during the gap since they ran.
  [ -L "$resolved" ] && fail "$resolved became a symlink"
  printf '%s' "$content" > "$resolved"
fi
