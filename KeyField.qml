import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The preset-name field, drawn from plain Text and key events in place of the
// kit's TextField. A native text input reads the clipboard when asked to
// paste, and Qt's Wayland transfer has no size cap or overall deadline, all
// inside the shell every bar widget shares. This one has no paste path to
// bound: typing appends, Backspace removes the last character, Enter accepts,
// Escape cancels, and nothing else changes it. No paste, no selection, no
// middle-click and no input method. Any name, pasted or composed, can still be
// saved from the command line: `omarchy-shell ichi save_preset "<name>"`.
Item {
  id: root

  property string text: ""
  property string placeholderText: ""
  property int maximumLength: Model.PRESET_NAME
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent

  signal accepted()
  signal escaped()

  activeFocusOnTab: true
  implicitWidth: Style.space(200)
  implicitHeight: Math.ceil(shown.implicitHeight) + 2 * Style.spacing.inputPaddingY
    + Border.top(_borderSpec) + Border.bottom(_borderSpec)

  readonly property var _borderSpec: Border.controlSpec(
    root.activeFocus ? "focus" : (hover.hovered ? "hover-cursor" : "normal"), root.foreground, root.accent)
  readonly property real _padLeft: Style.spacing.controlPaddingX + Border.left(_borderSpec)
  readonly property real _padRight: Style.spacing.controlPaddingX + Border.right(_borderSpec)
  property bool _caretOn: true

  BorderSurface {
    anchors.fill: parent
    color: Style.controlFill(root.activeFocus, hover.hovered, root.foreground, root.accent)
    borderSpec: root._borderSpec
    radius: Style.cornerRadius
  }

  HoverHandler {
    id: hover
    cursorShape: Qt.IBeamCursor
  }

  // Left button only: a middle click, which pastes the primary selection in a
  // native input, does nothing here.
  TapHandler {
    acceptedButtons: Qt.LeftButton
    onTapped: root.forceActiveFocus()
  }

  Text {
    textFormat: Text.PlainText
    id: shown
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: root._padLeft
    anchors.rightMargin: root._padRight
    anchors.verticalCenter: parent.verticalCenter
    text: root.text === "" ? root.placeholderText : root.text
    color: root.text === "" ? Qt.darker(root.foreground, 1.6) : root.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    // The end is where typing happens, so a name too long to fit loses its
    // start rather than the characters going in.
    elide: root.text === "" ? Text.ElideRight : Text.ElideLeft
  }

  Rectangle {
    visible: root.activeFocus && root._caretOn
    x: root._padLeft + (root.text === "" ? 0 : Math.min(shown.contentWidth, shown.width))
    anchors.verticalCenter: parent.verticalCenter
    width: 1
    height: Style.font.body
    color: root.foreground
  }

  Timer {
    interval: 530
    repeat: true
    running: root.activeFocus
    onRunningChanged: root._caretOn = true
    onTriggered: root._caretOn = !root._caretOn
  }

  Keys.onPressed: (event) => {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      event.accepted = true
      root.accepted()
      return
    }
    if (event.key === Qt.Key_Escape) {
      event.accepted = true
      root.escaped()
      return
    }
    // A Ctrl, Alt or Super chord is a shortcut, not text. Ctrl+V is one of
    // them, and here it does nothing; so does Shift+Insert, which types no
    // text either.
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
    var backspace = event.key === Qt.Key_Backspace
    var next = Model.nameAfterKey(root.text, event.text, backspace, root.maximumLength)
    if (next !== null) {
      root.text = next
      root._caretOn = true
    }
    if (next !== null || backspace) event.accepted = true
  }
}
