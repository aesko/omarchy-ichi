#!/usr/bin/env bash
# Exercises scripts/install-hyprland-loader.sh's ownership and ancestor
# checks. Run: tests/loader_install_test.sh
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/scripts/install-hyprland-loader.sh"

# The script refuses group-writable ancestors, and mkdir honours the caller's
# umask; a 002 umask (the Debian/Ubuntu default) would make every directory
# below group-writable and fail the happy-path cases for a reason that has
# nothing to do with what they are testing.
umask 022

failures=0
check() {
  local name=$1 ok=$2
  if [ "$ok" = "1" ]; then
    echo "ok   $name"
  else
    failures=$((failures + 1))
    echo "FAIL $name"
  fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
home="$work/home"
mkdir -p "$home/dotfiles/hypr" "$home/.config/hypr"
printf -- '-- original\n' > "$home/dotfiles/hypr/hyprland.lua"
ln -s "$home/dotfiles/hypr/hyprland.lua" "$home/.config/hypr/hyprland.lua"

ICHI_LOADER_CONTENT=$'-- original\nloader\n' "$script" "$home/.config/hypr/hyprland.lua" "$home" >/dev/null 2>&1
check "writes through a well-owned symlink into a dotfiles repo" "$([ $? -eq 0 ] && grep -q loader "$home/dotfiles/hypr/hyprland.lua" && echo 1 || echo 0)"

outside=$(mktemp -d)
trap 'rm -rf "$work" "$outside"' EXIT
printf -- '-- evil\n' > "$outside/hyprland.lua"
ln -sf "$outside/hyprland.lua" "$home/.config/hypr/hyprland.lua"
ICHI_LOADER_CONTENT='new' "$script" "$home/.config/hypr/hyprland.lua" "$home" >/dev/null 2>&1
check "refuses a symlink that resolves outside \$HOME" "$([ $? -ne 0 ] && ! grep -q new "$outside/hyprland.lua" && echo 1 || echo 0)"

ln -sf "$home/dotfiles/hypr/hyprland.lua" "$home/.config/hypr/hyprland.lua"
chmod 777 "$home/dotfiles/hypr"
ICHI_LOADER_CONTENT='new' "$script" "$home/.config/hypr/hyprland.lua" "$home" >/dev/null 2>&1
check "refuses a world-writable ancestor directory" "$([ $? -ne 0 ] && ! grep -q '^new$' "$home/dotfiles/hypr/hyprland.lua" && echo 1 || echo 0)"
chmod 755 "$home/dotfiles/hypr"

rm "$home/dotfiles/hypr/hyprland.lua"
ICHI_LOADER_CONTENT='new' "$script" "$home/.config/hypr/hyprland.lua" "$home" >/dev/null 2>&1
check "refuses when the resolved target no longer exists" "$([ $? -ne 0 ] && echo 1 || echo 0)"

# The attack an ancestor-only check misses: ~/.config/hypr itself (not just
# hyprland.lua) is a symlink out to a directory anyone can write in, so an
# attacker can point the eventual hyprland.lua leaf anywhere they like.
rm -rf "$home/.config/hypr"
attacker_writable=$(mktemp -d)
trap 'rm -rf "$work" "$outside" "$attacker_writable"' EXIT
chmod 777 "$attacker_writable"
ln -s "$attacker_writable" "$home/.config/hypr"
ln -s "$home/.bashrc" "$attacker_writable/hyprland.lua"
printf 'victim bashrc\n' > "$home/.bashrc"
ICHI_LOADER_CONTENT='PWNED' "$script" "$home/.config/hypr/hyprland.lua" "$home" >/dev/null 2>&1
check "refuses a symlinked intermediate directory anyone can write in" \
  "$([ $? -ne 0 ] && ! grep -q PWNED "$home/.bashrc" && echo 1 || echo 0)"
rm -f "$home/.config/hypr"

# $HOME itself may be a symlink (autofs, NFS, some container setups); that
# alone should not trip the ownership checks below it.
mkdir -p "$home/.config/hypr"
printf -- '-- original\n' > "$home/dotfiles/hypr/hyprland.lua"
ln -sf "$home/dotfiles/hypr/hyprland.lua" "$home/.config/hypr/hyprland.lua"
homelink="$work/homelink"
ln -s "$home" "$homelink"
ICHI_LOADER_CONTENT=$'-- original\nloader\n' "$script" "$homelink/.config/hypr/hyprland.lua" "$homelink" >/dev/null 2>&1
check "writes through a symlinked \$HOME" \
  "$([ $? -eq 0 ] && grep -q loader "$home/dotfiles/hypr/hyprland.lua" && echo 1 || echo 0)"

# Same setup, but the dotfiles link spells the unresolved $HOME, which is
# what `ln -s $HOME/dotfiles/...` produces.
printf -- '-- original\n' > "$home/dotfiles/hypr/hyprland.lua"
ln -sfn "$homelink/dotfiles/hypr/hyprland.lua" "$home/.config/hypr/hyprland.lua"
ICHI_LOADER_CONTENT=$'-- original\nloader\n' "$script" "$homelink/.config/hypr/hyprland.lua" "$homelink" >/dev/null 2>&1
check "writes through a link spelled with the unresolved \$HOME" \
  "$([ $? -eq 0 ] && grep -q loader "$home/dotfiles/hypr/hyprland.lua" && echo 1 || echo 0)"

# A relative link can climb out of $HOME with `..` just as an absolute one
# can point outside it. Climbing past root-owned directories already fails
# the ownership check, so the case that matters is a sibling of $HOME under
# a parent the user owns, which is what $work is.
escape="$work/escape"
mkdir -p "$escape"
printf -- '-- elsewhere\n' > "$escape/hyprland.lua"
ln -sfn "../../../escape/hyprland.lua" "$home/.config/hypr/hyprland.lua"
ICHI_LOADER_CONTENT='new' "$script" "$home/.config/hypr/hyprland.lua" "$home" >/dev/null 2>&1
check "refuses a relative link that climbs out of \$HOME" \
  "$([ $? -ne 0 ] && ! grep -q '^new$' "$escape/hyprland.lua" && echo 1 || echo 0)"

# ---------------------------------------------------------- atomic replace --
#
# The write used to open hyprland.lua with O_TRUNC and then write, so anything
# that went wrong in between left the user with an empty config -- and the
# no-python3 fallback re-tested `-L` and then wrote through `>`, which follows
# a symlink swapped in after the test. Both are gone: the content goes to a
# temp file in the same directory and is renamed over the target.

mkdir -p "$home/.config/hypr"
printf -- '-- original\n' > "$home/dotfiles/hypr/hyprland.lua"
chmod 640 "$home/dotfiles/hypr/hyprland.lua"
ln -sfn "$home/dotfiles/hypr/hyprland.lua" "$home/.config/hypr/hyprland.lua"
before_inode=$(stat -c '%i' "$home/dotfiles/hypr/hyprland.lua")
ICHI_LOADER_CONTENT=$'-- original\nloader\n' "$script" "$home/.config/hypr/hyprland.lua" "$home" >/dev/null 2>&1
rc=$?

# A different inode is the observable difference between replacing the file and
# truncating it in place, which is the whole point of the change.
check "replaces the target rather than writing into it" \
  "$([ $rc -eq 0 ] && [ "$(stat -c '%i' "$home/dotfiles/hypr/hyprland.lua")" != "$before_inode" ] && echo 1 || echo 0)"
check "keeps the dotfiles symlink a symlink" \
  "$([ -L "$home/.config/hypr/hyprland.lua" ] && grep -q loader "$home/dotfiles/hypr/hyprland.lua" && echo 1 || echo 0)"
check "carries the target's mode onto the replacement" \
  "$([ "$(stat -c '%a' "$home/dotfiles/hypr/hyprland.lua")" = 640 ] && echo 1 || echo 0)"

# Fail the write itself and the original must survive it untouched, which is
# the property the old O_TRUNC open could not offer: it emptied hyprland.lua
# before it had the new bytes, so every failure past that point cost the user
# their config. Injected by shadowing mktemp rather than by taking write
# permission off the directory, because root ignores directory modes and the
# suite should not quietly stop testing this when it runs as root.
stub="$work/stub"
mkdir -p "$stub"
printf '#!/bin/sh\nexit 1\n' > "$stub/mktemp"
chmod 755 "$stub/mktemp"
printf -- '-- original\n' > "$home/dotfiles/hypr/hyprland.lua"
ln -sfn "$home/dotfiles/hypr/hyprland.lua" "$home/.config/hypr/hyprland.lua"
PATH="$stub:$PATH" ICHI_LOADER_CONTENT='replacement' "$script" "$home/.config/hypr/hyprland.lua" "$home" >/dev/null 2>&1
check "leaves the original intact when the replacement cannot be written" \
  "$([ $? -ne 0 ] && [ "$(cat "$home/dotfiles/hypr/hyprland.lua")" = '-- original' ] && echo 1 || echo 0)"

# The content is no longer an argument, so a caller that still passes it as one
# must fail rather than write whatever happens to be in the environment.
printf -- '-- original\n' > "$home/dotfiles/hypr/hyprland.lua"
ln -sfn "$home/dotfiles/hypr/hyprland.lua" "$home/.config/hypr/hyprland.lua"
env -u ICHI_LOADER_CONTENT "$script" "$home/.config/hypr/hyprland.lua" "$home" 'as-an-argument' >/dev/null 2>&1
check "refuses when ICHI_LOADER_CONTENT is not set" \
  "$([ $? -ne 0 ] && [ "$(cat "$home/dotfiles/hypr/hyprland.lua")" = '-- original' ] && echo 1 || echo 0)"

# No temp file may outlive the run, on the way out of either a success or a
# refusal; both of the cases above have just exercised one each.
check "leaves no temporary file behind" \
  "$([ -z "$(find "$home/dotfiles/hypr" -name '.hyprland.lua.ichi-*' -print -quit)" ] && echo 1 || echo 0)"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
