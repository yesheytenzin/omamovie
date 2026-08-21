"""Helpers ported from service.rs"""
def subject_id(value) -> str | None:
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return value
    if isinstance(value, float):
        # Rust uses as_i64, so floats not used but handle
        try:
            return str(int(value))
        except:
            return str(value)
    return None

def stype(value: dict) -> int:
    if isinstance(value, dict):
        for k in ("subjectType", "stype"):
            v = value.get(k)
            if isinstance(v, int):
                return v
            if isinstance(v, str) and v.lstrip("-").isdigit():
                try:
                    return int(v)
                except:
                    pass
    return 1

def extract_cover_url(val: dict) -> str | None:
    keys = [
        "cover", "poster", "pic", "coverUrl", "cover_url", "posterUrl", "poster_url", "thumbnail", "image", "logo", "imgUrl", "img_url",
    ]
    for key in keys:
        v = val.get(key) if isinstance(val, dict) else None
        if v is None:
            continue
        if isinstance(v, str) and v:
            return v
        if isinstance(v, dict):
            url = v.get("url")
            if isinstance(url, str) and url:
                return url
    return None

def metric_value(item: dict, keys: list[str]) -> float | None:
    containers = [item]
    if isinstance(item, dict):
        if "metadata" in item and isinstance(item["metadata"], dict):
            containers.append(item["metadata"])
        if "meta" in item and isinstance(item["meta"], dict):
            containers.append(item["meta"])
    for container in containers:
        for key in keys:
            v = container.get(key)
            if v is None:
                continue
            if isinstance(v, (int, float)):
                return float(v)
            if isinstance(v, str):
                try:
                    return float(v)
                except:
                    continue
    return None

def extract_browse_metrics(item: dict) -> dict:
    return {
        "trending": metric_value(item, ["__browse_rank", "imdb_trending", "imdbTrending", "trending"]),
        "rating": metric_value(item, ["imdbRatingValue", "imdbRate", "imdb_rating", "imdbRating"]),
        "recent_rating": metric_value(item, ["imdb_rating_30d", "imdbRating30Days", "imdbRatingLast30Days", "imdb_rating_recent", "imdbRatingValue", "imdbRate"]),
        "popularity": metric_value(item, ["__browse_rank", "imdb_popularity", "imdbPopularity", "popularity", "viewers"]),
    }

def captions_json_to_options(payload: dict) -> list[dict]:
    caps = payload.get("extCaptions") if isinstance(payload, dict) else None
    if not isinstance(caps, list):
        return []
    out = []
    for cap in caps:
        if not isinstance(cap, dict):
            continue
        url = cap.get("url")
        if not isinstance(url, str) or not url:
            continue
        name = cap.get("lanName") if isinstance(cap.get("lanName"), str) else "Unknown"
        out.append({"name": name, "url": url})
    return out

def caption_options(payload: dict) -> list[tuple[str,str]]:
    opts = [("None", "")]
    for o in captions_json_to_options(payload):
        opts.append((o["name"], o["url"]))
    return opts

def clean_title_simple(raw: str) -> str:
    if not raw:
        return ""
    return raw.split("[")[0].strip()

def is_trailer_title(title: str) -> bool:
    t = title.strip().lower()
    return t.startswith("trailer-") or t.startswith("trailer ") or t.startswith("trailer:")
