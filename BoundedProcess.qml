import QtQuick
import Quickshell.Io

// Every program Ichi runs goes through this: a Process with an absolute
// deadline, a cap on what it keeps of each output stream, and one `finished`
// signal however the run ends. All of them run inside the shared shell, so one
// that stalls, or writes without end, must not be able to hold it up.
//
// `finished(outcome, exitCode)` fires exactly once per start():
//   "exited"   the program ran and exited; exitCode is its status
//   "failed"   it never started, e.g. the binary is missing or the
//              environment is too large for exec
//   "timedout" it was still running at the deadline and was stopped: SIGTERM,
//              then SIGKILL after `grace` if it is still there
//
// Output is read as it arrives (a SplitParser with no marker, so nothing is
// buffered waiting for a newline) and kept up to the limit, in characters;
// the rest is read and dropped so the program never blocks on a full pipe.
// `truncated` says whether anything was dropped.
Item {
  id: root

  property var command: []
  // Passed to the program for this one run and cleared when it ends, however
  // it ends: the loader hands the user's whole hyprland.lua over this way.
  property var environment: ({})
  property int deadline: 5000
  property int grace: 1000
  // 0 keeps nothing.
  property int outputLimit: 0
  property int errorLimit: 4096

  // True from start() until finished has been emitted, so a handler of
  // finished can start the next run at once. It is not derived from the
  // Process's own running, which reads stale while Quickshell is still
  // emitting its change.
  readonly property bool busy: pending
  property string output: ""
  property string errorOutput: ""
  property bool truncated: false

  signal finished(string outcome, int exitCode)

  property bool pending: false
  property bool settling: false
  property bool started: false
  property bool timedOut: false
  property int exitCode: -1
  property string outcome: ""

  // Returns false, and runs nothing, while a run is still in progress.
  function start() {
    if (busy) return false
    output = ""
    errorOutput = ""
    truncated = false
    started = false
    timedOut = false
    exitCode = -1
    pending = true
    process.environment = root.environment
    process.command = root.command
    deadlineTimer.restart()
    process.running = true
    // A failed start can report before running ever reads true, in which
    // case runningChanged has already been and gone.
    if (!process.running) Qt.callLater(root.settle)
    return true
  }

  function keep(current, data, limit) {
    if (current.length >= limit) {
      if (data.length > 0) root.truncated = true
      return current
    }
    var room = limit - current.length
    if (data.length > room) root.truncated = true
    return current + data.slice(0, room)
  }

  // Called once the Process has stopped running. finished goes out on the
  // next turn of the event loop rather than from inside Quickshell's own
  // runningChanged, so a handler that starts the next run is not re-entering
  // the Process while it is still being torn down.
  function settle() {
    if (!pending || settling || process.running) return
    settling = true
    deadlineTimer.stop()
    killTimer.stop()
    process.environment = ({})
    root.environment = ({})
    outcome = timedOut ? "timedout" : started ? "exited" : "failed"
    Qt.callLater(root.report)
  }

  function report() {
    var how = outcome
    var code = how === "exited" ? exitCode : -1
    settling = false
    pending = false
    root.finished(how, code)
  }

  Process {
    id: process
    stdout: SplitParser {
      splitMarker: ""
      onRead: (data) => { if (root.outputLimit > 0) root.output = root.keep(root.output, data, root.outputLimit) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: (data) => { if (root.errorLimit > 0) root.errorOutput = root.keep(root.errorOutput, data, root.errorLimit) }
    }
    onStarted: root.started = true
    // Quickshell emits exited before running turns false, and a program that
    // never started emits neither started nor exited, only running false.
    onExited: (code) => root.exitCode = code
    onRunningChanged: if (!running) root.settle()
  }

  Timer {
    id: deadlineTimer
    interval: root.deadline
    onTriggered: {
      if (!process.running) return
      root.timedOut = true
      process.signal(15)
      killTimer.restart()
    }
  }

  Timer {
    id: killTimer
    interval: root.grace
    onTriggered: if (process.running) process.signal(9)
  }
}
