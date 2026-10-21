import QtQuick
import "../../design"
import "../../parts"
import "StyleLogic.js" as Logic

// One context tab: three tone cards, the apps that count as it, and the cleanup level for it. Other has no list; it holds the
// default tone and the rules that belong to no list.
Column {
  id: root

  property var context: ({})
  property var tones: []
  property var rules: []
  property var ownRules: []
  property string globalLevel: "off"
  signal edit(var requests)

  readonly property bool isOther: context.id === "other"
  readonly property string noun: context && context.id ? (Logic.NOUNS[context.id] || "") : ""
  readonly property var samples: context.samples || []
  readonly property string suggested: context.suggested_tone || ""
  property real cardHeight: 0

  width: parent ? parent.width : 520
  spacing: 18

  function setTone(tone) {
    root.edit([[isOther ? "style-set-default-tone" : "style-set-tone", isOther ? [tone] : [context.id, tone]]])
  }

  function measure() {
    var h = 0
    for (var i = 0; i < cards.count; i++) {
      var card = cards.itemAt(i)
      if (card) h = Math.max(h, card.implicitHeight)
    }
    cardHeight = h
  }

  Column {
    width: parent.width
    spacing: 8

    DesignEyebrow { text: Logic.TONE_EYEBROWS[root.context.id] || "Tone" }

    Row {
      id: cardRow
      width: parent.width
      spacing: 12

      Repeater {
        id: cards
        model: root.samples
        delegate: ToneCard {
          required property var modelData
          width: (cardRow.width - 24) / 3
          height: Math.max(implicitHeight, root.cardHeight)
          title: modelData.title
          blurb: Logic.TONE_BLURBS[modelData.tone] || ""
          lines: modelData.lines
          selected: root.context.tone === modelData.tone
          onActivated: root.setTone(modelData.tone)
          onImplicitHeightChanged: root.measure()
          Component.onCompleted: root.measure()
        }
      }
    }

    // A quiet line under the cards: what an unset tone means here, the tone the Mac starts with, or how to clear it.
    Flow {
      width: parent.width
      leftPadding: 4
      spacing: 6

      Text {
        visible: !root.context.tone
        text: root.suggested !== ""
          ? "No tone is set, so your text keeps the punctuation it was spoken with. Suggested: " + Logic.toneTitle(root.tones, root.suggested) + "."
          : "No tone is set, so your text keeps the punctuation it was spoken with."
        wrapMode: Text.Wrap
        width: Math.min(implicitWidth, parent.width - 8)
        color: Theme.ink3
        font: Type.sans(Type.caption)
      }
      LinkText {
        visible: !root.context.tone && root.suggested !== ""
        text: "Use " + Logic.toneTitle(root.tones, root.suggested)
        onActivated: root.setTone(root.suggested)
      }
      LinkText {
        visible: !!root.context.tone
        text: "Clear the tone"
        onActivated: root.setTone("none")
      }
    }
  }

  CountsAs {
    visible: !root.isOther
    width: parent.width
    context: root.context
    tones: root.tones
    rules: root.rules
    globalLevel: root.globalLevel
    onEdit: function(requests) { root.edit(requests) }
  }

  Column {
    visible: root.isOther
    width: parent.width
    spacing: 8
    DesignEyebrow { text: "Counts as other" }
    DesignCard {
      width: parent.width
      DesignRow {
        title: "Everything not listed under Personal, Work or Email"
        detail: "Terminals, editors and any app with no list of its own. It uses the tone above."
      }
    }
  }

  Column {
    width: parent.width
    spacing: 8

    DesignCard {
      width: parent.width
      DesignRow {
        title: "Cleanup here"
        detail: Logic.CLEANUP_HERE[root.context.id] || ""
        StatePopup {
          model: Logic.levelChoices(Logic.sameAs("everywhere", Logic.levelTitle(root.globalLevel)))
          value: Logic.levelIndex(root.context.cleanup)
          text: "Cleanup for " + root.noun
          onActivated: function(index) {
            root.edit([["style-set-cleanup", [root.context.id, Logic.LEVEL_IDS[index] || "none"]]])
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
      text: root.context.id === "email"
        ? "Say \"new paragraph\" to break lines. That's a spoken command, so it works at every tone."
        : "Anything not listed under Personal, Work or Email counts as Other. An app you add to one list leaves the others."
    }
  }

  Column {
    visible: root.isOther && root.ownRules.length > 0
    width: parent.width
    spacing: 8
    DesignEyebrow { text: "Your own rules" }
    DesignCard {
      width: parent.width
      Repeater {
        model: root.ownRules
        delegate: MemberRow {
          required property var modelData
          name: modelData.name
          detail: modelData.app
          toneModel: Logic.toneChoices("Use default tone", root.tones)
          toneValue: Logic.toneIndex(modelData.tone)
          cleanupModel: Logic.levelChoices("Cleanup: use default")
          cleanupValue: Logic.levelIndex(modelData.cleanup)
          removeLabel: "Remove the rule for " + modelData.name
          onToneChosen: function(index) {
            root.edit([["style-rule", [modelData.app, Logic.TONE_IDS[index] || "none", modelData.cleanup || "none", modelData.name]]])
          }
          onCleanupChosen: function(index) {
            root.edit([["style-rule", [modelData.app, modelData.tone || "none", Logic.LEVEL_IDS[index] || "none", modelData.name]]])
          }
          onRemoved: root.edit([Logic.removeRuleRequest(modelData)])
        }
      }
    }
    Text {
      width: parent.width
      leftPadding: 4
      rightPadding: 4
      wrapMode: Text.Wrap
      color: Theme.ink2
      font: Type.sans(Type.caption)
      text: "A rule you set for one app wins over its list."
    }
  }
}
