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
  // Shared width of the small label column (Lightness/Contrast and the
  // auto-clear rows) so the controls after it start on one vertical line.
  readonly property int labelColumnWidth: Style.space(84)
  readonly property string currentMode: service ? String(service.currentMode || "unknown") : "unknown"
  readonly property var modes: service && Array.isArray(service.modes) ? service.modes : []

  // One −/+ stepper button, themed like the mode rows.
  component StepperButton : BorderSurface {
    id: stepper
    property string glyph: "+"
    signal step()
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
      onClicked: stepper.step()
    }
  }

  // Label + −/value/+ group for one tone control; both groups share a line.
  component ToneGroup : Row {
    id: toneGroup
    property string label: ""
    property bool isLightness: true
    spacing: Style.space(6)
    property bool toneReady: root.service && root.service.toneAvailable
    property int value: root.service
      ? (toneGroup.isLightness ? root.service.lightness : root.service.contrast) : 0

    Text {
      text: toneGroup.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      width: root.labelColumnWidth
      elide: Text.ElideRight
      anchors.verticalCenter: parent.verticalCenter
    }

    StepperButton {
      glyph: "−"
      visible: toneGroup.toneReady
      anchors.verticalCenter: parent.verticalCenter
      onStep: root.service && (toneGroup.isLightness
        ? root.service.setLightness(root.service.lightness - 1)
        : root.service.setContrast(root.service.contrast - 1))
    }

    Text {
      text: toneGroup.toneReady ? toneGroup.value : "—"
      color: Qt.darker(root.foreground, 1.45)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
      width: Style.space(28)
      anchors.verticalCenter: parent.verticalCenter
    }

    StepperButton {
      glyph: "+"
      visible: toneGroup.toneReady
      anchors.verticalCenter: parent.verticalCenter
      onStep: root.service && (toneGroup.isLightness
        ? root.service.setLightness(root.service.lightness + 1)
        : root.service.setContrast(root.service.contrast + 1))
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
          visible: root.service && root.service.lastError !== ""
          width: parent.width
          text: root.service ? root.service.lastError : "Modos service is loading…"
          wrapMode: Text.Wrap
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
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

        // Both tone controls share one line: Lightness −/value/+ on the left,
        // Contrast −/value/+ right-aligned.
        Item {
          width: content.width
          height: Math.max(lightGroup.implicitHeight, contrastGroup.implicitHeight)

          ToneGroup {
            id: lightGroup
            label: "Lightness"
            isLightness: true
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          ToneGroup {
            id: contrastGroup
            label: "Contrast"
            isLightness: false
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // Auto Clear (anti-ghosting refresh) — every option shown as a
        // clickable chip with the active one highlighted, mirroring the OSD's
        // Auto Clear submenu. Interval applies to Fixed mode and the ghost
        // threshold to Adaptive, so each row only appears when it matters.
        Column {
          id: acSection
          visible: root.service && root.service.autoclearAvailable
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: [
              { field: "mode", label: "Clear", values: "acModeLabels", current: "acMode", always: true, showWhen: "" },
              { field: "interval", label: "Every", values: "acIntervalLabels", current: "acInterval", always: false, showWhen: "Fixed" },
              { field: "threshold", label: "Ghost", values: "acThresholdLabels", current: "acThreshold", always: false, showWhen: "Adaptive" }
            ]
            delegate: Row {
              id: acRow
              required property var modelData
              width: acSection.width
              spacing: Style.space(6)
              visible: acRow.modelData.always
                || (root.service && root.service.acMode === acRow.modelData.showWhen)

              // Labels and the current value come straight from the service so
              // rows update on every status poll without rebuilding the model.
              property var values: root.service ? root.service[acRow.modelData.values] : []
              property string current: root.service ? String(root.service[acRow.modelData.current] || "") : ""

              Text {
                text: acRow.modelData.label
                color: Qt.darker(root.foreground, 1.45)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                width: root.labelColumnWidth
                elide: Text.ElideRight
                anchors.verticalCenter: parent.verticalCenter
              }

              Repeater {
                model: acRow.values
                delegate: BorderSurface {
                  id: chip
                  required property string modelData
                  required property int index
                  width: chipLabel.implicitWidth + Style.space(16)
                  implicitHeight: Style.space(26)
                  radius: Style.cornerRadius
                  anchors.verticalCenter: parent.verticalCenter
                  property bool selected: acRow.current === chip.modelData
                  property bool hovered: chipMouse.containsMouse
                  color: selected
                    ? Style.selectedFillFor(root.foreground, Color.accent)
                    : (hovered ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")
                  borderSpec: selected
                    ? Border.controlSpec("selected", root.foreground, Color.accent)
                    : Border.controlSpec(hovered ? "hover-cursor" : "normal", root.foreground, Color.accent)

                  Text {
                    id: chipLabel
                    anchors.centerIn: parent
                    text: chip.modelData
                    color: chip.selected
                      ? Style.selectedStateColor(root.foreground, Color.accent) : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: chip.selected
                  }

                  MouseArea {
                    id: chipMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.service && root.service.setAutoclear(acRow.modelData.field, chip.modelData)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}