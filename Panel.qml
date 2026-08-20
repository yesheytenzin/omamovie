import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import QtMultimedia
import qs.Commons
import qs.Ui

Panel {
    id: root
    moduleName: "tenzin.omamovie"

    property var anchorItem: null
    property var hostWidget: null
    readonly property var barIdentity: hostWidget || root

    readonly property string bridge: Qt.resolvedUrl(".runtime/omamovie-bridge").toString().replace(/^file:\/\//, "")

    implicitWidth: 820
    implicitHeight: 560

    // ---------------- state ----------------
    property string view: "home"          // home | grid | details
    property var details: null
    property string currentId: ""
    property string currentTitle: ""
    property var seasons: []
    property int curSeason: 1
    property int maxEp: 0
    property int curEp: 0                 // 0 = movie
    property var streams: []
    property int selStream: -1
    property var subs: []
    property bool busy: false
    property string busyLabel: ""
    property string statusText: "Search movies, shows and anime"
    property string query: ""
    property var results: []
    property bool playing: false
    property bool homeLoading: false
    property int suggestGen: 0
    property int searchGen: 0
    property int detailGen: 0
    property int resourceGen: 0
    property string playerUrl: ""
    property string playerTitle: ""
    property bool embeddedPlaying: false
    property bool playerFullscreen: false

    readonly property bool isSeries: root.details ? (root.details.subjectType === 2 || root.seasons.length > 0) : false

    // ---------------- bridge IPC (single serialized process) ----------------
    property var pending: []
    property var cbChain: null

    function request(cmd, params, cb) {
        params = params || {};
        if (bridgeProc.running) {
            root.pending.push({ cmd: cmd, params: params, cb: cb });
            return;
        }
        root._start(cmd, params, cb);
    }

    function _start(cmd, params, cb) {
        bridgeProc.collected = "";
        root.cbChain = cb;
        var req = JSON.parse(JSON.stringify(params));
        req.cmd = cmd;
        bridgeProc.command = [root.bridge, JSON.stringify(req)];
        bridgeProc.running = true;
    }

    Process {
        id: bridgeProc
        property string collected: ""
        stdout: SplitParser {
            onRead: function(data) { bridgeProc.collected += data }
        }
        onExited: function(code, status) {
            var cb = root.cbChain;
            root.cbChain = null;
            var resp = null;
            try { resp = JSON.parse(bridgeProc.collected); } catch (e) {}
            if (cb) cb(resp, code);
            if (root.pending.length > 0) {
                var next = root.pending.shift();
                root._start(next.cmd, next.params, next.cb);
            }
        }
    }

    // ---------------- helpers ----------------
    function fmtSize(s) {
        var n = parseInt(s || "0", 10);
        if (n > 1073741824) return (n / 1073741824).toFixed(1) + " GB";
        if (n > 1048576) return (n / 1048576).toFixed(0) + " MB";
        return n + " B";
    }
    function fmtDur(s) {
        s = Math.floor(s || 0);
        var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
        if (h > 0) return h + "h " + String(m).padStart(2, "0") + "m";
        return m + "m";
    }
    function coverUrlOf(obj) {
        if (!obj) return "";
        var c = obj.cover;
        if (c && typeof c === "object") return c.url || "";
        if (typeof c === "string") return c;
        return "";
    }
    function episodeCount(se) {
        for (var i = 0; i < root.seasons.length; i++)
            if (root.seasons[i].se === se) return Number(root.seasons[i].maxEp) || 0;
        if (root.details && root.details.resourceDetectors && root.details.resourceDetectors.length > 0) {
            var d = root.details.resourceDetectors[0];
            return Number(d.totalEpisode) || 1;
        }
        return 1;
    }

    // ---------------- actions ----------------
    function doSearch() {
        var q = searchField.text.trim();
        if (!q) return;
        root.query = q;
        root.busy = true;
        root.busyLabel = "Searching \u2026";
        root.statusText = "";
        root.searchGen++;
        var gen = root.searchGen;
        request("search", { q: q, page: 1 }, function(resp, code) {
            if (gen !== root.searchGen) return;
            root.busy = false;
            if (!resp || !resp.ok) {
                root.statusText = (resp && resp.error) || "Search failed";
                return;
            }
            root.results = resp.items || [];
            resultModel.clear();
            for (var i = 0; i < root.results.length; i++) {
                var r = root.results[i];
                resultModel.append({ id: r.id, title: r.title, year: r.year || "", rating: r.rating !== null ? String(r.rating) : "-", cover: r.cover || "", coverPath: r.cover || "", duration: r.duration || "", stype: r.stype });
            }
            root.view = "grid";
            root.statusText = resultModel.count + " results for \u201C" + q + "\u201D";
        });
    }

    function debounceSuggest() {
        suggestTimer.restart();
    }

    function openDetails(idx) {
        if (idx < 0 || idx >= resultModel.count) return;
        var it = resultModel.get(idx);
        root.currentId = it.id;
        root.currentTitle = it.title;
        // optimistic — switch immediately for snappy feel
        root.details = null;
        root.seasons = [];
        root.streams = [];
        root.selStream = -1;
        root.subs = [];
        detailPoster.source = it.cover || "";
        root.view = "details";
        root.statusText = "Loading \u201C" + it.title + "\u201D \u2026";
        root.busy = true;
        root.busyLabel = "Loading details \u2026";
        root.detailGen++;
        var gen = root.detailGen;
        // parallel streams for movie guess (will be overwritten if series)
        root.resourceGen++;
        var resGen = root.resourceGen;
        request("resources", { id: it.id, season: 0, episode: 0, perPage: 20 }, function(resp){
            if (resGen !== root.resourceGen) return;
            // only use if still movie-like (no seasons yet) and view still details for same id
            if (gen !== root.detailGen) return;
            if (root.currentId !== it.id) return;
            if (resp && resp.ok && resp.items && resp.items.length > 0 && !root.isSeries) {
                root.streams = resp.items;
                root.selStream = 0;
                root.statusText = "Pick a stream and press Play";
                root.busy = false;
            }
        });
        request("details", { id: it.id }, function(resp, code) {
            if (gen !== root.detailGen) return;
            root.busy = false;
            if (!resp || !resp.ok) {
                root.statusText = (resp && resp.error) || "Details failed";
                return;
            }
            root.details = resp.value;
            var ss = (resp.value && resp.value.seasons && resp.value.seasons.seasons) || [];
            root.seasons = ss.length ? ss : [];
            root.curSeason = 1;
            root.maxEp = root.episodeCount(1);
            root.curEp = root.isSeries ? 1 : 0;
            // if we already have streams for movie and this is series, reload correct episode
            if (root.isSeries) {
                root.streams = [];
                root.selStream = -1;
                root.subs = [];
                root.statusText = "Pick a season and episode";
                root.loadStreams(root.curSeason, root.curEp);
            } else {
                // movie: if parallel streams already arrived, keep them; otherwise load
                if (root.streams.length === 0) {
                    root.streams = [];
                    root.selStream = -1;
                    root.subs = [];
                    root.statusText = "Pick a stream and press Play";
                    root.loadStreams(0, 0);
                }
            }
            var cover = root.coverUrlOf(root.details);
            if (cover) detailPoster.source = cover;
        });
    }

    function openHomeDetails(idx) {
        if (idx < 0 || idx >= homeModel.count) return;
        var it = homeModel.get(idx);
        root.currentId = it.id;
        root.currentTitle = it.title;
        root.details = null;
        root.seasons = [];
        root.streams = [];
        root.selStream = -1;
        root.subs = [];
        detailPoster.source = it.cover || "";
        root.view = "details";
        root.statusText = "Loading \u201C" + it.title + "\u201D \u2026";
        root.busy = true;
        root.busyLabel = "Loading details \u2026";
        root.detailGen++;
        var gen = root.detailGen;
        root.resourceGen++;
        var resGen = root.resourceGen;
        request("resources", { id: it.id, season: 0, episode: 0, perPage: 20 }, function(resp){
            if (resGen !== root.resourceGen) return;
            if (gen !== root.detailGen) return;
            if (root.currentId !== it.id) return;
            if (resp && resp.ok && resp.items && resp.items.length > 0 && !root.isSeries) {
                root.streams = resp.items;
                root.selStream = 0;
                root.statusText = "Pick a stream and press Play";
                root.busy = false;
            }
        });
        request("details", { id: it.id }, function(resp, code) {
            if (gen !== root.detailGen) return;
            root.busy = false;
            if (!resp || !resp.ok) {
                root.statusText = (resp && resp.error) || "Details failed";
                return;
            }
            root.details = resp.value;
            var ss = (resp.value && resp.value.seasons && resp.value.seasons.seasons) || [];
            root.seasons = ss.length ? ss : [];
            root.curSeason = 1;
            root.maxEp = root.episodeCount(1);
            root.curEp = root.isSeries ? 1 : 0;
            if (root.isSeries) {
                root.streams = [];
                root.selStream = -1;
                root.subs = [];
                root.statusText = "Pick a season and episode";
                root.loadStreams(root.curSeason, root.curEp);
            } else {
                if (root.streams.length === 0) {
                    root.streams = [];
                    root.selStream = -1;
                    root.subs = [];
                    root.statusText = "Pick a stream and press Play";
                    root.loadStreams(0, 0);
                }
            }
            var cover = root.coverUrlOf(root.details);
            if (cover) detailPoster.source = cover;
        });
    }

    function loadStreams(se, ep) {
        root.busy = true;
        root.busyLabel = "Loading streams \u2026";
        root.resourceGen++;
        var gen = root.resourceGen;
        request("resources", { id: root.currentId, season: se, episode: ep, perPage: 20 }, function(resp, code) {
            if (gen !== root.resourceGen) return;
            root.busy = false;
            root.streams = (resp && resp.ok && resp.items) ? resp.items : [];
            root.selStream = root.streams.length > 0 ? 0 : -1;
            if (root.streams.length === 0)
                root.statusText = "No streams available for this \u2026";
        });
    }

    function selectStream(i) {
        root.selStream = i;
    }

    Process {
        id: prefetchProc
        property string collected: ""
        stdout: SplitParser { onRead: function(data){ prefetchProc.collected += data } }
        onExited: function(code){ try{ JSON.parse(prefetchProc.collected);}catch(e){} }
    }

    function prefetchDetails(id) {
        if (!id || bridgeProc.running || root.pending.length > 0 || prefetchProc.running) return;
        var req = JSON.stringify({ cmd: "details", id: id });
        prefetchProc.collected = "";
        prefetchProc.command = [root.bridge, req];
        prefetchProc.running = true;
    }

    function play() {
        // Only mkv (mpv) — embedded view removed per request
        root.playExternal();
        Qt.callLater(function(){ if (root.playing) root.close(); });
    }

    function playEmbedded() {
        if (root.selStream < 0 || root.streams.length === 0) return;
        var s = root.streams[root.selStream];
        var link = s.resourceLink || s.link || "";
        if (!link) { root.statusText = "Stream has no URL"; return; }
        root.playerUrl = link;
        root.playerTitle = root.currentTitle + (root.isSeries ? (" S" + root.curSeason + "E" + root.curEp) : "");
        root.view = "player";
        root.embeddedPlaying = true;
        root.statusText = "Playing \u201C" + root.playerTitle + "\u201D";
        // Defer source assignment to next tick to ensure view switch completes
        Qt.callLater(function() {
            embeddedPlayer.source = link;
            embeddedPlayer.play();
        });
    }

    function playExternal() {
        if (root.selStream < 0 || root.streams.length === 0) return;
        var s = root.streams[root.selStream];
        var link = s.resourceLink || s.link || "";
        if (!link) { root.statusText = "Stream has no URL"; return; }
        // Fast path: launch mpv immediately without waiting for captions
        root._launch(["mpv", "--force-window=immediate", "--no-terminal", "--cache=yes", "--demuxer-max-bytes=50M"], link, "");
        // Fetch captions in background for next time (cached)
        request("captions", { id: root.currentId, rid: String(s.resourceId || "") }, function(resp) {
            var opts = (resp && resp.ok && resp.options) ? resp.options : [];
            if (opts.length) root.subs = opts.filter(function(o){ return o.url; });
        });
    }

    function _launch(args, link, subLabel) {
        args.push(link);
        mpvProc.command = args;
        mpvProc.running = true;
        root.playing = true;
        root.statusText = "Playing in mpv" + subLabel + " \u2022 close the player to stop";
        // auto-close panel when external player starts
        Qt.callLater(function(){ root.close(); });
    }

    Process {
        id: mpvProc
        onExited: function() {
            root.playing = false;
            root.statusText = "Player closed";
        }
    }

    AudioOutput {
        id: embeddedAudio
        volume: 1.0
    }

    MediaPlayer {
        id: embeddedPlayer
        audioOutput: embeddedAudio
        videoOutput: root.playerFullscreen ? fullscreenVideoOutput : embeddedVideoOutput
        onErrorOccurred: function(error, errorString) {
            root.statusText = "Playback error: " + errorString;
            root.embeddedPlaying = false;
        }
        onPlaybackStateChanged: {
            root.embeddedPlaying = (playbackState === MediaPlayer.PlayingState);
        }
        onPositionChanged: {
            // keep slider in sync; no-op if user dragging
        }
    }

    function loadHome(force) {
        if (root.homeLoading) return;
        if (!force && homeModel.count > 0) { root.view = "home"; return; }
        root.homeLoading = true;
        root.busy = true;
        root.busyLabel = "Loading home \u2026";
        request("homepage", { tab: "2", page: 1, perPage: 24 }, function(resp) {
            root.homeLoading = false;
            root.busy = false;
            if (!resp || !resp.ok) {
                root.statusText = (resp && resp.error) || "Could not load home";
                root.view = "home";
                return;
            }
            var items = resp.items || [];
            // Shuffle for variety
            for (var i = items.length - 1; i > 0; i--) {
                var j = Math.floor(Math.random() * (i + 1));
                var tmp = items[i]; items[i] = items[j]; items[j] = tmp;
            }
            homeModel.clear();
            for (var k = 0; k < items.length && k < 24; k++) {
                var r = items[k];
                homeModel.append({ id: r.id, title: r.title, year: r.year || "", rating: r.rating !== null ? String(r.rating) : "-", cover: r.cover || "", coverPath: r.cover || "", duration: r.duration || "", stype: r.stype });
            }
            root.view = "home";
            root.statusText = homeModel.count ? "Discover \u2022 " + homeModel.count + " titles" : "Search movies, shows and anime";
        });
    }

    function goHome() {
        if (homeModel.count === 0) root.loadHome(false);
        else root.view = "home";
        if (root.view === "home" && homeModel.count) root.statusText = "Discover \u2022 " + homeModel.count + " titles";
        else root.statusText = "Search movies, shows and anime";
    }

    function backToGrid() {
        root.view = "grid";
    }

    function refreshCurrent() {
        if (root.view === "home") root.loadHome(true);
        else if (root.view === "grid") root.doSearch();
        else if (root.view === "details" && root.currentId) {
            // reload details and streams for current item
            var idx = -1;
            for (var i=0;i<resultModel.count;i++) if (resultModel.get(i).id===root.currentId) { idx=i; break; }
            if (idx>=0) root.openDetails(idx);
            else {
                for (var j=0;j<homeModel.count;j++) if (homeModel.get(j).id===root.currentId) { idx=j; break; }
                if (idx>=0) root.openHomeDetails(idx);
                else root.loadHome(true);
            }
        } else root.loadHome(true);
    }

    function stopEmbedded() {
        if (embeddedPlayer) {
            embeddedPlayer.stop();
            embeddedPlayer.source = "";
        }
        root.embeddedPlaying = false;
        root.playerUrl = "";
        root.playerFullscreen = false;
    }

    // ---------------- open/close wiring (same contract as pacman) ----------------
    function openFromHotkey() {
        if (homeModel.count === 0 && !root.homeLoading) root.loadHome(false);
        root.controller.show();
        Qt.callLater(function() {
            if (root.opened) searchField.forceActiveFocus();
        });
    }
    onPlayerFullscreenChanged: {
        if (root.view !== "player" || !embeddedPlayer.source) return;
        var wasPlaying = embeddedPlayer.playbackState === MediaPlayer.PlayingState;
        var pos = embeddedPlayer.position;
        Qt.callLater(function() {
            embeddedPlayer.position = pos;
            if (wasPlaying) embeddedPlayer.play();
            else embeddedPlayer.pause();
        });
    }

    function close() {
        if (root.view === "player") { root.stopEmbedded(); root.playerFullscreen = false; }
        root.controller.hide();
    }
    function toggle() {
        if (root.opened) root.close();
        else root.openFromHotkey();
    }
    function closeForPopoutSwitch() { root.close(); }
    function switchPanel(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
            return root.bar.switchPanelFrom(root.barIdentity, direction);
        return false;
    }

    // ---------------- UI ----------------
    ListModel { id: resultModel }
    ListModel { id: homeModel }

    Timer {
        id: suggestTimer
        interval: 380
        repeat: false
        onTriggered: {
            var q = searchField.text.trim();
            if (q.length < 2) { suggestionModel.clear(); return; }
            root.suggestGen++;
            var gen = root.suggestGen;
            request("suggest", { q: q }, function(resp) {
                if (gen !== root.suggestGen) return;
                suggestionModel.clear();
                var list = (resp && resp.ok && resp.suggestions) ? resp.suggestions : [];
                for (var i = 0; i < list.length && i < 8; i++)
                    suggestionModel.append({ name: list[i].name });
            });
        }
    }
    ListModel { id: suggestionModel }

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.barIdentity
        bar: root.bar
        open: root.opened
        centerOnBar: true
        margin: root.playerFullscreen && root.view === "player" ? 0 : Style.gapsOut
        gap: root.playerFullscreen && root.view === "player" ? 0 : Style.gapsOut
        // Responsive breakpoints: <1366 small 96%/90%, 1366-1920 medium 88%/82% cap 1100, >1920 large 80%/78% cap 1400
        readonly property bool isSmallScreen: panel.screenW > 0 && panel.screenW < 1366
        readonly property bool isLargeScreen: panel.screenW >= 1920
        contentWidth: root.playerFullscreen && root.view === "player"
                      ? panel.screenW
                      : isSmallScreen ? panel.fittedContentWidth(panel.screenW * 0.96)
                      : isLargeScreen ? panel.fittedContentWidth(Math.min(panel.screenW * 0.80, 1400))
                      : panel.fittedContentWidth(Math.min(panel.screenW * 0.88, 1100))
        contentHeight: root.playerFullscreen && root.view === "player"
                       ? panel.screenH
                       : isSmallScreen ? panel.fittedContentHeight(mainColumn.implicitHeight, panel.screenH * 0.92)
                       : isLargeScreen ? panel.fittedContentHeight(mainColumn.implicitHeight, panel.screenH * 0.84)
                       : panel.fittedContentHeight(mainColumn.implicitHeight, panel.screenH * 0.88)

        ColumnLayout {
            id: mainColumn
            anchors.fill: parent
            anchors.margins: 14
            spacing: 10

        // header — refined, responsive
        RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                RowLayout {
                    spacing: 8
                    Text { text: ""; font.family: Style.font.family; font.pixelSize: Style.font.title; color: Color.accent }
                    Text { text: "OmaMovie"; font.family: Style.font.family; font.pixelSize: Style.font.title; font.bold: true; color: Color.foreground }
                    Rectangle { width: 1; height: 18; color: Color.foreground; opacity: 0.12; Layout.leftMargin: 4; Layout.rightMargin: 4 }
                    Text {
                        text: root.view === "player" ? "Player" : root.view === "details" ? "Details" : root.view === "grid" ? "Results" : "Discover"
                        font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; color: Qt.darker(Color.foreground, 1.25); font.capitalization: Font.AllUppercase
                    }
                    Item { Layout.fillWidth: true }
                    // busy indicator inline
                    RowLayout {
                        spacing: 6; visible: root.busy || root.playing
                        Rectangle { width: 8; height: 8; radius: 4; color: Color.accent; opacity: 0.9; visible: root.busy
                            SequentialAnimation on opacity { running: root.busy; loops: Animation.Infinite; NumberAnimation { from: 0.4; to: 1.0; duration: 700 } NumberAnimation { from: 1.0; to: 0.4; duration: 700 } }
                        }
                        Text {
                            text: root.busy ? root.busyLabel : "Playing"
                            font.family: Style.font.family; font.pixelSize: Style.font.caption; color: Color.accent
                        }
                    }
                }
                Text {
                    text: root.statusText
                    font.family: Style.font.family; font.pixelSize: Style.font.caption - 1; color: Qt.darker(Color.foreground, 1.35)
                    elide: Text.ElideRight; Layout.fillWidth: true; maximumLineCount: 1
                }
            }
            Button {
                text: "\u21bb"
                tooltipText: "Refresh"
                fontSize: Style.font.body
                horizontalPadding: 10
                verticalPadding: 5
                onClicked: root.refreshCurrent()
            }
            Button {
                text: "✕"
                tooltipText: "Close"
                fontSize: Style.font.body
                horizontalPadding: 12
                verticalPadding: 6
                onClicked: root.close()
            }
        }
        PanelSeparator { Layout.fillWidth: true; opacity: 0.5 }

        // search — prominent, rounded
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            TextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: "Search movies, shows, anime \u2026"
                onAccepted: root.doSearch()
                onTextChanged: root.debounceSuggest()
                // clear on Esc
                Keys.onEscapePressed: { clear(); suggestionModel.clear(); }
            }
            Button {
                text: "Search"
                iconText: "\uf002"
                selected: true
                onClicked: root.doSearch()
            }
            Button {
                text: "Home"
                iconText: "\uf015"
                onClicked: root.goHome()
            }
        }

        // suggestions — pill chips
        Flow {
            Layout.fillWidth: true
            spacing: 6
            Layout.preferredHeight: suggestionModel.count ? Math.min(suggestionModel.count, 2) * 28 + 6 : 0
            visible: suggestionModel.count > 0
            Repeater {
                model: suggestionModel
                Button {
                    text: model.name
                    fontSize: Style.font.caption
                    horizontalPadding: 10
                    verticalPadding: 4
                    onClicked: { searchField.text = model.name; root.doSearch(); }
                }
            }
        }

        // body — responsive, no empty space below
        Item {
            id: body
            Layout.fillWidth: true
            Layout.preferredHeight: {
                if (root.view === "player" && root.playerFullscreen) return Math.round(panel.screenH * 0.78);
                if (root.view === "player") return 460;
                if (root.view === "home") {
                    if (homeGrid.contentHeight === 0) return Math.round(Math.min(460, panel.screenH * 0.52));
                    return Math.round(Math.min(Math.max(360, homeGrid.contentHeight + 16), panel.screenH * 0.64));
                }
                if (root.view === "grid") {
                    if (grid.contentHeight === 0) return 360;
                    return Math.round(Math.min(Math.max(360, grid.contentHeight + 8), panel.screenH * 0.64));
                }
                if (root.view === "details") {
                    return Math.round(Math.min(Math.max(400, detailsContent.implicitHeight + 20), panel.screenH * 0.70));
                }
                return 360;
            }
            Layout.fillHeight: false
            clip: true

            // ---- home (discover) ----
            Item {
                anchors.fill: parent
                visible: root.view === "home"
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 8
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text {
                            Layout.fillWidth: true
                            text: root.homeLoading ? "Discover \u2026" : (homeModel.count ? "Discover \u2022 tap any title" : "Discover")
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            font.bold: true
                            color: Color.accent
                        }
                    }
                    GridView {
                        id: homeGrid
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        cacheBuffer: 400
                        flickableDirection: Flickable.VerticalFlick
                        boundsBehavior: Flickable.StopAtBounds
                        maximumFlickVelocity: 4000
                        reuseItems: true
                        visible: !root.homeLoading
                        model: homeModel
                        cellWidth: 168
                        cellHeight: 236
                        delegate: Item {
                            id: homeDelegate
                            width: homeGrid.cellWidth
                            height: homeGrid.cellHeight
                            property bool hovered: homeMouse.containsMouse
                            Column {
                                anchors.fill: parent
                                anchors.margins: 6
                                spacing: 5
                                Rectangle {
                                    width: parent.width
                                    height: parent.height * 0.74
                                    radius: Style.cornerRadius
                                    color: Color.surface ?? Qt.darker(Color.foreground, 2.15)
                                    border.width: homeDelegate.hovered ? 1 : 0
                                    border.color: homeDelegate.hovered ? Color.accent : "transparent"
                                    clip: true
                                    // hover scale removed
                                    Image {
                                        anchors.fill: parent
                                        source: model.cover || model.coverPath || ""
                                        fillMode: Image.PreserveAspectCrop
                                        visible: source !== ""
                                        asynchronous: true
                                        cache: true
                                    }
                                    Rectangle {
                                        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                                        height: 22; color: "#66000000"; visible: model.rating && model.rating !== "-"
                                        Text { anchors.centerIn: parent; text: "\u2605 " + model.rating; font.family: Style.font.family; font.pixelSize: 10; color: "white"; font.bold: true}
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        visible: !model.cover && !model.coverPath
                                        text: ""
                                        font.family: Style.font.family
                                        font.pixelSize: 30
                                        color: Qt.darker(Color.foreground, 1.3)
                                    }
                                }
                                Text {
                                    width: parent.width
                                    text: model.title
                                    elide: Text.ElideRight
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    color: Color.foreground
                                    maximumLineCount: 1
                                }
                                Text {
                                    width: parent.width
                                    text: (model.year ? model.year : "\u2013") + "  \u2605 " + model.rating
                                    elide: Text.ElideRight
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption - 2
                                    color: Qt.darker(Color.foreground, 1.5)
                                }
                            }
                            MouseArea {
                                id: homeMouse
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                hoverEnabled: true
                                onEntered: homeHoverTimer.restart()
                                onExited: homeHoverTimer.stop()
                                onClicked: root.openHomeDetails(index)
                                Timer {
                                    id: homeHoverTimer
                                    interval: 380
                                    repeat: false
                                    onTriggered: root.prefetchDetails(model.id)
                                }
                            }
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: root.homeLoading
                        text: "Loading highlights \u2026"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        color: Qt.darker(Color.foreground, 1.5)
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: !root.homeLoading && homeModel.count === 0
                        text: "No highlights yet \u2014 try Search above."
                        horizontalAlignment: Text.AlignHCenter
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        color: Qt.darker(Color.foreground, 1.4)
                    }
                }
            }

            // ---- results grid ----
            GridView {
                id: grid
                anchors.fill: parent
                visible: root.view === "grid"
                model: resultModel
                clip: true
                cacheBuffer: 600
                flickableDirection: Flickable.VerticalFlick
                boundsBehavior: Flickable.StopAtBounds
                maximumFlickVelocity: 4000
                reuseItems: true
                cellWidth: 168
                cellHeight: 236
                delegate: Item {
                    id: gridDelegate
                    width: grid.cellWidth
                    height: grid.cellHeight
                    property bool hovered: gridMouse.containsMouse
                    Column {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 5
                        Rectangle {
                            width: parent.width
                            height: parent.height * 0.74
                            radius: Style.cornerRadius
                            color: Color.surface ?? Qt.darker(Color.foreground, 2.15)
                            border.width: gridDelegate.hovered ? 1 : 0
                            border.color: gridDelegate.hovered ? Color.accent : "transparent"
                            clip: true
                            // hover scale removed for scroll performance
                            Behavior on border.width { NumberAnimation { duration: 100 } }
                            Image {
                                anchors.fill: parent
                                source: model.cover || model.coverPath || ""
                                fillMode: Image.PreserveAspectCrop
                                visible: source !== ""
                                asynchronous: true
                                cache: true
                            }
                            // subtle gradient + rating badge
                            Rectangle {
                                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                                height: 22; radius: 0
                                visible: model.rating && model.rating !== "-"
                                color: "#66000000"
                                Text {
                                    anchors.centerIn: parent
                                    text: "\u2605 " + model.rating
                                    font.family: Style.font.family; font.pixelSize: 10; color: "white"; font.bold: true
                                }
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: !model.cover && !model.coverPath
                                text: ""
                                font.family: Style.font.family
                                font.pixelSize: 30
                                color: Qt.darker(Color.foreground, 1.3)
                            }
                        }
                        Text {
                            width: parent.width
                            text: model.title
                            elide: Text.ElideRight
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            color: Color.foreground
                            maximumLineCount: 1
                        }
                        Text {
                            width: parent.width
                            text: (model.year ? model.year : "\u2013") + "  \u2605 " + model.rating
                            elide: Text.ElideRight
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption - 2
                            color: Qt.darker(Color.foreground, 1.5)
                        }
                    }
                    MouseArea {
                        id: gridMouse
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        hoverEnabled: true
                        onEntered: hoverTimer.restart()
                        onExited: hoverTimer.stop()
                        onClicked: root.openDetails(index)
                        Timer {
                            id: hoverTimer
                            interval: 380
                            repeat: false
                            onTriggered: root.prefetchDetails(model.id)
                        }
                    }
                }
            }

            // ---- details ----
            Item {
                anchors.fill: parent
                visible: root.view === "details"

                RowLayout {
                    anchors.fill: parent
                    spacing: 14

                    // poster
                    Rectangle {
                        Layout.preferredWidth: 170
                        Layout.fillHeight: true
                        radius: Style.cornerRadius
                        color: Qt.darker(Color.foreground, 2.2)
                        clip: true
                        Image {
                            id: detailPoster
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            source: ""
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: detailPoster.source === ""
                            text: ""
                            font.family: Style.font.family
                            font.pixelSize: 40
                            color: Qt.darker(Color.foreground, 1.3)
                        }
                    }

                    // info column
                    ColumnLayout {
                        id: detailsContent
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 8

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Text {
                                Layout.fillWidth: true
                                text: root.currentTitle
                                elide: Text.ElideRight
                                font.family: Style.font.family
                                font.pixelSize: Style.font.title
                                font.bold: true
                                color: Color.foreground
                            }
                            Button {
                                text: "\u2190 Back"
                                fontSize: Style.font.caption
                                onClicked: root.goHome()
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            text: {
                                if (!root.details) return "";
                                var parts = [];
                                var year = root.details.year ? String(root.details.year) : (root.details.releaseDate ? String(root.details.releaseDate).slice(0, 4) : "");
                                if (year) parts.push(year);
                                if (root.details.genre) parts.push(root.details.genre);
                                if (root.details.duration) parts.push(root.details.duration);
                                if (root.details.imdbRatingValue) parts.push("\u2605 " + root.details.imdbRatingValue);
                                if (root.details.language) parts.push(root.details.language);
                                return parts.join("  \u2022  ");
                            }
                            wrapMode: Text.WordWrap
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            color: Qt.darker(Color.foreground, 1.4)
                        }

                        Text {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 48
                            text: (root.details && (root.details.intro || root.details.description || root.details.contentRating || "")) || ""
                            wrapMode: Text.WordWrap
                            elide: Text.ElideRight
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            color: Qt.darker(Color.foreground, 1.4)
                        }

                        // seasons
                        Flow {
                            Layout.fillWidth: true
                            visible: root.isSeries && root.seasons.length > 1
                            spacing: 6
                            Repeater {
                                model: root.seasons
                                Button {
                                    text: "S" + modelData.se
                                    fontSize: Style.font.caption
                                    selected: modelData.se === root.curSeason
                                    onClicked: {
                                        root.curSeason = modelData.se;
                                        root.maxEp = root.episodeCount(modelData.se);
                                        root.curEp = 1;
                                        root.loadStreams(modelData.se, 1);
                                    }
                                }
                            }
                        }

                        // episodes
                        Flow {
                            Layout.fillWidth: true
                            visible: root.isSeries
                            spacing: 6
                            Repeater {
                                model: root.maxEp
                                Button {
                                    text: "E" + (index + 1)
                                    fontSize: Style.font.caption
                                    selected: (index + 1) === root.curEp
                                    onClicked: {
                                        root.curEp = index + 1;
                                        root.loadStreams(root.curSeason, index + 1);
                                    }
                                }
                            }
                        }

                        PanelSeparator { Layout.fillWidth: true }

                        // streams
                        Text {
                            Layout.fillWidth: true
                            text: root.isSeries ? ("Streams \u2014 S" + root.curSeason + (root.curEp ? " E" + root.curEp : "")) : "Streams"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            color: Color.accent
                        }

                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            spacing: 4
                            cacheBuffer: 200
                            boundsBehavior: Flickable.StopAtBounds
                            maximumFlickVelocity: 3500
                            reuseItems: true
                            model: root.streams
                            delegate: Button {
                                width: parent ? parent.width : 0
                                text: {
                                    var parts = [];
                                    var res = modelData.resolution || 0;
                                    if (res) parts.push(res + "p");
                                    if (modelData.codecName) parts.push(String(modelData.codecName).toUpperCase());
                                    if (modelData.size) parts.push(root.fmtSize(modelData.size));
                                    if (modelData.duration) parts.push(root.fmtDur(modelData.duration));
                                    return parts.join("  \u2022  ") || "Stream";
                                }
                                leftAlign: true
                                selected: index === root.selStream
                                fontSize: Style.font.caption
                                onClicked: root.selectStream(index)
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Layout.bottomMargin: 10
                            Text {
                                Layout.fillWidth: true
                                text: root.statusText
                                elide: Text.ElideRight
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption - 2
                                color: Qt.darker(Color.foreground, 1.4)
                            }
                            Button {
                                text: "\u25B6 Play"
                                selected: true
                                enabled: root.selStream >= 0 && !root.playing
                                onClicked: { root.playExternal(); root.close(); }
                            }
                        }
                        Item { Layout.preferredHeight: 4 }
                    }
                }
            }

            // ---- embedded player ----
            Item {
                anchors.fill: parent
                visible: root.view === "player"
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 8
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text {
                            Layout.fillWidth: true
                            text: root.playerTitle || "Player"
                            elide: Text.ElideRight
                            font.family: Style.font.family
                            font.pixelSize: Style.font.title
                            font.bold: true
                            color: Color.foreground
                        }
                        Button {
                            text: root.playerFullscreen ? "\u00D7 Full" : "\u26F6 Full"
                            tooltipText: root.playerFullscreen ? "Exit fullscreen" : "Fullscreen"
                            fontSize: Style.font.caption
                            onClicked: root.playerFullscreen = !root.playerFullscreen
                        }
                        Button {
                            text: "\u2190 Back"
                            fontSize: Style.font.caption
                            onClicked: { root.stopEmbedded(); root.goHome(); root.playerFullscreen = false; }
                        }
                        Button {
                            text: "X"
                            tooltipText: "Close"
                            fontSize: Style.font.body
                            horizontalPadding: 10
                            verticalPadding: 5
                            onClicked: root.close()
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: Style.cornerRadius
                        color: "black"
                        clip: true
                        VideoOutput {
                            id: embeddedVideoOutput
                            anchors.fill: parent
                            fillMode: VideoOutput.PreserveAspectFit
                            smooth: true
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: embeddedPlayer.playbackState !== MediaPlayer.PlayingState && embeddedPlayer.playbackState !== MediaPlayer.PausedState
                            text: root.embeddedPlaying ? "Buffering \u2026" : ""
                            font.family: Style.font.family
                            font.pixelSize: 32
                            color: "white"
                            opacity: 0.7
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Button {
                            text: embeddedPlayer.playbackState === MediaPlayer.PlayingState ? "\u23F8 Pause" : "\u25B6 Play"
                            enabled: root.playerUrl !== ""
                            onClicked: {
                                if (embeddedPlayer.playbackState === MediaPlayer.PlayingState) embeddedPlayer.pause();
                                else embeddedPlayer.play();
                            }
                        }
                        PanelSlider {
                            id: playerSlider
                            Layout.fillWidth: true
                            bar: root.bar
                            minimum: 0
                            maximum: embeddedPlayer.duration > 0 ? embeddedPlayer.duration : 1
                            value: embeddedPlayer.position
                            enabled: embeddedPlayer.seekable
                            onMoved: function(v) { embeddedPlayer.position = v; }
                        }
                        Text {
                            text: {
                                function fmt(ms) {
                                    if (!ms || ms < 0) return "0:00";
                                    var s = Math.floor(ms/1000);
                                    var m = Math.floor(s/60);
                                    var sec = s % 60;
                                    return m + ":" + (sec < 10 ? "0"+sec : sec);
                                }
                                return fmt(embeddedPlayer.position) + " / " + fmt(embeddedPlayer.duration);
                            }
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption - 1
                            color: Qt.darker(Color.foreground, 1.2)
                        }
                        Button {
                            text: "mpv"
                            tooltipText: "Open same stream in mpv"
                            enabled: root.selStream >= 0
                            onClicked: root.playExternal()
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: root.statusText
                        elide: Text.ElideRight
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption - 2
                        color: Qt.darker(Color.foreground, 1.4)
                    }
                }
            }
        }
    }

}
    // True fullscreen - covers entire screen
    PanelWindow {
        id: fullscreenWindow
        visible: root.playerFullscreen && root.view === "player"
        screen: panel.screen
        color: "black"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore

        VideoOutput {
            id: fullscreenVideoOutput
            anchors.fill: parent
            fillMode: VideoOutput.PreserveAspectFit
            smooth: true
        }

        Rectangle {
            anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
            height: 48; color: "#80000000"; visible: fullscreenWindow.visible
            RowLayout {
                anchors.fill: parent; anchors.margins: 10; spacing: 10
                Text { Layout.fillWidth: true; text: root.playerTitle || "Player"; color: "white"; font.family: Style.font.family; font.pixelSize: Style.font.title; font.bold: true; elide: Text.ElideRight }
                Button { text: "✕ Exit Full"; fontSize: Style.font.caption; onClicked: root.playerFullscreen = false }
                Button { text: "X"; fontSize: Style.font.caption; onClicked: root.close() }
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
            height: 64; color: "#80000000"; visible: fullscreenWindow.visible
            RowLayout {
                anchors.fill: parent; anchors.margins: 10; spacing: 10
                Button {
                    text: embeddedPlayer.playbackState === MediaPlayer.PlayingState ? "⏸" : "▶"
                    onClicked: embeddedPlayer.playbackState === MediaPlayer.PlayingState ? embeddedPlayer.pause() : embeddedPlayer.play()
                }
                PanelSlider {
                    Layout.fillWidth: true; bar: root.bar
                    minimum: 0; maximum: embeddedPlayer.duration > 0 ? embeddedPlayer.duration : 1
                    value: embeddedPlayer.position; enabled: embeddedPlayer.seekable
                    onMoved: function(v) { embeddedPlayer.position = v; }
                }
                Text {
                    text: {
                        function fmt(ms){ if(!ms||ms<0) return "0:00"; var s=Math.floor(ms/1000); var m=Math.floor(s/60); var sec=s%60; return m+":"+(sec<10?"0"+sec:sec); }
                        return fmt(embeddedPlayer.position)+" / "+fmt(embeddedPlayer.duration);
                    }
                    color: "white"; font.family: Style.font.family; font.pixelSize: Style.font.caption - 1
                }
                Button { text: "mpv"; onClicked: { root.playerFullscreen = false; root.playExternal(); } }
            }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            onDoubleClicked: root.playerFullscreen = false
        }
    }
}