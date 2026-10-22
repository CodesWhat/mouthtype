import QtQuick
import "../../design"
import "StatsFormat.js" as F

// Speaking speed: the average as a big number, and a 25 segment meter over 0 to 250 wpm. Lit segments are neutral, the average
// marker is lime, the peak is the first ink, and a typist at 40 wpm is outlined. The caption is only "N× a typist."
StatsCard {
  id: card

  readonly property int segments: 25
  readonly property real maxWpm: 250

  property var speed: ({})
  readonly property var average: speed.average_wpm === undefined ? null : speed.average_wpm
  readonly property var peak: speed.peak_wpm === undefined ? null : speed.peak_wpm
  readonly property real typing: speed.typing_wpm || 40
  readonly property int averageSegment: F.meterSegment(average, segments, maxWpm)
  readonly property int peakSegment: F.meterSegment(peak, segments, maxWpm)
  readonly property int typistSegment: F.meterSegment(typing, segments, maxWpm)
  readonly property string caption: F.typistRatio(average, typing)

  tip: "Words over speaking time, from takes of at least " + (speed.minimum_words || 5) + " words and " +
       Math.round((speed.minimum_milliseconds || 3000) / 1000) + " seconds."
  contentHeight: col.implicitHeight

  function fill(index) {
    if (index === peakSegment) return Theme.ink
    if (index === averageSegment) return Theme.accent
    if (averageSegment >= 0 && index < averageSegment) return Theme.neutralMark
    return Theme.track
  }

  Column {
    id: col
    width: parent.width
    spacing: 12

    DesignEyebrow { width: parent.width; text: "Speaking speed" }

    Row {
      width: parent.width
      spacing: 16

      Row {
        id: figure
        spacing: 5
        Text {
          id: bigNumber
          text: card.average === null ? "None" : String(Math.round(card.average))
          color: Theme.ink
          font: Type.sans(34, "semibold")
        }
        MonoLine {
          visible: card.average !== null
          y: bigNumber.height - height - 8
          label: "wpm"
        }
      }

      Column {
        id: meter
        width: parent.width - figure.width - 16
        spacing: 4
        Accessible.role: Accessible.StaticText
        Accessible.name: "A meter from 0 to " + card.maxWpm + " words per minute: lit to the average of " + F.wpmText(card.average) +
          ", a dark segment at the best of " + F.wpmText(card.peak) + ", an outlined segment at a typist's " + Math.round(card.typing)

        Row {
          spacing: 2
          Repeater {
            model: card.segments
            delegate: Rectangle {
              required property int index
              width: (meter.width - 2 * (card.segments - 1)) / card.segments
              height: 18
              radius: 2
              color: card.fill(index)
              border.width: index === card.averageSegment && index !== card.peakSegment ? 1 : 0
              border.color: Theme.accentMark

              Rectangle {
                visible: parent.index === card.typistSegment
                anchors.fill: parent
                radius: 2
                color: "transparent"
                border.width: 1.5
                border.color: Theme.ink
              }
            }
          }
        }
        Item {
          width: parent.width
          height: zero.height
          AxisLabel { id: zero; text: "0" }
          AxisLabel { anchors.right: parent.right; text: String(card.maxWpm) }
        }
      }
    }

    Flow {
      width: parent.width
      spacing: 14
      Repeater {
        model: [
          { label: "average", value: F.wpmText(card.average), kind: "average" },
          { label: "peak", value: F.wpmText(card.peak), kind: "peak" },
          { label: "a typist", value: String(Math.round(card.typing)), kind: "typist" }
        ]
        delegate: Row {
          required property var modelData
          spacing: 5
          Rectangle {
            y: 1
            width: 8
            height: 10
            radius: 2
            color: modelData.kind === "average" ? Theme.accent : (modelData.kind === "peak" ? Theme.ink : Theme.track)
            border.width: modelData.kind === "typist" ? 1.5 : (modelData.kind === "average" ? 1 : 0)
            border.color: modelData.kind === "average" ? Theme.accentMark : Theme.ink
          }
          MonoLine { text: "<font color='" + Theme.ink2 + "'>" + modelData.label + "</font> <font color='" + Theme.ink + "'>" + modelData.value + "</font>" }
        }
      }
    }

    Text {
      visible: card.caption !== ""
      width: parent.width
      text: card.caption
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.caption)
    }
  }
}
