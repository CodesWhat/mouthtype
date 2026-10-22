import QtQuick
import "../design"
import "TransformModel.js" as Model

// The Transform Selection card, per the Mac panel and the TransformSelection boards. A pure view over one session
// object (see TransformModel.js): it holds no process state, so the render harness drives it with fixtures and
// TransformWindow.qml wires it to control.py. Every action is a signal; nothing here talks to the system.
FocusScope {
  id: root

  property var session: Model.empty()
  readonly property string resultText: resultBox.text
  readonly property var chipList: Model.chips(session)
  readonly property bool busy: Model.isBusy(session)
  readonly property bool failed: session.phase === "error"
  readonly property bool refused: session.refused !== null && session.refused !== undefined
  readonly property bool accepted: session.submitted === true
  readonly property string app: Model.appName(session)
  readonly property var shownDiff: Model.diffFor(session, resultBox.settled)

  signal chosen(string kind)
  signal retryRequested()
  signal copyResultRequested()
  signal copyOriginalRequested()
  signal acceptRequested()
  signal cancelRequested()

  width: 640
  implicitHeight: content.implicitHeight + 40
  height: implicitHeight

  Keys.onEscapePressed: root.cancelRequested()

  Rectangle {
    anchors.fill: parent
    radius: 12
    color: Theme.bg
    border.width: 1
    border.color: Theme.hair
  }

  Column {
    id: content
    x: 24
    y: 20
    width: parent.width - 48
    spacing: 12

    Item {
      width: parent.width
      height: Math.max(leftEyebrow.implicitHeight, rightEyebrow.implicitHeight)
      DesignEyebrow {
        id: leftEyebrow
        anchors.left: parent.left
        width: parent.width - rightEyebrow.implicitWidth - 12
        text: root.app !== "" ? "Transform selection · from " + root.app : "Transform selection"
      }
      DesignEyebrow {
        id: rightEyebrow
        anchors.right: parent.right
        wrapMode: Text.NoWrap
        text: "AI transforms run on this computer"
      }
    }

    Chips {
      width: parent.width
      visible: !root.failed
      chips: root.chipList
      onChosen: function(kind) { root.chosen(kind) }
    }

    Text {
      width: parent.width
      visible: !root.failed && text !== ""
      text: root.session.modelNote
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.caption)
      objectName: "modelNote"
    }

    Column {
      width: parent.width
      spacing: 4
      visible: !root.failed
      DesignEyebrow { text: "Original" }
      DiffView {
        width: parent.width
        segments: root.shownDiff.original
        objectName: "original"
      }
    }

    Column {
      width: parent.width
      spacing: 4
      visible: !root.failed
      DesignEyebrow { text: "Result · edit it before you accept" }
      ResultBox {
        id: resultBox
        width: parent.width
        session: root.session
        editable: !root.busy && !root.accepted && !root.refused
        objectName: "result"
      }
    }

    Item {
      width: parent.width
      height: busyLabel.implicitHeight + 10
      visible: root.busy
      objectName: "busy"
      Text {
        id: busyLabel
        width: parent.width
        text: Model.busyText(root.session)
        wrapMode: Text.Wrap
        color: Theme.ink2
        font: Type.sans(Type.caption)
      }
      Rectangle {
        id: track
        anchors.bottom: parent.bottom
        width: parent.width
        height: 3
        radius: 2
        color: Theme.track
        clip: true
        Rectangle {
          id: slider
          height: parent.height
          width: parent.width * 0.3
          radius: 2
          color: Theme.accentMark
          x: parent.width * 0.35
          SequentialAnimation on x {
            running: root.busy
            loops: Animation.Infinite
            NumberAnimation { from: -slider.width; to: track.width; duration: 1100; easing.type: Easing.InOutQuad }
          }
        }
      }
    }

    Text {
      width: parent.width
      visible: !root.busy && !root.refused && text !== ""
      text: root.session.message
      wrapMode: Text.Wrap
      color: root.session.messageTone === "error" ? Theme.danger : Theme.ink2
      font: Type.sans(Type.caption)
      objectName: "message"
    }

    Text {
      width: parent.width
      visible: !root.failed && text !== ""
      text: Model.highlightNote(root.session)
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.caption)
      objectName: "highlightNote"
    }

    RefusedNotice {
      width: parent.width
      visible: root.refused
      title: root.refused ? root.session.refused.title : ""
      detail: root.refused ? root.session.refused.detail : ""
      objectName: "refused"
    }

    Item {
      width: parent.width
      height: Theme.controlHeight

      Row {
        anchors.left: parent.left
        spacing: 8
        DesignSecondaryButton {
          text: root.accepted ? "Close" : "Cancel"
          enabled: root.session.phase !== "accepting"
          objectName: "cancel"
          onActivated: root.cancelRequested()
        }
        DesignSecondaryButton {
          visible: Model.retryVisible(root.session)
          enabled: Model.canRetry(root.session)
          text: "Retry"
          objectName: "retry"
          onActivated: root.retryRequested()
        }
      }
      Row {
        anchors.right: parent.right
        spacing: 8
        visible: !root.failed
        DesignSecondaryButton {
          visible: root.accepted
          text: "Copy original"
          objectName: "copyOriginal"
          onActivated: root.copyOriginalRequested()
        }
        // Refused: Copy result is the way forward, so it takes the accent and Accept goes quiet.
        DesignButton {
          primary: root.refused
          enabled: Model.canCopy(root.session, root.resultText)
          text: "Copy result"
          objectName: "copyResult"
          onActivated: root.copyResultRequested()
        }
        DesignButton {
          primary: !root.refused
          enabled: Model.canAccept(root.session, root.resultText)
          text: "Accept"
          objectName: "accept"
          onActivated: root.acceptRequested()
        }
      }
    }
  }
}
