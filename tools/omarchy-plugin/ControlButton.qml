import QtQuick
import qs.Commons

Rectangle {
  id: root
  property string label: ""
  signal clicked()
  implicitWidth: caption.implicitWidth + Style.space(20)
  implicitHeight: caption.implicitHeight + Style.space(12)
  radius: Style.space(6)
  color: enabled ? Color.accent : Color.popups.background
  opacity: enabled ? 1 : 0.45

  Text {
    id: caption
    anchors.centerIn: parent
    text: root.label
    color: Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.enabled
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
