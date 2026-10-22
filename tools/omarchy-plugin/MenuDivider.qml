import QtQuick

Item {
  id: root
  property var style: MenuStyle {}

  implicitWidth: root.style.space(320)
  implicitHeight: root.style.space(9)
  Rectangle {
    x: root.style.space(8)
    y: root.style.space(4)
    width: parent.width - root.style.space(16)
    height: 1
    color: "#A8A8A6"
  }
}
