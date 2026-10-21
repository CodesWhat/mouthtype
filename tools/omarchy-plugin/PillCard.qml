import QtQuick
import "design"
import "CardPalette.js" as Cards

// The pill's settled message drawn as a delivery card: a headline, an optional detail line, a status dot on the Classic
// style. Classic is the dark capsule; Minimal follows light and dark and puts lime on the one primary action only.
// The pill has no card actions today, so primaryText and secondaryText stay empty in the shipped service and exist for
// the render sheet and the contrast test.
//
// fontFamily is the user's pill font. Empty means the Default: Instrument Serif headline over Instrument Sans detail,
// as the Mac does. Anything else is used for both lines.
Item {
  id: root

  property string style: "classic"
  property bool dark: Theme.dark
  property string headline: ""
  property string detail: ""
  property bool isError: false
  property string fontFamily: ""
  property string primaryText: ""
  property string secondaryText: ""
  // Render sheet only: "" follows the mouse, "hover" or "press" pins the primary button.
  property string previewState: ""
  signal primaryClicked()
  signal secondaryClicked()

  readonly property var palette: Cards.palette(style, dark)
  readonly property bool hasActions: primaryText !== "" || secondaryText !== ""
  readonly property bool hasDetail: detail !== ""
  readonly property font headFont: fontFamily === ""
    ? Type.serif(14)
    : Qt.font({ family: fontFamily, pixelSize: 13, weight: Font.Medium })
  readonly property font detailFont: fontFamily === ""
    ? Type.sans(11)
    : Qt.font({ family: fontFamily, pixelSize: 11, weight: Font.Normal })
  readonly property real dotSpace: palette.showsDot ? 6 + 7 : 0
  readonly property real textWidth: Math.ceil(Math.max(headMetrics.advanceWidth + 1 + dotSpace, detailMetrics.advanceWidth))
  readonly property real cardWidth: hasActions ? Math.max(224, Math.min(320, textWidth + 24)) : Math.min(320, Math.max(64, textWidth + 32))
  readonly property real padding: hasActions ? 12 : 16

  implicitWidth: card.width
  implicitHeight: card.height

  TextMetrics { id: headMetrics; font: root.headFont; text: root.headline }
  TextMetrics { id: detailMetrics; font: root.detailFont; text: root.detail }

  Rectangle {
    id: card
    width: root.cardWidth
    height: Math.max(28, content.implicitHeight + (root.hasActions ? 11 + 12 : 14))
    radius: root.hasActions ? 16 : Math.min(root.palette.radius, height / 2)
    antialiasing: true
    gradient: Gradient {
      GradientStop { position: 0; color: Cards.withAlpha(root.palette.bodyTop, root.palette.bodyAlpha) }
      GradientStop { position: 1; color: Cards.withAlpha(root.palette.bodyBottom, root.palette.bodyAlpha) }
    }
    border.width: 1
    border.color: Cards.withAlpha(root.palette.border, root.palette.borderAlpha)
    Behavior on width { NumberAnimation { duration: 165; easing.type: Easing.OutCubic } }

    Column {
      id: content
      x: root.padding
      y: root.hasActions ? 11 : 7
      width: card.width - 2 * root.padding
      spacing: 1

      Row {
        id: headRow
        spacing: 7
        anchors.horizontalCenter: root.hasActions ? undefined : parent.horizontalCenter
        Rectangle {
          visible: root.palette.showsDot
          width: 6; height: 6; radius: 3
          anchors.verticalCenter: parent.verticalCenter
          color: Cards.dotColor(root.palette, root.isError)
        }
        Text {
          width: Math.min(Math.ceil(headMetrics.advanceWidth) + 1, content.width - root.dotSpace)
          text: root.headline
          wrapMode: Text.Wrap
          color: Cards.headlineColor(root.palette, root.isError)
          font: root.headFont
        }
      }
      Text {
        visible: root.hasDetail
        width: content.width
        horizontalAlignment: root.hasActions ? Text.AlignLeft : Text.AlignHCenter
        text: root.detail
        wrapMode: Text.Wrap
        color: Cards.withAlpha(root.palette.text, root.palette.detailAlpha)
        font: root.detailFont
      }
      Item { visible: root.hasActions; width: 1; height: 10 }
      Row {
        visible: root.hasActions
        layoutDirection: Qt.RightToLeft
        width: content.width
        spacing: 6
        PillCardButton {
          visible: root.primaryText !== ""
          primary: true
          palette: root.palette
          text: root.primaryText
          previewState: root.previewState
          onActivated: root.primaryClicked()
        }
        PillCardButton {
          visible: root.secondaryText !== ""
          palette: root.palette
          text: root.secondaryText
          onActivated: root.secondaryClicked()
        }
      }
    }
  }
}
