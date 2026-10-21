import QtQuick

// The bar-widget base. The real one owns the popup lifecycle; here the case sets opened directly.
Item {
  property string moduleName: ""
  property string ipcTarget: ""
  property bool manageIpc: true
  property bool opened: false
  property var bar: null

  function open() { opened = true }
  function close() { opened = false }
  function toggle() { opened = !opened }
  function switchPanel(direction) {}
}
