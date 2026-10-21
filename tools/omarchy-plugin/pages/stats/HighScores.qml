import QtQuick
import "../../design"
import "StatsFormat.js" as F

// High scores: fastest speaking, biggest day, longest streak and longest take, each with the date it was set. The medal dots use
// the gold, silver and bronze roles (the fourth has none), and a record set today carries the personal best chip.
StatsCard {
  id: card

  property var scores: ({})
  property string today: ""

  padTop: 14
  padBottom: 12
  contentHeight: col.implicitHeight

  readonly property var rows: {
    var s = scores || ({})
    var fastest = s.fastest, day = s.biggest_day, run = s.longest_streak, take = s.longest_take
    return [
      { number: "01", title: "Fastest speaking", medal: Theme.gold,
        value: fastest ? Math.round(fastest.value) + " WPM" : "", day: fastest ? fastest.date : "", extra: "" },
      { number: "02", title: "Biggest day", medal: Theme.silver,
        value: day ? F.number(day.value) : "", day: day ? day.date : "", extra: "" },
      { number: "03", title: "Longest streak", medal: Theme.bronze,
        value: run ? F.days(run.value).toUpperCase() : "", day: run ? run.date : "", extra: "" },
      { number: "04", title: "Longest take", medal: "transparent",
        value: take ? F.number(take.value) : "", day: take ? take.date : "", extra: take ? F.speaking(take.duration_ms) : "" }
    ]
  }

  Column {
    id: col
    width: parent.width
    spacing: 4

    DesignEyebrow { width: parent.width; text: "High scores"; bottomPadding: 4 }

    Repeater {
      model: card.rows
      delegate: Column {
        id: row
        required property var modelData
        readonly property string detail: [modelData.day ? F.recordDate(modelData.day, card.today) : "", modelData.extra].filter(function(p) { return p !== "" }).join(F.dot)
        readonly property bool fresh: modelData.day !== "" && modelData.day === card.today
        width: col.width
        spacing: 0
        Accessible.role: Accessible.StaticText
        Accessible.name: modelData.title + ": " + (modelData.value || "none yet") + (detail ? ", " + detail : "")

        Rectangle { width: parent.width; height: 1; color: Theme.hair2 }

        Item {
          id: cell
          // On a narrow card the value, chip and date drop under the title instead of colliding with it.
          readonly property bool stacked: line.width + 12 + valueRow.width > width
          width: parent.width
          height: (stacked ? line.height + 2 + valueRow.height : Math.max(line.height, valueRow.height)) + 10

          Row {
            id: line
            y: 5
            spacing: 10
            Text {
              width: 18
              text: row.modelData.number
              color: Theme.ink3
              font: Type.mono(Type.eyebrowSize)
            }
            Rectangle {
              y: 3
              width: 10
              height: 10
              radius: 5
              color: row.modelData.medal
              border.width: row.modelData.number === "04" ? 1 : 0
              border.color: Theme.hair
            }
            Text {
              text: row.modelData.title
              color: Theme.ink
              font: Type.sans(12.5)
            }
          }

          Row {
            id: valueRow
            y: cell.stacked ? 5 + line.height + 2 : 5
            anchors.right: parent.right
            spacing: 8
            Rectangle {
              visible: row.fresh
              y: 2
              width: chip.width + 12
              height: chip.height + 4
              radius: 4
              color: Theme.personalBest
              Text {
                id: chip
                anchors.centerIn: parent
                text: "Personal best"
                color: Theme.personalBestInk
                font: Type.eyebrow
              }
            }
            Text {
              text: row.modelData.value || "None yet"
              color: row.modelData.value ? Theme.ink : Theme.ink3
              font: Type.mono(13)
            }
            Text {
              visible: row.detail !== ""
              y: 2
              text: row.detail
              color: Theme.ink3
              font: Type.sans(11)
            }
          }
        }
      }
    }
  }
}
