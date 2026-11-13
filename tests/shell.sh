#!/usr/bin/env bash
# The shell side against a real Quickshell and the installed Omarchy shell,
# offscreen: the preset-name field, the steppers, BoundedProcess and
# Service.qml's action queue; that the qs.Commons members, plugin API
# functions and omarchy-* commands Ichi uses are all there; and that
# BarWidget.qml compiles against this qs.Ui. Run it by hand before a release,
# next to tests/nested.sh, and after an Omarchy update (ichi-upstream-check
# runs it):
#
#   tests/shell.sh
#
# Nothing opens on screen: Quickshell runs on Qt's offscreen platform with a
# private clipboard, a temporary config and state, and a fake hyprctl first on
# PATH. Key presses and clicks are real Qt input events, sent with QtTest's
# helpers. It cannot run in CI, which has no Quickshell or Omarchy shell;
# tests/run.sh is what CI runs.
#
# Needs qs, Omarchy's shell (for qs.Ui and qs.Commons) and Qt's QtTest module.
# Takes about 15 seconds, most of it waiting out a deadline on purpose.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OMARCHY=${OMARCHY_PATH:-/usr/share/omarchy}

command -v qs >/dev/null || { echo "skip: qs not installed"; exit 0; }
[[ -d $OMARCHY/shell/Ui && -d $OMARCHY/shell/Commons ]] || { echo "skip: no Omarchy shell at $OMARCHY/shell"; exit 0; }

S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT
mkdir -p "$S/qs" "$S/bin" "$S/config"
# qs.Ui and qs.Commons resolve against the config's own directory.
ln -s "$OMARCHY/shell/Ui" "$S/qs/Ui"
ln -s "$OMARCHY/shell/Commons" "$S/qs/Commons"

# hyprctl does what $S/mode says: answer, stall, or flood its stderr. PATH
# holds only $S/bin, so a hyprctl moved out of it cannot fall back to the real
# one; everything else is called by its full path.
cat >"$S/bin/hyprctl" <<EOF
#!/bin/bash
case \$(/usr/bin/cat "$S/mode" 2>/dev/null) in
  stall) exec /usr/bin/sleep 30 ;;
  flood) /usr/bin/head -c 10000000 /dev/zero | /usr/bin/tr '\\0' e >&2 ;;
  *) echo ok >&2 ;;
esac
EOF
chmod +x "$S/bin/hyprctl"
ln -s /usr/bin/mkdir "$S/bin/mkdir"
echo ok >"$S/mode"

# Code only, comments dropped: QML's // and Lua's --.
code() { sed -E 's#(^|[[:space:]])(//|--).*##' "$@"; }
# Every Style., Color. and Border. member Ichi's QML reads, with a trailing (
# for one it calls. A member the kit drops reads as undefined, which QML
# draws as nothing or NaN rather than failing, so each is looked up here.
kit_members=$(code "$ROOT"/*.qml | grep -ohE '\b(Style|Color|Border)(\.[A-Za-z_]+)+\(?' | sort -u |
  sed 's/.*/"&"/' | paste -sd, -)

cat >"$S/qs/shell.qml" <<EOF
import QtQuick
import QtTest
import Quickshell
import qs.Commons as Commons
import "file:$ROOT"

ShellRoot {
  id: shell
  property var steps: []
  property int failures: 0
  // Every error the service reports, since one can come and go between two
  // looks at lastError.
  property var errors: []

  Connections {
    target: service
    function onLastErrorChanged() { if (service.lastError !== "") shell.errors = shell.errors.concat([service.lastError]) }
  }

  // Runs a shell command and waits for it, for the steps that change the
  // fake hyprctl.
  BoundedProcess { id: helper }
  function pause(ms) {
    var from = Date.now()
    return { what: "a pause", timeout: ms + 1000, until: () => Date.now() - from >= ms }
  }

  function run(command) {
    helper.command = ["/bin/sh", "-c", command]
    helper.start()
    return { what: command, timeout: 2000, until: () => !helper.busy }
  }

  function check(name, ok, detail) {
    if (!ok) failures++
    console.log((ok ? "ok   " : "FAIL ") + name + (ok || detail === undefined ? "" : ": " + detail))
  }

  // Runs the steps in order. A step returns nothing to go straight on, or
  // { until: fn, timeout: ms, then: fn } to wait for fn() first.
  function next() {
    if (steps.length === 0) { console.log("done " + failures); Qt.quit(); return }
    var step = steps.shift()
    var wait = step()
    if (!wait) { Qt.callLater(next); return }
    poll.wait = wait
    poll.started = Date.now()
    poll.start()
  }

  Timer {
    id: poll
    property var wait: null
    property real started: 0
    interval: 25
    repeat: true
    onTriggered: {
      var done = wait.until()
      if (!done && Date.now() - started < wait.timeout) return
      stop()
      if (!done) shell.check("waited for: " + (wait.what || "a condition"), false, "timed out; queue "
        + service.queue.length + ", evaluating " + service.evaluating + ", errors " + JSON.stringify(shell.errors.slice(-3)))
      else if (wait.then) wait.then(Date.now() - started)
      Qt.callLater(shell.next)
    }
  }

  FloatingWindow {
    id: win
    implicitWidth: 420
    implicitHeight: 240
    visible: true

    KeyField {
      id: field
      width: 300
      property int acceptedCount: 0
      property int escapedCount: 0
      onAccepted: acceptedCount++
      onEscaped: escapedCount++
    }

    Stepper {
      id: stepper
      y: 80
      label: "Step"
      value: 5
      from: 1
      to: 25
      onModified: (v) => value = v
      // The row with − value +, after the label.
      readonly property var row: children[1]
    }
    property alias stepperRow: stepper.row

    TestCase { id: tc; name: "ichi"; when: false }
  }

  // ---------------------------------------------------- BoundedProcess --

  BoundedProcess {
    id: proc
    property var outcomes: []
    property int lastCode: -2
    onFinished: (outcome, code) => { outcomes = outcomes.concat([outcome]); lastCode = code }
  }

  // ------------------------------------------------------- Service.qml --

  Service { id: service }

  Component.onCompleted: {
    var big = "x".repeat(1000000)
    steps = [
      // What Ichi uses of the installed kit.
      () => {
        var roots = { Style: Commons.Style, Color: Commons.Color, Border: Commons.Border }
        var used = [$kit_members]
        var missing = used.filter((name) => {
          var call = name.endsWith("(")
          var v = roots
          for (var part of name.replace(/\\($/, "").split(".")) v = v === undefined || v === null ? undefined : v[part]
          return call ? typeof v !== "function" : v === undefined || v === null
        })
        check("qs.Commons has the " + used.length + " Style, Color and Border members Ichi uses",
          used.length > 0 && missing.length === 0, "missing " + missing.join(" "))
        // Plugins get a PluginShellApi as bar.shell. BarWidget.qml checks for
        // these before calling them, so a rename would go quiet, not fail.
        var api = Qt.createComponent("file:$OMARCHY/shell/services/PluginShellApi.qml")
        var shellApi = api.status === Component.Ready ? api.createObject(shell, { pluginId: "io.github.aesko.ichi" }) : null
        check("the plugin shell API loads", shellApi !== null, api.errorString())
        if (shellApi) for (var fn of ["serviceFor", "updateEntryInline"])
          check("the plugin shell API has " + fn + "()", typeof shellApi[fn] === "function", typeof shellApi[fn])
      },

      // The preset-name field.
      () => {
        field.forceActiveFocus()
        "wide".split("").forEach((c) => tc.keyClick(c))
        check("typing goes into the name field", field.text === "wide", field.text)
        tc.keyClick(Qt.Key_Backspace)
        check("Backspace removes the last character", field.text === "wid", field.text)
        Quickshell.clipboardText = big
      },
      () => {
        tc.keyClick(Qt.Key_V, Qt.ControlModifier)
        check("Ctrl+V pastes nothing", field.text === "wid", field.text.length + " characters")
        tc.keyClick(Qt.Key_Insert, Qt.ShiftModifier)
        check("Shift+Insert pastes nothing", field.text === "wid", field.text.length + " characters")
        tc.mouseClick(field, 20, field.height / 2, Qt.MiddleButton)
        check("a middle click pastes nothing", field.text === "wid", field.text.length + " characters")
        tc.mouseClick(field, 20, field.height / 2, Qt.RightButton)
        check("a right click pastes nothing and opens no menu", field.text === "wid", field.text.length + " characters")
        check("the clipboard still holds the large text", Quickshell.clipboardText.length === big.length)
        for (var i = 0; i < 50; i++) tc.keyClick("a")
        check("the field stops at " + field.maximumLength + " characters", field.text.length === field.maximumLength, field.text.length)
        tc.keyClick(Qt.Key_Return)
        check("Enter accepts", field.acceptedCount === 1)
        tc.keyClick(Qt.Key_Escape)
        check("Escape cancels", field.escapedCount === 1)
        tc.mouseClick(win.stepperRow.children[0])
      },

      // The stepper.
      () => {
        check("the stepper's − steps down", stepper.value === 4, stepper.value)
        tc.mouseWheel(win.stepperRow, win.stepperRow.width / 2, win.stepperRow.height / 2, 0, 120)
        check("a scroll notch steps up", stepper.value === 5, stepper.value)
        tc.mouseWheel(win.stepperRow, win.stepperRow.width / 2, win.stepperRow.height / 2, 0, 40)
        check("a partial notch does nothing yet", stepper.value === 5, stepper.value)
        stepper.value = 1
        stepper.step(-1)
        check("it stops at its minimum", stepper.value === 1, stepper.value)
      },

      // BoundedProcess.
      () => {
        proc.command = ["/bin/sh", "-c", "/usr/bin/head -c 4000000 /dev/zero | /usr/bin/tr '\\\\0' x"]
        proc.outputLimit = 1000
        proc.start()
        check("a second start while one runs is refused", proc.start() === false)
        return { what: "the flood to end", timeout: 5000, until: () => proc.outcomes.length === 1, then: () => {
          check("a flood of output exits normally", proc.outcomes[0] === "exited" && proc.lastCode === 0, proc.outcomes)
          check("and keeps only up to its limit", proc.output.length === 1000 && proc.truncated, proc.output.length)
        } }
      },
      () => {
        proc.command = ["/nonexistent/hyprctl"]
        proc.environment = ({ "ICHI_LOADER_CONTENT": "secret" })
        proc.start()
        return { what: "the failed start", timeout: 2000, until: () => proc.outcomes.length === 2, then: () => {
          check("a missing program reports failed", proc.outcomes[1] === "failed" && proc.lastCode === -1, proc.outcomes)
          check("and its environment is cleared", Object.keys(proc.environment).length === 0)
        } }
      },
      () => {
        proc.command = ["/usr/bin/sleep", "30"]
        proc.deadline = 300
        proc.start()
        return { what: "the deadline", timeout: 3000, until: () => proc.outcomes.length === 3, then: (ms) => {
          check("a program past its deadline is stopped", proc.outcomes[2] === "timedout", proc.outcomes)
          check("at the deadline", ms < 1500, ms + " ms")
        } }
      },
      () => {
        proc.command = ["/bin/sh", "-c", "trap '' TERM; /usr/bin/sleep 30"]
        proc.grace = 400
        proc.start()
        return { what: "the kill", timeout: 4000, until: () => proc.outcomes.length === 4, then: (ms) => {
          check("one that ignores SIGTERM is killed after the grace", proc.outcomes[3] === "timedout", proc.outcomes)
          check("one finished signal per run", proc.outcomes.length === 4, proc.outcomes.length)
        } }
      },

      // Service.qml's queue, against the fake hyprctl.
      () => {
        service.cmdRefresh()
        return { what: "an ok action", timeout: 3000, until: () => service.queue.length === 0 && !service.evaluating, then: () => {
          check("an action hyprctl answers leaves no error", service.lastError === "", service.lastError)
        } }
      },
      () => shell.run("echo stall > '$S/mode'"),
      () => {
        service.cmdRefresh()
        for (var i = 0; i < 40; i++) service.cmdRefresh()
        check("the queue holds at most " + service.queueLimit, service.queue.length === service.queueLimit, service.queue.length)
        check("and says it dropped the rest", service.lastError.indexOf("not keeping up") !== -1, service.lastError)
        // Long enough for the stalled hyprctl to have read its mode, so
        // answering again only reaches the actions behind it.
        return shell.pause(1000)
      },
      () => shell.run("echo ok > '$S/mode'"),
      () => {
        return { what: "the queue to drain", timeout: 9000, until: () => service.queue.length === 0 && !service.evaluating, then: (ms) => {
          check("a stalled action is stopped at its deadline and reported",
            shell.errors.some((e) => e.indexOf("did not answer within 5 seconds") !== -1), shell.errors)
          check("the queue drains once hyprctl answers again", service.lastError === "", service.lastError)
        } }
      },
      () => shell.run("echo flood > '$S/mode'"),
      () => {
        service.cmdRefresh()
        return { what: "the flooded action", timeout: 8000, until: () => service.lastError !== "", then: () => {
          check("a flood of errors is kept to its limit", service.lastError.length <= 2049, service.lastError.length)
        } }
      },
      () => shell.run("/usr/bin/mv '$S/bin/hyprctl' '$S/hyprctl.off'"),
      () => {
        service.cmdRefresh()
        service.cmdRefresh()
        return { what: "the failed start", timeout: 3000, until: () => service.lastError === "could not run hyprctl", then: () => {
          check("a hyprctl that cannot start is reported", true)
          check("and the queue behind it is dropped, not replayed", service.queue.length === 0, service.queue.length)
          check("status shows it", service.cmdStatus().indexOf("Last error") !== -1)
        } }
      },
    ]
    startTimer.start()
  }

  Timer { id: startTimer; interval: 500; onTriggered: shell.next() }
  Timer { interval: 60000; running: true; onTriggered: { console.log("FAIL the suite timed out"); Qt.quit() } }
}
EOF

out=$(env -i HOME="$S" PATH="$S/bin" XDG_CONFIG_HOME="$S/config" XDG_STATE_HOME="$S/state" \
  XDG_RUNTIME_DIR="$S" QT_QPA_PLATFORM=offscreen "$(command -v timeout)" 90 "$(command -v qs)" -p "$S/qs" 2>&1)
results=$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out" | sed -n 's/^.*qml: //p' | grep -E '^(ok|FAIL|done) ')
if [[ -z $results ]]; then
  echo "FAIL the suite did not run:"
  sed 's/\x1b\[[0-9;]*m//g' <<<"$out" | grep -iE 'error|unavailable|not found|warn' | head -20
  exit 1
fi
# The commands Ichi runs, found in its code, and omarchy-shell, which every
# `omarchy-shell ichi ...` command and binding goes through. Ichi passes -u
# to omarchy-notification-send, so check that it still documents it.
for c in omarchy-shell $(code "$ROOT"/*.qml "$ROOT"/ichi.lua | grep -ohE '\bomarchy-[a-z]+(-[a-z]+)+' | sort -u); do
  if [[ -x $OMARCHY/bin/$c ]]; then results+=$'\n'"ok   $c is installed"
  else results+=$'\n'"FAIL $c is installed: not in $OMARCHY/bin"; fi
done
if grep -q -- '-u <low|normal|critical>' "$OMARCHY/bin/omarchy-notification-send" 2>/dev/null; then
  results+=$'\n'"ok   omarchy-notification-send still takes -u"
else
  results+=$'\n'"FAIL omarchy-notification-send still takes -u: its usage no longer lists -u <low|normal|critical>"
fi

# The widget itself, compiled against this Omarchy's qs.Ui. KeyboardPanel
# needs Quickshell.Wayland, which the offscreen platform lacks, so this one
# connects to the running session; it only compiles, and opens no window.
if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
  mkdir -p "$S/compile"
  ln -s "$OMARCHY/shell/Ui" "$S/compile/Ui"
  ln -s "$OMARCHY/shell/Commons" "$S/compile/Commons"
  cat >"$S/compile/shell.qml" <<EOF
import QtQuick
import Quickshell
ShellRoot {
  Timer {
    interval: 200
    running: true
    onTriggered: {
      var widget = Qt.createComponent("file:$ROOT/BarWidget.qml")
      console.log(widget.status === Component.Ready ? "ok   BarWidget.qml compiles" : "FAIL BarWidget.qml compiles: " + widget.errorString())
      Qt.quit()
    }
  }
}
EOF
  compiled=$(QT_QPA_PLATFORM=wayland timeout 20 qs -p "$S/compile" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/^.*qml: //p' | grep -E '^(ok|FAIL) ')
  results+=$'\n'"${compiled:-FAIL BarWidget.qml compiles: no answer from qs}"
else
  echo "note: no Wayland session, so BarWidget.qml was not compiled"
fi

grep -vE '^done ' <<<"$results"
passed=$(grep -c '^ok ' <<<"$results")
failed=$(grep -c '^FAIL ' <<<"$results")
grep -q '^done ' <<<"$results" || { echo "FAIL the suite stopped early"; failed=$((failed + 1)); }
if ((failed > 0)); then
  echo "$failed failed, $passed passed"
  exit 1
fi
echo "$passed passed"
