import QtQuick
import "../parts"

// Placeholder for the Dictionary page until its Linux backend lands. The slice that builds it replaces this file and keeps the
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
    title: "Dictionary"
    summary: "Words you teach it."
    note: "There is no editor for saved spellings on Linux yet. The spellings file the service reads still works."
  }
}
