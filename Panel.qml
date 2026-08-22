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

    function sanitize(s) {
        if (!s) return "";
        return String(s).replace(/<[^>]*>/g, "");
    }
    function sanitizeDetails(d) {
        if (!d) return null;
        var out = {};
        for (var k in d) {
            var v = d[k];
            if (typeof v === "string") out[k] = root.sanitize(v);
            else if (Array.isArray(v)) out[k] = v.map(function(x) { return typeof x === "string" ? root.sanitize(x) : x; });
            else out[k] = v;
        }
        return out;
    }
    function sanitizeStreams(arr) {
        if (!Array.isArray(arr)) return [];
        return arr.map(function(s) {
            var out = {};
            for (var k in s) {
                var v = s[k];
                if (typeof v === "string") out[k] = root.sanitize(v);
                else out[k] = v;
            }
            return out;
        });
    }

    readonly property string bridge: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omamovie/omamovie-bridge"

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
    property string selectedGenre: ""
    property int genreGen: 0
    property var genreCache: ({}) // genre -> items array, fast second-click
    property var genreCacheTime: ({}) // genre -> timestamp ms

    readonly property var genres: [
        "All", "Action", "Comedy", "Drama", "Horror", "Sci-Fi",
        "Thriller", "Romance", "Animation", "Documentary", "Fantasy",
        "Mystery", "Adventure", "Crime", "Family"
    ]

    readonly property bool isSeries: root.details ? (root.details.subjectType === 2 || root.seasons.length > 0) : false
    property bool streamsBusy: false
    property int streamsGen: 0

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

    // dedicated streams process — bypasses main queue so E1 loads instantly even when details pending
    Process {
        id: streamsProc
        property string collected: ""
        property var pendingCb: null
        stdout: SplitParser { onRead: function(data) { streamsProc.collected += data } }
        onExited: function(code, status) {
            var cb = streamsProc.pendingCb;
            streamsProc.pendingCb = null;
            var resp = null;
            try { resp = JSON.parse(streamsProc.collected); } catch (e) {}
            if (cb) cb(resp, code);
        }
    }
    function requestStreams(params, cb) {
        // if streams proc busy, queue via main request to avoid overlap — rare
        if (streamsProc.running) {
            request("resources", params, cb);
            return;
        }
        streamsProc.collected = "";
        streamsProc.pendingCb = cb;
        var req = JSON.parse(JSON.stringify(params));
        req.cmd = "resources";
        streamsProc.command = [root.bridge, JSON.stringify(req)];
        streamsProc.running = true;
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
        if (c && typeof c === "object") return root.safeUrl(c.url || "");
        if (typeof c === "string") return root.safeUrl(c);
        return "";
    }
    // Only http(s) URLs may reach Image.source (scraper-controlled data)
    function safeUrl(s) {
        s = String(s || "");
        if (s.indexOf("https://") === 0 || s.indexOf("http://") === 0) return s;
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

    // ---------------- recent search history (max 10, in-memory) ----------------
    function pushHistory(q) {
        q = String(q || "").trim();
        if (!q) return;
        // dedupe: remove existing then prepend
        var found = -1;
        for (var i = 0; i < historyModel.count; i++) {
            if (historyModel.get(i).name.toLowerCase() === q.toLowerCase()) { found = i; break; }
        }
        if (found >= 0) historyModel.remove(found);
        historyModel.insert(0, { name: root.sanitize(q) });
        while (historyModel.count > 10) historyModel.remove(historyModel.count - 1);
    }

    // ---------------- actions ----------------
    function doSearch() {
        var q = searchField.text.trim();
        if (!q) return;
        root.pushHistory(q);
        root.query = q;
        root.selectedGenre = ""; // clear genre selection so bar shows All
        root.busy = true;
        root.busyLabel = "Searching \u2026";
        root.statusText = "";
        root.searchGen++;
        root.genreGen++; // cancel any pending genre fetch
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
                resultModel.append({ id: root.sanitize(r.id), title: root.sanitize(r.title), year: root.sanitize(r.year || ""), rating: root.sanitize(r.rating !== null ? String(r.rating) : "-"), cover: root.sanitize(r.cover || ""), coverPath: root.sanitize(r.cover || ""), duration: root.sanitize(r.duration || ""), stype: root.sanitize(r.stype || "") });
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
        root.currentId = root.sanitize(it.id);
        root.currentTitle = root.sanitize(it.title);
        // optimistic — switch immediately for snappy feel
        root.details = null;
        root.seasons = [];
        root.streams = [];
        root.selStream = -1;
        root.subs = [];
        detailPoster.source = root.safeUrl(it.cover);
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
                root.streams = root.sanitizeStreams(resp.items);
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
            root.details = root.sanitizeDetails(resp.value);
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
            if (cover) detailPoster.source = root.safeUrl(cover);
        });
    }

    function openHomeDetails(idx) {
        if (idx < 0 || idx >= homeModel.count) return;
        var it = homeModel.get(idx);
        root.currentId = root.sanitize(it.id);
        root.currentTitle = root.sanitize(it.title);
        root.details = null;
        root.seasons = [];
        root.streams = [];
        root.selStream = -1;
        root.subs = [];
        detailPoster.source = root.safeUrl(it.cover);
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
                root.streams = root.sanitizeStreams(resp.items);
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
            root.details = root.sanitizeDetails(resp.value);
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
            if (cover) detailPoster.source = root.safeUrl(cover);
        });
    }

    function loadStreams(se, ep) {
        root.busy = true;
        root.streamsBusy = true;
        root.busyLabel = "Loading streams \u2026";
        root.resourceGen++;
        root.streamsGen++;
        var gen = root.resourceGen;
        var sgen = root.streamsGen;
        // status placeholder handled via streamsBusy + streams length in UI
        if (root.isSeries) root.statusText = "Loading streams for S" + se + "E" + (ep || 1) + " \u2026";
        else root.statusText = "Loading streams \u2026";
        var params = { id: root.currentId, season: se, episode: ep, perPage: 20 };
        var cb = function(resp, code) {
            if (gen !== root.resourceGen || sgen !== root.streamsGen) return;
            root.busy = false;
            root.streamsBusy = false;
            var items = (resp && resp.ok && resp.items) ? resp.items : [];
            root.streams = root.sanitizeStreams(items);
            root.selStream = root.streams.length > 0 ? 0 : -1;
            if (root.streams.length === 0) {
                // Sub->Dub auto-fallback: if no streams and details has dubs, try first alt subjectId
                var dubs = (root.details && root.details.dubs) ? root.details.dubs : [];
                var tried = false;
                for (var i = 0; i < dubs.length; i++) {
                    var d = dubs[i];
                    var dubId = d.subjectId || d.id || "";
                    var lan = d.lanName || d.language || "dub";
                    if (dubId && dubId !== root.currentId) {
                        tried = true;
                        root.statusText = "No streams for S" + se + "E" + (ep || 1) + " — trying " + lan + " \u2026";
                        // fire fallback via main queue (avoid streamsProc recursion)
                        request("resources", { id: dubId, season: se, episode: ep, perPage: 20 }, function(r2) {
                            if (gen !== root.resourceGen || sgen !== root.streamsGen) return;
                            var it2 = (r2 && r2.ok && r2.items) ? r2.items : [];
                            if (it2.length > 0) {
                                root.streams = root.sanitizeStreams(it2);
                                root.selStream = 0;
                                root.statusText = "auto-switched to " + lan + " — " + root.streams.length + " streams";
                            } else {
                                root.statusText = "No streams for S" + se + "E" + (ep || 1) + " — tap again to retry";
                            }
                        });
                        break;
                    }
                }
                if (!tried) root.statusText = "No streams for S" + se + "E" + (ep || 1) + " — tap again to retry";
                if (!root.isSeries) root.statusText = root.streams.length === 0 ? "No streams — tap again to retry" : root.statusText;
            } else {
                if (root.isSeries) root.statusText = root.streams.length + " streams for S" + se + "E" + (ep || 1) + " — pick one and press Play";
                else root.statusText = root.streams.length + " streams — pick one and press Play";
                // prefetch next episode for instant E+1 switch
                if (root.isSeries && ep > 0 && ep < root.maxEp) {
                    Qt.callLater(function(){ root.prefetchStreams(se, ep + 1); });
                }
            }
        };
        // use dedicated proc for instant E1 load without blocking on details queue
        root.requestStreams(params, cb);
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
    Process {
        id: prefetchStreamsProc
        property string collected: ""
        stdout: SplitParser { onRead: function(data){ prefetchStreamsProc.collected += data } }
        onExited: function(code){ try{ JSON.parse(prefetchStreamsProc.collected);}catch(e){} }
    }

    function prefetchDetails(id) {
        if (!id || bridgeProc.running || root.pending.length > 0 || prefetchProc.running) return;
        var req = JSON.stringify({ cmd: "details", id: id });
        prefetchProc.collected = "";
        prefetchProc.command = [root.bridge, req];
        prefetchProc.running = true;
    }
    function prefetchStreams(se, ep) {
        if (!root.currentId || !root.isSeries) return;
        if (ep < 1 || ep > root.maxEp) return;
        if (bridgeProc.running || root.pending.length > 0 || prefetchStreamsProc.running || streamsProc.running) return;
        // only prefetch if next episode not yet cached in file system? we just fire and let bridge cache it
        var req = JSON.stringify({ cmd: "resources", id: root.currentId, season: se, episode: ep, perPage: 20 });
        prefetchStreamsProc.collected = "";
        prefetchStreamsProc.command = [root.bridge, req];
        prefetchStreamsProc.running = true;
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
                homeModel.append({ id: root.sanitize(r.id), title: root.sanitize(r.title), year: root.sanitize(r.year || ""), rating: root.sanitize(r.rating !== null ? String(r.rating) : "-"), cover: root.sanitize(r.cover || ""), coverPath: root.sanitize(r.cover || ""), duration: root.sanitize(r.duration || ""), stype: root.sanitize(r.stype || "") });
            }
            root.view = "home";
            root.statusText = homeModel.count ? "Discover \u2022 " + homeModel.count + " titles" : "Search movies, shows and anime";
        });
    }

    function goHome() {
        if (homeModel.count === 0) root.loadHome(false);
        else root.view = "home";
        root.selectedGenre = "";
        if (root.view === "home" && homeModel.count) root.statusText = "Discover \u2022 " + homeModel.count + " titles";
        else root.statusText = "Search movies, shows and anime";
    }

    function searchByGenre(genre, force) {
        if (genre === "All" || genre === "") {
            root.selectedGenre = "";
            root.loadHome(true);
            return;
        }
        root.selectedGenre = genre;
        // Fast path: in-memory cache (10 min) for instant second click — choose best
        var now = Date.now();
        var cached = root.genreCache[genre];
        var cachedAt = root.genreCacheTime[genre] || 0;
        var fresh = cached && (now - cachedAt < 600000) && !force;
        if (fresh) {
            root.results = cached;
            resultModel.clear();
            for (var ci = 0; ci < cached.length; ci++) {
                var cr = cached[ci];
                resultModel.append({ id: root.sanitize(cr.id), title: root.sanitize(cr.title), year: root.sanitize(cr.year || ""), rating: root.sanitize(cr.rating !== null ? String(cr.rating) : "-"), cover: root.sanitize(cr.cover || ""), coverPath: root.sanitize(cr.cover || ""), duration: root.sanitize(cr.duration || ""), stype: root.sanitize(cr.stype || "") });
            }
            root.view = "grid";
            root.statusText = resultModel.count + " " + genre + " titles";
            root.busy = false;
            return;
        }
        root.busy = true;
        root.busyLabel = "Loading " + genre + " \u2026";
        root.statusText = "";
        root.genreGen++;
        var gen = root.genreGen;
        request("genre", { genre: genre }, function(resp, code) {
            if (gen !== root.genreGen) return;
            root.busy = false;
            if (!resp || !resp.ok) {
                root.statusText = (resp && resp.error) || "Search failed";
                return;
            }
            root.results = resp.items || [];
            // cache for fast next click
            var nc = {}; for (var k in root.genreCache) nc[k] = root.genreCache[k];
            nc[genre] = root.results.slice();
            root.genreCache = nc;
            var nt = {}; for (var k2 in root.genreCacheTime) nt[k2] = root.genreCacheTime[k2];
            nt[genre] = Date.now();
            root.genreCacheTime = nt;
            resultModel.clear();
            for (var i = 0; i < root.results.length; i++) {
                var r = root.results[i];
                resultModel.append({ id: root.sanitize(r.id), title: root.sanitize(r.title), year: root.sanitize(r.year || ""), rating: root.sanitize(r.rating !== null ? String(r.rating) : "-"), cover: root.sanitize(r.cover || ""), coverPath: root.sanitize(r.cover || ""), duration: root.sanitize(r.duration || ""), stype: root.sanitize(r.stype || "") });
            }
            root.view = "grid";
            root.statusText = resultModel.count + " " + genre + " titles";
        });
    }

    function backToGrid() {
        root.view = "grid";
    }

    function refreshCurrent() {
        if (root.view === "home") root.loadHome(true);
        else if (root.view === "grid") {
            if (root.selectedGenre) root.searchByGenre(root.selectedGenre, true);
            else root.doSearch();
        }
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
    ListModel { id: historyModel }

    Timer {
        id: suggestTimer
        interval: 220
        repeat: false
        onTriggered: {
            var q = searchField.text.trim();
            if (q.length < 2) { suggestionModel.clear(); return; }
            // instant history prefix matches (no network)
            var ql = q.toLowerCase();
            var hist = [];
            for (var hi = 0; hi < historyModel.count; hi++) {
                var hn = historyModel.get(hi).name;
                if (hn.toLowerCase().indexOf(ql) === 0) hist.push(hn);
                if (hist.length >= 4) break;
            }
            if (hist.length > 0) {
                suggestionModel.clear();
                for (var h = 0; h < hist.length; h++) suggestionModel.append({ name: hist[h] });
            }
            root.suggestGen++;
            var gen = root.suggestGen;
            request("suggest", { q: q }, function(resp) {
                if (gen !== root.suggestGen) return;
                var list = (resp && resp.ok && resp.suggestions) ? resp.suggestions : [];
                // merge history + network, dedup
                var seen = {};
                for (var si = 0; si < suggestionModel.count; si++) seen[suggestionModel.get(si).name.toLowerCase()] = true;
                // if hist was shown, keep it and append new network items not in hist
                if (hist.length > 0 && suggestionModel.count > 0) {
                    // clear and rebuild merged to keep hist first
                    var merged = hist.slice();
                    for (var i = 0; i < list.length && merged.length < 8; i++) {
                        var n = root.sanitize(list[i].name);
                        if (!seen[n.toLowerCase()]) { merged.push(n); seen[n.toLowerCase()] = true; }
                    }
                    suggestionModel.clear();
                    for (var m = 0; m < merged.length; m++) suggestionModel.append({ name: merged[m] });
                } else {
                    suggestionModel.clear();
                    for (var i2 = 0; i2 < list.length && i2 < 8; i2++)
                        suggestionModel.append({ name: root.sanitize(list[i2].name) });
                }
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
        // Dynamic sizing: fractions of the user's screen resolution, no fixed caps.
        // uiScale scales poster cells/details with the screen width (1.0 at 1920px).
        readonly property bool isSmallScreen: panel.screenW > 0 && panel.screenW < 1366
        readonly property bool isLargeScreen: panel.screenW >= 1920
        readonly property real uiScale: Math.min(1.4, Math.max(0.9, panel.screenW / 1920))
        contentWidth: root.playerFullscreen && root.view === "player"
                      ? panel.screenW
                      : isSmallScreen ? panel.fittedContentWidth(panel.screenW * 0.74)
                      : isLargeScreen ? panel.fittedContentWidth(panel.screenW * 0.67)
                      : panel.fittedContentWidth(panel.screenW * 0.71)
        // Same computed size for every view (home/grid/details/player)
        contentHeight: root.playerFullscreen && root.view === "player"
                       ? panel.screenH
                       : isSmallScreen ? panel.fittedContentHeight(panel.screenH * 0.86, panel.screenH * 0.94)
                       : isLargeScreen ? panel.fittedContentHeight(panel.screenH * 0.84, panel.screenH * 0.90)
                       : panel.fittedContentHeight(panel.screenH * 0.82, panel.screenH * 0.90)

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
                            textFormat: Text.PlainText
                            text: root.busy ? root.busyLabel : "Playing"
                            font.family: Style.font.family; font.pixelSize: Style.font.caption; color: Color.accent
                        }
                    }
                }
                Text {
                    textFormat: Text.PlainText
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
                Keys.onEscapePressed: function(event) {
                    if (searchField.text.length > 0) {
                        searchField.clear();
                        suggestionModel.clear();
                    } else {
                        suggestionModel.clear();
                        root.close();
                    }
                    event.accepted = true;
                }
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

        // recent searches — chips row (max 10, click to re-search)
        Flow {
            id: historyFlow
            Layout.fillWidth: true
            spacing: 6
            visible: historyModel.count > 0 && suggestionModel.count === 0 && (root.view === "home" || root.view === "grid")
            Layout.preferredHeight: visible ? implicitHeight : 0
            Repeater {
                model: historyModel
                Button {
                    text: model.name
                    fontSize: Style.font.caption
                    horizontalPadding: 10
                    verticalPadding: 4
                    onClicked: { searchField.text = model.name; root.doSearch(); }
                }
            }
        }

        // genre selector — persistent for home + grid only (fixes disappearing on genre click)
        Flow {
            Layout.fillWidth: true
            visible: root.view === "home" || root.view === "grid"
            spacing: 6
            Repeater {
                model: root.genres
                Button {
                    text: modelData
                    fontSize: Style.font.caption
                    horizontalPadding: 10
                    verticalPadding: 4
                    enabled: !root.busy && !root.homeLoading
                    selected: root.selectedGenre === modelData || (modelData === "All" && root.selectedGenre === "")
                    onClicked: root.searchByGenre(modelData)
                }
            }
        }

        // body — fills the fixed panel; same size on every view
        Item {
            id: body
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: Math.round(Math.min(Math.max(300, panel.screenH * 0.52), panel.screenH * 0.60))
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
                        cellWidth: Math.round(168 * panel.uiScale)
                        cellHeight: Math.round(236 * panel.uiScale)
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
                                        source: root.safeUrl(model.cover) || root.safeUrl(model.coverPath)
                                        fillMode: Image.PreserveAspectCrop
                                        visible: source !== ""
                                        asynchronous: true
                                        cache: true
                                    }
                                    Rectangle {
                                        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                                        height: 22; color: "#66000000"; visible: model.rating && model.rating !== "-"
                                        Text { anchors.centerIn: parent; textFormat: Text.PlainText; text: "\u2605 " + model.rating; font.family: Style.font.family; font.pixelSize: 10; color: "white"; font.bold: true}
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
                                    textFormat: Text.PlainText
                                    text: model.title
                                    elide: Text.ElideRight
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    color: Color.foreground
                                    maximumLineCount: 1
                                }
                                Text {
                                    textFormat: Text.PlainText
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
                                enabled: !root.busy && !root.homeLoading
                                onEntered: homeHoverTimer.restart()
                                onExited: homeHoverTimer.stop()
                                onClicked: { if (!root.busy && !root.homeLoading) root.openHomeDetails(index) }
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
                cellWidth: Math.round(168 * panel.uiScale)
                cellHeight: Math.round(236 * panel.uiScale)
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
                                source: root.safeUrl(model.cover) || root.safeUrl(model.coverPath)
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
                                    textFormat: Text.PlainText
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
                            textFormat: Text.PlainText
                            text: model.title
                            elide: Text.ElideRight
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            color: Color.foreground
                            maximumLineCount: 1
                        }
                        Text {
                            textFormat: Text.PlainText
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
                        enabled: !root.busy
                        onEntered: if (!root.busy) hoverTimer.restart()
                        onExited: hoverTimer.stop()
                        onClicked: { if (!root.busy) root.openDetails(index) }
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
                        Layout.preferredWidth: Math.round(170 * panel.uiScale)
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
                                textFormat: Text.PlainText
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
                            textFormat: Text.PlainText
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
                            textFormat: Text.PlainText
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
                            visible: root.streams.length > 0
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
                        // streams placeholder — visible when empty (loading vs no streams)
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.streams.length === 0
                            Text {
                                anchors.centerIn: parent
                                width: parent.width - 20
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                wrapMode: Text.WordWrap
                                textFormat: Text.PlainText
                                text: root.streamsBusy
                                      ? (root.isSeries ? ("Loading streams for S" + root.curSeason + "E" + (root.curEp || 1) + " \u2026") : "Loading streams \u2026")
                                      : (root.isSeries ? ("No streams for S" + root.curSeason + "E" + (root.curEp || 1) + " — tap again to retry") : "No streams — tap again to retry")
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                color: root.streamsBusy ? Color.accent : Qt.darker(Color.foreground, 1.4)
                                opacity: root.streamsBusy ? 0.9 : 0.8
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                enabled: !root.streamsBusy && root.currentId !== ""
                                onClicked: root.loadStreams(root.isSeries ? root.curSeason : 0, root.isSeries ? root.curEp : 0)
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Layout.bottomMargin: 10
                            Text {
                                Layout.fillWidth: true
                                textFormat: Text.PlainText
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
                            textFormat: Text.PlainText
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
                            textFormat: Text.PlainText
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
                        textFormat: Text.PlainText
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
                Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: root.playerTitle || "Player"; color: "white"; font.family: Style.font.family; font.pixelSize: Style.font.title; font.bold: true; elide: Text.ElideRight }
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
                    textFormat: Text.PlainText
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

    // Esc from any view closes panel; searchField's own Keys handler clears field when focused
    Shortcut {
        sequence: "Escape"
        enabled: root.opened && !searchField.activeFocus
        onActivated: root.close()
        context: Qt.WindowShortcut
    }
}