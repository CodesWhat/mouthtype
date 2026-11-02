import QtQuick
import "../../design"

// The last row of a capped list: how many rows are still hidden, and a click that reveals the next batch.
DesignRow {
  id: root

  property int hidden: 0
  property int batch: 120

  title: "Show more"
  detail: Math.min(batch, hidden) + " of " + hidden + " more"
  clickable: true
}
