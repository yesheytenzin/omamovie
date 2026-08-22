#!/usr/bin/env python3
"""Python bridge for OmaMovie - pure Python backend (Rust removed)."""
import sys
import json
import os
import hashlib
from pathlib import Path

# Make imports work for both:
#   python3 /path/bridge/python/__main__.py
#   python3 /path/bridge/python '{"cmd":...}'   (dir exec, __main__)
#   python3 -m bridge.python  (when plugin root in PYTHONPATH)
_this = Path(__file__).resolve()
_py_dir = _this.parent  # bridge/python
_bridge_dir = _py_dir.parent  # bridge
_plugin_root = _bridge_dir.parent  # omamovie
for p in [str(_py_dir), str(_bridge_dir), str(_plugin_root)]:
    if p not in sys.path:
        sys.path.insert(0, p)

# Now try imports - prefer direct sibling imports
try:
    from client import MovieBoxClient
    from cache import (
        get_provider_search_cache, set_provider_search_cache,
        get_provider_details_cache, set_provider_details_cache,
        get_provider_stream_cache, set_provider_stream_cache,
        get_homepage_cache, set_homepage_cache,
        get_genre_cache, set_genre_cache,
    )
    from models import subject_id as sid_fn, stype as stype_fn, extract_cover_url, extract_browse_metrics, captions_json_to_options, clean_title_simple, is_trailer_title
    from titles import clean_moviebox_title
    from utils import poster_dir, detect_ext, resolve_subtitle_dir
except ImportError as e:
    # fallback package style
    try:
        from bridge.python.client import MovieBoxClient
        from bridge.python.cache import (
            get_provider_search_cache, set_provider_search_cache,
            get_provider_details_cache, set_provider_details_cache,
            get_provider_stream_cache, set_provider_stream_cache,
            get_homepage_cache, set_homepage_cache,
            get_genre_cache, set_genre_cache,
        )
        from bridge.python.models import subject_id as sid_fn, stype as stype_fn, extract_cover_url, extract_browse_metrics, captions_json_to_options, clean_title_simple, is_trailer_title
        from bridge.python.titles import clean_moviebox_title
        from bridge.python.utils import poster_dir, detect_ext, resolve_subtitle_dir
    except ImportError:
        raise e


# Global service singletons similar to Rust OnceLock
_CLIENT = None

def get_client():
    global _CLIENT
    if _CLIENT is None:
        _CLIENT = MovieBoxClient()
    return _CLIENT

def str_arg(req: dict, key: str) -> str:
    v = req.get(key)
    return str(v) if isinstance(v, str) else ""

def usz_arg(req: dict, key: str, default: int) -> int:
    v = req.get(key)
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        try:
            return int(v)
        except:
            return default
    if isinstance(v, str) and v.isdigit():
        try:
            return int(v)
        except:
            return default
    return default

def safe_http_url(u) -> str:
    if isinstance(u, str) and (u.startswith("https://") or u.startswith("http://")):
        return u
    return ""

def sanitize_details_value(value):
    # Enforce http(s) scheme on any URL that can reach QML Image.source
    if not isinstance(value, dict):
        return value
    for key in ("cover", "stills", "trailer"):
        node = value.get(key)
        if isinstance(node, dict) and isinstance(node.get("url"), str):
            node["url"] = safe_http_url(node["url"])
    return value

def clean_title(raw: str) -> str:
    return raw.split("[")[0].strip() if raw else ""

def filter_and_sort_search_items(items: list, query: str):
    q = query.strip().lower()
    filtered = []
    for v in items:
        st = v.get("stype")
        try:
            st_int = int(st) if st is not None else 0
        except:
            st_int = 0
        if st_int != 1 and st_int != 2:
            continue
        title = v.get("title", "")
        if isinstance(title, str) and is_trailer_title(title):
            continue
        filtered.append(v)
    def score(title: str):
        t = title.lower()
        if t == q:
            return 0
        if q and q in t:
            return 1
        return 2
    def sort_key(v):
        title = v.get("title", "") or ""
        s = score(title)
        rating = v.get("rating")
        try:
            r = float(rating) if rating is not None else 0.0
        except:
            r = 0.0
        return (s, -r)
    filtered.sort(key=sort_key)
    seen = set()
    out = []
    for v in filtered:
        idv = v.get("id")
        if isinstance(idv, str):
            if idv in seen:
                continue
            seen.add(idv)
        out.append(v)
    return out

def unwrap_subjects(value):
    out = []
    if isinstance(value, dict):
        groups = value.get("results")
        if isinstance(groups, list):
            for group in groups:
                if isinstance(group, dict):
                    subjects = group.get("subjects")
                    if isinstance(subjects, list):
                        out.extend(subjects)
        if not out:
            lst = value.get("list")
            if isinstance(lst, list):
                out = lst[:]
            elif isinstance(value, list):
                out = value[:]
        if not out:
            if isinstance(value, list):
                out = value[:]
    elif isinstance(value, list):
        out = value[:]
    return out

def unwrap_homepage_subjects(value):
    out = []
    if not isinstance(value, dict):
        return out
    items = value.get("items")
    if isinstance(items, list):
        for item in items:
            if not isinstance(item, dict):
                continue
            banners = None
            b = item.get("banner")
            if isinstance(b, dict):
                banners = b.get("banners")
            if isinstance(banners, list):
                for bn in banners:
                    if isinstance(bn, dict) and "subject" in bn:
                        subj = bn.get("subject")
                        if subj:
                            out.append(subj)
            custom_items = None
            cd = item.get("customData")
            if isinstance(cd, dict):
                custom_items = cd.get("items")
            if isinstance(custom_items, list):
                for ci in custom_items:
                    if isinstance(ci, dict) and "subject" in ci:
                        out.append(ci["subject"])
            subjects = item.get("subjects")
            if isinstance(subjects, list):
                for s in subjects:
                    out.append(s)
    return out

def normalize_search_item(item: dict):
    id_val = item.get("subjectId") if "subjectId" in item else item.get("id")
    sid = sid_fn(id_val) if id_val is not None else ""
    if sid is None:
        sid = ""
    raw_title = item.get("title", "") if isinstance(item.get("title"), str) else ""
    title = clean_title(raw_title)
    st = stype_fn(item)
    year = ""
    rd = item.get("releaseDate")
    if isinstance(rd, str) and rd:
        year = rd[:4]
    cover = None
    c = item.get("cover")
    if isinstance(c, dict):
        url = c.get("url")
        if isinstance(url, str):
            cover = url
    cover = safe_http_url(cover)
    if not cover:
        cover = safe_http_url(extract_cover_url(item))
    rating = None
    irv = item.get("imdbRatingValue")
    if isinstance(irv, str):
        try:
            rating = float(irv)
        except:
            rating = None
    if rating is None:
        rating = extract_browse_metrics(item).get("rating")
    season = item.get("season")
    try:
        season = int(season) if isinstance(season, (int, str)) and str(season).lstrip("-").isdigit() else season
    except:
        pass
    duration = item.get("duration", "")
    if not isinstance(duration, str):
        duration = str(duration) if duration is not None else ""
    genre = item.get("genre", "")
    if not isinstance(genre, str):
        genre = str(genre) if genre is not None else ""
    return {
        "id": sid,
        "title": title,
        "stype": st,
        "year": year,
        "cover": cover,
        "rating": rating,
        "season": season,
        "duration": duration,
        "genre": genre,
    }

def run(cmd: str, req: dict):
    client = get_client()
    if cmd == "ping":
        return {"pong": True}

    elif cmd == "suggest":
        q = str_arg(req, "q")
        if not q:
            return {"suggestions": []}
        cached = get_provider_search_cache("moviebox", q.strip().lower(), 1)
        if cached is not None:
            items_raw = unwrap_subjects(cached)
            filtered = []
            for subj in items_raw:
                if not isinstance(subj, dict):
                    continue
                name = subj.get("title")
                if not isinstance(name, str):
                    continue
                name = clean_title(name)
                if not name or is_trailer_title(name):
                    continue
                st = stype_fn(subj)
                if st != 1 and st != 2:
                    continue
                idv = sid_fn(subj.get("subjectId") if "subjectId" in subj else subj.get("id"))
                if idv is None:
                    idv = ""
                cover = None
                c = subj.get("cover")
                if isinstance(c, dict):
                    url = c.get("url")
                    if isinstance(url, str):
                        cover = url
                cover = safe_http_url(cover)
                if not cover:
                    cover = safe_http_url(extract_cover_url(subj))
                filtered.append({"name": name, "id": idv, "cover": cover})
            if filtered:
                return {"suggestions": filtered[:8]}
        try:
            client.init()
        except:
            pass
        raw = client.suggest(q)
        items_raw = unwrap_subjects(raw)
        out = []
        for s in items_raw:
            if not isinstance(s, dict):
                continue
            name = s.get("title")
            if not isinstance(name, str):
                continue
            name = clean_title(name)
            if not name or is_trailer_title(name):
                continue
            st = stype_fn(s)
            if st != 1 and st != 2:
                continue
            idv = sid_fn(s.get("subjectId") if "subjectId" in s else s.get("id"))
            if idv is None:
                idv = ""
            cover = None
            c = s.get("cover")
            if isinstance(c, dict):
                url = c.get("url")
                if isinstance(url, str):
                    cover = url
            cover = safe_http_url(cover)
            if not cover:
                cover = safe_http_url(extract_cover_url(s))
            out.append({"name": name, "id": idv, "cover": cover})
        return {"suggestions": out[:8]}

    elif cmd == "genre":
        genre = str_arg(req, "genre") or str_arg(req, "q")
        genre = genre.strip()
        if not genre:
            return {"items": []}
        gl = genre.lower()
        cached = get_genre_cache(genre)
        if cached is not None:
            return {"items": cached}
        try:
            client.init()
        except:
            pass
        # candidate pool: keyword search pages, CONCURRENT; reuse cached raw pages
        candidates = []
        gk = f"genre:{gl}"
        pages = [1, 2, 3]
        missing = []
        for pg in pages:
            r = get_provider_search_cache("moviebox", gk, pg)
            if r is not None:
                items_raw = unwrap_subjects(r)
                items = [normalize_search_item(x) for x in items_raw if isinstance(x, dict)]
                if items:
                    candidates.extend(items)
            else:
                missing.append(pg)
        if len(candidates) < 40:
            missing.extend([4, 5])
        if missing:
            try:
                from concurrent.futures import ThreadPoolExecutor
                def _gpage(p):
                    try:
                        cc = MovieBoxClient()
                        try:
                            main = get_client()
                            cc.runtime_token = main.runtime_token
                            cc.active_base_idx = main.active_base_idx
                            cc.user_agent = main.user_agent
                            cc.client_info = main.client_info
                            cc.spoofed_ip = main.spoofed_ip
                        except:
                            pass
                        return p, cc.search(genre, p)
                    except Exception:
                        return p, None
                with ThreadPoolExecutor(max_workers=3) as ex:
                    for p, raw in ex.map(_gpage, missing):
                        if not raw:
                            continue
                        items_raw = unwrap_subjects(raw)
                        items = [normalize_search_item(x) for x in items_raw if isinstance(x, dict)]
                        if items:
                            candidates.extend(items)
                            try:
                                set_provider_search_cache("moviebox", gk, p, raw)
                            except:
                                pass
            except Exception:
                # fallback: serial
                for pg in missing:
                    try:
                        raw = client.search(genre, pg)
                    except:
                        continue
                    if not raw:
                        continue
                    items_raw = unwrap_subjects(raw)
                    items = [normalize_search_item(x) for x in items_raw if isinstance(x, dict)]
                    if not items:
                        continue
                    candidates.extend(items)
                    try:
                        set_provider_search_cache("moviebox", gk, pg, raw)
                    except:
                        pass
        # keep movies/series only, no trailers
        valid = filter_and_sort_search_items(candidates, genre)
        # genre-field match is the real filter (title-keyword match is wrong here)
        matched = []
        for v in valid:
            g = (v.get("genre") or "").lower()
            if gl in g:
                matched.append(v)
        # rank: non-title matches first (genre browsing), then title-keyword matches,
        # rating desc within each group
        def gkey(v):
            try:
                r = float(v.get("rating")) if v.get("rating") is not None else 0.0
            except:
                r = 0.0
            title = (v.get("title") or "").lower()
            in_title = 1 if gl in title else 0
            return (in_title, -r)
        matched.sort(key=gkey)
        seen = set()
        out = []
        for v in matched:
            idv = v.get("id")
            if isinstance(idv, str):
                if idv in seen:
                    continue
                seen.add(idv)
            out.append(v)
        # fallback: if genre-field matching is too thin, return valid keyword pool
        if len(out) < 5:
            out = valid[:20]
        try:
            set_genre_cache(genre, 1, out)
        except:
            pass
        return {"items": out}

    elif cmd == "search":
        q = str_arg(req, "q")
        page = usz_arg(req, "page", 1)
        if page < 1:
            page = 1
        if not q.strip():
            return {"items": []}
        cq = q.strip().lower()
        # genre browsing via genre cmd keeps keyword search pure
        cached = get_provider_search_cache("moviebox", cq, page)
        if cached is not None:
            items_raw = unwrap_subjects(cached)
            items = [normalize_search_item(x) for x in items_raw if isinstance(x, dict)]
            filtered = filter_and_sort_search_items(items, q)
            query_filtered = [v for v in filtered if isinstance(v.get("title"), str) and cq in v["title"].lower()]
            final = query_filtered if query_filtered else filtered
            if final:
                return {"items": final}
        try:
            client.init()
        except:
            pass
        raw = client.search(q, page)
        items_raw = unwrap_subjects(raw)
        items = [normalize_search_item(x) for x in items_raw if isinstance(x, dict)]
        if items:
            try:
                set_provider_search_cache("moviebox", cq, page, raw)
            except:
                pass
        filtered = filter_and_sort_search_items(items, q)
        if len(filtered) < 5 and page == 1:
            # concurrent fetch for pages 2-3 to cut latency (fresh token/host already persisted)
            try:
                from concurrent.futures import ThreadPoolExecutor, as_completed
                def _fetch(p):
                    try:
                        cc = MovieBoxClient()
                        try:
                            main = get_client()
                            cc.runtime_token = main.runtime_token
                            cc.active_base_idx = main.active_base_idx
                            cc.user_agent = main.user_agent
                            cc.client_info = main.client_info
                            cc.spoofed_ip = main.spoofed_ip
                        except:
                            pass
                        r = cc.search(q, p)
                        return p, r
                    except Exception:
                        return p, None
                with ThreadPoolExecutor(max_workers=2) as ex:
                    futs = {ex.submit(_fetch, pg): pg for pg in (2, 3)}
                    for fut in as_completed(futs):
                        p, raw2 = fut.result()
                        if raw2 is None:
                            continue
                        items2_raw = unwrap_subjects(raw2)
                        items2 = [normalize_search_item(x) for x in items2_raw if isinstance(x, dict)]
                        if not items2:
                            continue
                        try:
                            set_provider_search_cache("moviebox", cq, p, raw2)
                        except:
                            pass
                        more = filter_and_sort_search_items(items2, q)
                        more = [v for v in more if isinstance(v.get("title"), str) and q.lower() in v["title"].lower()]
                        if more:
                            filtered.extend(more)
                            # dedup
                            seen = set()
                            dedup = []
                            for v in filtered:
                                idv = v.get("id")
                                if isinstance(idv, str):
                                    if idv in seen:
                                        continue
                                    seen.add(idv)
                                dedup.append(v)
                            filtered = dedup
                            break
                    # if still <5 after concurrent, fallback sequential already covered
            except Exception:
                # fallback to old sequential on any error
                for next_page in range(2, 4):
                    if len(filtered) >= 5:
                        break
                    try:
                        raw2 = client.search(q, next_page)
                    except:
                        break
                    items2_raw = unwrap_subjects(raw2)
                    items2 = [normalize_search_item(x) for x in items2_raw if isinstance(x, dict)]
                    if not items2:
                        break
                    try:
                        set_provider_search_cache("moviebox", cq, next_page, raw2)
                    except:
                        pass
                    more = filter_and_sort_search_items(items2, q)
                    more = [v for v in more if isinstance(v.get("title"), str) and q.lower() in v["title"].lower()]
                    filtered.extend(more)
                    seen = set()
                    dedup = []
                    for v in filtered:
                        idv = v.get("id")
                        if isinstance(idv, str):
                            if idv in seen:
                                continue
                            seen.add(idv)
                        dedup.append(v)
                    filtered = dedup
                    if more:
                        break
            if not filtered:
                fallback = [normalize_search_item(x) for x in items_raw if isinstance(x, dict)]
                seen = set()
                dedup2 = []
                for v in fallback:
                    idv = v.get("id")
                    if isinstance(idv, str):
                        if idv in seen:
                            continue
                        seen.add(idv)
                    dedup2.append(v)
                def fallback_key(v):
                    title = (v.get("title") or "").lower()
                    is_tr = title.startswith("trailer-") or title.startswith("trailer ")
                    contains = q.lower() in title
                    rating = v.get("rating")
                    try:
                        r = float(rating) if rating is not None else 0.0
                    except:
                        r = 0.0
                    return (is_tr, not contains, -r)
                dedup2.sort(key=fallback_key)
                filtered = dedup2[:12]
        query_filtered = [v for v in filtered if isinstance(v.get("title"), str) and q.lower() in v["title"].lower()]
        final = query_filtered if query_filtered else filtered
        return {"items": final}

    elif cmd == "details":
        idv = str_arg(req, "id")
        if not idv:
            raise ValueError("missing id")
        cached = get_provider_details_cache("moviebox", idv)
        if cached is not None:
            return {"value": sanitize_details_value(cached)}
        try:
            client.init()
        except:
            pass
        value = client.get_details(idv)
        try:
            set_provider_details_cache("moviebox", idv, value)
        except:
            pass
        return {"value": sanitize_details_value(value)}

    elif cmd == "resources":
        idv = str_arg(req, "id")
        season = usz_arg(req, "season", 0)
        episode = usz_arg(req, "episode", 0)
        page = usz_arg(req, "page", 1)
        if page < 1:
            page = 1
        per_page = usz_arg(req, "perPage", 20)
        per_page = max(1, min(per_page, 50))
        resolution = req.get("resolution")
        if isinstance(resolution, str) and not resolution.strip():
            resolution = None
        elif not isinstance(resolution, str):
            resolution = None
        if not idv:
            raise ValueError("missing id")
        if resolution is None:
            cached = get_provider_stream_cache("moviebox", idv, season, episode)
            if cached is not None:
                items = cached.get("list", []) if isinstance(cached, dict) else []
                return {"items": items, "value": cached}
        try:
            client.init()
        except:
            pass
        raw = client.get_resources(idv, season, episode, page, resolution, per_page)
        if resolution is None:
            try:
                set_provider_stream_cache("moviebox", idv, season, episode, raw)
            except:
                pass
        items = raw.get("list", []) if isinstance(raw, dict) else []
        return {"items": items, "value": raw}

    elif cmd == "captions":
        idv = str_arg(req, "id")
        rid = str_arg(req, "rid")
        if not idv or not rid:
            raise ValueError("missing id or rid")
        try:
            client.init()
        except:
            pass
        payload = client.get_ext_captions(idv, rid)
        opts = captions_json_to_options(payload)
        options = [{"name": o["name"], "url": o["url"]} for o in opts]
        return {"options": options}

    elif cmd == "subfile":
        url = str_arg(req, "url")
        if not url:
            raise ValueError("missing url")
        headers = []
        h = req.get("headers")
        if isinstance(h, list):
            for pair in h:
                if isinstance(pair, list) and len(pair) >= 2 and isinstance(pair[0], str) and isinstance(pair[1], str):
                    headers.append((pair[0], pair[1]))
        path = client.download_subtitle_file(url, headers)
        return {"path": str(path)}

    elif cmd == "poster":
        url = str_arg(req, "url")
        if not url:
            raise ValueError("missing url")
        url = safe_http_url(url)
        if not url:
            raise ValueError("poster url must be http(s)")
        short = hashlib.md5(url.encode()).hexdigest()[:16]
        pdir = poster_dir()
        for ext in ["jpg", "png", "webp", "img"]:
            path = pdir / f"{short}.{ext}"
            if path.exists():
                return {"path": str(path)}
        data = client.fetch_poster_bytes(url)
        if not data:
            raise RuntimeError("poster download failed")
        if not data:
            raise RuntimeError("poster download returned no data")
        ext = detect_ext(data)
        path = pdir / f"{short}.{ext}"
        try:
            path.write_bytes(data)
        except Exception as e:
            raise RuntimeError(str(e))
        return {"path": str(path)}

    elif cmd == "posters":
        urls = req.get("urls")
        if not isinstance(urls, list) or not urls:
            return {"paths": {}}
        # dedupe, http(s) only
        seen = set()
        uniq = []
        for u in urls:
            if not isinstance(u, str) or u in seen:
                continue
            seen.add(u)
            s = safe_http_url(u)
            if s:
                uniq.append(s)
        out = {}
        def _one(u):
            short = hashlib.md5(u.encode()).hexdigest()[:16]
            pdir = poster_dir()
            for ext in ("jpg", "png", "webp", "img"):
                p = pdir / f"{short}.{ext}"
                if p.exists():
                    return u, str(p)
            data = client.fetch_poster_bytes(u)
            if not data:
                return u, ""
            p = pdir / f"{short}.{detect_ext(data)}"
            try:
                p.write_bytes(data)
                return u, str(p)
            except:
                return u, ""
        # parallel downloads, single python process
        try:
            from concurrent.futures import ThreadPoolExecutor
            with ThreadPoolExecutor(max_workers=8) as ex:
                for u, p in ex.map(_one, uniq):
                    if p:
                        out[u] = p
        except Exception:
            for u in uniq:
                _, p = _one(u)
                if p:
                    out[u] = p
        return {"paths": out}

    elif cmd in ("homepage", "discover", "home"):
        tab = str_arg(req, "tab")
        tab_id = tab if tab else "2"
        page = usz_arg(req, "page", 1)
        if page < 1:
            page = 1
        per_page = usz_arg(req, "perPage", 24)
        per_page = max(1, min(per_page, 50))
        raw = get_homepage_cache(tab_id, page)
        if raw is None:
            try:
                client.init()
            except:
                pass
            raw = client.get_homepage(tab_id, page)
            try:
                set_homepage_cache(tab_id, page, raw)
            except:
                pass
        subjects = unwrap_homepage_subjects(raw)
        seen = set()
        uniq = []
        for subj in subjects:
            if not isinstance(subj, dict):
                continue
            idv = sid_fn(subj.get("subjectId") if "subjectId" in subj else subj.get("id"))
            if not idv or idv in seen:
                continue
            seen.add(idv)
            uniq.append(subj)
        limited = uniq[:per_page*3]
        items = []
        for s in limited:
            norm = normalize_search_item(s)
            if norm.get("id"):
                items.append(norm)
            if len(items) >= per_page:
                break
        return {"items": items, "rawCount": len(limited)}

    elif cmd == "raw":
        op = str_arg(req, "op")
        try:
            client.init()
        except:
            pass
        if op == "suggest":
            q = str_arg(req, "q")
            return {"value": client.suggest(q)}
        elif op == "search":
            q = str_arg(req, "q")
            page = usz_arg(req, "page", 1)
            return {"value": client.search(q, page)}
        elif op == "details":
            idv = str_arg(req, "id")
            return {"value": client.get_details(idv)}
        else:
            raise ValueError(f"unknown raw op: {op}")
    else:
        raise ValueError(f"unknown command: {cmd}")

def main():
    raw = sys.argv[1] if len(sys.argv) > 1 else "{}"
    try:
        req = json.loads(raw)
        if not isinstance(req, dict):
            raise ValueError("bad request: not an object")
        cmd = req.get("cmd")
        if not isinstance(cmd, str):
            raise ValueError("missing cmd")
        rest = {k: v for k, v in req.items() if k != "cmd"}
        data = run(cmd, rest)
        resp = {"ok": True, "error": None}
        resp.update(data)
        print(json.dumps(resp, separators=(',', ':')))
    except Exception as e:
        err = str(e)
        try:
            print(json.dumps({"ok": False, "error": f"bad request: {err}" if "bad request" not in err else err}, separators=(',', ':')))
        except:
            print(json.dumps({"ok": False, "error": err}))
        return

if __name__ == "__main__":
    main()
