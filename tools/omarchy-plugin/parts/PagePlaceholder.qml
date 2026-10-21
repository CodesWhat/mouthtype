import QtQuick
import "../design"

// The body of a page whose Linux backend has not shipped. A page slice replaces its own pages/<Name>Page.qml and stops using
// this. `title` is the serif headline, `summary` the line under it, `note` the honest explanation in the card.
Column {
  id: root

  property string title: ""
  property string summary: ""
  property string note: ""

  width: parent ? parent.width : 520
  spacing: 18

  DesignPageHeader {
    width: parent.width
    title: root.title
    summary: root.summary
  }

  DesignCard {
    width: parent.width
    DesignRow {
      title: "Not available on Linux yet"
      detail: root.note
      Icon { name: "clock"; size: 24; color: Theme.ink3 }
    }
  }
}
