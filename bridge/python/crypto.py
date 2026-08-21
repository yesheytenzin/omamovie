"""Port of MovieBox crypto signing - see bridge/src providers/moviebox/crypto.rs"""
import base64
import hashlib
import hmac
import random
import time
import urllib.parse

SECRET_KEY_DEFAULT = "76iRl07s0xSN9jqmEWAt79EBJZulIQIsV64FZr2O"
SIGNATURE_BODY_MAX_BYTES = 102_400


def md5_hex(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()


def _b64_decode(val: str) -> bytes:
    padded = val + "=" * ((4 - len(val) % 4) % 4)
    try:
        return base64.b64decode(padded)
    except Exception:
        return b""


def _b64_encode(data: bytes) -> str:
    return base64.b64encode(data).decode()


def generate_x_client_token(ts: int) -> str:
    ts_str = str(ts)
    reversed_ts = ts_str[::-1]
    hash_val = md5_hex(reversed_ts.encode())
    return f"{ts_str},{hash_val}"


def sorted_query_string(url: str) -> str:
    try:
        parsed = urllib.parse.urlparse(url)
        qs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    except Exception:
        return ""
    if not qs:
        return ""
    grouped = {}
    for k, v in qs:
        grouped.setdefault(k, []).append(v)
    parts = []
    for key in sorted(grouped):
        for val in grouped[key]:
            parts.append(f"{key}={val}")
    return "&".join(parts)


def build_canonical_string(method: str, accept: str | None, content_type: str | None, url: str, body: str | None, timestamp_ms: int) -> str:
    try:
        parsed = urllib.parse.urlparse(url)
        path = parsed.path or "/"
        query = sorted_query_string(url)
        if query:
            canonical_url = f"{path}?{query}"
        else:
            canonical_url = path
    except Exception:
        canonical_url = url

    if body is not None:
        body_bytes = body.encode("utf-8")
        length = len(body_bytes)
        truncated = body_bytes[:SIGNATURE_BODY_MAX_BYTES] if length > SIGNATURE_BODY_MAX_BYTES else body_bytes
        body_hash = md5_hex(truncated)
        body_length = str(length)
    else:
        body_hash = ""
        body_length = ""

    return f"{method.upper()}\n{accept or ''}\n{content_type or ''}\n{body_length}\n{timestamp_ms}\n{body_hash}\n{canonical_url}"


# Pre-decode secret once
_SECRET_BYTES = _b64_decode(SECRET_KEY_DEFAULT)

def generate_x_tr_signature(method: str, accept: str | None, content_type: str | None, url: str, body: str | None, timestamp_ms: int) -> str:
    canonical = build_canonical_string(method, accept, content_type, url, body, timestamp_ms)
    try:
        mac = hmac.new(_SECRET_BYTES, canonical.encode("utf-8"), hashlib.md5)
        sig_b64 = _b64_encode(mac.digest())
    except Exception:
        return f"{timestamp_ms}|2|"
    return f"{timestamp_ms}|2|{sig_b64}"


def build_signed_headers(method: str, url: str, body: str | None, auth_token: str | None, user_agent: str, client_info: str, spoofed_ip: str) -> dict:
    ts = int(time.time() * 1000)
    accept = "application/json"
    content_type = "application/json"
    client_token = generate_x_client_token(ts)
    signature = generate_x_tr_signature(method, accept, content_type, url, body, ts)
    headers = {
        "User-Agent": user_agent,
        "Accept": accept,
        "Content-Type": content_type,
        "Connection": "keep-alive",
        "x-client-token": client_token,
        "x-tr-signature": signature,
        "x-client-info": client_info,
        "x-client-status": "0",
        "x-forwarded-for": spoofed_ip,
    }
    if auth_token:
        headers["Authorization"] = f"Bearer {auth_token}"
    return headers


def generate_client_info_and_ua() -> tuple[str, str]:
    android_versions = [
        ("9", "PQ3A.190605.03081104"),
        ("10", "QP1A.191005.007.A3"),
        ("11", "RP1A.200720.011"),
        ("12", "S1B.220414.015"),
        ("13", "TQ2A.230405.003"),
    ]
    redmi_devices = [
        ("23078RKD5C", "Redmi"),
        ("2201117TY", "Redmi"),
        ("2201117TG", "Redmi"),
        ("22101316G", "Redmi"),
        ("21121210G", "Redmi"),
        ("M2012K11AG", "Redmi"),
        ("M2007J20CG", "Redmi"),
    ]
    version_codes = [50020042, 50020043, 50020044, 50020045, 50020046]
    network_types = ["NETWORK_WIFI", "NETWORK_MOBILE"]
    timezones = [
        "Asia/Kolkata",
        "Asia/Shanghai",
        "Asia/Tokyo",
        "America/New_York",
        "Europe/London",
    ]

    android = random.choice(android_versions)
    device = random.choice(redmi_devices)
    version_code = random.choice(version_codes)
    network = random.choice(network_types)
    timezone = random.choice(timezones)
    gaid = _random_uuid()
    device_id = _random_hex(32)

    user_agent = f"com.community.oneroom/{version_code} (Linux; U; Android {android[0]}; en_US; {device[0]}; Build/{android[1]}; Cronet/135.0.7012.3)"
    client_info = (
        f'{{"package_name":"com.community.oneroom","version_name":"3.0.03.0529.03","version_code":{version_code},'
        f'"os":"android","os_version":"{android[0]}","install_ch":"ps","device_id":"{device_id}",'
        f'"install_store":"ps","gaid":"{gaid}","brand":"{device[1]}","model":"{device[0]}",'
        f'"system_language":"en","net":"{network}","region":"US","timezone":"{timezone}",'
        f'"sp_code":"40401","X-Play-Mode":"2"}}'
    )
    return user_agent, client_info


def _random_hex(length: int) -> str:
    return "".join(random.choice("0123456789abcdef") for _ in range(length))


def _random_uuid() -> str:
    return f"{_random_hex(8)}-{_random_hex(4)}-{_random_hex(4)}-{_random_hex(4)}-{_random_hex(12)}"


def random_spoofed_ip() -> str:
    prefixes = [
        "103.241", "49.36", "117.195", "106.198", "122.162", "157.32", "182.70", "103.58", "27.60", "59.90",
    ]
    prefix = random.choice(prefixes)
    c = random.randint(1, 253)
    d = random.randint(1, 253)
    return f"{prefix}.{c}.{d}"
