import os
from pathlib import Path
import hashlib
import time

def poster_dir() -> Path:
    home = Path.home()
    dir = home / ".cache" / "omamovie" / "posters"
    # also respect XDG_CACHE_HOME if set? Keep same as Rust: HOME/.cache/omamovie/posters
    # Rust uses HOME/.cache/omamovie/posters regardless of XDG_CACHE_HOME for posters.
    # We'll follow that but also support XDG_CACHE_HOME if HOME not available.
    try:
        dir.mkdir(parents=True, exist_ok=True)
    except:
        pass
    return dir

def detect_ext(data: bytes) -> str:
    if data.startswith(b"\xFF\xD8"):
        return "jpg"
    if data.startswith(b"\x89PNG"):
        return "png"
    if data.startswith(b"RIFF") and len(data) > 12 and data[8:12] == b"WEBP":
        return "webp"
    return "img"

def resolve_subtitle_dir() -> Path:
    home = Path.home()
    storage = home / "storage" / "downloads" / "moviebox_subs"
    if (home / "storage" / "downloads").exists():
        try:
            storage.mkdir(parents=True, exist_ok=True)
        except:
            pass
        return storage
    # fallback to cache_dir/subs
    from .cache import cache_dir
    d = cache_dir() / "subs"
    try:
        d.mkdir(parents=True, exist_ok=True)
    except:
        pass
    return d
