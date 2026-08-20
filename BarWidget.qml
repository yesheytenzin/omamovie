import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
    id: root
    moduleName: "tenzin.omamovie"

    visible: true
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
    readonly property string setupScript: Qt.resolvedUrl("omamovie-setup.sh").toString().replace(/^file:\/\//, "")
    property bool bridgeReady: false
    property bool installing: false
    property string bridgeError: ""

    function ensureBridge() {
        if (setupProc.running) return;
        root.installing = true;
        root.bridgeError = "";
        setupProc.command = ["bash", root.setupScript];
        setupProc.running = true;
    }

    function injectPanel() {
        var target = panelLoader.item;
        if (!target) return;
        if ("bar" in target) target.bar = root.bar;
        if ("settings" in target) target.settings = root.settings;
        if ("anchorItem" in target) target.anchorItem = button;
        if ("hostWidget" in target) target.hostWidget = root;
    }

    function togglePanel() {
        if (!root.bridgeReady) {
            root.ensureBridge();
            return;
        }
        if (panelLoader.item && panelLoader.item.toggle)
            panelLoader.item.toggle();
    }
    function open() {
        if (panelLoader.item && panelLoader.item.openFromHotkey)
            panelLoader.item.openFromHotkey();
    }
    function close() {
        if (panelLoader.item && panelLoader.item.close)
            panelLoader.item.close();
    }
    function closeForPopoutSwitch() {
        if (panelLoader.item && panelLoader.item.closeForPopoutSwitch)
            panelLoader.item.closeForPopoutSwitch();
    }

    onBarChanged: injectPanel()
    onSettingsChanged: injectPanel()

    Process {
        id: setupProc
        property string errorOutput: ""
        stderr: SplitParser {
            onRead: function(data) { setupProc.errorOutput += data + "\n" }
        }
        onRunningChanged: {
            if (running) setupProc.errorOutput = "";
        }
        onExited: function(exitCode) {
            root.installing = false;
            root.bridgeReady = exitCode === 0;
            if (!root.bridgeReady)
                root.bridgeError = setupProc.errorOutput.trim() || "Bridge installation failed";
        }
    }

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.injectPanel();
            Qt.callLater(root.injectPanel);
        }
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "\uf03d"
        slotSize: Style.bar.statusSlot
        tooltipText: root.installing ? "OmaMovie \u2022 installing bridge \u2026" :
                     (root.bridgeReady ? "OmaMovie \u2022 search, browse and watch movies, shows and anime in mpv" :
                      (root.bridgeError || "OmaMovie \u2022 bridge not installed; click to retry"))
        onPressed: root.togglePanel()
    }

    Component.onCompleted: root.ensureBridge()
}
