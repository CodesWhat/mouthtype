import QtQuick
import "../../design"
import "../../parts"
import "StyleLogic.js" as Logic

// "Counts as <context>": the apps in one list, each with a tone and a cleanup popup, and the row that adds an app by window
// class. Apps only: Wayland does not tell Mouthtype which website is open, so there are no website rows.
Column {
  id: root

  property var context: ({})
  property var tones: []
  property var rules: []
  property string globalLevel: "off"
  // Each edit is a list of [verb, args] control.py requests, sent in order.
  signal edit(var requests)

  readonly property string noun: context && context.id ? (Logic.NOUNS[context.id] || context.id) : ""
  readonly property var members: context.members || []
  property bool adding: false
  property string problem: ""

  width: parent ? parent.width : 520
  spacing: 8

  function ctxToneLabel() { return Logic.sameAs(noun, Logic.toneTitle(tones, context.tone)) }
  function ctxLevelLabel() { return Logic.sameAs(noun, context.cleanup ? Logic.levelTitle(context.cleanup) : Logic.levelTitle(globalLevel)) }

  function submit() {
    var text = field.text
    var found = Logic.classProblem(text)
    problem = found
    if (found !== "") return
    edit([["style-add-app", [context.id, text]]])
    field.text = ""
    adding = false
  }

  function cancel() {
    field.text = ""
    problem = ""
    adding = false
  }

  DesignEyebrow { text: "Counts as " + root.noun }

  DesignCard {
    width: parent.width

    Repeater {
      model: root.members
      delegate: MemberRow {
        required property var modelData
        readonly property var rule: Logic.ruleFor(root.rules, modelData.apps)
        name: modelData.name
        tag: modelData.built_in ? "BUILT IN" : "ADDED BY YOU"
        detail: modelData.built_in ? "" : modelData.apps.join(", ")
        toneModel: Logic.toneChoices(root.ctxToneLabel(), root.tones)
        toneValue: Logic.toneIndex(rule ? rule.tone : null)
        cleanupModel: Logic.levelChoices(root.ctxLevelLabel())
        cleanupValue: Logic.levelIndex(rule ? rule.cleanup : null)
        removeLabel: "Remove " + modelData.name + " from " + root.noun
        onToneChosen: function(index) { root.edit(Logic.ruleRequests(modelData, root.rules, "tone", Logic.TONE_IDS[index])) }
        onCleanupChosen: function(index) { root.edit(Logic.ruleRequests(modelData, root.rules, "cleanup", Logic.LEVEL_IDS[index])) }
        onRemoved: root.edit([["style-remove-app", [root.context.id, modelData.id]]])
      }
    }

    DesignRow {
      visible: root.members.length === 0
      title: "No apps in this list"
      detail: "Add the window class of an app to make it count as " + root.noun + "."
    }

    DesignRow {
      id: addRow
      title: "Add an app"
      clickable: !root.adding
      visible: !root.adding
      onActivated: { root.adding = true; field.forceActiveFocus() }
      Icon { name: "plus"; size: 24; color: Theme.ink }
    }

    Column {
      id: editor
      visible: root.adding
      width: parent.width
      Item {
        width: parent.width
        height: 1
        Rectangle { anchors.fill: parent; color: Theme.hair2; visible: root.members.length > 0 }
      }
      Column {
        x: 14
        width: parent.width - 28
        topPadding: 10
        bottomPadding: 12
        spacing: 8

        Text {
          width: parent.width
          text: "Add an app to " + root.noun
          wrapMode: Text.Wrap
          color: Theme.ink
          font: Type.sans(Type.body, "medium")
        }
        Row {
          width: parent.width
          spacing: 8
          FieldBox {
            id: field
            width: parent.width - addButton.width - cancelButton.width - 16
            hint: "Window class, e.g. org.telegram.desktop"
            Accessible.name: "Window class"
            onAccepted: root.submit()
            Keys.onEscapePressed: root.cancel()
            onTextChanged: root.problem = ""
          }
          DesignPrimaryButton { id: addButton; text: "Add"; anchors.verticalCenter: field.verticalCenter; onActivated: root.submit() }
          DesignSecondaryButton { id: cancelButton; text: "Cancel"; anchors.verticalCenter: field.verticalCenter; onActivated: root.cancel() }
        }
        Text {
          visible: root.problem !== ""
          width: parent.width
          text: root.problem
          wrapMode: Text.Wrap
          color: Theme.danger
          font: Type.sans(Type.caption)
        }
        Text {
          width: parent.width
          text: "Find the class by running hyprctl clients in a terminal and copying the line that starts with class:. It has to match exactly, apart from capital letters."
          wrapMode: Text.Wrap
          color: Theme.ink3
          font: Type.sans(Type.caption)
        }
      }
    }
  }
}
