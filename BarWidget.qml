import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "cittadhammo.modos-eink"

  // Third-party bar widgets are not injected with their matching service;
  // the installed Omarchy 4.0.2 bar deliberately exposes its shell instead.
  readonly property var modosService: bar && bar.shell && bar.shell.serviceFor
    ? bar.shell.serviceFor(moduleName) : null
  readonly property string label: modosService && modosService.connected
    ? modosService.modeLabel(modosService.currentMode) : "Modos off"

  // BarWidget.qml is the panel's host, matching Omarchy's clock and weather
  // widgets. The service itself remains the one shared singleton.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function injectPanel() {
    var panel = panelLoader.item
    if (!panel) return
    if ("bar" in panel) panel.bar = root.bar
    if ("settings" in panel) panel.settings = root.settings
    if ("anchorItem" in panel) panel.anchorItem = button
    if ("hostWidget" in panel) panel.hostWidget = root
    if ("service" in panel) panel.service = root.modosService
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onModosServiceChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // WidgetButton forwards LeftButton | RightButton | MiddleButton, so the
    // right-click branch below receives Qt.RightButton.
    text: "󰚝 " + root.label
    tooltipText: root.modosService && root.modosService.lastError
      ? root.modosService.lastError + " · right-click forces a screen refresh"
      : "Left-click: choose mode. Right-click: force screen refresh."
    active: root.modosService && root.modosService.connected
    onPressed: function(button) {
      if (button === Qt.RightButton && root.modosService) root.modosService.redraw()
      else root.togglePanel()
    }
  }
}