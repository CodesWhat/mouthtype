import QtQuick

// Surface, 1 px hair2 border, radius 12. Children stack top to bottom and get a hairline between them. Rows that expose
// `cardFirst`/`cardLast` (DesignRow does) round the matching corners of their own hover and selection fill, so the fill
// follows the card shape without a mask: masks need a shader, which the software Qt Quick backend cannot draw.
Rectangle {
  id: root

  default property alias content: column.data

  color: Theme.surface
  radius: Theme.cardRadius
  border.width: 1
  border.color: Theme.hair2
  implicitWidth: 320
  implicitHeight: column.implicitHeight + 2
  clip: true

  function relayout() {
    var visibleKids = []
    for (var i = 0; i < column.children.length; i++) {
      if (column.children[i].visible) visibleKids.push(column.children[i])
    }
    for (var j = 0; j < visibleKids.length; j++) {
      var kid = visibleKids[j]
      if (kid.cardFirst !== undefined) kid.cardFirst = j === 0
      if (kid.cardLast !== undefined) kid.cardLast = j === visibleKids.length - 1
    }
  }

  Column {
    id: column
    property var owner: root
    x: 1
    y: 1
    width: root.width - 2
    spacing: 0
    onChildrenChanged: root.relayout()
  }

  Component.onCompleted: relayout()
}
