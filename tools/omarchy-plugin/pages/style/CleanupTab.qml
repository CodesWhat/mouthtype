import QtQuick
import "../../design"
import "StyleLogic.js" as Logic

// The Cleanup tab: the level every take runs at, each level with the same messy take as it comes out, and the contexts that
// differ. The level chooser moved here from Settings, Health; the model status and Prepare buttons stay in Health too.
Column {
  id: root

  property var contexts: []
  property var overrides: []
  property var rules: []
  property string level: "off"
  property var models: ({})
  property var service: null
  property var setup: null
  signal chooseLevel(string level)
  signal prepare(string level)
  signal openContext(string id)

  readonly property bool setupActive: !!setup && (setup.state === "preparing" || setup.state === "building" || setup.state === "downloading")
  property real rowOne: 0
  property real rowTwo: 0

  width: parent ? parent.width : 520
  spacing: 18

  function usable(key) { return key === "off" || key === "basic" || (models && models[key] === "prepared") }

  function setupLine() {
    if (!setup) return ""
    if (setup.state === "building") return " Building the pinned llama.cpp server…"
    if (setup.state === "downloading") return " Downloading and verifying the " + (setup.level || "") + " model…"
    if (setup.state === "preparing") return " Preparing…"
    if (setup.state === "failed") return " Preparation failed (" + (setup.error || "error") + "). Check the cleanup setup log."
    return ""
  }

  Column {
    width: parent.width
    spacing: 10

    DesignEyebrow { text: "Cleanup · every take, in every app" }

    Repeater {
      model: [["off", "basic"], ["fast", "thorough"]]
      delegate: Row {
        id: pair
        required property var modelData
        required property int index
        width: parent.width
        spacing: 12
        readonly property real shared: index === 0 ? root.rowOne : root.rowTwo

        Repeater {
          id: pairCards
          model: pair.modelData
          delegate: LevelCard {
            required property string modelData
            width: (pair.width - 12) / 2
            height: Math.max(implicitHeight, pair.shared)
            title: Logic.levelTitle(modelData)
            blurb: Logic.LEVEL_BLURBS[modelData]
            sample: Logic.LEVEL_SAMPLES[modelData]
            status: Logic.levelStatus(modelData, root.models, root.service, root.setup)
            selected: root.level === modelData
            usable: root.usable(modelData)
            canPrepare: !root.usable(modelData) && !root.setupActive
            onActivated: root.chooseLevel(modelData)
            onPrepareRequested: root.prepare(modelData)
            onImplicitHeightChanged: pair.measure()
            Component.onCompleted: pair.measure()
          }
        }

        function measure() {
          var h = 0
          for (var i = 0; i < pairCards.count; i++) {
            var card = pairCards.itemAt(i)
            if (card) h = Math.max(h, card.implicitHeight)
          }
          if (index === 0) root.rowOne = h
          else root.rowTwo = h
        }
      }
    }
  }

  Column {
    width: parent.width
    spacing: 8

    DesignEyebrow { text: "Where it's different" }
    DesignCard {
      width: parent.width

      Repeater {
        model: root.overrides
        delegate: DesignRow {
          required property var modelData
          title: root.titleOf(modelData.context)
          detail: modelData.context === "other"
            ? "Terminals, editors and everything unlisted. Basic never rewrites a command."
            : "Apps listed under " + root.titleOf(modelData.context) + "."
          Text {
            text: Logic.levelTitle(modelData.level).toUpperCase()
            color: Theme.ink
            font: Type.mono(11)
            anchors.verticalCenter: parent.verticalCenter
          }
          LinkText {
            text: "Change on its tab"
            anchors.verticalCenter: parent.verticalCenter
            onActivated: root.openContext(modelData.context)
          }
        }
      }
      DesignRow {
        visible: root.ownLevels > 0
        title: root.ownLevels + (root.ownLevels === 1 ? " of your own app rules sets" : " of your own app rules set") + " a cleanup level"
        detail: "They win over the lists. Find them on the Other tab, or on the app's own row."
      }
      DesignRow {
        title: Logic.followText(root.contexts, root.level)
        Text {
          text: Logic.followCount(root.contexts) + " OF " + root.contexts.length + " FOLLOW"
          color: Theme.ink3
          font: Type.eyebrow
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }

  Text {
    width: parent.width
    leftPadding: 4
    rightPadding: 4
    wrapMode: Text.Wrap
    color: Theme.ink3
    font: Type.sans(Type.caption)
    text: "Fast and Thorough run on this computer and never change what you meant. Until a model is prepared and ready, takes use Basic." + root.setupLine()
  }

  readonly property int ownLevels: Logic.ownRuleCount({ rules: rules })

  function titleOf(id) {
    for (var i = 0; i < contexts.length; i++) if (contexts[i].id === id) return contexts[i].title
    return id
  }
}
