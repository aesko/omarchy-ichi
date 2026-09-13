#!/usr/bin/env bash
# Installs Ichi's guarded `dofile` line into hyprland.lua without trusting a
# symlink or directory an untrusted local account may have planted along the
# way. hyprland.lua is often itself a symlink into a dotfiles repo (see the
# comment in Service.qml on why the write stays in-place rather than
# rename-over), so this resolves that symlink deliberately rather than
# refusing to follow it: it just requires everything resolution passes
# through to belong to the user Ichi runs as, and to sit under $HOME.
#
# Resolution walks one path component at a time rather than calling
# `readlink -f` up front, and checks ownership at every step -- of the
# original path (a symlink could be planted at any directory leading to
# hyprland.lua, not just at hyprland.lua itself) and of wherever a symlink
# along the way points. That is the same ancestor check sshd's StrictModes
# applies to ~/.ssh.
#
# Usage: install-hyprland-loader.sh <hyprland-lua-path> <home> <new-content>
# Exits 0 only if the write happened.
set -euo pipefail

target=$1
home_arg=$2
content=$3
me=$(id -u)

fail() {
  echo "ichi: $1" >&2
  exit 1
}

# $HOME itself may be a symlink (an autofs or NFS home is a common case), so
# it is resolved once up front and used as the walk's anchor and as the
# containment boundary, alongside the raw value the caller passed in.
home=$(readlink -f -- "$home_arg") || fail "cannot resolve \$HOME ($home_arg)"

# Every directory the walk passes through, on the original path or after a
# symlink redirects it, must belong to the current user and not be group- or
# world-writable. That is how a symlink, or a directory swapped in ahead of
# one, gets planted in the first place.
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

check_symlink_owner() {
  local link=$1 owner
  owner=$(stat -c '%u' -- "$link") || fail "cannot stat $link"
  [ "$owner" = "$me" ] || fail "$link is a symlink not owned by the current user"
}

case "$target" in
  "$home_arg"/*) rel=${target#"$home_arg"/} ;;
  "$home"/*) rel=${target#"$home"/} ;;
  *) fail "$target is not under \$HOME" ;;
esac
[ -n "$rel" ] || fail "$target is \$HOME itself"

check_dir "$home"

queue=()
IFS='/' read -ra queue <<< "$rel"

cur=$home
hops=0
while [ "${#queue[@]}" -gt 0 ]; do
  comp=${queue[0]}
  queue=("${queue[@]:1}")
  [ -z "$comp" ] && continue
  [ "$comp" = "." ] && continue

  # `cur` is always a real directory, never a symlink, so `..` can be taken
  # lexically. Climbing out of $HOME this way is refused just like an
  # absolute link that points outside it.
  if [ "$comp" = ".." ]; then
    [ "$cur" = "$home" ] && fail "$target climbs out of \$HOME"
    cur=$(dirname -- "$cur")
    check_dir "$cur"
    continue
  fi

  next="$cur/$comp"
  if [ -L "$next" ]; then
    hops=$((hops + 1))
    (( hops > 40 )) && fail "too many symlinks resolving $target"
    check_symlink_owner "$next"
    link_target=$(readlink -- "$next") || fail "cannot read symlink $next"
    case "$link_target" in
      /*)
        # A dotfiles link made with `ln -s $HOME/...` spells the unresolved
        # $HOME, so either spelling counts as inside it.
        case "$link_target" in
          "$home"/*|"$home") rest=${link_target#"$home"} ;;
          "$home_arg"/*|"$home_arg") rest=${link_target#"$home_arg"} ;;
          *) fail "$next resolves outside \$HOME ($link_target)" ;;
        esac
        cur=$home
        rest=${rest#/}
        ;;
      *)
        cur=$(dirname -- "$next")
        rest=$link_target
        ;;
    esac
    parts=()
    IFS='/' read -ra parts <<< "$rest"
    queue=("${parts[@]}" "${queue[@]}")
  else
    cur=$next
    if [ "${#queue[@]}" -gt 0 ]; then
      # More path remains, so this component must be a traversable directory.
      [ -d "$cur" ] || fail "$cur does not exist or is not a directory"
      check_dir "$cur"
    fi
  fi
done
resolved=$cur

# Only ever edit an existing hyprland.lua; a missing one is not this plugin's
# to create, and one that vanished mid-check is not this plugin's to guess at.
[ -e "$resolved" ] || fail "$resolved no longer exists, not creating it"
[ -L "$resolved" ] && fail "$resolved is unexpectedly still a symlink"
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
