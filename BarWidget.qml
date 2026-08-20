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
    readonly property string pendingOpenMarker: Qt.resolvedUrl(".runtime/.pending-open").toString().replace(/^file:\/\//, "")
    property bool bridgeReady: false
    property bool installing: false
    property string bridgeError: ""
    property bool userClickedInstall: false

    function ensureBridge() {
        if (setupProc.running) return;
        root.installing = true;
        root.bridgeError = "";
        setupProc.setupOutput = "";
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
            // The bridge is still downloading (or missing): note that the
            // user wants the panel, and re-open it once installation lands.
            root.userClickedInstall = true;
            touchProc.command = ["touch", root.pendingOpenMarker];
            touchProc.running = true;
            root.ensureBridge();
            return;
        }
        if (panelLoader.item && panelLoader.item.toggle)
            panelLoader.item.toggle();
    }

    // One-shot: a click may have asked for the panel while the bridge was
    // installing (possibly across the shell reload we trigger on a fresh
    // install). If such a marker file exists, open the panel now.
    function consumePendingOpen() {
        markerProc.out = "";
        markerProc.command = ["bash", "-c", "m=\"$1\"; [ -f \"$m\" ] && rm -f \"$m\" && echo OPEN", "_", root.pendingOpenMarker];
        markerProc.running = true;
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
        property string setupOutput: ""
        property string errorOutput: ""
        stdout: SplitParser {
            onRead: function(data) { setupProc.setupOutput += data + "\n" }
        }
        stderr: SplitParser {
            onRead: function(data) { setupProc.errorOutput += data + "\n" }
        }
        onRunningChanged: {
            if (running) {
                setupProc.setupOutput = "";
                setupProc.errorOutput = "";
            }
        }
        onExited: function(exitCode) {
            root.installing = false;
            root.bridgeReady = exitCode === 0;
            if (!root.bridgeReady) {
                root.bridgeError = setupProc.errorOutput.trim() || "Bridge installation failed";
                return;
            }
            var restartScheduled = setupProc.setupOutput.indexOf("OMAMOVIE_RESTART_SHELL=1") !== -1;
            if (restartScheduled) {
                // The setup script scheduled a detached full-shell restart.
                // Its replacement widget picks up any pending-open marker.
                return;
            }
            if (root.userClickedInstall) {
                root.userClickedInstall = false;
                touchProc.command = ["rm", "-f", root.pendingOpenMarker];
                touchProc.running = true;
                Qt.callLater(root.togglePanel);
            }
        }
    }

    Process {
        id: markerProc
        property string out: ""
        stdout: SplitParser {
            onRead: function(data) { markerProc.out += data }
        }
        onExited: function(exitCode) {
            if (markerProc.out.indexOf("OPEN") !== -1)
                Qt.callLater(root.togglePanel);
        }
    }

    Process {
        id: touchProc
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
        text: "󰨂"
        slotSize: Style.bar.statusSlot
        tooltipText: root.installing ? "OmaMovie \u2022 installing bridge \u2026" :
                     (root.bridgeReady ? "OmaMovie \u2022 search, browse and watch movies, shows and anime in mpv" :
                      (root.bridgeError || "OmaMovie \u2022 bridge not installed; click to retry"))
        onPressed: root.togglePanel()
    }

    Component.onCompleted: {
        root.consumePendingOpen();
        root.ensureBridge();
    }
}
