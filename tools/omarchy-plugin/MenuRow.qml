import QtQuick

Rectangle {
  id: root
  property var style: MenuStyle {}
  property string label: ""
  property string detail: ""
  property bool checked: false
  property bool chevron: false
  property string fontFamily: style.font.family
  signal activated()

  implicitWidth: root.style.space(320)
  implicitHeight: root.style.space(28)
  color: pointer.containsMouse && enabled ? "#4F78C3" : "transparent"

  Text {
    id: tick
    x: root.style.space(9)
    anchors.verticalCenter: parent.verticalCenter
    text: root.checked ? "✓" : ""
    color: pointer.containsMouse ? "#FFFFFF" : "#242424"
    font.pixelSize: root.style.font.body
    font.family: root.fontFamily
  }

  Text {
    id: caption
    x: root.style.space(30)
    anchors.verticalCenter: parent.verticalCenter
    width: parent.width - x - (root.detail !== "" ? root.style.space(100) : root.style.space(34))
    text: root.label
    elide: Text.ElideRight
    color: !root.enabled ? "#8B8B89" : pointer.containsMouse ? "#FFFFFF" : "#252525"
    font.pixelSize: root.style.font.body
    font.family: root.fontFamily
    renderType: Text.NativeRendering
  }

  Text {
    visible: root.detail !== ""
    anchors.right: chevron.left
    anchors.rightMargin: root.style.space(5)
    anchors.verticalCenter: parent.verticalCenter
    text: root.detail
    color: !root.enabled ? "#969694" : pointer.containsMouse ? "#FFFFFF" : "#777775"
    font.pixelSize: root.style.font.bodySmall
    font.family: root.fontFamily
  }

  Text {
    id: chevron
    visible: root.chevron
    anchors.right: parent.right
    anchors.rightMargin: root.style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    text: "›"
    color: pointer.containsMouse ? "#FFFFFF" : "#777775"
    font.pixelSize: root.style.font.title
    font.family: root.fontFamily
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    enabled: root.enabled
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }
}
