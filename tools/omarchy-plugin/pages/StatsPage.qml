import QtQuick
import "../parts"

// Placeholder for the Stats page until its Linux backend lands. The slice that builds it replaces this file and keeps the
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
    title: "Stats"
    summary: "Your numbers, kept on this machine."
    note: "Words, streaks and high scores are not computed on Linux yet. Today's word count is on Home."
  }
}
