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
  // 1 camera fills the width; 2+ tile two-across (2x1, 2x2, 2x3, ...).
  readonly property int gridColumns: visibleCameras.length > 1 ? 2 : 1
  property bool settingsMode: false
  property bool showSettingsHelp: false

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

  // ------------------------------------------------- settings row reorder
  //
  // Rows normally stack at variable heights (collapsed vs. expanded).
  // Reassigning `cameras` mid-drag to actually reorder it would rebuild
  // every Repeater delegate — including the one currently being dragged,
  // which would kill the gesture — so during a drag every row (dragged one
  // excepted) is repositioned purely visually via dragFromIndex/dragToIndex,
  // and the array is only reordered once, on release.
  property int dragFromIndex: -1
  property int dragToIndex: -1
  readonly property real rowSpacingPx: Style.space(8)
  readonly property real collapsedRowHeight: Style.space(48)

  function settingsRowHeight(idx) {
    var item = settingsRepeater.itemAt(idx)
    return item ? item.height : root.collapsedRowHeight
  }

  function settingsRowY(idx) {
    var y = 0
    for (var i = 0; i < idx; i++) y += settingsRowHeight(i) + root.rowSpacingPx
    return y
  }

  function settingsRowsTotalHeight() {
    if (root.cameras.length === 0) return 0
    var total = 0
    for (var i = 0; i < root.cameras.length; i++) total += settingsRowHeight(i)
    return total + root.rowSpacingPx * (root.cameras.length - 1)
  }

  // Where row `idx` visually sits while a drag is in progress: shifted by
  // one slot if it's between the drag's start and current-hover position.
  function dragVisualSlot(idx) {
    if (root.dragFromIndex < 0 || idx === root.dragFromIndex) return idx
    if (root.dragFromIndex < root.dragToIndex && idx > root.dragFromIndex && idx <= root.dragToIndex) return idx - 1
    if (root.dragFromIndex > root.dragToIndex && idx >= root.dragToIndex && idx < root.dragFromIndex) return idx + 1
    return idx
  }

  function dragSlotY(slot) { return slot * (root.collapsedRowHeight + root.rowSpacingPx) }

  function collapseAllSettingsRows() {
    for (var i = 0; i < settingsRepeater.count; i++) {
      var item = settingsRepeater.itemAt(i)
      if (item) item.expanded = false
    }
  }

  function beginRowDrag(index) {
    root.collapseAllSettingsRows()
    root.dragFromIndex = index
    root.dragToIndex = index
  }

  function updateRowDrag(currentY) {
    if (root.dragFromIndex < 0) return
    var slotHeight = root.collapsedRowHeight + root.rowSpacingPx
    var slot = Math.round(currentY / slotHeight)
    root.dragToIndex = Math.max(0, Math.min(root.cameras.length - 1, slot))
  }

  function endRowDrag() {
    if (root.dragFromIndex >= 0 && root.dragToIndex >= 0 && root.dragFromIndex !== root.dragToIndex) {
      var arr = root.cameras.slice()
      var moved = arr.splice(root.dragFromIndex, 1)[0]
      arr.splice(root.dragToIndex, 0, moved)
      root.cameras = arr
      root.persist()
    }
    root.dragFromIndex = -1
    root.dragToIndex = -1
  }

  Timer {
    id: saveTimer
    interval: 500
    onTriggered: root.persist()
  }

  property bool mpvAvailable: true
  property bool ffprobeAvailable: true

  Component.onCompleted: {
    tileRuleProc.running = true
    migrateProc.running = true
    checkMpvProc.running = true
    checkFfprobeProc.running = true
  }

  // -------------------------------------------- offline/online notifications
  //
  // Runs regardless of whether the panel is open — that's the whole point
  // of a notification. Checks run one camera at a time through a single
  // Process (reusing it for concurrent checks would just no-op, the same
  // bug openStream() used to have) and only ever fire a notification on an
  // actual state *change*, never for a camera that's simply always offline
  // (an unconfigured stub, or one you know is down), and never on the very
  // first check each session (nothing to compare against yet).
  property var cameraOnlineState: ({})
  property var offlineCheckQueue: []

  Timer {
    id: offlineCheckTimer
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.startOfflineCheckRound()
  }

  function startOfflineCheckRound() {
    if (!root.ffprobeAvailable) return
    root.offlineCheckQueue = root.visibleCameras.filter(function (c) { return c.ip })
    root.runNextOfflineCheck()
  }

  function runNextOfflineCheck() {
    if (offlineCheckProc.running || root.offlineCheckQueue.length === 0) return
    offlineCheckProc.currentCamera = root.offlineCheckQueue.shift()
    offlineCheckProc.capturedOut = ""
    offlineCheckProc.command = ["timeout", "8", "ffprobe", "-rtsp_transport", "tcp", "-v", "error",
      "-show_entries", "stream=codec_name", "-of", "csv=p=0", CameraModel.rtspUrl(offlineCheckProc.currentCamera)]
    offlineCheckProc.running = true
  }

  function noteOnlineState(camera, isOnline) {
    var previous = root.cameraOnlineState[camera.name]
    root.cameraOnlineState[camera.name] = isOnline
    if (previous === undefined || previous === isOnline) return
    if (isOnline) {
      Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Tapo Cameras",
        "-u", "low", camera.name + " is back online"])
    } else {
      Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Tapo Cameras",
        "-u", "normal", camera.name + " is offline", "Couldn't reach its RTSP stream."])
    }
  }

  Process {
    id: offlineCheckProc
    property var currentCamera: null
    property string capturedOut: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: offlineCheckProc.capturedOut = String(text || "").trim()
    }
    onExited: function (exitCode) {
      if (offlineCheckProc.currentCamera) {
        root.noteOnlineState(offlineCheckProc.currentCamera, exitCode === 0 && offlineCheckProc.capturedOut !== "")
      }
      offlineCheckProc.currentCamera = null
      root.runNextOfflineCheck()
    }
  }

  // Makes mpv windows opened for camera streams tile into the layout
  // instead of floating, so they're not left as an unmanaged window.
  Process {
    id: tileRuleProc
    command: ["hyprctl", "keyword", "windowrulev2", "tile,class:^(" + root.streamAppId + ")$"]
  }

  // mpv/ffmpeg aren't hard dependencies of Omarchy itself, so a fresh
  // install of this plugin can easily be missing one. Surface that as a
  // banner instead of a click that silently does nothing.
  Process {
    id: checkMpvProc
    command: ["sh", "-c", "command -v mpv"]
    onExited: function (exitCode) { root.mpvAvailable = exitCode === 0 }
  }

  Process {
    id: checkFfprobeProc
    command: ["sh", "-c", "command -v ffprobe"]
    onExited: function (exitCode) { root.ffprobeAvailable = exitCode === 0 }
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

  // Overrides Panel's base open/close/toggle so every caller — the bar
  // icon, IPC, a keybind — reloads from disk before showing, instead of
  // risking a stale camera list if cameras.json changed since last open.
  // Also resets both Flickables' scroll position: they're hidden rather
  // than destroyed when the panel closes, so a scroll from an earlier,
  // shorter-panel session otherwise stuck around and made the next open
  // look like it needed scrolling even after a height fix landed.
  function open() {
    root.reload()
    // Blocks until the reload's file read actually completes, so
    // root.cameras (and everything sized from it — the grid column count,
    // the panel's height) reflects real data before the window is shown.
    // Without this, show() could run while the read was still in flight,
    // and this popup's window sizes itself once at show time and never
    // grows afterward — a race that looked identical to "not tall enough"
    // no matter how generous the height formula was.
    configFile.waitForJob()
    root.controller.show()
  }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  IpcHandler {
    enabled: root.manageIpc === false
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  // execDetached, not a shared Process: a Process element's `running = true`
  // is a no-op while it's already running, so reusing one meant clicking a
  // second camera while the first stream was still open did nothing. Each
  // call here spawns its own independent mpv instance.
  function openStream(camera) {
    var args = ["mpv", "--no-cache", "--untimed", "--profile=low-latency",
      "--wayland-app-id=" + root.streamAppId, "--title=" + camera.name]
    // PTZ arrows for the tiled view: handled entirely inside mpv itself
    // (see onvif-ptz-osc.lua) rather than a separate overlay window kept
    // in sync with this one, which is what made the old grid-preview
    // arrows laggy in the first place.
    if (camera.ptz !== false) {
      args.push("--script=" + root.pluginDir + "/onvif-ptz-osc.lua")
      args.push("--script-opts=onvifptz-script=" + root.pluginDir + "/onvif-ptz.sh"
        + ",onvifptz-host=" + camera.ip
        + ",onvifptz-user=" + camera.username
        + ",onvifptz-pass=" + camera.password)
    }
    args.push(CameraModel.rtspUrl(camera))
    Quickshell.execDetached(args)
  }

  // Bundled alongside Panel.qml — path matches this plugin's own install
  // directory, same convention as legacyConfigPath above. Used to locate
  // onvif-ptz.sh and onvif-ptz-osc.lua, passed into mpv above.
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.zestybytes.tapo-cameras"

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "" // fa-video
    slotSize: Style.bar.statusSlot
    tooltipText: "Tapo Cameras"
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: !root.settingsMode && root.gridColumns > 1 ? Style.space(520) : Style.space(340)
    // Base buffer covers the header row + outer margins; extra is added
    // only for rows that are actually visible right now (the missing-
    // dependency banner, the empty-state text + add-camera button) so a
    // populated camera/settings list doesn't carry padding meant for those.
    //
    // Camera view: uncapped, no internal scroll — sized to fit every row
    // exactly, however many cameras there are. Settings keeps a cap with a
    // Flickable as a fallback, since scrolling a long edit-everything list
    // is reasonable in a way scrolling a camera you opened this for is not.
    contentHeight: root.settingsMode
      ? Style.space(70) + settingsColumn.implicitHeight + Style.space(24)
      : Style.space(70) +
        (root.mpvAvailable && root.ffprobeAvailable ? 0 : Style.space(30)) +
        (root.visibleCameras.length === 0 ? Style.space(56) : 0) +
        cameraColumn.implicitHeight +
        (root.visibleCameras.length > 0 ? Style.space(24) : 0) // breathing room under the last row

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
          visible: root.settingsMode
          iconText: "" // fa-info-circle
          tooltipText: "About camera accounts"
          foreground: root.showSettingsHelp ? (root.bar ? root.bar.urgent : Color.urgent) : root.barForeground
          onClicked: root.showSettingsHelp = !root.showSettingsHelp
        }

        PanelActionButton {
          iconText: root.settingsMode ? "" : "" // fa-arrow-left : fa-cog
          tooltipText: root.settingsMode ? "Back" : "Camera settings"
          foreground: root.barForeground
          onClicked: root.settingsMode = !root.settingsMode
        }
      }

      Text {
        visible: !root.mpvAvailable || !root.ffprobeAvailable
        text: {
          var missing = []
          if (!root.mpvAvailable) missing.push("mpv")
          if (!root.ffprobeAvailable) missing.push("ffprobe (from ffmpeg)")
          return "Missing " + missing.join(" and ") + " — install " +
            (missing.length > 1 ? "them" : "it") + " to use this plugin fully."
        }
        color: root.bar ? root.bar.urgent : Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
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

      Rectangle {
        visible: !root.settingsMode && root.cameras.length === 0
        Layout.fillWidth: true
        implicitHeight: Style.space(34)
        radius: Style.space(6)
        color: addFirstMouse.containsMouse ? Qt.darker(root.barForeground, 6) : "transparent"
        border.color: root.barForeground
        border.width: Style.space(1)

        Text {
          anchors.centerIn: parent
          text: "+ Add your first camera"
          color: root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          id: addFirstMouse
          anchors.fill: parent
          hoverEnabled: true
          onClicked: root.addCamera()
        }
      }

      // No Flickable here on purpose: the panel's contentHeight above is
      // uncapped for this view specifically so it always sizes to fit
      // every row exactly, so wrapping this in a scrollable area would
      // never actually have anything to scroll to under normal use.
      Item {
        visible: !root.settingsMode
        Layout.fillWidth: true
        implicitHeight: cameraColumn.implicitHeight

        GridLayout {
          id: cameraColumn
          width: parent.width
          columns: root.gridColumns
          columnSpacing: Style.space(14)
          rowSpacing: Style.space(14)

        Repeater {
          // Always the full list, even while settings is showing — the
          // outer Item just hides it (visible above). Emptying the model
          // here used to destroy and recreate every MediaPlayer/RTSP
          // connection on every trip into and back out of settings, even
          // for cameras nothing was changed on.
          model: root.visibleCameras

          delegate: ColumnLayout {
            id: cameraDelegate
            // Named alias for the outer Repeater's implicit `modelData`
            // (the camera), so the PTZ direction-pad Repeater further down
            // — whose own `modelData` shadows this one — can still reach
            // it unambiguously.
            property var camera: modelData
            Layout.fillWidth: true
            // Without this, GridLayout can size a column from its cell's
            // own content width — here, the short "Preview unavailable"
            // text on an unconfigured camera — instead of splitting the
            // available width evenly between columns like fillWidth alone
            // implies.
            Layout.preferredWidth: 0
            spacing: Style.space(4)
            // Fixed, not derived from the name/ip row's text-metrics-based
            // implicitHeight: that needs a layout pass to settle, but the
            // popup window snapshots its size once when it opens (see the
            // settingsRow comment below) — a reactive height here caused
            // the same "have to scroll to see everything" undersizing.
            implicitHeight: (root.gridColumns > 1 ? Style.space(120) : Style.space(160)) + Style.space(40)

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
              id: previewCell
              Layout.fillWidth: true
              implicitHeight: root.gridColumns > 1 ? Style.space(120) : Style.space(160)
              radius: Style.space(8)
              clip: true
              color: Qt.darker(root.barForeground, 10)
              border.color: previewMouse.containsMouse ? root.barForeground : "transparent"
              border.width: Style.space(1)

              // Decoding only happens while the panel is actually open: the
              // Loader tears the player down when it closes, instead of
              // leaving RTSP connections and decoders running in the
              // background. It stays active while settings mode is showing
              // (the grid is just hidden, not torn down) so switching into
              // settings and back doesn't force every camera to reconnect
              // from scratch for an edit to just one of them.
              Loader {
                anchors.fill: parent
                active: root.opened

                sourceComponent: Item {
                  anchors.fill: parent

                  MediaPlayer {
                    id: player
                    source: modelData.previewUrl
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

              // Pan/tilt used to have a hover-revealed arrow overlay right
              // here, but sitting on top of the live VideoOutput made the
              // already-decoding preview flicker, and PTZ on a thumbnail
              // you're not actually watching full-size isn't that useful
              // anyway. It lives in the tiled mpv view instead now — see
              // openStream() and onvif-ptz-osc.lua.
            }
          }
        }
        }
      }

      // ---------------------------------------------------- settings mode

      // No Flickable, same reasoning as the camera view above: the panel's
      // contentHeight is sized to fit this exactly, so there'd be nothing
      // to scroll to.
      Item {
        visible: root.settingsMode
        Layout.fillWidth: true
        implicitHeight: settingsColumn.implicitHeight

        ColumnLayout {
          id: settingsColumn
          width: parent.width
          spacing: Style.space(10)

          Text {
            visible: root.showSettingsHelp
            text: "Camera account credentials come from the Tapo app: open the camera, tap the gear icon, then Advanced Settings → Camera Account. That's a separate login from your TP-Link cloud account — create one there if you haven't."
            color: Qt.darker(root.barForeground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
          }

          Item {
            id: reorderArea
            Layout.fillWidth: true
            implicitHeight: root.dragFromIndex >= 0
              ? Math.max(0, root.dragSlotY(root.cameras.length) - root.rowSpacingPx)
              : root.settingsRowsTotalHeight()

          Repeater {
            id: settingsRepeater
            model: root.settingsMode ? root.cameras : []

            delegate: Rectangle {
              id: settingsRow
              required property var modelData
              required property int index
              width: reorderArea.width
              z: dragArea.drag.active ? 100 : 0

              Binding {
                target: settingsRow
                property: "y"
                value: root.dragFromIndex >= 0
                  ? root.dragSlotY(root.dragVisualSlot(settingsRow.index))
                  : root.settingsRowY(settingsRow.index)
                when: !dragArea.drag.active
              }
              Behavior on y {
                enabled: !dragArea.drag.active
                NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
              }

              // Bound to rowContent's real implicitHeight (see below), not a
              // fixed guess: a hardcoded constant here had to be hand-tuned
              // for the exact row count/wrapping of the expanded form, and
              // silently went stale (content spilling out past this
              // Rectangle's bottom edge, overlapping whatever row comes
              // next) the moment that form changed shape, most recently
              // when the Preview field pushed the old single Stream/Preview/
              // Pan-tilt row wider than the popup and it had to split in
              // two. This can't go stale the same way since it's the actual
              // measured content, not an estimate of it.
              implicitHeight: rowContent.implicitHeight + Style.space(12) * 2
              radius: Style.space(8)
              color: Qt.darker(root.barForeground, 10)

              // A freshly-added blank row starts expanded, since it has
              // nothing to show collapsed; existing cameras start collapsed
              // so a multi-camera list reads as a clean name list first.
              property bool expanded: CameraModel.isBlank(modelData)

              // Mirrors modelData.name so the collapsed header updates as
              // you type. modelData itself is a snapshot taken when this
              // delegate was created, not a live reference — mutating
              // root.cameras[index] (see the Name field below) doesn't
              // change what modelData reports back.
              property string currentName: modelData.name
              // Same staleness issue as currentName above, for the PTZ
              // toggle's checkbox fill.
              property bool currentPtz: modelData.ptz !== false
              property bool confirmingDelete: false

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
                id: rowContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(12)
                spacing: Style.space(8)

                // Collapsed row: name on the left, eye/trash on the right.
                // Clicking the name area (not the icons) expands the row.
                RowLayout {
                  id: headerRow
                  Layout.fillWidth: true

                  Rectangle {
                    id: gripHandle
                    implicitWidth: Style.space(22)
                    implicitHeight: Style.space(22)
                    radius: Style.space(6)
                    color: dragArea.containsMouse ? Qt.darker(root.barForeground, 6) : "transparent"

                    Text {
                      anchors.centerIn: parent
                      text: "" // fa-bars (drag handle)
                      color: Qt.darker(root.barForeground, 1.3)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                      id: dragArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.SizeVerCursor
                      drag.target: settingsRow
                      drag.axis: Drag.YAxis
                      drag.minimumY: 0
                      drag.maximumY: Math.max(0, reorderArea.height - settingsRow.height)
                      onPressed: root.beginRowDrag(settingsRow.index)
                      onPositionChanged: if (drag.active) root.updateRowDrag(settingsRow.y)
                      onReleased: root.endRowDrag()
                    }
                  }

                  spacing: Style.space(4)

                  Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: Style.space(26)
                    radius: Style.space(6)
                    color: headerMouse.containsMouse ? Qt.darker(root.barForeground, 6) : "transparent"

                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(4)
                      spacing: Style.space(6)

                      Text {
                        text: settingsRow.expanded ? "" : "" // fa-chevron-down : fa-chevron-right
                        color: Qt.darker(root.barForeground, 1.4)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        Layout.fillWidth: true
                        text: settingsRow.currentName || "(unnamed camera)"
                        color: root.barForeground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        elide: Text.ElideRight
                      }
                    }

                    MouseArea {
                      id: headerMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      onClicked: settingsRow.expanded = !settingsRow.expanded
                    }
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
                    implicitWidth: settingsRow.confirmingDelete ? Style.space(96) : Style.space(26)
                    implicitHeight: Style.space(26)
                    radius: Style.space(6)
                    color: settingsRow.confirmingDelete ? (root.bar ? root.bar.urgent : Color.urgent)
                      : trashMouse.containsMouse ? Qt.darker(root.bar ? root.bar.urgent : Color.urgent, 2.2) : "transparent"

                    Behavior on implicitWidth { NumberAnimation { duration: 120 } }

                    // First click arms it (widens to "Confirm?" and resets
                    // after a few seconds if you don't follow through);
                    // second click while armed actually deletes. Removing a
                    // configured camera has no undo, so a stray click
                    // shouldn't be able to do it by itself.
                    Timer {
                      id: confirmTimer
                      interval: 3000
                      onTriggered: settingsRow.confirmingDelete = false
                    }

                    Text {
                      anchors.centerIn: parent
                      text: settingsRow.confirmingDelete ? "Confirm?" : ""
                      color: settingsRow.confirmingDelete ? "#ffffff" : (trashMouse.containsMouse ? (root.bar ? root.bar.urgent : Color.urgent) : root.barForeground)
                      font.family: Style.font.family
                      font.pixelSize: settingsRow.confirmingDelete ? Style.font.caption : Style.font.icon
                    }

                    MouseArea {
                      id: trashMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      onClicked: {
                        if (settingsRow.confirmingDelete) {
                          confirmTimer.stop()
                          root.removeCamera(settingsRow.index)
                        } else {
                          settingsRow.confirmingDelete = true
                          confirmTimer.restart()
                        }
                      }
                    }
                  }
                }

                // Expanded body: full editable fields + test.
                ColumnLayout {
                  id: bodyColumn
                  visible: settingsRow.expanded
                  Layout.fillWidth: true
                  Layout.topMargin: Style.space(4)
                  spacing: Style.space(8)

                  TextField {
                    Layout.fillWidth: true
                    text: settingsRow.modelData.name
                    placeholderText: "Name (e.g. Front Door)"
                    onTextChanged: {
                      root.cameras[settingsRow.index].name = text
                      settingsRow.currentName = text
                      root.scheduleSave()
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

                  // Stream + Preview together used to share a row with the
                  // Pan/tilt checkbox, but that row's natural width (two
                  // labeled stream fields plus a checkbox) ran wider than
                  // this popup's fixed content width, and nothing here
                  // wraps -- it just spilled out past the window's edge.
                  // Split across two rows instead of trying to cram it in.
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
                      Layout.fillWidth: true
                      text: settingsRow.modelData.stream
                      placeholderText: "stream1"
                      onTextChanged: { root.cameras[settingsRow.index].stream = text; root.scheduleSave() }
                    }

                    Text {
                      text: "Preview"
                      color: Qt.darker(root.barForeground, 1.4)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }

                    TextField {
                      Layout.fillWidth: true
                      text: settingsRow.modelData.previewStream
                      placeholderText: "stream2"
                      onTextChanged: { root.cameras[settingsRow.index].previewStream = text; root.scheduleSave() }
                    }
                  }

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(6)

                    Rectangle {
                      implicitWidth: Style.space(18)
                      implicitHeight: Style.space(18)
                      radius: Style.space(4)
                      color: settingsRow.currentPtz ? root.barForeground : "transparent"
                      border.color: root.barForeground
                      border.width: Style.space(1)

                      Text {
                        anchors.centerIn: parent
                        visible: settingsRow.currentPtz
                        text: "\uf00c" // fa-check
                        color: Qt.darker(root.barForeground, 10)
                        font.family: Style.font.family
                        font.pixelSize: Style.space(10)
                      }

                      MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        onClicked: {
                          settingsRow.currentPtz = !settingsRow.currentPtz
                          root.cameras[settingsRow.index].ptz = settingsRow.currentPtz
                          root.scheduleSave()
                        }
                      }
                    }

                    Text {
                      text: "Pan/tilt"
                      color: Qt.darker(root.barForeground, 1.4)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }

                    Item { Layout.fillWidth: true }
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
          }
          }

          Rectangle {
            Layout.fillWidth: true
            implicitHeight: Style.space(34)
            radius: Style.space(6)
            color: addMouse.containsMouse ? Qt.darker(root.barForeground, 6) : "transparent"
            border.color: root.barForeground
            border.width: Style.space(1)

            Text {
              anchors.centerIn: parent
              text: "+ Add camera"
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: addMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: root.addCamera()
            }
          }
        }
      }
    }
  }
}
