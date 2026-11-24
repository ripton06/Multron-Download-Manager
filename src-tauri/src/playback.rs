use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{bail, Result};

use crate::model::TorrentOptions;

#[derive(Default)]
pub struct StreamTokens {
    files: HashMap<(String, usize), String>,
}

impl StreamTokens {
    pub fn retain_files(&mut self, hash: &str, files: &[usize]) {
        self.files
            .retain(|(existing, index), _| existing != hash || files.contains(index));
    }

    pub fn token(&mut self, hash: &str, file: usize) -> String {
        self.files
            .entry((hash.to_owned(), file))
            .or_insert_with(|| uuid::Uuid::new_v4().simple().to_string())
            .clone()
    }

    pub fn allows(&self, token: &str, hash: &str, file: usize) -> bool {
        self.files
            .get(&(hash.to_owned(), file))
            .is_some_and(|expected| expected == token)
    }
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
