#!/usr/bin/env bash
# The checkout against a real compositor: starts a nested Hyprland that loads
# this ichi.lua, opens terminals in it and checks the gaps Ichi sets. Run it
# from inside a Hyprland session before a release, and again after a Hyprland
# or Omarchy update:
#
#   tests/nested.sh
#
# The nested Hyprland opens as a window on your desktop for about a minute.
# Everything it reads and writes lives in a temporary HOME, notifications are
# captured rather than shown, and hyprctl is pointed at the nested instance
# only. It cannot run in CI, which has no Wayland session; tests/run.sh is
# what CI runs.
#
# Needs Hyprland, foot and jq. Omarchy 4.5's floating workspaces and
# per-monitor numbering are checked when Omarchy is installed, and the shell
# side when Quickshell (qs) is.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OMARCHY=${OMARCHY_PATH:-/usr/share/omarchy}

for tool in Hyprland hyprctl foot jq; do
  command -v "$tool" >/dev/null || { echo "skip: $tool not installed"; exit 0; }
done
[[ -n ${WAYLAND_DISPLAY:-} && -n ${XDG_RUNTIME_DIR:-} ]] || { echo "skip: needs a running Wayland session"; exit 0; }

with_omarchy=0
[[ -f $OMARCHY/default/hypr/workspace-modes.lua ]] && with_omarchy=1
with_qs=0
command -v qs >/dev/null && (( with_omarchy )) && with_qs=1

S=$(mktemp -d)
HOME_DIR=$S/home
STATE=$HOME_DIR/.local/state
NOTES=$S/notes
mkdir -p "$HOME_DIR/.config/ichi" "$HOME_DIR/.config/hypr" "$STATE/omarchy/workspace-layouts" "$S/qs"
: >"$NOTES"

cat >"$HOME_DIR/.config/ichi/ichi.json" <<'JSON'
{
  "settings": { "step": 5, "fine_step": 1, "notify": "changes", "all_workspaces": false, "max_windows": 1, "paused": false },
  "defaults": { "width": 50, "height": 50 },
  "presets": {},
  "workspaces": {
    "2": { "mode": "size", "width": 50, "height": 50 },
    "3": { "mode": "size", "width": 50, "height": 50 }
  }
}
JSON

{
  if (( with_omarchy )); then
    printf 'dofile("%s/default/hypr/bootstrap.lua")\n' "$OMARCHY"
    printf 'require("default.hypr.helpers")\n'
  fi
  cat <<'LUA'
hl.config({ general = { gaps_out = 10, gaps_in = 5, layout = "dwindle" }, misc = { disable_hyprland_logo = true } })
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
LUA
  (( with_omarchy )) && printf 'require("default.hypr.workspace-layouts")\n'
  printf 'dofile("%s/ichi.lua")\n' "$ROOT"
  # hl.exec_cmd does not take this script's PATH, so a fake notifier would be
  # passed over for the real one. Notifications are written to a file instead.
  cat <<'LUA'
ichi.notify_command = function(message)
  local file = io.open(os.getenv("ICHI_TEST_NOTES"), "a")
  file:write(message, "\n")
  file:close()
  return "true"
end
LUA
} >"$HOME_DIR/.config/hypr/hyprland.lua"

printf 'import Quickshell\nimport "file:%s" as Ichi\nShellRoot { Ichi.Service {} }\n' "$ROOT" >"$S/qs/shell.qml"

ENVS=(ICHI_TEST_NOTES="$NOTES" HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" XDG_STATE_HOME="$STATE")

RUN=$XDG_RUNTIME_DIR/hypr
before=$(ls -1 "$RUN" 2>/dev/null | sort)
env "${ENVS[@]}" Hyprland -c "$HOME_DIR/.config/hypr/hyprland.lua" >"$S/hyprland.log" 2>&1 &
HPID=$!
QPID=""
cleanup() {
  [[ -n $QPID ]] && kill "$QPID" 2>/dev/null
  kill "$HPID" 2>/dev/null
  wait "$HPID" 2>/dev/null
  rm -rf "$S"
}
trap cleanup EXIT

SIG=""
for _ in $(seq 1 50); do
  sleep 0.2
  new=$(comm -13 <(printf '%s\n' "$before") <(ls -1 "$RUN" 2>/dev/null | sort) | head -1)
  if [[ -n $new && -S $RUN/$new/.socket.sock ]]; then SIG=$new; break; fi
done
[[ -n $SIG ]] || { echo "FAIL the nested Hyprland did not start"; tail -20 "$S/hyprland.log"; exit 1; }
export HYPRLAND_INSTANCE_SIGNATURE=$SIG

failures=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+: $2}"; failures=$((failures + 1)); }

hc() { hyprctl "$@"; }
gaps() { hc workspacerules -j | jq -c --arg w "$1" '[.[] | select(.workspaceString==$w) | .gapsOut] | last'; }
floats() { hc clients -j | jq -c --argjson w "$1" '[.[] | select(.workspace.id==$w) | .floating] | sort | unique'; }
count() { hc clients -j | jq --argjson w "$1" '[.[] | select(.workspace.id==$w)] | length'; }
first() { hc clients -j | jq -r --argjson w "$1" '[.[] | select(.workspace.id==$w) | .address] | first'; }
plain() { [[ $(gaps "$1") == "[10,10,10,10]" ]]; }
inset() { local g; g=$(gaps "$1"); [[ $g != "null" && $g != "[10,10,10,10]" ]]; }
note() { tail -1 "$NOTES"; }

# Waits up to about three seconds for a condition, so a slow machine does not
# fail a check that only needed another moment.
eventually() {
  for _ in $(seq 1 30); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}
# DETAIL, when set, is a command whose output explains a failure, run only
# once the check has failed so it shows the state that failed.
check() {
  local name=$1; shift
  if eventually "$@"; then pass "$name"; else fail "$name" "$([[ -n ${DETAIL:-} ]] && eval "$DETAIL")"; fi
}

focus() { hc dispatch "hl.dsp.focus({ workspace = \"$1\" })" >/dev/null; sleep 0.3; }
open() { local n; n=$(count "$1"); hc dispatch 'hl.dsp.exec_cmd("foot")' >/dev/null; eventually test "$(count "$1")" -gt "$n"; sleep 0.3; }
close() { hc dispatch "hl.dsp.window.close({ window = \"address:$(first "$1")\" })" >/dev/null; sleep 0.5; }
move() { hc dispatch "hl.dsp.window.move({ workspace = \"$2\", follow = false, window = \"address:$(first "$1")\" })" >/dev/null; sleep 0.5; }
mode() { hc eval "o.workspace_mode({ workspace = \"$1\", mode = \"$2\" })" >/dev/null; sleep 0.5; }
reload() { hc reload >/dev/null; sleep 1.5; }

omarchy_version="not installed"
(( with_omarchy )) && omarchy_version=$(omarchy version 2>/dev/null || echo "installed")
echo "Hyprland $(hc version -j | jq -r .tag), Omarchy $omarchy_version"
errors=$(hc configerrors | tr -d '\n')
[[ -z $errors ]] && pass "the config loads without errors" || fail "the config loads without errors" "$errors"

# The core: one tiled window insets, a second gives the space back.
focus 2
open 2
DETAIL='echo "gaps $(gaps 2)"' check "one tiled window is inset" inset 2
open 2
check "a second tiled window restores the normal gaps" plain 2
close 2
check "closing it brings the inset back" inset 2

# A ratio, then the same ratio at half its size. The nested session has no
# bar, so the box is the monitor less the gaps. At full size the base gaps
# trim the side that fills the monitor, so the ratio is checked at 50.
box_ratio() { hc monitors -j | jq --argjson g "$(gaps 2)" '.[0] | ((.width / .scale) - $g[1] - $g[3]) / ((.height / .scale) - $g[0] - $g[2])'; }
near43() { local r; r=$(box_ratio); awk -v r="$r" 'BEGIN { exit !(r > 1.32 && r < 1.35) }'; }
hc eval 'ichi.set_aspect(4, 3, "2")' >/dev/null
DETAIL='echo "gaps $(gaps 2)"' check "an aspect workspace is inset" inset 2
full=$(gaps 2)
hc eval 'ichi.set_scale(50, "2")' >/dev/null
grown() { local g; g=$(gaps 2); [[ $g != "$full" ]] && jq -en --argjson a "$full" --argjson b "$g" '$b[0] > $a[0] and $b[1] > $a[1] and $b[2] > $a[2] and $b[3] > $a[3]' >/dev/null; }
DETAIL='echo "gaps $full, then $(gaps 2)"' check "at scale 50 it shrinks on every side" grown
DETAIL='echo "gaps $(gaps 2), ratio $(box_ratio)"' check "and is 4:3" near43
# A nudge of no steps leaves the ratio for a size at the box's own share of
# the screen, so the gaps stay within a rounding of where they were.
half=$(gaps 2)
hc eval 'ichi.nudge(0, 0, false, "2")' >/dev/null
same_box() { jq -en --argjson a "$half" --argjson b "$(gaps 2)" '[range(4)] | all(($a[.] - $b[.]) | fabs < 15)' >/dev/null; }
switched() { jq -e '.workspaces["2"].mode == "size"' "$HOME_DIR/.config/ichi/ichi.json" >/dev/null; }
check "a nudge on a ratio switches it to a size" switched
DETAIL='echo "gaps $half, then $(gaps 2)"' check "starting from the box on screen" same_box
hc eval 'ichi.reset("2")' >/dev/null
focus 4
open 4
check "a workspace that is off keeps its normal gaps" test "$(gaps 4)" = null -o "$(gaps 4)" = "[10,10,10,10]"
close 4

if (( with_omarchy )); then
  # Omarchy's floating layout floats every window, leaving nothing to inset.
  focus 2
  mode 2 floating
  check "a floating workspace floats its window" test "$(floats 2)" = "[true]"
  check "and keeps the normal gaps" plain 2
  open 2
  check "a window opened there floats too" test "$(floats 2)" = "[true]"
  focus 3
  open 3
  check "a lone tiled window on another workspace is inset" inset 3
  move 3 2
  check "carried into the floating workspace, it floats" test "$(floats 2)" = "[true]"
  check "and the floating workspace keeps the normal gaps" plain 2
  move 2 4
  move 2 3
  check "carried out to a workspace of its own, it tiles and is inset" inset 3
  mode 2 dwindle
  check "tiled again, the floating workspace's window tiles" test "$(floats 2)" = "[false]"
  check "and is inset again" inset 2
  mode 2 scrolling
  check "a scrolling workspace is inset" inset 2
  mode 2 dwindle

  printf 'o.workspace_mode({ default = "floating" })\n' >"$STATE/omarchy/workspace-layouts/default.lua"
  reload
  check "with floating as the default, every workspace keeps normal gaps" plain 2
  check "workspace 3 too" plain 3
  rm -f "$STATE/omarchy/workspace-layouts/default.lua"
  reload
  check "without the default, the insets come back" inset 2
  check "on workspace 3 too" inset 3

  # Saved the way omarchy-hyprland-workspace-layout-toggle saves it.
  printf 'o.workspace_mode({ workspace = "2", mode = "floating" })\n' >"$STATE/omarchy/workspace-layouts/2.lua"
  mode 2 floating
  focus 2
  hc eval 'ichi.disable("2")' >/dev/null
  hc eval 'ichi.enable("2")' >/dev/null
  DETAIL='echo "note: $(note)"' check "turning Ichi on in a floating workspace says it waits" grep -q "once it stops floating" "$NOTES"
  rm -f "$STATE/omarchy/workspace-layouts/2.lua"
  mode 2 dwindle

  # Per-monitor numbering: the second monitor's 3 is workspace 13.
  printf '0\tWAYLAND-1\tnested\n1\t\tSecond Monitor\n' >"$STATE/omarchy/monitor-workspaces"
  focus 13
  open 13
  hc eval 'ichi.toggle()' >/dev/null
  DETAIL='echo "note: $(note)"' check "workspace 13 is called 3, as the bar calls it" eval '[[ $(note) == "Ichi: workspace 3 at"* ]]'
  check "and its entry keeps Hyprland's number" eval "jq -e '.workspaces | has(\"13\")' '$HOME_DIR/.config/ichi/ichi.json' >/dev/null"
  check "and it is inset" inset 13

  if (( with_qs )); then
    env "${ENVS[@]}" qs -p "$S/qs/shell.qml" >"$S/qs.log" 2>&1 &
    QPID=$!
    ipc() { env "${ENVS[@]}" qs ipc -p "$S/qs/shell.qml" call ichi "$@" 2>/dev/null; }
    status_row() { ipc status | grep -E '^Workspace'; }
    DETAIL='echo "row: $(status_row)"' check "status shows the bar's number and Hyprland's" eval '[[ $(status_row) == *"3 (Hyprland'"'"'s 13)"* ]]'
    check "status_json keeps the key and adds the label" eval '[[ $(ipc status_json | jq -c "{workspace,label}") == "{\"workspace\":\"13\",\"label\":\"3\"}" ]]'
  else
    echo "skip: Quickshell not installed, shell side not checked"
  fi

  rm -f "$STATE/omarchy/monitor-workspaces"
  hc eval 'ichi.toggle()' >/dev/null
  hc eval 'ichi.toggle()' >/dev/null
  DETAIL='echo "note: $(note)"' check "without Omarchy's blocks, 13 is 13" eval '[[ $(note) == "Ichi: workspace 13 at"* ]]'
else
  echo "skip: Omarchy not installed, floating and per-monitor cases not checked"
fi

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
