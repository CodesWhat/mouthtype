import QtQuick

Rectangle {
  id: root
  property var style: MenuStyle {}
  property string label: ""
  signal clicked()
  implicitWidth: caption.implicitWidth + root.style.space(20)
  implicitHeight: caption.implicitHeight + root.style.space(12)
  radius: root.style.space(6)
  color: enabled ? root.style.accent : root.style.mutedBackground
  opacity: enabled ? 1 : 0.45

  Text {
    id: caption
    anchors.centerIn: parent
    text: root.label
    color: root.style.foreground
    font.family: root.style.font.family
    font.pixelSize: root.style.font.body
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.enabled
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
