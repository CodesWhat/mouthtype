import QtQuick
import "../design"
import "stats"

// The Stats page: a hero counter, today's tape, speaking speed and streak side by side, your day and High scores side by
// side. It asks control.py for `stats` whenever it becomes the shown page and draws backend.results.stats; the JSON shape is
// in tools/linux-desktop/stats.py. Page contract: see MouthtypeShell.qml.
Item {
  id: root

  property var backend: ({})
  property bool active: false
  signal request(string command, var args)

  // How often the shown page re-reads stats and moves the NOW marker.
  property int refreshInterval: 60000
  // Seconds since local midnight, refreshed with the stats while shown so the NOW marker keeps up.
  property int nowSeconds: secondsNow()

  readonly property var stats: backend && backend.results && backend.results.stats && backend.results.stats.version !== undefined ? backend.results.stats : null
  readonly property bool hasHistory: stats !== null && stats.has_history === true
  readonly property bool hasTape: stats !== null && stats.tape !== undefined && stats.tape.length > 0
  readonly property string failure: stats === null && backend && backend.error ? String(backend.error) : ""

  implicitHeight: column.implicitHeight

  function secondsNow() {
    var d = new Date()
    return d.getHours() * 3600 + d.getMinutes() * 60 + d.getSeconds()
  }

  function refresh() { request("stats", []) }

  onActiveChanged: if (active) { nowSeconds = secondsNow(); refresh() }
  Component.onCompleted: if (active) refresh()

  Timer {
    interval: root.refreshInterval
    running: root.active
    repeat: true
    onTriggered: {
      root.nowSeconds = root.secondsNow()
      if (!(root.backend && root.backend.busy)) root.refresh()
    }
  }

  Column {
    id: column
    width: parent.width
    spacing: 16

    DesignPageHeader {
      width: parent.width
      title: "Stats"
      summary: "Your numbers, kept on this machine."
    }

    // Nothing to draw yet: still loading, failed, or no takes at all.
    Rectangle {
      visible: !root.hasHistory && !root.hasTape
      width: parent.width
      height: visible ? message.implicitHeight + 32 : 0
      radius: Theme.cardRadius
      color: Theme.surface
      border.width: 1
      border.color: Theme.hair2

      Text {
        id: message
        x: 16
        y: 16
        width: parent.width - 32
        wrapMode: Text.Wrap
        color: Theme.ink2
        font: Type.sans(Type.body)
        text: root.failure !== "" ? root.failure :
              root.stats === null ? "Reading your history." :
              "No stats yet. Dictate something and your numbers show up here."
      }
    }

    // Only audio today, no transcripts: the tape alone, like the Mac.
    Tape {
      visible: root.stats !== null && !root.hasHistory && root.hasTape
      width: parent.width
      takes: root.stats ? root.stats.tape : []
      summary: root.stats ? root.stats.tape_summary : ({})
      nowSeconds: root.nowSeconds
    }

    Counter {
      visible: root.hasHistory
      width: parent.width
      stats: root.stats || ({})
    }

    Tape {
      visible: root.hasHistory
      width: parent.width
      takes: root.stats ? root.stats.tape : []
      summary: root.stats ? root.stats.tape_summary : ({})
      nowSeconds: root.nowSeconds
    }

    Item {
      id: upper
      visible: root.hasHistory
      width: parent.width
      readonly property bool side: width >= 560
      readonly property real each: (width - 12) / 2
      height: visible ? (side ? Math.max(speed.implicitHeight, streak.implicitHeight) : speed.implicitHeight + 12 + streak.implicitHeight) : 0

      SpeedMeter {
        id: speed
        width: upper.side ? upper.each : upper.width
        height: upper.side ? upper.height : implicitHeight
        speed: root.stats ? root.stats.speed : ({})
      }
      StreakDots {
        id: streak
        x: upper.side ? upper.each + 12 : 0
        y: upper.side ? 0 : speed.height + 12
        width: upper.side ? upper.each : upper.width
        height: upper.side ? upper.height : implicitHeight
        daily: root.stats ? root.stats.daily : []
        lit: root.stats ? root.stats.streak_lit : []
        streak: root.stats ? root.stats.streak : ({})
      }
    }

    Item {
      id: lower
      visible: root.hasHistory
      width: parent.width
      readonly property bool side: width >= 560
      readonly property real each: (width - 12) / 2
      height: visible ? (side ? Math.max(day.implicitHeight, scores.implicitHeight) : day.implicitHeight + 12 + scores.implicitHeight) : 0

      HourChart {
        id: day
        width: lower.side ? lower.each : lower.width
        height: lower.side ? lower.height : implicitHeight
        hourly: root.stats ? root.stats.hourly : []
        peakHour: root.stats ? root.stats.peak_hour : null
        windowDays: root.stats ? root.stats.hour_window_days : 30
      }
      HighScores {
        id: scores
        x: lower.side ? lower.each + 12 : 0
        y: lower.side ? 0 : day.height + 12
        width: lower.side ? lower.each : lower.width
        height: lower.side ? lower.height : implicitHeight
        scores: root.stats ? root.stats.high_scores : ({})
        today: root.stats ? root.stats.today : ""
      }
    }

    Text {
      visible: root.stats !== null && root.stats.history_limited === true && (root.hasHistory || root.hasTape)
      width: parent.width
      leftPadding: 4
      wrapMode: Text.Wrap
      color: Theme.ink3
      font: Type.sans(11)
      text: "History is limited to saved takes, so forgetting or pruning one lowers these numbers. Worked out on this machine. Nothing is sent anywhere."
    }
  }
}
