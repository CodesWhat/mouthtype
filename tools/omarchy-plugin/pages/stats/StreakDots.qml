import QtQuick
import "../../design"
import "StatsFormat.js" as F

// Streak: the current run with a flame, the longest run, and one dot per day for the last 30. Lit dots are the first ink,
// days with words are neutral, empty days are the track. Today is outlined only while it has no take yet. No ring, no caption.
StatsCard {
  id: card

  property var daily: []
  property var lit: []
  property var streak: ({})
  readonly property int current: streak.current || 0
  readonly property int longest: streak.longest || 0
  readonly property int count: daily.length
  readonly property real dot: Math.max(4, Math.min(18, (col.width - 2 * (count - 1)) / Math.max(1, count)))
  readonly property bool todayEmpty: count > 0 && daily[count - 1].words === 0

  tip: "A day counts with one take, and today carries until midnight."
  contentHeight: col.implicitHeight

  function dotColor(index) {
    if (lit[index] === true) return Theme.ink
    return daily[index].words > 0 ? Theme.neutralMark : Theme.track
  }

  Column {
    id: col
    width: parent.width
    spacing: 12

    DesignEyebrow { width: parent.width; text: "Streak · last " + (card.count || 30) + " days" }

    Item {
      width: parent.width
      height: Math.max(figure.height, longestLine.height)

      Row {
        id: figure
        spacing: 6
        Icon { name: "flame"; size: 20; color: Theme.orange; anchors.verticalCenter: parent.verticalCenter }
        Text {
          id: streakNumber
          text: String(card.current)
          color: Theme.ink
          font: Type.sans(34, "semibold")
        }
        MonoLine {
          y: streakNumber.height - height - 8
          leftPadding: 2
          label: card.current === 1 ? "day" : "days"
        }
      }
      MonoLine {
        id: longestLine
        anchors.right: parent.right
        y: figure.height - height - 8
        text: "<font color='" + Theme.ink3 + "'>LONGEST</font> <font color='" + Theme.ink + "'>" + card.longest + "</font>"
      }
    }

    Row {
      id: dots
      spacing: 2
      Accessible.role: Accessible.StaticText
      Accessible.name: card.count + " dots, one per day"

      Repeater {
        model: card.count
        delegate: Rectangle {
          required property int index
          readonly property bool today: index === card.count - 1 && card.todayEmpty
          width: card.dot
          height: card.dot
          radius: card.dot / 2
          color: today ? Theme.surface : card.dotColor(index)
          border.width: today ? 1.5 : 0
          border.color: Theme.ink3
        }
      }
    }
  }
}
