"""Port of providers/moviebox/client.rs"""
import json
import os
import time
import urllib.request
import urllib.error
import urllib.parse
try:
    from .crypto import build_signed_headers, generate_client_info_and_ua, random_spoofed_ip
except ImportError:
    from crypto import build_signed_headers, generate_client_info_and_ua, random_spoofed_ip

HOST_POOL = [
    "https://api6.aoneroom.com",
    "https://api5.aoneroom.com",
    "https://api4.aoneroom.com",
    "https://api4sg.aoneroom.com",
    "https://api3.aoneroom.com",
    "https://api6sg.aoneroom.com",
    "https://api.inmoviebox.com",
]

RETRY_STATUS_CODES = {403, 406, 407, 429, 500, 502, 503, 504}

class ScraperError(Exception):
    pass

class MovieBoxClient:
    def __init__(self):
        self.runtime_token = None
        self.active_base_idx = 0
        self.user_agent, self.client_info = generate_client_info_and_ua()
        self.spoofed_ip = random_spoofed_ip()
        # try to load persisted token/host to avoid init roundtrip on cold start
        self._load_persisted_state()
        # Use requests if available, else urllib
        self._use_requests = False
        try:
            import requests  # type: ignore
            from requests.adapters import HTTPAdapter
            self._requests = requests
            self._session = requests.Session()
            # keep-alive pool tuned for 7 hosts
            adapter = HTTPAdapter(pool_connections=7, pool_maxsize=7, max_retries=0)
            self._session.mount("https://", adapter)
            self._session.mount("http://", adapter)
            self._session.headers.update({"Connection": "keep-alive", "Accept-Encoding": "gzip"})
            self._use_requests = True
        except ImportError:
            self._requests = None
            self._session = None

    def _token_path(self):
        try:
            from pathlib import Path
            import os
            base = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "moviebox-tui" / "moviebox"
            base.mkdir(parents=True, exist_ok=True)
            return base / ".token.json"
        except:
            return None

    def _host_path(self):
        try:
            from pathlib import Path
            import os
            base = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "moviebox-tui" / "moviebox"
            return base / ".host_idx"
        except:
            return None

    def _load_persisted_state(self):
        # token: {"token": "...", "ts": 123} 12h expiry
        try:
            p = self._token_path()
            if p and p.exists():
                import json, time
                data = json.loads(p.read_text())
                tok = data.get("token")
                ts = data.get("ts", 0)
                if tok and isinstance(tok, str) and (time.time() - ts) < 12*3600:
                    self.runtime_token = tok
        except:
            pass
        try:
            p = self._host_path()
            if p and p.exists():
                idx = int(p.read_text().strip())
                if 0 <= idx < len(HOST_POOL):
                    self.active_base_idx = idx
        except:
            pass

    def _save_token(self):
        try:
            p = self._token_path()
            if p:
                import json, time
                p.write_text(json.dumps({"token": self.runtime_token, "ts": int(time.time())}))
        except:
            pass

    def _save_host(self):
        try:
            p = self._host_path()
            if p:
                p.write_text(str(self.active_base_idx))
        except:
            pass

    def _absorb_x_user(self, headers):
        x_user = None
        for k, v in headers.items():
            if k.lower() == "x-user":
                x_user = v
                break
        if not x_user:
            return
        try:
            if isinstance(x_user, bytes):
                x_user = x_user.decode()
            data = json.loads(x_user)
            token = data.get("token") if isinstance(data, dict) else None
            if isinstance(token, str) and token:
                self.runtime_token = token
                self._save_token()
        except:
            pass

    def _http_request(self, method: str, url: str, headers: dict, body: str | None):
        if self._use_requests:
            try:
                if method.upper() == "POST":
                    resp = self._session.request(method, url, headers=headers, data=body.encode() if body else None, timeout=(2, 8))
                else:
                    resp = self._session.request(method, url, headers=headers, timeout=(2, 8))
                status = resp.status_code
                resp_headers = dict(resp.headers)
                self._absorb_x_user(resp_headers)
                if status in RETRY_STATUS_CODES:
                    # Handle 429 backoff header
                    retry_after = None
                    if status == 429:
                        ra = resp.headers.get("Retry-After") or resp.headers.get("retry-after")
                        try:
                            retry_after = int(ra) * 1000 if ra else 400
                            retry_after = min(retry_after, 3000)
                        except:
                            retry_after = 400
                    return None, status, retry_after, None  # signal retry
                # success?
                if not (200 <= status < 300):
                    return None, status, None, f"API status {status}"
                try:
                    text = resp.text
                    data = json.loads(text) if text else {}
                    # unwrap data field if present
                    if isinstance(data, dict) and "data" in data:
                        return data["data"], status, None, None
                    return data, status, None, None
                except json.JSONDecodeError as e:
                    return None, status, None, f"JSON {e}"
            except Exception as e:
                return None, None, None, str(e)
        else:
            # urllib fallback
            try:
                req = urllib.request.Request(url, method=method.upper(), headers=headers)
                if body is not None:
                    req.data = body.encode()
                with urllib.request.urlopen(req, timeout=8) as resp:
                    status = resp.getcode()
                    resp_headers = dict(resp.getheaders())
                    self._absorb_x_user(resp_headers)
                    if status in RETRY_STATUS_CODES:
                        retry_after = 400 if status == 429 else None
                        # Try to get Retry-After
                        if status == 429:
                            ra = resp_headers.get("Retry-After") or resp_headers.get("retry-after")
                            try:
                                retry_after = int(ra) * 1000 if ra else 400
                                retry_after = min(retry_after, 3000)
                            except:
                                retry_after = 400
                        return None, status, retry_after, None
                    if not (200 <= status < 300):
                        return None, status, None, f"API status {status}"
                    text = resp.read().decode('utf-8', errors='ignore')
                    try:
                        data = json.loads(text) if text else {}
                        if isinstance(data, dict) and "data" in data:
                            return data["data"], status, None, None
                        return data, status, None, None
                    except json.JSONDecodeError as e:
                        return None, status, None, f"JSON {e}"
            except urllib.error.HTTPError as e:
                status = e.code
                try:
                    headers = dict(e.headers)
                    self._absorb_x_user(headers)
                except:
                    pass
                if status in RETRY_STATUS_CODES:
                    retry_after = None
                    if status == 429:
                        try:
                            ra = e.headers.get("Retry-After")
                            retry_after = int(ra) * 1000 if ra else 400
                            retry_after = min(retry_after, 3000)
                        except:
                            retry_after = 400
                    return None, status, retry_after, None
                return None, status, None, f"API status {status}"
            except Exception as e:
                return None, None, None, str(e)

    def _request_hosts(self, method: str, path_and_query: str, body: str | None):
        backoff_ms = 50
        start_idx = self.active_base_idx
        last_error = None
        for i in range(len(HOST_POOL)):
            if i > 0:
                time.sleep(backoff_ms / 1000.0)
                backoff_ms = 50
            idx = (start_idx + i) % len(HOST_POOL)
            base = HOST_POOL[idx]
            url = f"{base}{path_and_query}"
            headers = build_signed_headers(method, url, body, self.runtime_token, self.user_agent, self.client_info, self.spoofed_ip)
            data, status, retry_after, err = self._http_request(method, url, headers, body)
            if err is None and data is not None:
                self.active_base_idx = idx
                self._save_host()
                return data
            if retry_after is not None:
                backoff_ms = retry_after
                last_error = f"retry {status}"
                continue
            if status in RETRY_STATUS_CODES:
                last_error = f"retry {status}"
                continue
            if data is None and err:
                last_error = err
                continue
            if status is not None:
                last_error = f"status {status}"
                continue
            last_error = err or "unknown"
            continue
        raise ScraperError(f"All hosts exhausted: {last_error}" if last_error else "All hosts exhausted")

    def request(self, method: str, path_and_query: str, body: str | None):
        try:
            return self._request_hosts(method, path_and_query, body)
        except ScraperError as e:
            # If no token, try init once
            if self.runtime_token is None:
                try:
                    self.init()
                except:
                    pass
                return self._request_hosts(method, path_and_query, body)
            raise

    def init(self):
        # fast path: token already in memory and file fresh
        if self.runtime_token is not None:
            try:
                p = self._token_path()
                if p and p.exists():
                    import json, time as _t
                    d = json.loads(p.read_text())
                    if _t.time() - d.get("ts", 0) < 12 * 3600:
                        return {"cached": True}
            except:
                pass
        # try load from file without network
        if self.runtime_token is None:
            try:
                p = self._token_path()
                if p and p.exists():
                    import json, time as _t2
                    d = json.loads(p.read_text())
                    tok = d.get("token")
                    ts = d.get("ts", 0)
                    if tok and isinstance(tok, str) and (_t2.time() - ts) < 12 * 3600:
                        self.runtime_token = tok
                        return {"cached": True}
            except:
                pass
        path = "/wefeed-mobile-bff/tab-operating?page=1&tabId=0&version="
        data = self._request_hosts("GET", path, None)
        if self.runtime_token is None:
            raise ScraperError("Missing token after init")
        return data

    def get(self, path_and_query: str):
        return self.request("GET", path_and_query, None)

    def post(self, path_and_query: str, body_dict: dict):
        body_str = json.dumps(body_dict, separators=(',', ':'))
        return self.request("POST", path_and_query, body_str)

    # High level API mirroring Rust

    def search(self, query: str, page: int):
        payload = {
            "keyword": query,
            "page": page,
            "perPage": 20,
            "subjectType": "All",
            "tabId": "All"
        }
        return self.post("/wefeed-mobile-bff/subject-api/search/v2", payload)

    def suggest(self, query: str):
        return self.search(query, 1)

    def get_details(self, subject_id: str):
        path = f"/wefeed-mobile-bff/subject-api/get?subjectId={subject_id}"
        details = self.get(path)
        # check stype
        stype = None
        if isinstance(details, dict):
            for k in ("subjectType", "stype"):
                v = details.get(k)
                if isinstance(v, int):
                    stype = v
                    break
                if isinstance(v, str) and v.isdigit():
                    try: stype = int(v); break
                    except: pass
        if stype is None:
            stype = 1
        if stype == 2:
            season_path = f"/wefeed-mobile-bff/subject-api/season-info?subjectId={subject_id}"
            try:
                season_info = self.get(season_path)
                if isinstance(details, dict) and isinstance(season_info, dict):
                    details["seasons"] = season_info
            except:
                pass
        return details

    def get_homepage(self, tab_id: str, page: int):
        path = f"/wefeed-mobile-bff/tab-operating?page={page}&tabId={tab_id}&version="
        return self.get(path)

    def get_resources(self, subject_id: str, season: int, episode: int, page: int, resolution: str | None, per_page: int):
        res_param = f"&resolution={resolution}" if resolution else ""
        if season == 0 and episode == 0:
            path = f"/wefeed-mobile-bff/subject-api/resource?subjectId={subject_id}&page={page}&perPage={per_page}{res_param}"
        else:
            path = f"/wefeed-mobile-bff/subject-api/resource?subjectId={subject_id}&se={season}&ep={episode}&page={page}&perPage={per_page}{res_param}"
        return self.get(path)

    def get_ext_captions(self, subject_id: str, resource_id: str):
        path = f"/wefeed-mobile-bff/subject-api/get-ext-captions?subjectId={subject_id}&resourceId={resource_id}"
        return self.get(path)

    def fetch_poster_bytes(self, url: str):
        # Use requests or urllib to fetch
        try:
            if self._use_requests:
                resp = self._session.get(url, headers={"User-Agent": "MovieBox-Tui/1.0"}, timeout=8)
                if resp.status_code >= 200 and resp.status_code < 300:
                    return resp.content
                return None
            else:
                req = urllib.request.Request(url, headers={"User-Agent": "MovieBox-Tui/1.0"})
                with urllib.request.urlopen(req, timeout=8) as r:
                    if 200 <= r.getcode() < 300:
                        return r.read()
                    return None
        except Exception:
            return None

    def download_subtitle_file(self, url: str, headers: list[tuple[str,str]]):
        # limit 8s
        try:
            if self._use_requests:
                import requests
                req_headers = {k: v for k, v in headers} if headers else {}
                resp = self._session.get(url, headers=req_headers, timeout=8)
                resp.raise_for_status()
                content = resp.content
            else:
                req = urllib.request.Request(url)
                for k, v in headers:
                    req.add_header(k, v)
                with urllib.request.urlopen(req, timeout=8) as r:
                    if not (200 <= r.getcode() < 300):
                        raise ScraperError(f"status {r.getcode()}")
                    content = r.read()
            ext = url.rsplit(".", 1)[-1].lower() if "." in url else "srt"
            if ext not in ("srt","vtt","ass","ssa","sub"):
                ext = "srt"
            try:
                from .utils import resolve_subtitle_dir
            except ImportError:
                from utils import resolve_subtitle_dir
            base = resolve_subtitle_dir()
            base.mkdir(parents=True, exist_ok=True)
            fname = f"{os.getpid()}_{time.time_ns()}.{ext}"
            path = base / fname
            path.write_bytes(content)
            return path
        except Exception as e:
            raise ScraperError(str(e))
