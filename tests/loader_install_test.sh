#!/usr/bin/env bash
# Exercises scripts/install-hyprland-loader.sh's ownership and ancestor
# checks. Run: tests/loader_install_test.sh
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/scripts/install-hyprland-loader.sh"

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

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
