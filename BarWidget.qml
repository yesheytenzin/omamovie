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
        installNotifyTimer.restart();
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

    function notify(title, body, urgency) {
        var u = urgency || "normal";
        var t = title || "OmaMovie";
        var b = body || "";
        // Use notify-send if available; fallback silently if not
        notifyProc.command = ["notify-send", "-a", "OmaMovie", "-u", u, "-i", "video-display", t, b];
        notifyProc.running = true;
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
        onExited: function(exitCode) {
            installNotifyTimer.stop();
            root.installing = false;
            root.bridgeReady = exitCode === 0;
            if (!root.bridgeReady) {
                root.bridgeError = setupProc.errorOutput.trim() || "Bridge installation failed";
                notify("OmaMovie — Install failed", root.bridgeError, "critical");
                return;
            }
            var out = setupProc.setupOutput;
            var isFresh = out.indexOf("already installed") === -1 && (out.indexOf("downloading") !== -1 || out.indexOf("installed") !== -1);
            if (isFresh) {
                notify("OmaMovie — Ready", "Bridge installed — click the film icon () to browse", "normal");
            }
            var restartScheduled = out.indexOf("OMAMOVIE_RESTART_SHELL=1") !== -1;
            if (restartScheduled) {
                // The setup script scheduled a detached rescan (omarchy-shell shell rescanPlugins).
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

    Process {
        id: notifyProc
    }

    Timer {
        id: installNotifyTimer
        interval: 600
        repeat: false
        onTriggered: {
            if (root.installing && !root.bridgeReady) {
                notify("OmaMovie", "Installing bridge… downloading", "normal");
            }
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
        text: ""
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
