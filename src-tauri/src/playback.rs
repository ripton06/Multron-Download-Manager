use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{bail, Result};
use futures_util::{Stream, StreamExt};
use tokio::io::AsyncRead;
use tokio_util::sync::CancellationToken;

use crate::model::TorrentOptions;

#[derive(Default)]
pub struct StreamTokens {
    files: HashMap<(String, usize), StreamPermit>,
}

struct StreamPermit {
    token: String,
    cancel: CancellationToken,
}

impl StreamTokens {
    pub fn retain_files(&mut self, hash: &str, files: &[usize]) {
        self.files.retain(|(existing, index), permit| {
            let keep = existing != hash || files.contains(index);
            if !keep {
                permit.cancel.cancel();
            }
            keep
        });
    }

    pub fn token(&mut self, hash: &str, file: usize) -> String {
        self.files
            .entry((hash.to_owned(), file))
            .or_insert_with(|| StreamPermit {
                token: uuid::Uuid::new_v4().simple().to_string(),
                cancel: CancellationToken::new(),
            })
            .token
            .clone()
    }

    pub fn allows(&self, token: &str, hash: &str, file: usize) -> bool {
        self.files
            .get(&(hash.to_owned(), file))
            .is_some_and(|expected| expected.token == token && !expected.cancel.is_cancelled())
    }

    pub fn cancellation(&self, token: &str, hash: &str, file: usize) -> Option<CancellationToken> {
        self.allows(token, hash, file)
            .then(|| self.files[&(hash.to_owned(), file)].cancel.clone())
    }
}

pub fn reader_stream<R: AsyncRead + Unpin + Send + 'static>(
    reader: R,
    cancel: CancellationToken,
) -> impl Stream<Item = std::io::Result<bytes::Bytes>> {
    let (sender, receiver) = tokio::sync::mpsc::channel(2);
    tokio::spawn(async move {
        let mut reader = tokio_util::io::ReaderStream::new(reader);
        loop {
            let next = tokio::select! {
                biased;
                _ = cancel.cancelled() => break,
                _ = sender.closed() => break,
                next = reader.next() => next,
            };
            let Some(next) = next else {
                break;
            };
            let failed = next.is_err();
            let sent = tokio::select! {
                biased;
                _ = cancel.cancelled() => false,
                sent = sender.send(next) => sent.is_ok(),
            };
            if !sent || failed {
                break;
            }
        }
    });
    futures_util::stream::unfold(receiver, |mut receiver| async move {
        receiver.recv().await.map(|next| (next, receiver))
    })
}

pub fn log_path(path: &str) -> &str {
    if path.starts_with("/stream/") {
        "/stream/[redacted]"
    } else {
        path
    }
}

pub fn stream_file(torrent: &TorrentOptions, file: usize) -> Result<(String, String)> {
    let hash = torrent
        .info_hash
        .as_deref()
        .ok_or_else(|| anyhow::anyhow!("metadata is still being fetched"))?;
    if hash.len() != 40 || !hash.chars().all(|c| c.is_ascii_hexdigit()) {
        bail!("invalid torrent infohash");
    }
    let entry = torrent
        .files
        .get(file)
        .ok_or_else(|| anyhow::anyhow!("torrent file does not exist"))?;
    if !entry.included
        || torrent
            .only_files
            .as_ref()
            .is_some_and(|selected| !selected.contains(&file))
    {
        bail!("apply the file selection before starting playback");
    }
    Ok((hash.to_owned(), entry.name.clone()))
}

pub fn is_stream_url(stream: &str) -> bool {
    if stream.contains(['\r', '\n', '\0']) {
        return false;
    }
    let Ok(url) = url::Url::parse(stream) else {
        return false;
    };
    let segments: Vec<_> = url
        .path_segments()
        .map(|parts| parts.collect::<Vec<_>>())
        .unwrap_or_default();
    url.scheme() == "http"
        && url.host_str() == Some("127.0.0.1")
        && url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && segments.len() == 4
        && segments[0] == "stream"
        && segments[1].len() == 32
        && segments[1].chars().all(|c| c.is_ascii_hexdigit())
        && segments[2].len() == 40
        && segments[2].chars().all(|c| c.is_ascii_hexdigit())
        && segments[3].parse::<usize>().is_ok()
}

fn contents(title: &str, stream: &str) -> Result<String> {
    if !is_stream_url(stream) {
        bail!("invalid stream URL");
    }
    let title: String = title
        .chars()
        .take(512)
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    Ok(format!("#EXTM3U\n#EXTINF:-1,{}\n{stream}\n", title.trim()))
}

pub fn save_cached(dir: &Path, title: &str, stream: &str) -> Result<PathBuf> {
    let body = contents(title, stream)?;
    std::fs::create_dir_all(dir)?;
    let path = dir.join(format!("multron-{}.m3u", uuid::Uuid::new_v4().simple()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)?;
    file.write_all(body.as_bytes())?;
    file.flush()?;
    drop(file);
    Ok(path)
}

pub fn save(dest: &Path, title: &str, stream: &str) -> Result<()> {
    if !dest.is_absolute()
        || !dest
            .extension()
            .and_then(|ext| ext.to_str())
            .is_some_and(|ext| matches!(ext.to_ascii_lowercase().as_str(), "m3u" | "m3u8"))
    {
        bail!("choose an M3U playlist destination");
    }
    let body = contents(title, stream)?;
    std::fs::write(dest, body)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream() -> String {
        format!(
            "http://127.0.0.1:6801/stream/{}/{}/0",
            "a".repeat(32),
            "b".repeat(40)
        )
    }

    #[test]
    fn stream_tokens_authorize_only_the_selected_file() {
        let mut tokens = StreamTokens::default();
        let token = tokens.token("hash", 2);
        assert_eq!(tokens.token("hash", 2), token);
        assert!(tokens.allows(&token, "hash", 2));
        assert!(!tokens.allows(&token, "hash", 3));
        assert!(!tokens.allows(&token, "another", 2));
        assert!(!StreamTokens::default().allows(&token, "hash", 2));
    }

    #[test]
    fn deselected_files_lose_their_playback_permission() {
        let mut tokens = StreamTokens::default();
        let removed = tokens.token("hash", 0);
        let kept = tokens.token("hash", 1);
        let other = tokens.token("other", 0);
        tokens.retain_files("hash", &[1]);
        assert!(!tokens.allows(&removed, "hash", 0));
        assert!(tokens.allows(&kept, "hash", 1));
        assert!(tokens.allows(&other, "other", 0));
    }

    #[test]
    fn removing_and_readding_a_torrent_does_not_restore_old_links() {
        let mut tokens = StreamTokens::default();
        let old = tokens.token("hash", 0);
        tokens.retain_files("hash", &[]);
        let new = tokens.token("hash", 0);
        assert_ne!(old, new);
        assert!(!tokens.allows(&old, "hash", 0));
    }

    #[tokio::test]
    async fn reader_stream_yields_already_buffered_bytes() {
        use tokio::io::AsyncWriteExt;
        let (reader, mut writer) = tokio::io::duplex(64);
        writer.write_all(b"ready").await.unwrap();
        let stream = reader_stream(reader, CancellationToken::new());
        futures_util::pin_mut!(stream);
        let chunk = tokio::time::timeout(std::time::Duration::from_secs(1), stream.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(chunk.as_ref(), b"ready");
    }

    #[tokio::test]
    async fn revocation_closes_an_http_response_waiting_for_more_bytes() {
        use axum::{
            body::Body,
            http::{Response, StatusCode},
            routing::get,
            Router,
        };
        use std::sync::Arc;
        use tokio::io::AsyncWriteExt;
        let mut tokens = StreamTokens::default();
        let token = tokens.token("hash", 0);
        let cancel = tokens.cancellation(&token, "hash", 0).unwrap();
        let tokens = Arc::new(parking_lot::Mutex::new(tokens));
        let (reader, mut writer) = tokio::io::duplex(16384);
        writer.write_all(&vec![7; 8192]).await.unwrap();
        let reader = Arc::new(parking_lot::Mutex::new(Some(reader)));
        let permit = tokens.clone();
        let app = Router::new().route(
            "/",
            get(move || {
                let reader = reader.clone();
                let permit = permit.clone();
                let token = token.clone();
                let cancel = cancel.clone();
                async move {
                    if !permit.lock().allows(&token, "hash", 0) {
                        return Response::builder()
                            .status(StatusCode::NOT_FOUND)
                            .body(Body::empty())
                            .unwrap();
                    }
                    let reader = reader.lock().take().unwrap();
                    Response::builder()
                        .header("content-length", "16384")
                        .body(Body::from_stream(reader_stream(reader, cancel)))
                        .unwrap()
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let client = reqwest::Client::builder()
            .no_proxy()
            .timeout(std::time::Duration::from_secs(3))
            .build()
            .unwrap();
        let mut response = client.get(&url).send().await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        tokens.lock().retain_files("hash", &[]);
        let received = tokio::time::timeout(std::time::Duration::from_secs(1), async {
            let mut received = 0;
            while let Ok(Some(chunk)) = response.chunk().await {
                received += chunk.len();
            }
            received
        })
        .await
        .expect("revocation must terminate the pending HTTP body");
        assert!(received < 16384);
        assert!(writer.write_all(b"more").await.is_err());
        assert_eq!(
            client.get(&url).send().await.unwrap().status(),
            StatusCode::NOT_FOUND
        );
        server.abort();
    }

    #[tokio::test]
    async fn revocation_drops_the_reader_even_with_a_stalled_http_consumer() {
        use std::{
            pin::Pin,
            sync::{
                atomic::{AtomicUsize, Ordering},
                Arc,
            },
            task::{Context, Poll},
        };
        use tokio::io::ReadBuf;
        struct Watched {
            bytes: std::io::Cursor<Vec<u8>>,
            reads: Arc<AtomicUsize>,
            full: Arc<tokio::sync::Notify>,
            dropped: Arc<tokio::sync::Notify>,
        }
        impl AsyncRead for Watched {
            fn poll_read(
                mut self: Pin<&mut Self>,
                cx: &mut Context<'_>,
                buf: &mut ReadBuf<'_>,
            ) -> Poll<std::io::Result<()>> {
                let before = buf.filled().len();
                let result = Pin::new(&mut self.bytes).poll_read(cx, buf);
                if buf.filled().len() > before && self.reads.fetch_add(1, Ordering::Relaxed) >= 2 {
                    self.full.notify_one();
                }
                result
            }
        }
        impl Drop for Watched {
            fn drop(&mut self) {
                self.dropped.notify_one();
            }
        }
        let full = Arc::new(tokio::sync::Notify::new());
        let dropped = Arc::new(tokio::sync::Notify::new());
        let cancel = CancellationToken::new();
        let stream = reader_stream(
            Watched {
                bytes: std::io::Cursor::new(vec![1; 65536]),
                reads: Arc::new(AtomicUsize::new(0)),
                full: full.clone(),
                dropped: dropped.clone(),
            },
            cancel.clone(),
        );
        tokio::time::timeout(std::time::Duration::from_secs(3), full.notified())
            .await
            .unwrap();
        cancel.cancel();
        tokio::time::timeout(std::time::Duration::from_secs(3), dropped.notified())
            .await
            .expect("cancellation must drop the reader without polling the HTTP body");
        drop(stream);
    }

    #[test]
    fn playlist_preserves_unicode_without_injecting_extra_entries() {
        let body = contents("Фильм\r\n#EXTINF:5,Injected\0", &stream()).unwrap();
        assert_eq!(body.lines().count(), 3);
        assert!(body.contains("Фильм"));
        assert!(!body.contains('\0'));
        assert_eq!(body.lines().last(), Some(stream().as_str()));
        assert!(contents("Title", "http://evil.example/file.mp4").is_err());
        assert!(contents("Title", &(stream() + "\nhttp://evil.example")).is_err());
    }

    #[test]
    fn writes_a_unique_cache_file_without_using_the_title_as_a_path() {
        let dir = std::env::temp_dir().join(format!(
            "multron-playlist-test-{}",
            uuid::Uuid::new_v4().simple()
        ));
        let path = save_cached(&dir, "../Фильм", &stream()).unwrap();
        assert_eq!(path.parent(), Some(dir.as_path()));
        assert!(path
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with("multron-"));
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            contents("../Фильм", &stream()).unwrap()
        );
        assert!(save(&dir.join("wrong.exe"), "Title", &stream()).is_err());
        std::fs::remove_file(path).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }

    #[test]
    fn rejects_missing_metadata_and_unselected_files() {
        let mut torrent = TorrentOptions::default();
        assert!(stream_file(&torrent, 0).is_err());
        torrent.info_hash = Some("a".repeat(40));
        torrent.files.push(crate::model::TorrentFile {
            name: "video.mp4".into(),
            length: 20,
            included: true,
        });
        assert_eq!(stream_file(&torrent, 0).unwrap().1, "video.mp4");
        assert!(stream_file(&torrent, 1).is_err());
        torrent.only_files = Some(vec![]);
        assert!(stream_file(&torrent, 0).is_err());
    }

    #[test]
    fn stream_tokens_are_not_written_to_request_logs() {
        assert_eq!(log_path("/stream/secret/hash/0"), "/stream/[redacted]");
        assert_eq!(log_path("/api/ping"), "/api/ping");
    }
}
