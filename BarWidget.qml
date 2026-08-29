import QtQuick
import Quickshell
import Quickshell.Io

// Bar entry point for the Tapo Cameras plugin.
// Shows a camera icon in the bar; clicking it toggles the camera panel.

BarWidget {
    id: root
    moduleName: "io.github.zestybytes.tapo-cameras"

    property bool opened: false
    property var panelLoader: null

    function open() {
        if (!panelLoader)
            panelLoader = panelComponent.createObject(root, { anchorItem: root });
        panelLoader.open();
        opened = true;
    }

    function close() {
        if (panelLoader)
            panelLoader.close();
        opened = false;
    }

    function toggle() {
        if (opened) close(); else open();
    }

    Component {
        id: panelComponent
        Panel {
            onClosed: root.opened = false
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "transparent"

        Row {
            anchors.centerIn: parent
            spacing: 4

            Text {
                text: "" // camera icon (Nerd Font / FontAwesome)
                font.pixelSize: 16
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.toggle()
        }
    }
}
