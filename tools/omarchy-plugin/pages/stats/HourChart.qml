import QtQuick
import "../../design"
import "StatsFormat.js" as F

// Your day: a serif headline naming the peak hour, a one line caption, and 24 hour bars that stretch to whatever height the
// card has left so it matches the card beside it. The peak hour is lime, other hours neutral, empty hours a 2 px track.
StatsCard {
  id: card

  property var hourly: []
  property var peakHour: null
  property int windowDays: 30
  readonly property int total: {
    var sum = 0
    for (var i = 0; i < hourly.length; i++) sum += hourly[i]
    return sum
  }
  readonly property real maxWords: {
    var most = 1
    for (var i = 0; i < hourly.length; i++) most = Math.max(most, hourly[i])
    return most
  }
  readonly property string headline: peakHour === null || peakHour === undefined ? "No pattern yet." : "A " + F.hourName(peakHour) + " talker."
  readonly property string detail: peakHour === null || peakHour === undefined || total <= 0 ? "" :
    Math.round(hourly[peakHour] / total * 100) + "% of your words."
  readonly property real minChart: 64
  readonly property real textHeight: textBlock.implicitHeight

  contentHeight: textHeight + 14 + minChart + 4 + axisRow.height

  Column {
    id: textBlock
    width: parent.width
    spacing: 6

    DesignEyebrow { width: parent.width; text: "Your day · last " + card.windowDays + " days" }
    Text {
      width: parent.width
      text: card.headline
      wrapMode: Text.Wrap
      color: Theme.ink
      font: Type.serif(30)
    }
    Text {
      visible: card.detail !== ""
      width: parent.width
      text: card.detail
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.detail)
    }
  }

  Item {
    id: chart
    y: card.textHeight + 14
    width: parent.width
    height: Math.max(card.minChart, parent.height - card.textHeight - 14 - 4 - axisRow.height)
    Accessible.role: Accessible.StaticText
    Accessible.name: card.peakHour === null || card.peakHour === undefined ?
      "Words by hour of day over the last " + card.windowDays + " days, no takes" :
      "Words by hour of day over the last " + card.windowDays + " days, peaking at " + F.hourName(card.peakHour)

    Repeater {
      model: 24
      delegate: Rectangle {
        required property int index
        readonly property int words: index < card.hourly.length ? card.hourly[index] : 0
        x: index * (chart.width - 5) / 23
        width: 5
        height: words === 0 ? 2 : Math.max(3, chart.height * words / card.maxWords)
        y: chart.height - height
        radius: words === 0 ? 0 : 2
        color: words === 0 ? Theme.track : (index === card.peakHour ? Theme.accent : Theme.neutralMark)
      }
    }
  }

  Item {
    id: axisRow
    y: parent.height - height
    width: parent.width
    height: left.height

    AxisLabel { id: left; text: "12 AM" }
    AxisLabel { anchors.horizontalCenter: parent.horizontalCenter; text: "NOON" }
    AxisLabel { anchors.right: parent.right; text: "11 PM" }
  }
}
