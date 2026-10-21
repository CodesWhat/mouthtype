import QtQuick
import "../../design"
import "StatsFormat.js" as F

// Today's tape: one thin needle per take at its time of day, taller for more words on a square-root scale. Takes closer than
// 6 px merge into one needle (hover shows "N takes, W words, start to end"). The axis fits the day's span, at least three
// hours. A NOW marker shows the current time. Audio-only takes are hollow, or carry a hollow cap when merged with real ones.
// Lime only on the biggest needle or the hovered one.
StatsCard {
  id: card

  property var takes: []
  property var summary: ({})
  property int nowSeconds: 0
  property int hovered: -1

  readonly property var range: F.tapeRange(takes, nowSeconds)
  readonly property var slots: F.mergeSlots(takes, range, field.width)
  readonly property int biggest: F.biggestSlot(slots)
  readonly property int highlighted: hovered >= 0 && hovered < slots.length ? hovered : biggest
  readonly property real maxWords: {
    var most = 1
    for (var i = 0; i < slots.length; i++) most = Math.max(most, slots[i].words)
    return most
  }
  readonly property real headroom: 26
  readonly property real plotHeight: 72

  tip: "Every take as a needle at its time of day. Takes closer together than the needles can show are merged, and their words added."
  contentHeight: head.height + 10 + headroom + plotHeight + 10 + foot.height

  Item {
    id: head
    width: parent.width
    height: Math.max(title.implicitHeight, taller.implicitHeight)
    DesignEyebrow { id: title; text: "Today's tape" }
    MonoLine {
      id: taller
      anchors.right: parent.right
      label: "Taller = more words"
    }
  }

  Item {
    id: plot
    y: head.height + 10 + card.headroom
    width: parent.width
    height: card.plotHeight

    Accessible.role: Accessible.StaticText
    Accessible.name: card.takes.length === 0 ? "No takes yet today" : card.takes.length + (card.takes.length === 1 ? " take" : " takes") + " today"

    Rectangle {
      anchors.fill: parent
      radius: 6
      color: Theme.bg
      border.width: 1
      border.color: Theme.hair2
    }

    Item {
      id: field
      anchors.fill: parent

      Repeater {
        model: card.range.ticks.slice(1)
        delegate: Rectangle {
          required property int modelData
          x: field.width * F.fraction(card.range, modelData * 3600)
          width: 1
          height: field.height
          color: Theme.hair2
        }
      }

      Rectangle {
        y: field.height - 11
        width: field.width
        height: 1
        color: Theme.hair
      }

      Repeater {
        model: card.slots
        delegate: Item {
          id: needle
          required property var modelData
          required property int index
          readonly property bool hot: index === card.highlighted
          readonly property bool allHollow: modelData.hollow === modelData.count
          readonly property real tall: F.needleHeight(modelData.words, card.maxWords)
          readonly property real wide: allHollow ? 4 : 2.5
          readonly property real pad: hot ? 3 : 0
          readonly property color mark: hot ? Theme.accent : Theme.neutralMark

          x: modelData.x - wide / 2 - pad
          y: field.height - 11 - tall - pad
          width: wide + 2 * pad
          height: tall + 2 * pad

          Rectangle {
            x: needle.pad
            y: needle.pad
            width: needle.wide
            height: needle.tall
            radius: 1.25
            color: needle.allHollow ? Theme.surface : needle.mark
            border.width: needle.allHollow ? 1 : 0
            border.color: needle.mark
          }
          Rectangle {
            visible: needle.modelData.hollow > 0 && !needle.allHollow
            x: needle.pad + needle.wide / 2 - 2.5
            y: needle.pad - 6
            width: 5
            height: 5
            radius: 2.5
            color: Theme.surface
            border.width: 1
            border.color: needle.mark
          }
          Rectangle {
            visible: needle.hot
            anchors.fill: parent
            radius: 3
            color: "transparent"
            border.width: 1
            border.color: Theme.accent
          }
        }
      }

      // The NOW marker and its label, which flips to the left of the line near the right edge.
      Rectangle {
        id: nowLine
        readonly property real nowX: field.width * F.fraction(card.range, card.nowSeconds)
        x: nowX - 0.75
        y: 6
        width: 1.5
        height: field.height - 12
        color: Theme.ink
      }
      AxisLabel {
        id: nowLabel
        text: "NOW"
        color: Theme.ink
        x: nowLine.nowX + 6 + width > field.width ? nowLine.nowX - 6 - width : nowLine.nowX + 6
        y: 4
      }

      Repeater {
        model: card.range.ticks
        delegate: AxisLabel {
          required property int modelData
          text: F.tickLabel(modelData, modelData === card.range.start)
          x: field.width * F.fraction(card.range, modelData * 3600) + (modelData === card.range.start ? 6 : 5)
          y: field.height - 10
        }
      }
      AxisLabel {
        text: F.tickLabel(card.range.end, true)
        x: field.width - 6 - width
        y: field.height - 10
      }

      // The callout over the highlighted needle, in the first ink with the page colour for text.
      Rectangle {
        id: callout
        readonly property var slot: card.highlighted >= 0 ? card.slots[card.highlighted] : null
        readonly property real needleTop: field.height - 11 - (slot ? F.needleHeight(slot.words, card.maxWords) : 0) - 3
        visible: slot !== null
        width: calloutText.width + 16
        height: calloutText.height + 8
        radius: 6
        color: Theme.ink
        y: needleTop - 28
        x: {
          if (!slot) return 0
          if (slot.x < field.width * 0.22) return Math.max(0, slot.x - 5)
          if (slot.x > field.width * 0.78) return Math.min(field.width - width, slot.x + 5 - width)
          return slot.x - width / 2
        }

        Text {
          id: calloutText
          x: 8
          y: 4
          textFormat: Text.StyledText
          text: callout.slot ? F.slotCallout(callout.slot) : ""
          color: Theme.bg
          font: Type.sans(11)
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onPositionChanged: function(mouse) { card.hovered = F.nearestSlot(card.slots, mouse.x) }
        onExited: card.hovered = -1
      }
    }
  }

  Flow {
    id: foot
    y: head.height + 10 + card.headroom + card.plotHeight + 10
    width: parent.width
    spacing: 14

    MonoLine { value: String(card.summary.takes || 0); label: (card.summary.takes || 0) === 1 ? "take" : "takes" }
    Text { text: "|"; color: Theme.hair; font: Type.mono(Type.eyebrowSize) }
    MonoLine { value: F.number(card.summary.words || 0); label: "words" }
    Text { text: "|"; color: Theme.hair; font: Type.mono(Type.eyebrowSize) }
    MonoLine { value: F.talkingMs(card.summary.speaking_ms || 0); label: "talking" }
    Text { text: "|"; color: Theme.hair; font: Type.mono(Type.eyebrowSize) }
    MonoLine { value: F.talkingMinutes(card.summary.minutes_avoided || 0); label: "of typing avoided" }

    Row {
      spacing: 5
      Rectangle {
        y: 1
        width: 8
        height: 8
        radius: 2
        color: Theme.surface
        border.width: 1.5
        border.color: Theme.ink3
      }
      MonoLine { color: Theme.ink2; label: "Audio saved, no transcript" }
    }
  }
}
