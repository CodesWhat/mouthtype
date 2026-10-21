import QtQuick
import "../../design"

// Card chrome for the Stats page: surface, hair2 border, radius 12, and the Mac padding (16/20/14/20). Put the content in the
// default slot; it fills the padded area. A card sets `contentHeight` to the height its content needs and the card derives its
// implicit height from it. `tip` is the hover help.
Rectangle {
  id: card

  default property alias content: body.data
  property real padTop: 16
  property real padSide: 20
  property real padBottom: 14
  property real contentHeight: 0
  property string tip: ""

  implicitWidth: 320
  implicitHeight: padTop + contentHeight + padBottom
  color: Theme.surface
  radius: Theme.cardRadius
  border.width: 1
  border.color: Theme.hair2

  // Assigned to `data` explicitly: the default slot above belongs to the content, not to these.
  data: [
    Item {
      id: body
      x: card.padSide
      y: card.padTop
      width: card.width - 2 * card.padSide
      height: card.height - card.padTop - card.padBottom
    },
    HoverHandler { id: cardHover },
    HoverTip { text: card.tip; hovered: cardHover.hovered; point: cardHover.point.position }
  ]
}
