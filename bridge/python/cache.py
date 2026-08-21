"""Port of cache.rs - file based JSON cache with expiry"""
import hashlib
import json
import os
import time
from pathlib import Path

CACHE_EXPIRY_SECS = 24 * 60 * 60
STREAM_CACHE_EXPIRY_SECS = 2 * 60 * 60
HOMEPAGE_CACHE_EXPIRY_SECS = 60 * 60
IMAGE_CACHE_EXPIRY_SECS = 30 * 24 * 60 * 60
APP_NAME = "moviebox-tui"

def cache_dir() -> Path:
    xdg = os.environ.get("XDG_CACHE_HOME")
    if xdg:
        return Path(xdg) / APP_NAME
    home = Path.home()
    # dirs::cache_dir on linux is $XDG_CACHE_HOME or $HOME/.cache
    # so mimic
    cache_base = Path(os.environ.get("XDG_CACHE_HOME", str(home / ".cache")))
    return cache_base / APP_NAME

def md5_hex(value: str) -> str:
    return hashlib.md5(value.encode()).hexdigest()

def hash_key(value: str) -> str:
    return md5_hex(value)

def _atomic_write(path: Path, data: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(f".tmp-{os.getpid()}-{time.time_ns()}")
    try:
        tmp.write_bytes(data)
        try:
            tmp.rename(path)
        except OSError:
            # if exists, try replace
            try:
                path.unlink()
            except:
                pass
            tmp.rename(path)
    finally:
        try:
            if tmp.exists():
                tmp.unlink()
        except:
            pass

def _read_json_cache(path: Path, expiry: int):
    if not path.exists():
        return None
    try:
        mtime = path.stat().st_mtime
        if time.time() - mtime > expiry:
            try: path.unlink()
            except: pass
            return None
    except:
        try: path.unlink()
        except: pass
        return None
    try:
        content = path.read_text()
        val = json.loads(content)
        if val is None or val == {}:
            # empty check? Rust checks is_null
            pass
        return val
    except:
        try: path.unlink()
        except: pass
        return None

def _write_json_cache(path: Path, data):
    if data is None:
        return
    try:
        content = json.dumps(data, separators=(',', ':')).encode()
    except:
        return
    try:
        _atomic_write(path, content)
    except Exception:
        pass

def _search_has_results(data) -> bool:
    if not isinstance(data, dict):
        return False
    results = data.get("results")
    if not isinstance(results, list) or not results:
        return False
    first = results[0]
    if not isinstance(first, dict):
        return False
    subjects = first.get("subjects")
    return isinstance(subjects, list) and len(subjects) > 0

def _stream_obj_has_results(obj) -> bool:
    # Check if obj contains list with resourceLink
    if isinstance(obj, dict):
        lst = obj.get("list")
        if isinstance(lst, list) and lst:
            for stream in lst:
                if isinstance(stream, dict):
                    link = stream.get("resourceLink")
                    if isinstance(link, str) and link:
                        return True
            return False
        # fallback if obj itself is list
        return False
    if isinstance(obj, list):
        for stream in obj:
            if isinstance(stream, dict):
                link = stream.get("resourceLink")
                if isinstance(link, str) and link:
                    return True
        return False
    return False

# Path helpers

def get_provider_cache_dir(provider: str, subdir: str) -> Path:
    # provider is string like "moviebox" - Rust uses ProviderKind::MovieBox cache_key() -> "moviebox"
    return cache_dir() / provider / subdir

def get_provider_stream_path(provider: str, subject_id: str, season: int, episode: int) -> Path:
    # Rust: hash(subject_id) + f"{schema}{hashed}_{season}_{episode}.json", schema v3_ for FourK but we only use moviebox
    base = get_provider_cache_dir(provider, "streams")
    hashed = hash_key(subject_id)
    schema = ""
    # provider key check
    if provider == "fourkhdhub":
        schema = "v3_"
    return base / f"{schema}{hashed}_{season}_{episode}.json"

def get_provider_stream_cache(provider: str, subject_id: str, season: int, episode: int):
    path = get_provider_stream_path(provider, subject_id, season, episode)
    val = _read_json_cache(path, STREAM_CACHE_EXPIRY_SECS)
    if val is None:
        return None
    if _stream_obj_has_results(val):
        return val
    # also check if val is cached list object wrapped?
    try: path.unlink()
    except: pass
    return None

def set_provider_stream_cache(provider: str, subject_id: str, season: int, episode: int, data):
    if not _stream_obj_has_results(data):
        # try to remove existing
        path = get_provider_stream_path(provider, subject_id, season, episode)
        try:
            if path.exists():
                path.unlink()
        except: pass
        return
    path = get_provider_stream_path(provider, subject_id, season, episode)
    _write_json_cache(path, data)

def get_provider_details_path(provider: str, subject_id: str) -> Path:
    base = get_provider_cache_dir(provider, "details")
    hashed = hash_key(subject_id)
    schema = ""
    if provider == "fourkhdhub":
        schema = "v2_"
    return base / f"details_{schema}{hashed}.json"

def get_provider_details_cache(provider: str, subject_id: str):
    path = get_provider_details_path(provider, subject_id)
    return _read_json_cache(path, CACHE_EXPIRY_SECS)

def set_provider_details_cache(provider: str, subject_id: str, data):
    path = get_provider_details_path(provider, subject_id)
    _write_json_cache(path, data)

def get_provider_search_path(provider: str, query: str, page: int) -> Path:
    base = get_provider_cache_dir(provider, "search")
    hashed = hash_key(query)
    return base / f"{hashed}_{page}.json"

def get_provider_search_cache(provider: str, query: str, page: int):
    path = get_provider_search_path(provider, query, page)
    val = _read_json_cache(path, CACHE_EXPIRY_SECS)
    if val is None:
        return None
    if _search_has_results(val):
        return val
    try: path.unlink()
    except: pass
    return None

def set_provider_search_cache(provider: str, query: str, page: int, data):
    if not _search_has_results(data):
        path = get_provider_search_path(provider, query, page)
        try:
            if path.exists():
                path.unlink()
        except: pass
        return
    path = get_provider_search_path(provider, query, page)
    _write_json_cache(path, data)

def get_homepage_path(tab_id: str, page: int) -> Path:
    base = get_provider_cache_dir("moviebox", "homepage")
    return base / f"{tab_id}_{page}.json"

def get_homepage_cache(tab_id: str, page: int):
    path = get_homepage_path(tab_id, page)
    return _read_json_cache(path, HOMEPAGE_CACHE_EXPIRY_SECS)

def set_homepage_cache(tab_id: str, page: int, data):
    path = get_homepage_path(tab_id, page)
    _write_json_cache(path, data)

# Captions cache (not strictly needed but keep compat)
def get_captions_path(subject_id: str, resource_id: str) -> Path:
    base = get_provider_cache_dir("moviebox", "captions")
    hashed = hash_key(f"{subject_id}_{resource_id}")
    return base / f"captions_{hashed}.json"

def get_captions_cache(subject_id: str, resource_id: str):
    path = get_captions_path(subject_id, resource_id)
    return _read_json_cache(path, CACHE_EXPIRY_SECS)

def set_captions_cache(subject_id: str, resource_id: str, data):
    path = get_captions_path(subject_id, resource_id)
    _write_json_cache(path, data)
