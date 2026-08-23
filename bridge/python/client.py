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

# byte limits to prevent memory/disk exhaustion from compromised upstream
MAX_API_BYTES = 5 * 1024 * 1024          # API JSON (search/details/etc.) ~50-300KB normally
MAX_POSTER_BYTES = 10 * 1024 * 1024       # poster images (pbcdn) ~30-300KB, cap 10MiB
MAX_SUBTITLE_BYTES = 2 * 1024 * 1024      # subtitles ~5-100KB, cap 2MiB

def _check_content_length(headers, limit: int):
    if not headers:
        return
    raw = headers.get("Content-Length") or headers.get("content-length") or headers.get("CONTENT-LENGTH")
    if raw is None:
        return
    try:
        n = int(str(raw).strip())
        if n > limit:
            raise ScraperError(f"response too large: Content-Length {n} > limit {limit}")
    except ScraperError:
        raise
    except Exception:
        pass

def _is_private_url(url: str) -> bool:
    """Return True if URL resolves to loopback/private/link-local (SSRF)."""
    try:
        host = urllib.parse.urlparse(url).hostname
        if not host:
            return True  # reject URLs without host
        # block non-http(s) already handled elsewhere, but be safe
        scheme = urllib.parse.urlparse(url).scheme.lower()
        if scheme not in ("http", "https"):
            return True
        # try literal IP first
        try:
            import ipaddress
            ip = ipaddress.ip_address(host)
            return ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved or ip.is_unspecified
        except ValueError:
            pass
        # DNS lookup with short timeout guard
        import socket
        # Use getaddrinfo; limit to 2s via setdefaulttimeout wrapper
        old_to = socket.getdefaulttimeout()
        try:
            socket.setdefaulttimeout(2)
            infos = socket.getaddrinfo(host, None, family=socket.AF_UNSPEC, type=socket.SOCK_STREAM)
        finally:
            socket.setdefaulttimeout(old_to)
        if not infos:
            return True
        import ipaddress
        for fam, _, _, _, sockaddr in infos:
            ip_str = sockaddr[0]
            try:
                ip = ipaddress.ip_address(ip_str)
                if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved or ip.is_unspecified:
                    return True
            except ValueError:
                continue
        return False
    except Exception:
        return True  # fail closed on parse/DNS error for poster/subtitle

def _assert_not_private_url(url: str):
    if _is_private_url(url):
        raise ScraperError(f"blocked private/loopback URL: {url[:80]}")

class _SSRFRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # newurl may be relative
        if newurl:
            # urljoin with original
            try:
                base = req.full_url
                joined = urllib.parse.urljoin(base, newurl)
                _assert_not_private_url(joined)
            except ScraperError:
                raise
            except Exception:
                raise ScraperError(f"blocked redirect to {newurl[:80]}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)

def _read_limited_requests(resp, limit: int) -> bytes:
    # stream already, read chunked with limit
    chunks = []
    total = 0
    for chunk in resp.iter_content(chunk_size=8192):
        if not chunk:
            continue
        total += len(chunk)
        if total > limit:
            raise ScraperError(f"response too large: > {limit} bytes")
        chunks.append(chunk)
    return b"".join(chunks)

def _read_limited_urllib(resp, limit: int) -> bytes:
    # check header first
    try:
        _check_content_length(dict(resp.getheaders()), limit)
    except ScraperError:
        raise
    except Exception:
        pass
    data = resp.read(limit + 1)
    if len(data) > limit:
        raise ScraperError(f"response too large: > {limit} bytes")
    return data

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
                import json, time, os
                # one-time repair: tighten mode of pre-existing token from older versions
                try:
                    os.chmod(p, 0o600)
                except OSError:
                    pass
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
                self._write_private(p, json.dumps({"token": self.runtime_token, "ts": int(time.time())}))
        except:
            pass

    def _write_private(self, path, text):
        # Atomic write with 0600 (owner-only) — token must not be world-readable
        import os, tempfile
        tmp = None
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tok-", suffix=".tmp")
            try:
                os.write(fd, text.encode("utf-8"))
            finally:
                os.close(fd)
            os.chmod(tmp, 0o600)
            os.replace(tmp, path)
            os.chmod(path, 0o600)
            tmp = None  # moved, don't unlink
        finally:
            if tmp is not None:
                try:
                    os.unlink(tmp)
                except OSError:
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
            assert self._session is not None
            try:
                if method.upper() == "POST":
                    resp = self._session.request(method, url, headers=headers, data=body.encode() if body else None, timeout=(2, 8), stream=True)
                else:
                    resp = self._session.request(method, url, headers=headers, timeout=(2, 8), stream=True)
                status = resp.status_code
                resp_headers = dict(resp.headers)
                self._absorb_x_user(resp_headers)
                if status in RETRY_STATUS_CODES:
                    try:
                        resp.close()
                    except:
                        pass
                    retry_after = None
                    if status == 429:
                        ra = resp.headers.get("Retry-After") or resp.headers.get("retry-after")
                        try:
                            retry_after = int(ra) * 1000 if ra else 400
                            retry_after = min(retry_after, 3000)
                        except:
                            retry_after = 400
                    return None, status, retry_after, None  # signal retry
                if not (200 <= status < 300):
                    try:
                        resp.close()
                    except:
                        pass
                    return None, status, None, f"API status {status}"
                try:
                    _check_content_length(resp_headers, MAX_API_BYTES)
                    raw = _read_limited_requests(resp, MAX_API_BYTES)
                    try:
                        resp.close()
                    except:
                        pass
                    text = raw.decode('utf-8', errors='ignore')
                    data = json.loads(text) if text else {}
                    if isinstance(data, dict) and "data" in data:
                        return data["data"], status, None, None
                    return data, status, None, None
                except ScraperError as se:
                    try:
                        resp.close()
                    except:
                        pass
                    return None, status, None, str(se)
                except json.JSONDecodeError as e:
                    try:
                        resp.close()
                    except:
                        pass
                    return None, status, None, f"JSON {e}"
            except ScraperError as se:
                return None, None, None, str(se)
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
                    try:
                        _check_content_length(resp_headers, MAX_API_BYTES)
                        raw = _read_limited_urllib(resp, MAX_API_BYTES)
                    except ScraperError as se:
                        return None, status, None, str(se)
                    text = raw.decode('utf-8', errors='ignore')
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
            except ScraperError as se:
                return None, None, None, str(se)
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
        try:
            _assert_not_private_url(url)
            if self._use_requests:
                assert self._session is not None
                # manual redirect handling with SSRF checks
                cur = url
                for _ in range(5):
                    resp = self._session.get(cur, headers={"User-Agent": "MovieBox-Tui/1.0"}, timeout=8, stream=True, allow_redirects=False)
                    if 300 <= resp.status_code < 400 and resp.headers.get("Location"):
                        loc = resp.headers.get("Location")
                        try:
                            resp.close()
                        except:
                            pass
                        nxt = urllib.parse.urljoin(cur, loc)
                        _assert_not_private_url(nxt)
                        cur = nxt
                        continue
                    if not (200 <= resp.status_code < 300):
                        try:
                            resp.close()
                        except:
                            pass
                        return None
                    try:
                        _check_content_length(dict(resp.headers), MAX_POSTER_BYTES)
                        data = _read_limited_requests(resp, MAX_POSTER_BYTES)
                    finally:
                        try:
                            resp.close()
                        except:
                            pass
                    return data
                return None
            else:
                # urllib with SSRF-aware redirect handler
                opener = urllib.request.build_opener(_SSRFRedirectHandler)
                req = urllib.request.Request(url, headers={"User-Agent": "MovieBox-Tui/1.0"})
                with opener.open(req, timeout=8) as r:
                    if not (200 <= r.getcode() < 300):
                        return None
                    _check_content_length(dict(r.getheaders()), MAX_POSTER_BYTES)
                    return _read_limited_urllib(r, MAX_POSTER_BYTES)
        except ScraperError:
            return None
        except Exception:
            return None

    def download_subtitle_file(self, url: str, headers: list[tuple[str,str]]):
        # limit 8s + byte cap + SSRF check
        try:
            _assert_not_private_url(url)
            if self._use_requests:
                assert self._session is not None
                import requests
                req_headers = {k: v for k, v in headers} if headers else {}
                cur = url
                cur_headers = req_headers
                content = None
                for _ in range(5):
                    resp = self._session.get(cur, headers=cur_headers, timeout=8, stream=True, allow_redirects=False)
                    if 300 <= resp.status_code < 400 and resp.headers.get("Location"):
                        loc = resp.headers.get("Location")
                        try:
                            resp.close()
                        except:
                            pass
                        nxt = urllib.parse.urljoin(cur, loc)
                        _assert_not_private_url(nxt)
                        cur = nxt
                        cur_headers = req_headers  # keep original headers on redirect
                        continue
                    resp.raise_for_status()
                    _check_content_length(dict(resp.headers), MAX_SUBTITLE_BYTES)
                    try:
                        content = _read_limited_requests(resp, MAX_SUBTITLE_BYTES)
                    finally:
                        try:
                            resp.close()
                        except:
                            pass
                    break
                if content is None:
                    raise ScraperError("subtitle download failed: redirect loop or no content")
            else:
                req = urllib.request.Request(url)
                for k, v in headers:
                    req.add_header(k, v)
                opener = urllib.request.build_opener(_SSRFRedirectHandler)
                with opener.open(req, timeout=8) as r:
                    # opener already validated redirects via handler
                    if not (200 <= r.getcode() < 300):
                        raise ScraperError(f"status {r.getcode()}")
                    _check_content_length(dict(r.getheaders()), MAX_SUBTITLE_BYTES)
                    content = _read_limited_urllib(r, MAX_SUBTITLE_BYTES)
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
        except ScraperError:
            raise
        except Exception as e:
            raise ScraperError(str(e))
