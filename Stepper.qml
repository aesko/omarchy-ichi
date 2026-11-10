import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A number with − and + beside it, in place of the kit's NumberField. That
// one is an editable native text input, which reads the clipboard on paste;
// this has no text input at all. Scrolling over it steps as well, one step
// per notch, so a trackpad's stream of small deltas does not race ahead.
Column {
  id: root

  property string label: ""
  property int value: 0
  property int from: 0
  property int to: 100
  property int stepSize: 1
  property color foreground: Commons.Color.foreground

  signal modified(int value)

  spacing: Style.spacing.md

  function step(direction) {
    var next = Math.max(root.from, Math.min(root.to, root.value + direction * root.stepSize))
    if (next !== root.value) root.modified(next)
  }

  Text {
    textFormat: Text.PlainText
    visible: root.label !== ""
    text: root.label
    color: Qt.darker(root.foreground, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  Row {
    id: row
    spacing: Style.space(4)

    Button {
      id: less
      text: "−"
      enabled: root.value > root.from
      opacity: enabled ? 1 : 0.4
      tooltipText: root.label === "" ? "" : root.label + " − " + root.stepSize
      foreground: root.foreground
      onClicked: root.step(-1)
    }

    Text {
      textFormat: Text.PlainText
      // As wide as the widest value, so the + does not move as it counts.
      width: Math.ceil(widest.width) + Style.space(12)
      height: less.height
      text: String(root.value)
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body

      TextMetrics {
        id: widest
        text: String(root.to)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    Button {
      text: "+"
      enabled: root.value < root.to
      opacity: enabled ? 1 : 0.4
      tooltipText: root.label === "" ? "" : root.label + " + " + root.stepSize
      foreground: root.foreground
      onClicked: root.step(1)
    }

    WheelHandler {
      property real pending: 0
      target: null
      onWheel: (event) => {
        pending += event.angleDelta.y
        while (pending >= 120) { pending -= 120; root.step(1) }
        while (pending <= -120) { pending += 120; root.step(-1) }
      }
    }
  }
}
