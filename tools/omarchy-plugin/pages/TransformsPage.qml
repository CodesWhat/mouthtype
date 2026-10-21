import QtQuick
import "../parts"

// Placeholder for the Transforms page until its Linux backend lands. The slice that builds it replaces this file and keeps the
// page contract in MouthtypeShell.qml: `backend`, `active`, and the `request(command, args)` signal.
Item {
  id: root

  property var backend: ({})
  property bool active: false
  signal request(string command, var args)

  implicitHeight: body.implicitHeight

  PagePlaceholder {
    id: body
    width: parent.width
    title: "Transforms"
    summary: "Say this, get that."
    note: "There is no editor for phrases on Linux yet. The phrases file the service reads still works."
  }
}
