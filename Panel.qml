import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "CameraModel.js" as CameraModel

// Floating panel listing configured Tapo cameras. Clicking a camera opens
// its RTSP live stream in mpv (low-latency flags set).

Panel {
    id: root
    moduleName: "io.github.zestybytes.tapo-cameras"
    manageIpc: false

    property var anchorItem: null
    property var cameras: []

    signal closed()

    function open() {
        reload();
        visible = true;
    }

    function close() {
        visible = false;
        closed();
    }

    function reload() {
        configFile.reload();
    }

    FileView {
        id: configFile
        path: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.zestybytes.tapo-cameras/cameras.json"
        watchChanges: true
        onLoaded: root.cameras = CameraModel.parseCameras(text())
        onLoadFailed: root.cameras = []
    }

    PanelKeyCatcher {
        onEscapePressed: root.close()
    }

    width: 320
    height: Math.min(400, 56 + cameraList.count * 44)

    Rectangle {
        anchors.fill: parent
        radius: 10
        color: "#1e1e2e"
        border.color: "#313244"
        border.width: 1

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 6

            Text {
                text: "Tapo Cameras"
                color: "#cdd6f4"
                font.bold: true
                font.pixelSize: 14
            }

            Text {
                visible: root.cameras.length === 0
                text: "No cameras configured.\nEdit ~/.config/omarchy/plugins/io.github.zestybytes.tapo-cameras/cameras.json"
                color: "#a6adc8"
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            ListView {
                id: cameraList
                Layout.fillWidth: true
                Layout.fillHeight: true
                model: root.cameras
                spacing: 4
                clip: true

                delegate: Rectangle {
                    width: cameraList.width
                    height: 40
                    radius: 6
                    color: cameraMouse.containsMouse ? "#313244" : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 8
                        spacing: 8

                        Text {
                            text: "" // camera icon
                            color: "#89b4fa"
                        }

                        Text {
                            text: modelData.name
                            color: "#cdd6f4"
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }

                        Text {
                            text: modelData.ip
                            color: "#6c7086"
                            font.pixelSize: 10
                        }
                    }

                    MouseArea {
                        id: cameraMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: streamProcess.launch(modelData)
                    }
                }
            }
        }
    }

    Process {
        id: streamProcess
        function launch(camera) {
            command = ["mpv", "--no-cache", "--untimed", "--profile=low-latency",
                       "--title=" + camera.name, camera.url];
            running = true;
        }
    }
}
