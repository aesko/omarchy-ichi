import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Ichi's bar widget. Left click opens the panel, right click toggles the
// workspace on this widget's own screen, matching what Omarchy's own audio,
// bluetooth and power widgets do with each button.
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
  // The bar is drawn once per monitor, so this copy of the widget is about
  // the workspace on *its* screen. The service's own `status` is about the
  // focused workspace, which is right for the command line and the menu —
  // they are asked from nowhere in particular — but taking it here would make
  // every copy show the focused monitor's workspace and act on it, so the
  // widget on the other screen would describe, and toggle, a workspace nobody
  // is looking at.
  readonly property var barScreen: root.QsWindow.window ? root.QsWindow.window.screen : null
  // Found by walking the monitor list rather than with Hyprland.monitorFor,
  // so the binding depends on the list and re-runs when a display is plugged
  // in or unplugged. monitorFor takes only the screen, and a lookup that
  // answered null once — which it does for a monitor Hyprland has not
  // reported yet — would never be asked again.
  readonly property var barMonitor: {
    if (!barScreen) return null
    var monitors = Hyprland.monitors.values
    for (var i = 0; i < monitors.length; i++) {
      if (monitors[i].name === barScreen.name) return monitors[i]
    }
    return null
  }
  readonly property var barWorkspace: barMonitor ? barMonitor.activeWorkspace : null
  // The config keys workspaces by name, and a numeric workspace is named by
  // its number; a named one has no useful id. The same pick as Service.qml.
  readonly property var screenWorkspaceId: barWorkspace
    ? String(barWorkspace.name !== undefined && barWorkspace.name !== null
      ? barWorkspace.name : barWorkspace.id)
    : null
  readonly property var screenMonitor: barMonitor
    ? ({ name: barMonitor.name, description: barMonitor.description })
    : null
  readonly property var ichiStatus: ichiService && ichiService.config
    ? Model.status(ichiService.config, screenWorkspaceId, screenMonitor, ichiService.stateProblem)
    : null
  readonly property bool ready: !!ichiStatus

  readonly property string workspaceKey: ready && ichiStatus.workspace ? String(ichiStatus.workspace) : ""
  readonly property bool onHere: !!(ready && ichiStatus.enabled)
  readonly property bool paused: !!(ready && ichiStatus.paused)
  // Whether Ichi runs on this widget's own monitor at all. Absent means on,
  // so an older state file and a monitor with no block both read as on.
  readonly property bool monitorOn: !(ready && ichiStatus.monitorEnabled === false)
  // What the bar answers at a glance: is Ichi doing anything here, whichever
  // of the three vetoes is the reason it is not.
  readonly property bool working: onHere && monitorOn && !paused
  readonly property string monitorName: barMonitor && barMonitor.name ? String(barMonitor.name) : ""
  readonly property var entry: ready ? ichiStatus.entry : null
  readonly property var resolved: ready ? ichiStatus.resolved : null
  readonly property string presetName: ready && ichiStatus.preset ? String(ichiStatus.preset) : ""
  readonly property var presetNames: ready && ichiStatus.presets ? ichiStatus.presets : []
  readonly property int minPercent: Model.LIMITS.min
  readonly property string notifyLevel: ready && ichiStatus.settings ? ichiStatus.settings.notify : "changes"
  readonly property int stepPoints: ready && ichiStatus.settings ? ichiStatus.settings.step : 5
  readonly property int fineStepPoints: ready && ichiStatus.settings ? ichiStatus.settings.fine_step : 1

  // Aspect entries have no percentage, so the sliders stand down for them.
  readonly property bool sizeMode: !!(resolved && resolved.mode === "size")
  // Adopt needs a fixed size to copy out; following the defaults or an aspect
  // ratio gives it nothing to do.
  readonly property bool canAdopt: !!(entry && entry.mode === "size")
  readonly property bool aspectMode: !!(resolved && resolved.mode === "aspect")
  readonly property int sizeWidth: sizeMode ? resolved.width : 0
  readonly property int sizeHeight: sizeMode ? resolved.height : 0

  readonly property string glyph: ""
  // Mirrors manifest.json's barWidget.defaults.
  readonly property var settingDefaults: ({ display: "Icon only", showWhenOff: true, clickAction: "Open panel" })
  readonly property string display: setting("display", settingDefaults.display)
  readonly property bool hidden: display === "Hidden"
  readonly property bool showWhenOff: setting("showWhenOff", settingDefaults.showWhenOff) === true
  readonly property string clickAction: setting("clickAction", settingDefaults.clickAction)

  // Hidden is the opt-out for people who want the service without the widget:
  // enabling a bar-widget plugin always places it, so it hides itself instead.
  readonly property bool shown: !hidden && (onHere || showWhenOff)

  readonly property string labelText: label()

  // Naming a preset needs typing, so the size row swaps for a field rather
  // than growing a dialog. Saving needs an entry to copy, so it is only
  // offered where Ichi is actually on.
  property bool naming: false
  readonly property bool canSave: onHere && !!entry

  // The settings page is this card turned over. settingsOpen is the side on
  // screen; pendingSettingsOpen is the side the running flip will land on,
  // since the swap happens edge-on at 90 degrees.
  property bool settingsOpen: false
  property bool pendingSettingsOpen: false

  // Read from `hyprctl binds` when the card is turned over, because bindings
  // live in the user's own config and can change between two openings.
  property var shortcuts: []
  // False until `hyprctl binds` has answered once, so the empty-list message
  // does not flash while the first read is under way, or show for a failure.
  property bool shortcutsLoaded: false

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
    if (!monitorOn || !onHere) return glyph
    if (display === "Icon and preset") return presetName === "" ? glyph : glyph + "  " + presetName
    if (!sizeMode) return glyph + "  " + ichiStatus.summary
    return glyph + "  " + sizeWidth + "×" + sizeHeight
  }

  // Every action on this screen's workspace goes through here, with the
  // command's own arguments first and quiet and the workspace appended. Panel
  // actions pass quiet: the panel shows its own result, and a notification
  // would land on top of the panel that caused it. Until this copy has found
  // its monitor there is no workspace to name, and ichi.lua would read the
  // missing one as the focused workspace, which may be on another screen, so
  // the action is dropped instead.
  function call(name) {
    if (!ichiService || typeof ichiService[name] !== "function") return
    if (root.screenWorkspaceId === null) return
    var args = Array.prototype.slice.call(arguments, 1)
    args.push(true, root.screenWorkspaceId)
    ichiService[name].apply(ichiService, args)
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
    // Dimmed when this workspace is not inset, whichever veto is the reason,
    // so the bar answers "is Ichi doing anything right now" at a glance.
    opacity: root.working ? 1.0 : 0.45
    // Widest veto first, so the tooltip names the one actually in the way.
    tooltipText: root.ready
      ? (root.paused ? "Ichi: paused everywhere"
        : !root.monitorOn ? "Ichi: off on " + (root.monitorName === "" ? "this monitor" : root.monitorName)
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
    }  }

  // ----------------------------------------------------------- the panel --

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.shown
    contentWidth: Style.space(300)
    // Bakes in the panel padding and border, and clamps to the screen. Both
    // sides are measured, since the card shows one or the other.
    contentHeight: panel.fittedContentHeight(root.settingsOpen
      ? settingsPage.implicitHeight
      : content.implicitHeight)

    // Rotating the card turns both pages together, so the settings are the
    // back of this panel rather than a second one.
    Item {
      id: card
      anchors.fill: parent

      transform: Rotation {
        id: cardRotation
        origin.x: card.width / 2
        origin.y: card.height / 2
        axis.x: 0
        axis.y: 1
        axis.z: 0
      }

      SequentialAnimation {
        id: pageFlip

        NumberAnimation { target: cardRotation; property: "angle"; from: 0; to: 90; duration: 130; easing.type: Easing.InQuad }
        // Edge-on, where swapping the pages cannot be seen.
        ScriptAction {
          script: {
            root.settingsOpen = root.pendingSettingsOpen
            cardRotation.angle = -90
            if (root.settingsOpen) settingsFlick.contentY = 0
          }
        }
        NumberAnimation { target: cardRotation; property: "angle"; from: -90; to: 0; duration: 170; easing.type: Easing.OutQuad }
      }

      ColumnLayout {
        id: content
        width: parent.width
        visible: !root.settingsOpen
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

          PanelActionButton {
            iconText: "󰒓"
            tooltipText: "Settings and shortcuts"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: root.showSettings(true)
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
              onClicked: root.call("cmdPreset", modelData)
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
              onClicked: root.call("cmdAspect", modelData[0], modelData[1])
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
            onClicked: root.call("cmdAdopt", "")
          }

          Button {
            text: "Adopt on monitor"
            enabled: root.canAdopt
            opacity: root.canAdopt ? 1 : 0.4
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: root.call("cmdAdopt", "monitor")
          }
        }

        PanelSeparator { Layout.fillWidth: true }

        // The two vetoes wider than a workspace, narrowest first. Both leave
        // every entry written down, so switching either back on restores what
        // was there rather than needing the workspaces turned on again.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: root.monitorName === "" ? "Run on this monitor" : "Run on " + root.monitorName
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          ToggleSwitch {
            checked: root.monitorOn
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onToggled: root.call("cmdMonitorToggle")
          }
        }

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
            // Pause is not about any workspace, so it works before this
            // copy has found its monitor.
            onToggled: if (root.ichiService) root.ichiService.cmdPauseToggle(true)
          }
        }
      }

      // --------------------------------------------------- the other side --

      Flickable {
        id: settingsFlick
        anchors.fill: parent
        visible: root.settingsOpen
        contentWidth: width
        contentHeight: settingsPage.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        // Only when there is something to scroll to: a short list that flicks
        // under the finger reads as the panel coming loose.
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ColumnLayout {
          id: settingsPage
          width: settingsFlick.width
          spacing: Style.space(10)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            PanelActionButton {
              iconText: "󰁍"
              tooltipText: "Back"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              onClicked: root.showSettings(false)
            }

            Text {
              Layout.fillWidth: true
              text: "Ichi"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }
          }

          PanelSectionHeader {
            Layout.fillWidth: true
            text: "Bar widget"
            foreground: root.bar ? root.bar.foreground : Color.foreground
          }

          // The widget's own settings, the same keys Omarchy's bar settings
          // writes. "Hidden" is deliberately not offered: choosing it here
          // would take away the panel that was chosen from, and a widget
          // already hidden cannot open this page to undo it.
          Dropdown {
            Layout.fillWidth: true
            label: "Show in the bar"
            options: ["Icon only", "Icon and size", "Icon and preset"]
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onChanged: function (choice) { root.persistSettings({ display: choice }) }

            // A Binding element rather than an inline one, which Dropdown's
            // imperative write to `value` on selection would destroy.
            Binding on value { value: root.display }
          }

          Dropdown {
            Layout.fillWidth: true
            label: "Left click"
            options: ["Open panel", "Toggle"]
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onChanged: function (choice) { root.persistSettings({ clickAction: choice }) }

            Binding on value { value: root.clickAction }
          }

          PanelSeparator { Layout.fillWidth: true }

          // Ichi's own settings, in ichi.json rather than shell.json: they
          // hold with or without the widget, so they get their own heading.
          PanelSectionHeader {
            Layout.fillWidth: true
            text: "Behaviour"
            foreground: root.bar ? root.bar.foreground : Color.foreground
          }

          // Labels for the stored levels: "changes" reports everything but
          // stepwise resizing, which its own name does not say.
          Dropdown {
            id: notifyDropdown
            readonly property var labels: ({ never: "Never", changes: "All but resizing", always: "All" })
            Layout.fillWidth: true
            label: "Notifications"
            options: [labels.never, labels.changes, labels.always]
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onChanged: function (choice) {
              for (var level in labels) {
                if (labels[level] === choice && root.ichiService) root.ichiService.cmdSet("settings.notify", level, true)
              }
            }

            Binding on value { value: notifyDropdown.labels[root.notifyLevel] || notifyDropdown.labels.changes }
          }

          // The arrow keys' increments, next to the list that shows those keys.
          NumberField {
            label: "Resize step"
            value: root.stepPoints
            from: 1
            to: 25
            stepSize: 1
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onModified: function (v) { if (root.ichiService) root.ichiService.cmdSet("settings.step", v, true) }
          }

          NumberField {
            label: "Fine step"
            value: root.fineStepPoints
            from: 1
            to: 25
            stepSize: 1
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onModified: function (v) { if (root.ichiService) root.ichiService.cmdSet("settings.fine_step", v, true) }
          }

          PanelSeparator { Layout.fillWidth: true }

          PanelSectionHeader {
            Layout.fillWidth: true
            text: "Shortcuts"
            foreground: root.bar ? root.bar.foreground : Color.foreground
          }

          // Whatever the user bound and described as Ichi's. Plugins cannot
          // install bindings, so an empty list is the ordinary state for
          // someone who has not written any yet, not a failure.
          Text {
            Layout.fillWidth: true
            visible: root.shortcutsLoaded && root.shortcuts.length === 0
            text: "No Ichi keybindings yet. Bindings whose description starts with “Ichi:” show up here; the README has a set to paste."
            color: root.bar ? root.bar.foreground : Color.foreground
            opacity: 0.6
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.shortcuts

            RowLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: Style.space(8)

              Text {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                text: modelData.action
                color: root.bar ? root.bar.foreground : Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                // Wrapped rather than elided: with four modifiers spelled out
                // the widest rows leave the action no room, and "resize" cut
                // short of "(fine)" is the wrong half to lose.
                wrapMode: Text.WordWrap
              }

              Text {
                Layout.alignment: Qt.AlignTop
                text: modelData.keys
                color: root.bar ? root.bar.foreground : Color.foreground
                opacity: 0.6
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }

  function isAspect(ratioWidth, ratioHeight) {
    return !!(entry && entry.mode === "aspect"
      && entry.ratio[0] === ratioWidth && entry.ratio[1] === ratioHeight)
  }

  function showSettings(open) {
    var next = open === true
    if (settingsOpen === next || pageFlip.running) return
    pendingSettingsOpen = next
    // Naming would otherwise still be waiting on the face that is turning away.
    if (next) {
      cancelName()
      bindsProcess.running = true
    }
    pageFlip.restart()
  }

  // The widget's settings live on its own entry in shell.json. Written back
  // whole, since that is what updateEntryInline does, and merged from the
  // entry as it stands so keys left at their manifest default stay absent
  // rather than being frozen at today's value.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    // Only keys the widget still has, so a stored key no setting reads any more
    // is not copied forward on every save.
    for (var existing in root.settingDefaults) if (root.settings[existing] !== undefined) entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    // Omarchy stores whatever it is handed, so a key at its default is left
    // out here; an entry stays bare until a setting really differs.
    for (var name in root.settingDefaults) if (entry[name] === root.settingDefaults[name]) delete entry[name]

    // Applied locally first so the control moves under the click; the shell's
    // write comes back through the bar as the same value.
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // The plain text, not `hyprctl binds -j`: Hyprland 0.56.0 emits invalid JSON
  // for binds, which is why Omarchy's own keybindings menu parses this too.
  Process {
    id: bindsProcess
    command: ["hyprctl", "binds"]
    stdout: StdioCollector {
      onStreamFinished: {
        // Hyprland always reports some binds; empty output means the call
        // failed, which is not the same as having none of Ichi's.
        if (String(text || "").trim() === "") return
        root.shortcuts = Model.ichiBinds(text)
        root.shortcutsLoaded = true
      }
    }
  }

  onOpenedChanged: {
    if (opened) return
    // A card left mid-flip would reopen edge-on, and the settings page is
    // never where someone expects to find the panel they just opened.
    pageFlip.stop()
    cardRotation.angle = 0
    settingsOpen = false
    pendingSettingsOpen = false
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
    if (name !== "") call("cmdSavePreset", name)
  }

  function applySizeOf(w, h) {
    call("cmdSize", w, h)
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
