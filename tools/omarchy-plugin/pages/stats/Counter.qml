import QtQuick
import "../../design"
import "StatsFormat.js" as F

// The hero card: all-time words as a flip counter (one cell per digit with a seam through the middle), TODAY, THIS WEEK and
// TAKES under it, and the hours saved on the right. The start date is the hover help on the counter block, not a subline.
StatsCard {
  id: card

  property var stats: ({})
  readonly property var words: stats.words || ({})
  readonly property var saved: stats.time_saved || ({})
  readonly property string countText: F.number(words.all_time || 0)
  readonly property real innerWidth: width - 2 * padSide
  readonly property real savedMax: 320
  readonly property bool wide: innerWidth - counterBlock.implicitWidth - 24 >= 200

  padTop: 18
  padBottom: 18
  contentHeight: wide ? Math.max(counterBlock.implicitHeight, savedBlock.implicitHeight) : counterBlock.implicitHeight + 16 + savedBlock.implicitHeight
  tip: stats.first_day ? "Since " + F.shortDay(stats.first_day) : ""

  Column {
    id: counterBlock
    spacing: 8

    DesignEyebrow { text: "Words, all time" }

    Row {
      id: cells
      spacing: 4
      Accessible.role: Accessible.StaticText
      Accessible.name: card.countText + " words"

      Repeater {
        model: card.countText.split("")
        delegate: Item {
          required property string modelData
          readonly property bool digit: modelData >= "0" && modelData <= "9"
          width: digit ? 36 : 14
          height: 48

          Rectangle {
            visible: parent.digit
            anchors.fill: parent
            radius: 6
            color: Theme.bg
            border.width: 1
            border.color: Theme.hair2

            Rectangle {
              x: 1
              y: parent.height / 2
              width: parent.width - 2
              height: 1
              color: Theme.hair
            }
            Text {
              anchors.centerIn: parent
              text: parent.parent.modelData
              color: Theme.ink
              font: Type.mono(30)
            }
          }
          Text {
            visible: !parent.digit
            anchors.horizontalCenter: parent.horizontalCenter
            y: 18
            text: parent.modelData
            color: Theme.ink3
            font: Type.mono(24)
          }
        }
      }
    }

    Row {
      spacing: 28
      topPadding: 2

      Repeater {
        model: [
          { label: "Today", value: words.today || 0 },
          { label: "This week", value: words.week || 0 },
          { label: "Takes", value: stats.takes || 0 }
        ]
        delegate: Column {
          required property var modelData
          spacing: 3
          MonoLine { label: parent.modelData.label }
          Text {
            text: F.number(parent.modelData.value)
            color: Theme.ink
            font: Type.sans(14, "medium")
          }
        }
      }
    }
  }

  Column {
    id: savedBlock
    spacing: 4
    width: card.wide ? Math.min(card.savedMax, card.innerWidth - counterBlock.implicitWidth - 24) : card.innerWidth
    x: card.wide ? card.innerWidth - width : 0
    y: card.wide ? 0 : counterBlock.implicitHeight + 16

    Text {
      width: parent.width
      text: F.savedHeadline(saved.minutes)
      wrapMode: Text.Wrap
      horizontalAlignment: card.wide ? Text.AlignRight : Text.AlignLeft
      color: Theme.ink
      font: Type.serif(Type.display)
    }
    MonoLine {
      width: parent.width
      horizontalAlignment: card.wide ? Text.AlignRight : Text.AlignLeft
      label: F.talkingMinutes(saved.speaking_minutes) + " talking"
    }
  }
}
