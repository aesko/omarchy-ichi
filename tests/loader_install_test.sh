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

"$script" "$home/.config/hypr/hyprland.lua" "$home" $'-- original\nloader\n' >/dev/null 2>&1
check "writes through a well-owned symlink into a dotfiles repo" "$([ $? -eq 0 ] && grep -q loader "$home/dotfiles/hypr/hyprland.lua" && echo 1 || echo 0)"

outside=$(mktemp -d)
trap 'rm -rf "$work" "$outside"' EXIT
printf -- '-- evil\n' > "$outside/hyprland.lua"
ln -sf "$outside/hyprland.lua" "$home/.config/hypr/hyprland.lua"
"$script" "$home/.config/hypr/hyprland.lua" "$home" 'new' >/dev/null 2>&1
check "refuses a symlink that resolves outside \$HOME" "$([ $? -ne 0 ] && ! grep -q new "$outside/hyprland.lua" && echo 1 || echo 0)"

ln -sf "$home/dotfiles/hypr/hyprland.lua" "$home/.config/hypr/hyprland.lua"
chmod 777 "$home/dotfiles/hypr"
"$script" "$home/.config/hypr/hyprland.lua" "$home" 'new' >/dev/null 2>&1
check "refuses a world-writable ancestor directory" "$([ $? -ne 0 ] && ! grep -q '^new$' "$home/dotfiles/hypr/hyprland.lua" && echo 1 || echo 0)"
chmod 755 "$home/dotfiles/hypr"

rm "$home/dotfiles/hypr/hyprland.lua"
"$script" "$home/.config/hypr/hyprland.lua" "$home" 'new' >/dev/null 2>&1
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
"$script" "$home/.config/hypr/hyprland.lua" "$home" 'PWNED' >/dev/null 2>&1
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
"$script" "$homelink/.config/hypr/hyprland.lua" "$homelink" $'-- original\nloader\n' >/dev/null 2>&1
check "writes through a symlinked \$HOME" \
  "$([ $? -eq 0 ] && grep -q loader "$home/dotfiles/hypr/hyprland.lua" && echo 1 || echo 0)"

# Same setup, but the dotfiles link spells the unresolved $HOME, which is
# what `ln -s $HOME/dotfiles/...` produces.
printf -- '-- original\n' > "$home/dotfiles/hypr/hyprland.lua"
ln -sfn "$homelink/dotfiles/hypr/hyprland.lua" "$home/.config/hypr/hyprland.lua"
"$script" "$homelink/.config/hypr/hyprland.lua" "$homelink" $'-- original\nloader\n' >/dev/null 2>&1
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
"$script" "$home/.config/hypr/hyprland.lua" "$home" 'new' >/dev/null 2>&1
check "refuses a relative link that climbs out of \$HOME" \
  "$([ $? -ne 0 ] && ! grep -q '^new$' "$escape/hyprland.lua" && echo 1 || echo 0)"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
