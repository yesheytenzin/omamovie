use std::path::PathBuf;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use moviebox_tui::providers::models::ProviderKind;
use moviebox_tui::service::{extract_browse_metrics, extract_cover_url, subject_id};

#[derive(Deserialize)]
struct Req {
    cmd: String,
    #[serde(flatten)]
    rest: Value,
}

#[derive(Serialize)]
struct Resp {
    ok: bool,
    error: Option<String>,
    #[serde(flatten)]
    data: Value,
}

static SERVICE: OnceLock<moviebox_tui::service::MovieBoxService> = OnceLock::new();

fn service() -> &'static moviebox_tui::service::MovieBoxService {
    SERVICE.get_or_init(moviebox_tui::service::MovieBoxService::new)
}

fn str_arg(req: &Value, key: &str) -> String {
    req.get(key).and_then(|v| v.as_str()).unwrap_or("").to_string()
}

fn usz_arg(req: &Value, key: &str, default: usize) -> usize {
    req.get(key)
        .and_then(|v| v.as_u64())
        .map(|n| n as usize)
        .unwrap_or(default)
}

fn clean_title(raw: &str) -> String {
    raw.split('[').next().unwrap_or(raw).trim().to_string()
}

fn unwrap_subjects(value: &Value) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    if let Some(groups) = value.get("results").and_then(|g| g.as_array()) {
        for group in groups {
            if let Some(subjects) = group.get("subjects").and_then(|s| s.as_array()) {
                out.extend(subjects.iter().cloned());
            }
        }
    }
    if out.is_empty() {
        if let Some(list) = value.get("list").and_then(|l| l.as_array()) {
            out = list.clone();
        }
        if out.is_empty() {
            if let Some(arr) = value.as_array() {
                out = arr.clone();
            }
        }
    }
    out
}

fn unwrap_homepage_subjects(value: &Value) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    if let Some(items) = value.get("items").and_then(|v| v.as_array()) {
        for item in items {
            if let Some(banners) = item.get("banner").and_then(|b| b.get("banners")).and_then(|b| b.as_array()) {
                for b in banners {
                    if let Some(subject) = b.get("subject") {
                        out.push(subject.clone());
                    }
                }
            }
            if let Some(custom_items) = item.get("customData").and_then(|c| c.get("items")).and_then(|i| i.as_array()) {
                for ci in custom_items {
                    if let Some(subject) = ci.get("subject") {
                        out.push(subject.clone());
                    }
                }
            }
            if let Some(subjects) = item.get("subjects").and_then(|s| s.as_array()) {
                for s in subjects {
                    out.push(s.clone());
                }
            }
        }
    }
    out
}

fn normalize_search_item(item: &Value) -> Value {
    let id = subject_id(item.get("subjectId").or_else(|| item.get("id")).unwrap_or(&Value::Null))
        .unwrap_or_default();
    let raw_title = item.get("postTitle").and_then(|t| t.as_str()).unwrap_or("");
    let title = if raw_title.is_empty() {
        clean_title(item.get("title").and_then(|t| t.as_str()).unwrap_or(""))
    } else {
        raw_title.trim().to_string()
    };
    let stype = moviebox_tui::service::stype(item);
    let year: String = item
        .get("releaseDate")
        .and_then(|rd| rd.as_str())
        .map(|s| s.chars().take(4).collect())
        .unwrap_or_default();
    let cover = item
        .get("cover")
        .and_then(|c| c.get("url").and_then(|u| u.as_str()))
        .map(|s| s.to_string())
        .or_else(|| extract_cover_url(item).filter(|s| !s.is_empty() && s.starts_with("http")));
    let rating = item
        .get("imdbRatingValue")
        .and_then(|r| r.as_str())
        .and_then(|s| s.parse::<f64>().ok())
        .or_else(|| extract_browse_metrics(item).rating);
    let season = item.get("season").and_then(|s| s.as_i64());
    let duration = item
        .get("duration")
        .and_then(|d| d.as_str())
        .unwrap_or("")
        .to_string();
    json!({
        "id": id,
        "title": title,
        "stype": stype,
        "year": year,
        "cover": cover,
        "rating": rating,
        "season": season,
        "duration": duration
    })
}

fn poster_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    let dir = PathBuf::from(home).join(".cache/omamovie/posters");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn detect_ext(bytes: &[u8]) -> &'static str {
    if bytes.starts_with(&[0xFF, 0xD8]) {
        "jpg"
    } else if bytes.starts_with(&[0x89, 0x50, 0x4E, 0x47]) {
        "png"
    } else if bytes.starts_with(b"RIFF") && bytes.len() > 12 && &bytes[8..12] == b"WEBP" {
        "webp"
    } else {
        "img"
    }
}

async fn run(cmd: &str, req: &Value) -> Result<Value, String> {
    let svc = service();
    match cmd {
        "ping" => Ok(json!({ "pong": true })),

        "suggest" => {
            let q = str_arg(req, "q");
            if q.is_empty() {
                return Ok(json!({ "suggestions": [] }));
            }
            // Check search cache for page 1 as suggest proxy
            if let Some(cached) = moviebox_tui::cache::get_provider_search_cache(ProviderKind::MovieBox, &q, 1) {
                let items: Vec<Value> = unwrap_subjects(&cached)
                    .into_iter()
                    .filter_map(|subj| {
                        let name = subj.get("postTitle").or_else(|| subj.get("title")).and_then(|n| n.as_str()).map(|n| clean_title(n)).unwrap_or_default();
                        if name.is_empty() { return None; }
                        let id = subject_id(subj.get("subjectId").or_else(|| subj.get("id")).unwrap_or(&Value::Null)).unwrap_or_default();
                        let cover = subj.get("cover").and_then(|c| c.get("url").and_then(|u| u.as_str())).map(|u| u.to_string()).or_else(|| extract_cover_url(&subj).filter(|u| u.starts_with("http")));
                        Some(json!({ "name": name, "id": id, "cover": cover }))
                    }).collect();
                if !items.is_empty() {
                    return Ok(json!({ "suggestions": items.into_iter().take(8).collect::<Vec<_>>() }));
                }
            }
            let _ = svc.client.init().await;
            let raw = svc.suggest(&q).await?;
            let items: Vec<Value> = unwrap_subjects(&raw)
                .into_iter()
                .filter_map(|s| {
                    let name = s
                        .get("postTitle")
                        .or_else(|| s.get("title"))
                        .and_then(|n| n.as_str())
                        .map(|n| clean_title(n))
                        .unwrap_or_default();
                    if name.is_empty() {
                        return None;
                    }
                    let id = subject_id(
                        s.get("subjectId")
                            .or_else(|| s.get("id"))
                            .unwrap_or(&Value::Null),
                    )
                    .unwrap_or_default();
                    let cover = s
                        .get("cover")
                        .and_then(|c| c.get("url").and_then(|u| u.as_str()))
                        .map(|u| u.to_string())
                        .or_else(|| extract_cover_url(&s).filter(|u| u.starts_with("http")));
                    Some(json!({ "name": name, "id": id, "cover": cover }))
                })
                .collect();
            Ok(json!({ "suggestions": items }))
        }

        "search" => {
            let q = str_arg(req, "q");
            let page = usz_arg(req, "page", 1).max(1);
            if q.is_empty() {
                return Ok(json!({ "items": [] }));
            }
            if let Some(cached) = moviebox_tui::cache::get_provider_search_cache(ProviderKind::MovieBox, &q, page) {
                let items: Vec<Value> = unwrap_subjects(&cached)
                    .iter()
                    .map(normalize_search_item)
                    .collect();
                if !items.is_empty() {
                    return Ok(json!({ "items": items }));
                }
            }
            let _ = svc.client.init().await;
            let raw = svc.search(ProviderKind::MovieBox, &q, page).await?;
            let items: Vec<Value> = unwrap_subjects(&raw)
                .iter()
                .map(normalize_search_item)
                .collect();
            if !items.is_empty() {
                moviebox_tui::cache::set_provider_search_cache(ProviderKind::MovieBox, &q, page, &raw);
            }
            Ok(json!({ "items": items }))
        }

        "details" => {
            let id = str_arg(req, "id");
            if id.is_empty() {
                return Err("missing id".into());
            }
            if let Some(cached) = moviebox_tui::cache::get_provider_details_cache(ProviderKind::MovieBox, &id) {
                return Ok(json!({ "value": cached }));
            }
            let _ = svc.client.init().await;
            let value = svc.details(ProviderKind::MovieBox, &id).await?;
            moviebox_tui::cache::set_provider_details_cache(ProviderKind::MovieBox, &id, &value);
            Ok(json!({ "value": value }))
        }

        "resources" => {
            let id = str_arg(req, "id");
            let season = usz_arg(req, "season", 0);
            let episode = usz_arg(req, "episode", 0);
            let page = usz_arg(req, "page", 1).max(1);
            let per_page = usz_arg(req, "perPage", 20).clamp(1, 50);
            let resolution = match req.get("resolution").and_then(|r| r.as_str()) {
                Some(r) if !r.is_empty() => Some(r.to_string()),
                _ => None,
            };
            if id.is_empty() {
                return Err("missing id".into());
            }
            if resolution.is_none() {
                if let Some(cached) = moviebox_tui::cache::get_provider_stream_cache(ProviderKind::MovieBox, &id, season, episode) {
                    let items = cached.get("list").cloned().unwrap_or_else(|| json!([]));
                    return Ok(json!({ "items": items, "value": cached }));
                }
            }
            let _ = svc.client.init().await;
            let raw = svc
                .client
                .get_resources(
                    &id,
                    season,
                    episode,
                    page,
                    resolution.as_deref(),
                    per_page,
                )
                .await
                .map_err(|e| e.to_string())?;
            if resolution.is_none() {
                moviebox_tui::cache::set_provider_stream_cache(ProviderKind::MovieBox, &id, season, episode, &raw);
            }
            let items = raw.get("list").cloned().unwrap_or_else(|| json!([]));
            Ok(json!({ "items": items, "value": raw }))
        }

        "captions" => {
            let id = str_arg(req, "id");
            let rid = str_arg(req, "rid");
            if id.is_empty() || rid.is_empty() {
                return Err("missing id or rid".into());
            }
            let _ = svc.client.init().await;
            let payload = svc.get_ext_captions(&id, &rid).await?;
            let options: Vec<Value> = moviebox_tui::service::caption_options(&payload)
                .into_iter()
                .map(|(name, url)| json!({ "name": name, "url": url }))
                .collect();
            Ok(json!({ "options": options }))
        }

        "subfile" => {
            let url = str_arg(req, "url");
            if url.is_empty() {
                return Err("missing url".into());
            }
            let headers: Vec<(String, String)> = req
                .get("headers")
                .and_then(|h| h.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|pair| {
                            let arr = pair.as_array()?;
                            if arr.len() < 2 {
                                return None;
                            }
                            let k = arr[0].as_str()?;
                            let v = arr[1].as_str()?;
                            Some((k.to_string(), v.to_string()))
                        })
                        .collect()
                })
                .unwrap_or_default();
            let path = svc.download_subtitle_file(&url, &headers).await?;
            Ok(json!({ "path": path.to_string_lossy().to_string() }))
        }

        "poster" => {
            let url = str_arg(req, "url");
            if url.is_empty() {
                return Err("missing url".into());
            }
            let mut hasher = std::collections::hash_map::DefaultHasher::new();
            use std::hash::{Hash, Hasher};
            url.hash(&mut hasher);
            // Try hash with common extensions first to avoid re-download
            for ext in ["jpg", "png", "webp", "img"] {
                let name = format!("{:016x}.{}", hasher.finish(), ext);
                let path = poster_dir().join(&name);
                if path.exists() {
                    return Ok(json!({ "path": path.to_string_lossy().to_string() }));
                }
            }
            let bytes = svc
                .fetch_poster_bytes(&url)
                .await
                .ok_or_else(|| "poster download failed".to_string())?;
            if bytes.is_empty() {
                return Err("poster download returned no data".into());
            }
            let mut hasher2 = std::collections::hash_map::DefaultHasher::new();
            url.hash(&mut hasher2);
            let name = format!("{:016x}.{}", hasher2.finish(), detect_ext(&bytes));
            let path = poster_dir().join(name);
            std::fs::write(&path, &bytes).map_err(|e| e.to_string())?;
            Ok(json!({ "path": path.to_string_lossy().to_string() }))
        }

        "homepage" | "discover" | "home" => {
            let tab = str_arg(req, "tab");
            let tab_id = if tab.is_empty() { "2" } else { tab.as_str() };
            let page = usz_arg(req, "page", 1).max(1);
            let per_page = usz_arg(req, "perPage", 24).clamp(1, 50);
            let raw = if let Some(cached) = moviebox_tui::cache::get_homepage_cache(tab_id, page) {
                cached
            } else {
                let _ = svc.client.init().await;
                let fetched = svc.homepage(tab_id, page).await?;
                moviebox_tui::cache::set_homepage_cache(tab_id, page, &fetched);
                fetched
            };
            let mut subjects = unwrap_homepage_subjects(&raw);
            // dedupe by id
            let mut seen = std::collections::HashSet::new();
            let mut uniq: Vec<Value> = Vec::new();
            for subj in subjects.drain(..) {
                let id = subject_id(subj.get("subjectId").or_else(|| subj.get("id")).unwrap_or(&Value::Null)).unwrap_or_default();
                if id.is_empty() || seen.contains(&id) { continue; }
                seen.insert(id);
                uniq.push(subj);
            }
            // Shuffle-like: take first per_page after simple deterministic shuffle based on hash
            // For true random, QML will shuffle; here just limit
            let limited = uniq.into_iter().take(per_page * 3).collect::<Vec<_>>();
            let items: Vec<Value> = limited.iter().map(normalize_search_item).filter(|v| v.get("id").and_then(|id| id.as_str()).map(|s| !s.is_empty()).unwrap_or(false)).take(per_page).collect();
            Ok(json!({ "items": items, "rawCount": limited.len() }))
        }

        "raw" => {
            let op = str_arg(req, "op");
            match op.as_str() {
                "suggest" => {
                    let q = str_arg(req, "q");
                    Ok(json!({ "value": svc.suggest(&q).await? }))
                }
                "search" => {
                    let q = str_arg(req, "q");
                    let page = usz_arg(req, "page", 1).max(1);
                    Ok(json!({ "value": svc.search(ProviderKind::MovieBox, &q, page).await? }))
                }
                "details" => {
                    let id = str_arg(req, "id");
                    Ok(json!({ "value": svc.details(ProviderKind::MovieBox, &id).await? }))
                }
                _ => Err(format!("unknown raw op: {op}")),
            }
        }

        _ => Err(format!("unknown command: {cmd}")),
    }
}

#[tokio::main]
async fn main() {
    let raw = std::env::args().nth(1).unwrap_or_else(|| "{}".into());
    let req: Req = match serde_json::from_str(&raw) {
        Ok(req) => req,
        Err(e) => {
            println!("{}", json!({ "ok": false, "error": format!("bad request: {e}") }));
            return;
        }
    };

    let data = run(&req.cmd, &req.rest).await;
    let resp = match data {
        Ok(data) => Resp { ok: true, error: None, data },
        Err(e) => Resp { ok: false, error: Some(e), data: json!({}) },
    };
    println!("{}", serde_json::to_string(&resp).unwrap_or_else(|_| "{}".into()));
}
