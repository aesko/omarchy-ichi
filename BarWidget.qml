import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Ichi's bar widget. Left click opens the panel, right click toggles the
// focused workspace, matching what Omarchy's own audio, bluetooth and power
// widgets do with each button.
//
// State comes straight off the plugin's own service rather than a second
// FileView, and actions call the same cmd* functions the two IPC targets
// forward to, so the bar, the command line and the menu can never disagree.
Panel {
  id: root
  moduleName: "io.github.aesko.ichi"
  // A route of its own so the panel can be opened from a keybinding or the
  // menu. It cannot be the plugin id, which the service already answers on.
  ipcTarget: "ichi.panel"

  readonly property var ichiService: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("io.github.aesko.ichi")
    : null
  readonly property var ichiStatus: ichiService ? ichiService.status : null
  readonly property bool ready: !!ichiStatus

  readonly property string workspaceKey: ready && ichiStatus.workspace ? String(ichiStatus.workspace) : ""
  readonly property bool onHere: !!(ready && ichiStatus.enabled)
  readonly property bool paused: !!(ready && ichiStatus.paused)
  readonly property var entry: ready ? ichiStatus.entry : null
  readonly property var resolved: ready ? ichiStatus.resolved : null
  readonly property string presetName: ready && ichiStatus.preset ? String(ichiStatus.preset) : ""
  readonly property var presetNames: ready && ichiStatus.presets ? ichiStatus.presets : []
  readonly property int minPercent: ready && ichiStatus.settings ? ichiStatus.settings.min_percent : 20

  // Aspect entries have no percentage, so the sliders stand down for them.
  readonly property bool sizeMode: !!(resolved && resolved.mode === "size")
  // Adopt needs a fixed size to copy out; following the defaults or an aspect
  // ratio gives it nothing to do.
  readonly property bool canAdopt: !!(entry && entry.mode === "size")
  readonly property bool aspectMode: !!(resolved && resolved.mode === "aspect")
  readonly property int sizeWidth: sizeMode ? resolved.width : 0
  readonly property int sizeHeight: sizeMode ? resolved.height : 0

  readonly property string glyph: ""
  readonly property string display: setting("display", "Icon only")
  readonly property bool hidden: display === "Hidden"
  readonly property bool showWhenOff: setting("showWhenOff", true) === true
  readonly property string scrollAction: setting("scrollAction", "Off")
  readonly property string clickAction: setting("clickAction", "Open panel")

  // Hidden is the opt-out for people who want the service without the widget:
  // enabling a bar-widget plugin always places it, so it hides itself instead.
  readonly property bool shown: !hidden && (onHere || showWhenOff)

  readonly property string labelText: label()

  // Naming a preset needs typing, so the size row swaps for a field rather
  // than growing a dialog. Saving needs an entry to copy, so it is only
  // offered where Ichi is actually on.
  property bool naming: false
  readonly property bool canSave: onHere && !!entry

  // The ratios offered as chips: the shapes a window is usually wanted in.
  // Any other ratio is still reachable from the command line, which is where
  // an unusual one belongs rather than in a row that has to stay scannable.
  readonly property var aspectRatios: [[16, 9], [16, 10], [3, 2], [4, 3], [1, 1]]

  implicitWidth: shown ? button.implicitWidth : 0
  implicitHeight: shown ? button.implicitHeight : 0
  visible: shown

  function label() {
    if (!ready || display === "Icon only") return glyph
    if (paused) return glyph + "  paused"
    if (!onHere) return glyph
    if (display === "Icon and preset") return presetName === "" ? glyph : glyph + "  " + presetName
    if (!sizeMode) return glyph + "  " + ichiStatus.summary
    return glyph + "  " + sizeWidth + "×" + sizeHeight
  }

  // Panel actions pass quiet: the panel shows its own result, and a
  // notification would land on top of the panel that caused it.
  function call(name) {
    if (ichiService && typeof ichiService[name] === "function") ichiService[name](true)
  }

  function onScroll(delta) {
    if (!ichiService) return
    var direction = delta > 0 ? 1 : -1
    if (scrollAction === "Resize width") ichiService.cmdNudge(direction, 0, false, true)
    else if (scrollAction === "Resize height") ichiService.cmdNudge(0, direction, false, true)
    else if (scrollAction === "Cycle presets") ichiService.cmdCycle(direction, true)
  }

  // ------------------------------------------------------------- the bar --

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.labelText
    // A slot sized for one glyph clips the size or preset name and collides
    // with the next widget. Widen it by roughly what the extra characters
    // paint, the way the power widget doubles its slot for a percentage.
    slotSize: root.vertical || root.display === "Icon only"
      ? Style.bar.iconSlot
      : Style.bar.iconSlot + Math.ceil(Style.font.body * 0.62 * Math.max(0, root.labelText.length - 1))
    // Dimmed when this workspace is not inset, or while everything is paused,
    // so the bar answers "is Ichi doing anything right now" at a glance.
    opacity: root.onHere && !root.paused ? 1.0 : 0.45
    tooltipText: root.ready
      ? (root.paused ? "Ichi: paused everywhere"
        : root.onHere ? "Ichi: " + root.ichiStatus.summary
        : "Ichi: off on this workspace")
      : "Ichi"
    onPressed: function (b) {
      if (b === Qt.RightButton) {
        if (root.clickAction === "Toggle") root.toggle()
        else root.call("cmdToggle")
      } else {
        if (root.clickAction === "Toggle") root.call("cmdToggle")
        else root.toggle()
      }
    }

    WheelHandler {
      enabled: root.scrollAction !== "Off"
      onWheel: function (event) { root.onScroll(event.angleDelta.y) }
    }
  }

  // ----------------------------------------------------------- the panel --

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.shown
    contentWidth: Style.space(300)
    // Bakes in the panel padding and border, and clamps to the screen.
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    ColumnLayout {
      id: content
      width: parent.width
      spacing: Style.space(10)

      // Which workspace this is about, and whether it is inset.
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          Layout.fillWidth: true
          text: root.workspaceKey === "" ? "Ichi" : "Workspace " + root.workspaceKey
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        ToggleSwitch {
          checked: root.onHere
          foreground: root.bar ? root.bar.foreground : Color.foreground
          onToggled: root.call("cmdToggle")
        }
      }

      Text {
        Layout.fillWidth: true
        text: root.ready ? root.ichiStatus.summary : ""
        color: root.bar ? root.bar.foreground : Color.foreground
        opacity: 0.6
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      PanelSeparator { Layout.fillWidth: true }

      // Which size this workspace is on. Following the defaults is the first
      // choice rather than a separate reset button, because it belongs on the
      // same axis as the presets: they all answer "what size is this".
      // Naming replaces the row rather than sitting beside it, so the panel
      // does not jump in height.
      TextField {
        id: nameField
        Layout.fillWidth: true
        visible: root.naming
        placeholderText: "name this size, Enter to save"
        foreground: root.bar ? root.bar.foreground : Color.foreground
        onAccepted: root.commitName()
        Keys.onEscapePressed: root.cancelName()
        // Typing over an existing name updates that preset, which is what
        // save_preset already does; nothing extra is needed here.
        onActiveFocusChanged: if (!activeFocus && root.naming) root.cancelName()
      }

      Flow {
        Layout.fillWidth: true
        Layout.preferredHeight: implicitHeight
        spacing: Style.space(6)
        visible: !root.naming

        Button {
          // Lower case to sit level with the preset names beside it, which
          // are user data and are never transformed for display.
          text: "default"
          selected: !!(root.entry && root.entry.mode === "default")
          foreground: root.bar ? root.bar.foreground : Color.foreground
          onClicked: root.call("cmdUseDefaults")
        }

        Repeater {
          model: root.presetNames

          Button {
            required property string modelData
            text: modelData
            selected: modelData === root.presetName
            tooltipText: "Right click to remove"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: if (root.ichiService) root.ichiService.cmdPreset(modelData, true)
            onRightClicked: if (root.ichiService) root.ichiService.cmdRemovePreset(modelData, true)
          }
        }

        Button {
          text: "+"
          enabled: root.canSave
          opacity: root.canSave ? 1 : 0.4
          tooltipText: root.canSave
            ? "Save this size as a preset"
            : "Turn Ichi on here to save a preset"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          onClicked: root.startName()
        }
      }

      // The other way to say what shape this workspace is. A selected chip
      // here is why the sliders below are absent, which is what the line of
      // explanation that used to sit here had to say in words.
      Flow {
        Layout.fillWidth: true
        Layout.preferredHeight: implicitHeight
        spacing: Style.space(6)
        visible: !root.naming

        Repeater {
          model: root.aspectRatios

          Button {
            required property var modelData
            text: modelData[0] + ":" + modelData[1]
            selected: root.isAspect(modelData[0], modelData[1])
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: if (root.ichiService) root.ichiService.cmdAspect(modelData[0], modelData[1], true)
          }
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)
        visible: root.sizeMode

        NumberField {
          label: "Width"
          value: Math.round(widthSlider.liveValue)
          from: root.minPercent
          to: 100
          stepSize: 1
          foreground: root.bar ? root.bar.foreground : Color.foreground
          onModified: function (v) { root.applySizeOf(v, Math.round(heightSlider.liveValue)) }
        }

        PanelSlider {
          id: widthSlider
          Layout.fillWidth: true
          bar: root.bar
          minimum: root.minPercent
          maximum: 100
          step: 1
          integer: true
          value: root.sizeWidth
          onMoved: root.throttledApply()
          onReleased: { sizeCommit.stop(); root.applySize() }
        }

        NumberField {
          label: "Height"
          value: Math.round(heightSlider.liveValue)
          from: root.minPercent
          to: 100
          stepSize: 1
          foreground: root.bar ? root.bar.foreground : Color.foreground
          onModified: function (v) { root.applySizeOf(Math.round(widthSlider.liveValue), v) }
        }

        PanelSlider {
          id: heightSlider
          Layout.fillWidth: true
          bar: root.bar
          minimum: root.minPercent
          maximum: 100
          step: 1
          integer: true
          value: root.sizeHeight
          onMoved: root.throttledApply()
          onReleased: { sizeCommit.stop(); root.applySize() }
        }
      }

      Flow {
        Layout.fillWidth: true
        Layout.preferredHeight: implicitHeight
        spacing: Style.space(6)

        Button {
          text: "Adopt as default"
          // Adopt copies a fixed size out of a workspace, so there has to be
          // one. Greyed rather than refusing, now that the panel is silent.
          enabled: root.canAdopt
          opacity: root.canAdopt ? 1 : 0.4
          foreground: root.bar ? root.bar.foreground : Color.foreground
          onClicked: if (root.ichiService) root.ichiService.cmdAdopt("", true)
        }

        Button {
          text: "Adopt on monitor"
          enabled: root.canAdopt
          opacity: root.canAdopt ? 1 : 0.4
          foreground: root.bar ? root.bar.foreground : Color.foreground
          onClicked: if (root.ichiService) root.ichiService.cmdAdopt("monitor", true)
        }
      }

      PanelSeparator { Layout.fillWidth: true }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          Layout.fillWidth: true
          text: "Pause everywhere"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        ToggleSwitch {
          checked: root.paused
          foreground: root.bar ? root.bar.foreground : Color.foreground
          onToggled: root.call("cmdPauseToggle")
        }
      }
    }
  }

  function isAspect(ratioWidth, ratioHeight) {
    return !!(entry && entry.mode === "aspect"
      && entry.ratio[0] === ratioWidth && entry.ratio[1] === ratioHeight)
  }

  function startName() {
    if (!canSave) return
    nameField.text = ""
    naming = true
    nameField.forceActiveFocus()
  }

  function cancelName() {
    naming = false
  }

  function commitName() {
    var name = nameField.text.trim()
    naming = false
    if (name !== "" && ichiService) ichiService.cmdSavePreset(name, true)
  }

  function applySizeOf(w, h) {
    if (ichiService) ichiService.cmdSize(w, h, true)
  }

  function applySize() {
    applySizeOf(Math.round(widthSlider.liveValue), Math.round(heightSlider.liveValue))
  }

  // A drag would otherwise write the state file on every pixel, and each write
  // round-trips back through the shell. This rate-limits to one write per
  // interval while the drag continues. Restarting the timer on each move
  // instead would debounce, not throttle: the moves arrive faster than the
  // interval, so it would never fire and the window would sit still until
  // you let go.
  function throttledApply() {
    if (!sizeCommit.running) sizeCommit.start()
  }

  Timer {
    id: sizeCommit
    interval: 150
    repeat: false
    onTriggered: root.applySize()
  }
}
