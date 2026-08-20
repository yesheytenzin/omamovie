import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
    id: root
    moduleName: "tenzin.omamovie"

    readonly property string launchScript: Qt.resolvedUrl("moviebox-launch.sh").replace(/^file:\/\//, "")
    property bool checking: true
    property bool installed: false

    function refresh() {
        root.checking = true
        checkProc.command = ["bash", "-lc", "command -v moviebox-tui >/dev/null 2>&1"]
        checkProc.running = true
    }

    function launch() {
        if (root.checking || launchProc.running) return
        launchProc.command = ["bash", root.launchScript]
        launchProc.running = true
    }

    Process {
        id: checkProc
        onExited: function(exitCode) {
            root.installed = exitCode === 0
            root.checking = false
        }
    }

    Process {
        id: launchProc
        onExited: function(exitCode) {
            if (exitCode !== 0) root.refresh()
        }
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "\uf03d"
        slotSize: Style.bar.statusSlot
        tooltipText: root.checking ? "MovieBox \u2026" :
                     (root.installed ? "MovieBox \u2022 click to open" :
                                       "MovieBox \u2022 not installed \u2022 click to install & open")
        onPressed: root.launch()
    }

    Component.onCompleted: root.refresh()
}
