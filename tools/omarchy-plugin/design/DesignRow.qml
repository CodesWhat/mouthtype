import QtQuick

// One row of a card, 48 px minimum. Title and detail on the left, controls on the right. When the controls do not fit beside
// a 180 px label they wrap below it, and the label wraps instead of truncating. Set `clickable` for a hover fill and the
// `activated` signal. A hairline is drawn above every row except the first one in its card.
Item {
  id: root

  property string title: ""
  property string detail: ""
  property bool clickable: false
  property bool selected: false
  property bool cardFirst: true
  property bool cardLast: true
  default property alias controls: controlRow.data
  signal activated()

  // The sel tint composed over the card surface into one opaque colour, so the corner repair below cannot double the alpha.
  readonly property color fillColor: Qt.tint(Theme.surface, Theme.sel)

  readonly property bool stacked: controlRow.visibleChildrenWidth > 0 && width - 28 - 16 - controlRow.visibleChildrenWidth < 180

  width: parent ? parent.width : 320
  implicitHeight: Math.max(Theme.rowMinHeight, content.height + 18)
  height: implicitHeight

  onVisibleChanged: if (parent && parent.owner) parent.owner.relayout()

  // Hover and selection fill. The card clips to a rounded rectangle, so the first and last rows round their outer corners.
  Item {
    anchors.fill: parent
    visible: fill.opacity > 0

    Rectangle {
      id: fill
      property real amount: root.selected ? 1 : (hover.containsMouse && root.clickable && root.enabled ? 1 : 0)
      anchors.fill: parent
      color: root.fillColor
      radius: (root.cardFirst || root.cardLast) ? Theme.cardRadius - 1 : 0
      opacity: amount
    }
    Rectangle {
      // Squares off the corners that should not be round.
      visible: fill.opacity > 0 && (root.cardFirst !== root.cardLast)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: root.cardFirst ? undefined : parent.top
      anchors.bottom: root.cardFirst ? parent.bottom : undefined
      height: Theme.cardRadius
      color: root.fillColor
      opacity: fill.opacity
    }
  }

  Rectangle {
    visible: !root.cardFirst
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: 1
    color: Theme.hair2
  }

  Item {
    id: content
    x: 14
    y: 9
    width: parent.width - 28
    height: root.stacked ? label.height + 8 + controlRow.height : Math.max(label.height, controlRow.height)

    Column {
      id: label
      spacing: 1
      width: root.stacked || controlRow.visibleChildrenWidth === 0 ? parent.width : parent.width - 16 - controlRow.visibleChildrenWidth
      anchors.verticalCenter: root.stacked ? undefined : parent.verticalCenter

      Text {
        width: parent.width
        text: root.title
        wrapMode: Text.Wrap
        color: Theme.ink
        font: Type.sans(Type.body, "medium")
      }
      Text {
        visible: root.detail !== ""
        width: parent.width
        text: root.detail
        wrapMode: Text.Wrap
        color: Theme.ink2
        font: Type.sans(Type.caption)
      }
    }

    Row {
      id: controlRow
      spacing: 8
      anchors.right: parent.right
      y: root.stacked ? label.height + 8 : (content.height - height) / 2
      // Row sums its visible children and the spacing between them, and tracks changes itself.
      readonly property real visibleChildrenWidth: implicitWidth
    }
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    enabled: root.clickable
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
    z: -1
  }
}
