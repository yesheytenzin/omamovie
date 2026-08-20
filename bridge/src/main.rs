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
            let raw = svc.search(ProviderKind::MovieBox, &q, page).await?;
            let items: Vec<Value> = unwrap_subjects(&raw)
                .iter()
                .map(normalize_search_item)
                .collect();
            Ok(json!({ "items": items }))
        }

        "details" => {
            let id = str_arg(req, "id");
            if id.is_empty() {
                return Err("missing id".into());
            }
            let value = svc.details(ProviderKind::MovieBox, &id).await?;
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
            let items = raw.get("list").cloned().unwrap_or_else(|| json!([]));
            Ok(json!({ "items": items, "value": raw }))
        }

        "captions" => {
            let id = str_arg(req, "id");
            let rid = str_arg(req, "rid");
            if id.is_empty() || rid.is_empty() {
                return Err("missing id or rid".into());
            }
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
            let bytes = svc
                .fetch_poster_bytes(&url)
                .await
                .ok_or_else(|| "poster download failed".to_string())?;
            if bytes.is_empty() {
                return Err("poster download returned no data".into());
            }
            let mut hasher = std::collections::hash_map::DefaultHasher::new();
            use std::hash::{Hash, Hasher};
            url.hash(&mut hasher);
            let name = format!("{:016x}.{}", hasher.finish(), detect_ext(&bytes));
            let path = poster_dir().join(name);
            std::fs::write(&path, &bytes).map_err(|e| e.to_string())?;
            Ok(json!({ "path": path.to_string_lossy().to_string() }))
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

    let needs_token = matches!(req.cmd.as_str(), "suggest" | "search" | "details" | "resources" | "captions");
    if needs_token {
        let _ = service().client.init().await;
    }

    let data = run(&req.cmd, &req.rest).await;
    let resp = match data {
        Ok(data) => Resp { ok: true, error: None, data },
        Err(e) => Resp { ok: false, error: Some(e), data: json!({}) },
    };
    println!("{}", serde_json::to_string(&resp).unwrap_or_else(|_| "{}".into()));
}
