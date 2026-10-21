import QtQuick
import "../parts"

// Placeholder for the Style page until its Linux backend lands. The slice that builds it replaces this file and keeps the
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
    title: "Style"
    summary: "Tone per context, and how much cleanup runs."
    note: "Tone and per-app rules are not on Linux yet. The cleanup level is in Settings, under Health."
  }
}
