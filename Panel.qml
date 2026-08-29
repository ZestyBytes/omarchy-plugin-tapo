import QtQuick
import QtQuick.Layouts
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "CameraModel.js" as CameraModel

// Single-file bar-widget: a camera icon in the bar (BarIconButton) plus a
// floating popup (KeyboardPanel). The popup has two modes:
//  - view (default): each non-hidden camera as a live embedded RTSP video
//    (Qt Multimedia MediaPlayer + VideoOutput), decoding only while the
//    panel is open. Clicking a thumbnail opens the full stream in mpv,
//    tiled into the workspace.
//  - settings (cog icon): add/edit/hide/remove cameras and test their RTSP
//    connection, without ever touching cameras.json by hand.

Panel {
  id: root
  moduleName: "io.github.zestybytes.tapo-cameras"
  ipcTarget: "tapo-cameras"
  manageIpc: false

  // All configured cameras, hidden ones included — the settings editor's
  // source of truth. The view list below filters it for display.
  property var cameras: []
  readonly property var visibleCameras: cameras.filter(function (c) { return !c.hidden })
  property bool settingsMode: false

  readonly property string streamAppId: "tapo-camera-stream"
  // Deliberately outside the plugin's own directory: Omarchy hot-reloads
  // the whole plugin whenever a file under its plugin directory changes, so
  // saving settings from inside cameras.json living next to the QML files
  // used to retrigger a full reload of this widget on every edit. Old
  // installs get migrated on first load (see migrateLegacyConfig below).
  readonly property string configPath: Quickshell.env("HOME") + "/.local/state/omarchy/tapo-cameras/cameras.json"
  readonly property string legacyConfigPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.zestybytes.tapo-cameras/cameras.json"

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function reload() { configFile.reload() }
  function persist() { configFile.setText(CameraModel.serializeCameras(root.cameras)) }
  function scheduleSave() { saveTimer.restart() }

  // Per-keystroke edits mutate root.cameras[index] directly by index (not
  // through a delegate's `modelData`, which QML hands out as a copy rather
  // than a live reference — mutating that silently edits a throwaway
  // object) so the field the user is typing in never loses focus, and just
  // debounce a write. Actions that change which rows exist (add/remove/hide)
  // reassign `cameras` so the settings list and view list both react.
  function addCamera() {
    root.settingsMode = true
    root.cameras = root.cameras.concat([CameraModel.blankCamera()])
  }

  function removeCamera(index) {
    if (index < 0 || index >= root.cameras.length) return
    root.cameras = root.cameras.filter(function (_, i) { return i !== index })
    root.persist()
  }

  function toggleHidden(index) {
    if (index < 0 || index >= root.cameras.length) return
    root.cameras[index].hidden = !root.cameras[index].hidden
    root.cameras = root.cameras.slice()
    root.persist()
  }

  Timer {
    id: saveTimer
    interval: 500
    onTriggered: root.persist()
  }

  Component.onCompleted: {
    tileRuleProc.running = true
    migrateProc.running = true
  }

  // Makes mpv windows opened for camera streams tile into the layout
  // instead of floating, so they're not left as an unmanaged window.
  Process {
    id: tileRuleProc
    command: ["hyprctl", "keyword", "windowrulev2", "tile,class:^(" + root.streamAppId + ")$"]
  }

  // One-time move for installs from before cameras.json lived outside the
  // plugin directory: create the new state dir, and if a legacy config is
  // sitting where the plugin's own files are but nothing exists at the new
  // path yet, move it over. No-op on every later run.
  Process {
    id: migrateProc
    command: ["sh", "-c",
      "mkdir -p \"$(dirname '" + root.configPath + "')\" && " +
      "[ -f '" + root.configPath + "' ] || [ ! -f '" + root.legacyConfigPath + "' ] || " +
      "(cp '" + root.legacyConfigPath + "' '" + root.configPath + "' && rm '" + root.legacyConfigPath + "')"]
    onExited: configFile.reload()
  }

  // Settings persistence owns writes; external hand-edits are picked up on
  // the next open (reload() below) rather than watched live, so a save from
  // here never races a filesystem-change reload mid-edit. Lives outside the
  // plugin directory — see configPath above.
  FileView {
    id: configFile
    path: root.configPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.cameras = CameraModel.parseCameras(text())
    onLoadFailed: root.cameras = []
  }

  IpcHandler {
    enabled: root.manageIpc === false
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  function openStream(camera) {
    streamProcess.launch(camera)
  }

  Process {
    id: streamProcess
    function launch(camera) {
      command = ["mpv", "--no-cache", "--untimed", "--profile=low-latency",
                 "--wayland-app-id=" + root.streamAppId,
                 "--title=" + camera.name, CameraModel.rtspUrl(camera)]
      running = true
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "" // fa-camera
    slotSize: Style.bar.statusSlot
    tooltipText: "Tapo Cameras"
    onPressed: {
      root.reload()
      root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: Style.space(340)
    // Buffer covers the header row, the empty-state text/add-camera button
    // (view mode) or the help text (settings mode), plus the outer margins
    // on both edges. Deliberately generous — both lists sit in a Flickable,
    // so a little unused space at the bottom beats clipping the last row.
    contentHeight: Math.min(Style.space(560), Style.space(118) +
      (root.settingsMode ? settingsColumn.implicitHeight : cameraColumn.implicitHeight))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
    }

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.space(16)
      spacing: Style.space(10)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Text {
          text: root.settingsMode ? "Camera Settings" : "Tapo Cameras"
          color: root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          Layout.fillWidth: true
        }

        PanelActionButton {
          iconText: root.settingsMode ? "" : "" // fa-arrow-left : fa-cog
          tooltipText: root.settingsMode ? "Back" : "Camera settings"
          foreground: root.barForeground
          onClicked: root.settingsMode = !root.settingsMode
        }
      }

      // -------------------------------------------------------- view mode

      Text {
        visible: !root.settingsMode && root.visibleCameras.length === 0
        text: root.cameras.length === 0
          ? "No cameras added yet."
          : "All cameras are hidden. Open settings to show one."
        color: Qt.darker(root.barForeground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
      }

      PanelActionButton {
        visible: !root.settingsMode && root.cameras.length === 0
        iconText: " + Add your first camera"
        bordered: true
        foreground: root.barForeground
        implicitWidth: Style.space(220)
        onClicked: root.addCamera()
      }

      Flickable {
        visible: !root.settingsMode
        Layout.fillWidth: true
        Layout.fillHeight: true
        contentWidth: width
        contentHeight: cameraColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
          id: cameraColumn
          width: parent.width
          spacing: Style.space(14)

        Repeater {
          model: root.settingsMode ? [] : root.visibleCameras

          delegate: ColumnLayout {
            id: cameraDelegate
            Layout.fillWidth: true
            spacing: Style.space(4)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                text: modelData.name
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                Layout.fillWidth: true
                elide: Text.ElideRight
              }

              Text {
                text: modelData.ip
                color: Qt.darker(root.barForeground, 1.6)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              Layout.fillWidth: true
              implicitHeight: Style.space(160)
              radius: Style.space(8)
              clip: true
              color: Qt.darker(root.barForeground, 10)
              border.color: previewMouse.containsMouse ? root.barForeground : "transparent"
              border.width: Style.space(1)

              // Decoding only happens while this camera is actually on
              // screen: the Loader tears the player down when the panel
              // closes or settings mode is opened, instead of leaving RTSP
              // connections and decoders running in the background.
              Loader {
                anchors.fill: parent
                active: root.opened && !root.settingsMode

                sourceComponent: Item {
                  anchors.fill: parent

                  MediaPlayer {
                    id: player
                    source: modelData.url
                    autoPlay: true
                    loops: MediaPlayer.Infinite
                    videoOutput: videoOutput
                  }

                  VideoOutput {
                    id: videoOutput
                    anchors.fill: parent
                    fillMode: VideoOutput.PreserveAspectCrop
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: player.mediaStatus === MediaPlayer.Loading || player.mediaStatus === MediaPlayer.NoMedia
                    text: "Connecting…"
                    color: Qt.darker(root.barForeground, 1.6)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: player.error !== MediaPlayer.NoError
                    text: "Preview unavailable"
                    color: Qt.darker(root.barForeground, 1.6)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              MouseArea {
                id: previewMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.openStream(modelData)
              }
            }
          }
        }
        }
      }

      // ---------------------------------------------------- settings mode

      Flickable {
        visible: root.settingsMode
        Layout.fillWidth: true
        Layout.fillHeight: true
        contentWidth: width
        contentHeight: settingsColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
          id: settingsColumn
          width: parent.width
          spacing: Style.space(10)

          Text {
            text: "Camera account credentials come from the Tapo app: open the camera, tap the gear icon, then Advanced Settings → Camera Account. That's a separate login from your TP-Link cloud account — create one there if you haven't."
            color: Qt.darker(root.barForeground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
          }

          Repeater {
            model: root.settingsMode ? root.cameras : []

            delegate: Rectangle {
              id: settingsRow
              required property var modelData
              required property int index
              Layout.fillWidth: true
              implicitHeight: fieldsColumn.implicitHeight + Style.space(24)
              radius: Style.space(8)
              color: Qt.darker(root.barForeground, 10)

              property string testState: "idle" // idle | testing | ok | fail
              property string testMessage: ""

              function runTest() {
                testState = "testing"
                testMessage = ""
                testProc.command = ["timeout", "6", "ffprobe", "-rtsp_transport", "tcp",
                  "-v", "error", "-show_entries", "stream=codec_name",
                  "-of", "csv=p=0", CameraModel.rtspUrl(settingsRow.modelData)]
                testProc.running = true
              }

              Process {
                id: testProc
                property string capturedOut: ""
                stdout: StdioCollector {
                  waitForEnd: true
                  onStreamFinished: testProc.capturedOut = String(text || "").trim()
                }
                onExited: function (exitCode) {
                  var ok = exitCode === 0 && testProc.capturedOut !== ""
                  settingsRow.testState = ok ? "ok" : "fail"
                  settingsRow.testMessage = ok ? "Connected" : "Couldn't connect"
                }
              }

              ColumnLayout {
                id: fieldsColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(12)
                spacing: Style.space(8)

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(4)

                  TextField {
                    Layout.fillWidth: true
                    text: settingsRow.modelData.name
                    placeholderText: "Name (e.g. Front Door)"
                    onTextChanged: { root.cameras[settingsRow.index].name = text; root.scheduleSave() }
                  }

                  Rectangle {
                    id: eyeButton
                    implicitWidth: Style.space(26)
                    implicitHeight: Style.space(26)
                    radius: Style.space(6)
                    color: eyeMouse.containsMouse ? Qt.darker(root.barForeground, 6) : "transparent"

                    Text {
                      anchors.centerIn: parent
                      text: settingsRow.modelData.hidden ? "" : "" // fa-eye-slash : fa-eye
                      color: root.barForeground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.icon
                    }

                    MouseArea {
                      id: eyeMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      onClicked: root.toggleHidden(settingsRow.index)
                    }
                  }

                  Rectangle {
                    id: trashButton
                    implicitWidth: Style.space(26)
                    implicitHeight: Style.space(26)
                    radius: Style.space(6)
                    color: trashMouse.containsMouse ? Qt.darker(root.bar ? root.bar.urgent : Color.urgent, 2.2) : "transparent"

                    Text {
                      anchors.centerIn: parent
                      text: "" // fa-trash
                      color: trashMouse.containsMouse ? (root.bar ? root.bar.urgent : Color.urgent) : root.barForeground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.icon
                    }

                    MouseArea {
                      id: trashMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      onClicked: root.removeCamera(settingsRow.index)
                    }
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(4)

                  TextField {
                    Layout.fillWidth: true
                    text: settingsRow.modelData.ip
                    placeholderText: "IP address"
                    onTextChanged: { root.cameras[settingsRow.index].ip = text; root.scheduleSave() }
                  }

                  TextField {
                    implicitWidth: Style.space(64)
                    text: String(settingsRow.modelData.port || 554)
                    placeholderText: "554"
                    validator: IntValidator { bottom: 1; top: 65535 }
                    onTextChanged: { root.cameras[settingsRow.index].port = parseInt(text, 10) || 554; root.scheduleSave() }
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(4)

                  TextField {
                    Layout.fillWidth: true
                    text: settingsRow.modelData.username
                    placeholderText: "Camera account username"
                    onTextChanged: { root.cameras[settingsRow.index].username = text; root.scheduleSave() }
                  }

                  TextField {
                    Layout.fillWidth: true
                    password: true
                    text: settingsRow.modelData.password
                    placeholderText: "Camera account password"
                    onTextChanged: { root.cameras[settingsRow.index].password = text; root.scheduleSave() }
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(4)

                  Text {
                    text: "Stream"
                    color: Qt.darker(root.barForeground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  TextField {
                    implicitWidth: Style.space(90)
                    text: settingsRow.modelData.stream
                    placeholderText: "stream1"
                    onTextChanged: { root.cameras[settingsRow.index].stream = text; root.scheduleSave() }
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  Text {
                    Layout.fillWidth: true
                    text: settingsRow.testState === "testing" ? "Testing…" : settingsRow.testMessage
                    color: settingsRow.testState === "ok" ? "#8bc34a"
                      : settingsRow.testState === "fail" ? (root.bar ? root.bar.urgent : Color.urgent)
                      : Qt.darker(root.barForeground, 1.6)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  PanelActionButton {
                    iconText: "Test"
                    tooltipText: "Test RTSP connection"
                    foreground: root.barForeground
                    bordered: true
                    implicitWidth: Style.space(56)
                    onClicked: settingsRow.runTest()
                  }
                }
              }
            }
          }

          PanelActionButton {
            iconText: " + Add camera"
            bordered: true
            foreground: root.barForeground
            implicitWidth: Style.space(140)
            onClicked: root.addCamera()
          }
        }
      }
    }
  }
}
