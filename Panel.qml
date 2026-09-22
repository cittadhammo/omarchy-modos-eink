import QtQuick
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "cittadhammo.modos-eink"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  property int selectedIndex: 0
  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string currentMode: service ? String(service.currentMode || "unknown") : "unknown"
  readonly property var modes: service && Array.isArray(service.modes) ? service.modes : []

  // One −/+ stepper button, themed like the mode rows.
  component StepperButton : BorderSurface {
    id: stepper
    property string glyph: "+"
    property var onStep: null
    width: Style.space(30)
    implicitHeight: Style.space(30)
    radius: Style.cornerRadius
    property bool hovered: stepperArea.containsMouse
    color: hovered ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
    borderSpec: Border.controlSpec(hovered ? "hover-cursor" : "normal", root.foreground, Color.accent)
    Text {
      anchors.centerIn: parent
      text: stepper.glyph
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    MouseArea {
      id: stepperArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (stepper.onStep) stepper.onStep()
    }
  }

  // Human label (device-menu style) plus the underlying technical enum name.
  // glider-api has no authoritative enum<->preset table, so both are shown.
  function labelFor(mode) {
    return service && service.modeLabel ? service.modeLabel(mode) : String(mode || "unknown")
  }

  function description(mode) {
    return service && service.modeDescription ? service.modeDescription(mode) : ""
  }

  function selectMode(mode) {
    if (service) service.setMode(mode)
  }

  function forceRedraw() {
    if (service) service.redraw()
  }

  onOpenedChanged: {
    if (opened && service) {
      service.refresh()
      var current = modes.indexOf(currentMode)
      if (current >= 0) selectedIndex = current
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (root.modes.length === 0) return
        var delta = dy !== 0 ? dy : dx
        root.selectedIndex = Math.max(0, Math.min(root.modes.length - 1, root.selectedIndex + delta))
      }
      onActivateRequested: {
        if (root.selectedIndex >= 0 && root.selectedIndex < root.modes.length)
          root.selectMode(root.modes[root.selectedIndex])
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        Row {
          width: parent.width
          spacing: Style.space(12)

          Text {
            text: "󰚝"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - parent.spacing - Style.space(36)
            spacing: Style.space(2)
            Text {
              text: "Modos Paper"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              text: root.currentMode === "unknown" ? "Current mode is not known yet"
                : "Current mode: " + root.labelFor(root.currentMode)
                  + ((root.service && String(root.service.modeSource || "").indexOf("local-state") === 0)
                    ? " (local state)" : "")
              color: Qt.darker(root.foreground, 1.45)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Row {
          id: refreshModeRow
          width: parent.width
          spacing: Style.space(12)

          Text {
            id: refreshTitle
            text: "REFRESH MODE"
            color: Qt.darker(root.foreground, 1.45)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: "(right-click the bar icon to force a refresh)"
            color: Qt.darker(root.foreground, 1.45)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
            width: parent.width - Style.space(96)
          }
        }

        Text {
          text: "Please refresh after changing mode"
          color: Qt.darker(root.foreground, 1.45)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.rightMargin: Style.space(96) - refreshTitle.implicitWidth - refreshModeRow.spacing
        }

        Repeater {
          model: root.modes
          delegate: BorderSurface {
            id: modeRow
            required property string modelData
            required property int index
            width: content.width
            implicitHeight: modeCopy.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            property bool selectedMode: root.currentMode === modelData
            property bool cursorMode: keyCatcher.activeFocus && root.selectedIndex === index
            property bool hovered: modeMouse.containsMouse
            color: selectedMode || cursorMode
              ? Style.selectedFillFor(root.foreground, Color.accent)
              : (hovered ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")
            borderSpec: selectedMode || cursorMode
              ? Border.controlSpec("selected", root.foreground, Color.accent)
              : Border.controlSpec(hovered ? "hover-cursor" : "normal", root.foreground, Color.accent)

            Column {
              id: modeCopy
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: parent.borderLeft + Style.space(10)
              anchors.rightMargin: parent.borderRight + Style.space(10)
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: root.labelFor(modelData)
                color: modeRow.selectedMode
                  ? Style.selectedStateColor(root.foreground, Color.accent) : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: modeRow.selectedMode
              }
              Text {
                width: parent.width
                text: modelData
                color: Qt.darker(root.foreground, 1.6)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                width: parent.width
                text: root.description(modelData)
                wrapMode: Text.Wrap
                color: Qt.darker(root.foreground, 1.45)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            MouseArea {
              id: modeMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.selectMode(modelData)
            }
          }
        }

        Text {
          visible: root.service && root.service.lastError !== ""
          width: parent.width
          text: root.service ? root.service.lastError : "Modos service is loading…"
          wrapMode: Text.Wrap
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          text: "TONE"
          color: Qt.darker(root.foreground, 1.45)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1
        }

        Repeater {
          model: [
            { kind: "lightness", label: "Lightness" },
            { kind: "contrast", label: "Contrast" }
          ]
          delegate: Row {
            id: toneRow
            required property var modelData
            width: content.width
            spacing: Style.space(8)
            property bool isLightness: modelData.kind === "lightness"
            property bool toneReady: root.service && root.service.toneAvailable
            property int value: root.service
              ? (isLightness ? root.service.lightness : root.service.contrast) : 0

            Text {
              text: toneRow.modelData.label
                + (toneRow.toneReady ? "" : " (read-back unavailable)")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
              width: content.width - Style.space(120)
            }

            StepperButton {
              glyph: "−"
              visible: toneRow.toneReady
              anchors.verticalCenter: parent.verticalCenter
              onStep: root.service && (toneRow.isLightness
                ? root.service.setLightness(root.service.lightness - 1)
                : root.service.setContrast(root.service.contrast - 1))
            }

            Text {
              text: toneRow.toneReady ? toneRow.value : "—"
              color: Qt.darker(root.foreground, 1.45)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
              width: Style.space(36)
              anchors.verticalCenter: parent.verticalCenter
            }

            StepperButton {
              glyph: "+"
              visible: toneRow.toneReady
              anchors.verticalCenter: parent.verticalCenter
              onStep: root.service && (toneRow.isLightness
                ? root.service.setLightness(root.service.lightness + 1)
                : root.service.setContrast(root.service.contrast + 1))
            }
          }
        }
      }
    }
  }
}