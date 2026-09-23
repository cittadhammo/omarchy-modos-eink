import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // Injected by omarchy-shell. BarWidget.qml obtains this singleton through
  // root.bar.shell.serviceFor("cittadhammo.modos-eink").
  property var shell: null
  property bool connected: false
  property string currentMode: "unknown"
  property string modeSource: ""
  property int lightness: 0
  property int contrast: 0
  property bool toneAvailable: false
  property var lightnessRange: [-3, 3]
  property var contrastRange: [-1, 6]
  // Auto Clear state (read back from the device; empty strings when unknown).
  property string acMode: ""
  property string acInterval: ""
  property string acThreshold: ""
  property bool autoclearAvailable: false
  property var acModeLabels: []
  property var acIntervalLabels: []
  property var acThresholdLabels: []
  property string lastError: "Checking Modos display…"
  property var modes: []
  property var modeLabels: ({})
  property var modeDescriptions: ({})
  property bool refreshing: false
  property string _statusOutput: ""
  property string _statusError: ""
  property string _actionOutput: ""
  property string _actionError: ""
  readonly property string helperPath: String(Qt.resolvedUrl("modosctl")).replace("file://", "")

  // Human-facing name for a mode (e.g. "Reading" for FastGrey-family modes),
  // falling back to the technical enum name so the underlying value is never
  // hidden. The device menu and glider-api expose different naming schemes;
  // both stay visible in the panel.
  function modeLabel(mode) {
    var mapped = root.modeLabels[String(mode)]
    return String(mapped || mode || "unknown")
  }

  function modeDescription(mode) {
    return String(root.modeDescriptions[String(mode)] || "Refresh mode provided by glider-api.")
  }

  function parseResult(raw, fallbackError) {
    try {
      var result = JSON.parse(raw)
      connected = result.connected === true
      if (Array.isArray(result.modes)) modes = result.modes
      if (result.modeLabels && typeof result.modeLabels === "object") modeLabels = result.modeLabels
      if (result.modeDescriptions && typeof result.modeDescriptions === "object") modeDescriptions = result.modeDescriptions
      if (Array.isArray(result.lightnessRange) && result.lightnessRange.length === 2) lightnessRange = result.lightnessRange
      if (Array.isArray(result.contrastRange) && result.contrastRange.length === 2) contrastRange = result.contrastRange
      if (Array.isArray(result.acModes)) acModeLabels = result.acModes
      if (Array.isArray(result.acIntervals)) acIntervalLabels = result.acIntervals
      if (Array.isArray(result.acThresholds)) acThresholdLabels = result.acThresholds
      if (result.autoclear && typeof result.autoclear === "object") {
        autoclearAvailable = true
        acMode = String(result.autoclear.mode)
        acInterval = String(result.autoclear.interval)
        acThreshold = String(result.autoclear.threshold)
      } else if (result.ok === true) {
        // Firmware without auto-clear read-back.
        autoclearAvailable = false
      }
      if (result.tone && typeof result.tone === "object") {
        toneAvailable = true
        lightness = parseInt(result.tone.lightness, 10)
        contrast = parseInt(result.tone.contrast, 10)
      } else if (result.ok === true) {
        // Firmware without tone read-back keeps the last known values.
        toneAvailable = false
      }
      if (result.modeSource) modeSource = String(result.modeSource)
      if (result.ok === true) {
        if (result.mode) currentMode = String(result.mode)
        lastError = ""
      } else {
        lastError = String(result.error || fallbackError)
      }
    } catch (error) {
      connected = false
      lastError = fallbackError || "Invalid response from modosctl"
    }
  }

  function refresh() {
    if (statusProcess.running) return
    _statusOutput = ""
    _statusError = ""
    refreshing = true
    statusProcess.command = [helperPath, "status"]
    statusProcess.running = true
  }

  function setMode(mode) {
    if (actionProcess.running || !mode) return
    _actionOutput = ""
    _actionError = ""
    actionProcess.command = [helperPath, "set-mode", String(mode)]
    actionProcess.running = true
  }

  function clampInt(value, range) {
    var lo = parseInt(range[0], 10)
    var hi = parseInt(range[1], 10)
    return Math.max(lo, Math.min(hi, Math.round(value)))
  }

  // Optimistically applies the new value, then confirms via the helper's
  // device read-back (a failed run falls back to the next status poll).
  function setLightness(value) {
    if (actionProcess.running) return
    var v = clampInt(value, lightnessRange)
    if (toneAvailable && v === lightness) return
    lightness = v
    _actionOutput = ""
    _actionError = ""
    actionProcess.command = [helperPath, "set-lightness", String(v)]
    actionProcess.running = true
  }

  function setContrast(value) {
    if (actionProcess.running) return
    var v = clampInt(value, contrastRange)
    if (toneAvailable && v === contrast) return
    contrast = v
    _actionOutput = ""
    _actionError = ""
    actionProcess.command = [helperPath, "set-contrast", String(v)]
    actionProcess.running = true
  }

  // Force a hard full-screen redraw to clear ghosting. Independent of the
  // connection/status poll and of the mode setter.
  function redraw() {
    if (actionProcess.running) return
    _actionOutput = ""
    _actionError = ""
    actionProcess.command = [helperPath, "redraw"]
    actionProcess.running = true
  }

  // Set one auto-clear setting by human label (e.g. Adaptive, 5 min, Often);
  // the helper reads the other two fields from the device so nothing else
  // changes. The follow-up status refresh confirms the new values.
  function setAutoclear(field, value) {
    if (actionProcess.running || !field || !value) return
    _actionOutput = ""
    _actionError = ""
    actionProcess.command = [helperPath, "set-autoclear", String(field), String(value)]
    actionProcess.running = true
  }

  Process {
    id: statusProcess
    running: false
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function(exitCode) {
      root.refreshing = false
      root.parseResult(String(statusStdout.text || root._statusOutput || ""),
        String(statusStderr.text || root._statusError || "Modos status check failed").trim())
    }
  }

  Process {
    id: actionProcess
    running: false
    stdout: StdioCollector { id: actionStdout; waitForEnd: true; onStreamFinished: root._actionOutput = text }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true; onStreamFinished: root._actionError = text }
    onExited: function(exitCode) {
      root.parseResult(String(actionStdout.text || root._actionOutput || ""),
        String(actionStderr.text || root._actionError || "Mode change failed").trim())
      if (exitCode === 0) root.refresh()
    }
  }

  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}