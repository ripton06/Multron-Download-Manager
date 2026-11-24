use std::future::Future;

use anyhow::{anyhow, bail, Result};
use scraper::{ElementRef, Html, Selector};
use url::Url;

use super::{SearchResult, SiteAnswer, MAX_RESULTS, RUTOR};

const MIRROR: &str = "https://new-rutor.org/search/{query}/";
const MAX_BYTES: usize = 2 * 1024 * 1024;

struct FetchFailure {
    cause: anyhow::Error,
    transport: bool,
}

impl FetchFailure {
    fn other(error: impl Into<anyhow::Error>) -> Self {
        Self {
            cause: error.into(),
            transport: false,
        }
    }

    fn request(error: reqwest::Error) -> Self {
        let transport = !error.is_redirect()
            && !error.is_builder()
            && !error.is_status()
            && (error.is_connect() || error.is_request() || error.is_timeout() || error.is_body());
        Self {
            cause: error.into(),
            transport,
        }
    }

    fn body(error: reqwest::Error) -> Self {
        Self {
            cause: error.into(),
            transport: true,
        }
    }
}

type FetchResult = std::result::Result<Vec<SearchResult>, FetchFailure>;

fn origin_family(url: &Url) -> Option<&'static str> {
    match url.host_str() {
        Some("rutor.info" | "www.rutor.info") => Some("primary"),
        Some("new-rutor.org" | "www.new-rutor.org") => Some("mirror"),
        _ => None,
    }
}

fn redirect_policy() -> reqwest::redirect::Policy {
    reqwest::redirect::Policy::custom(|attempt| {
        if attempt.previous().len() >= 5 {
            attempt.error("RuTor redirected too many times")
        } else {
            let Some(origin) = attempt.previous().first() else {
                return attempt.error("RuTor redirected without a supported origin");
            };
            let previous = attempt.previous().last().unwrap_or(origin);
            match validate_redirect(origin, previous, attempt.url()) {
                Ok(()) => attempt.follow(),
                Err(error) => attempt.error(error.to_string()),
            }
        }
    })
}

fn validate_redirect(origin: &Url, previous: &Url, target: &Url) -> Result<()> {
    validate_origin(target)?;
    if origin_family(origin) != origin_family(target) {
        bail!("RuTor redirected to another origin family");
    }
    if previous.scheme() == "https" && target.scheme() == "http" {
        bail!("RuTor redirected from HTTPS to HTTP");
    }
    Ok(())
}

pub fn client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .user_agent(concat!(
            "Multron-Download-Manager/",
            env!("CARGO_PKG_VERSION")
        ))
        .connect_timeout(std::time::Duration::from_secs(15))
        .timeout(super::TIMEOUT)
        .retry(reqwest::retry::never())
        .redirect(redirect_policy())
        .min_tls_version(reqwest::tls::Version::TLS_1_2)
        .build()?)
}

pub fn search_url(template: &str, query: &str) -> String {
    let encoded: String = url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect();
    template.replace("{query}", &encoded.replace('+', "%20"))
}

pub fn validate_origin(url: &Url) -> Result<()> {
    if !matches!(url.scheme(), "http" | "https")
        || origin_family(url).is_none()
        || (origin_family(url) == Some("mirror") && url.scheme() != "https")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
    {
        bail!("RuTor redirected to an unsupported address");
    }
    Ok(())
}

async fn fetch(client: &reqwest::Client, url: Url) -> FetchResult {
    validate_origin(&url).map_err(FetchFailure::other)?;
    let mut response = client
        .get(url)
        .timeout(super::TIMEOUT)
        .send()
        .await
        .map_err(FetchFailure::request)?;
    let status = response.status();
    if !status.is_success() {
        return Err(FetchFailure::other(anyhow!(
            "the site answered HTTP {status}"
        )));
    }
    let final_url = response.url().clone();
    validate_origin(&final_url).map_err(FetchFailure::other)?;
    if response
        .content_length()
        .is_some_and(|length| length > MAX_BYTES as u64)
    {
        return Err(FetchFailure::other(anyhow!(
            "RuTor returned a response that is too large"
        )));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(FetchFailure::body)? {
        if bytes.len() + chunk.len() > MAX_BYTES {
            return Err(FetchFailure::other(anyhow!(
                "RuTor returned a response that is too large"
            )));
        }
        bytes.extend_from_slice(&chunk);
    }
    let body = String::from_utf8(bytes).map_err(FetchFailure::other)?;
    parse(&body, &final_url).map_err(FetchFailure::other)
}

pub(super) async fn search(template: &str, query: &str) -> Result<SiteAnswer> {
    let client = client()?;
    search_with_fetch(template, query, |url| fetch(&client, url)).await
}

async fn search_with_fetch<F, Fut>(template: &str, query: &str, mut fetch: F) -> Result<SiteAnswer>
where
    F: FnMut(Url) -> Fut,
    Fut: Future<Output = FetchResult>,
{
    let primary = Url::parse(&search_url(template, query))?;
    validate_origin(&primary)?;
    match fetch(primary).await {
        Ok(results) => Ok(SiteAnswer {
            results,
            notice: None,
        }),
        Err(primary) if primary.transport => {
            let mirror = Url::parse(&search_url(MIRROR, query))?;
            match fetch(mirror).await {
                Ok(results) => Ok(SiteAnswer {
                    results,
                    notice: Some(format!("RuTor primary request failed: {:#}. Results from HTTPS mirror new-rutor.org may be incomplete.", primary.cause)),
                }),
                Err(mirror) => Err(primary.cause.context(format!("RuTor HTTPS mirror new-rutor.org also failed: {:#}", mirror.cause))),
            }
        }
        Err(failure) => Err(failure.cause),
    }
}

fn text(element: ElementRef<'_>) -> String {
    element
        .text()
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn size(element: ElementRef<'_>) -> Option<u64> {
    let value = text(element);
    let (number, unit) = value.rsplit_once(' ')?;
    let unit = match unit.to_ascii_uppercase().as_str() {
        "KB" => "KiB",
        "MB" => "MiB",
        "GB" => "GiB",
        "TB" => "TiB",
        _ => unit,
    };
    crate::rss::human_size(&format!("{number} {unit}"))
}

fn number(element: ElementRef<'_>) -> Option<u64> {
    let digits: String = text(element).chars().filter(char::is_ascii_digit).collect();
    digits.parse().ok()
}

fn topic(base: &Url, href: &str) -> Option<(Url, String)> {
    let url = base.join(href).ok()?;
    validate_origin(&url).ok()?;
    let mut segments = url.path_segments()?;
    if segments.next()? != "torrent" {
        return None;
    }
    let id = segments.next()?;
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    Some((url.clone(), id.to_owned()))
}

fn magnet(href: &str) -> Option<String> {
    let url = Url::parse(href).ok()?;
    if url.scheme() != "magnet" {
        return None;
    }
    let valid = url.query_pairs().any(|(key, value)| {
        key == "xt"
            && value.strip_prefix("urn:btih:").is_some_and(|hash| {
                (hash.len() == 40 && hash.chars().all(|c| c.is_ascii_hexdigit()))
                    || (hash.len() == 32
                        && hash
                            .chars()
                            .all(|c| c.is_ascii_alphabetic() || ('2'..='7').contains(&c)))
            })
    });
    valid.then(|| href.to_owned())
}

fn download(base: &Url, href: &str, id: &str) -> Option<String> {
    let url = base.join(href).ok()?;
    let primary = matches!(
        url.host_str(),
        Some("rutor.info" | "www.rutor.info" | "d.rutor.info")
    ) && url.path() == format!("/download/{id}");
    let mirror = matches!(url.host_str(), Some("new-rutor.org" | "www.new-rutor.org"))
        && url.scheme() == "https"
        && url.path() == format!("/parse/d.rutor.org/download/{id}")
        && url.query().is_none()
        && url.fragment().is_none();
    if !matches!(url.scheme(), "http" | "https")
        || (!primary && !mirror)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
    {
        return None;
    }
    Some(url.to_string())
}

fn published(value: &str) -> Option<String> {
    let parts: Vec<_> = value.split_whitespace().collect();
    if parts.len() != 3 {
        return None;
    }
    let day = parts[0].parse().ok()?;
    let month = match parts[1].to_lowercase().as_str() {
        "янв" => 1,
        "фев" => 2,
        "мар" => 3,
        "апр" => 4,
        "май" => 5,
        "июн" => 6,
        "июл" => 7,
        "авг" => 8,
        "сен" => 9,
        "окт" => 10,
        "ноя" => 11,
        "дек" => 12,
        _ => return None,
    };
    let year: i32 = parts[2].parse().ok()?;
    let year = if parts[2].len() == 2 {
        year + 2000
    } else {
        year
    };
    chrono::NaiveDate::from_ymd_opt(year, month, day).map(|date| date.to_string())
}

pub fn parse(body: &str, base: &Url) -> Result<Vec<SearchResult>> {
    validate_origin(base)?;
    let html = Html::parse_document(body);
    let index = Selector::parse("#index").unwrap();
    let rows = Selector::parse("table tr").unwrap();
    let links = Selector::parse("a[href]").unwrap();
    let seeds = Selector::parse("span.green").unwrap();
    let peers = Selector::parse("span.red").unwrap();
    let Some(index) = html.select(&index).next() else {
        bail!("RuTor did not return its search results; access may be blocked or the page layout has changed");
    };
    let mut results = Vec::new();
    for row in index.select(&rows) {
        let cells: Vec<_> = row
            .children()
            .filter_map(ElementRef::wrap)
            .filter(|cell| cell.value().name() == "td")
            .collect();
        let Some((title_link, page, id)) = row.select(&links).find_map(|link| {
            let (page, id) = topic(base, link.value().attr("href")?)?;
            Some((link, page, id))
        }) else {
            continue;
        };
        let title = text(title_link);
        if title.is_empty() {
            continue;
        }
        let hrefs: Vec<_> = row
            .select(&links)
            .filter_map(|link| link.value().attr("href"))
            .collect();
        let Some(download) = hrefs
            .iter()
            .find_map(|href| magnet(href))
            .or_else(|| hrefs.iter().find_map(|href| download(base, href, &id)))
        else {
            continue;
        };
        results.push(SearchResult {
            site: RUTOR.into(),
            title,
            download,
            page: Some(page.to_string()),
            size: cells.iter().rev().nth(1).and_then(|cell| size(*cell)),
            seeders: row.select(&seeds).next().and_then(number),
            leechers: row.select(&peers).next().and_then(number),
            published: cells.first().and_then(|cell| published(&text(*cell))),
        });
        if results.len() == MAX_RESULTS {
            break;
        }
    }
    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIRROR_RESULTS: &str = r#"<div id="index"><table>
<tr><td>18 Мар 10</td><td colspan="2"><a href="/parse/d.rutor.org/download/39424">D</a><a href="/torrent/39424/debian-lessons">Debian lessons</a></td><td>331.90 MB</td><td><span class="green">1</span><span class="red">0</span></td></tr>
<tr><td>11 Апр 15</td><td colspan="2"><a href="/parse/d.rutor.org/download/425262">D</a><a href="/torrent/425262/linux-mint">Linux Mint Debian</a></td><td>5.87 GB</td><td><span class="green">0</span><span class="red">0</span></td></tr>
<tr><td>11 Ноя 14</td><td colspan="2"><a href="/parse/d.rutor.org/download/390348">D</a><a href="/torrent/390348/debian-jessie">Debian Jessie</a></td><td>1.19 GB</td><td><span class="green">0</span><span class="red">0</span></td></tr>
</table></div>"#;

    fn base() -> Url {
        Url::parse("http://rutor.info/search/0/0/100/0/test").unwrap()
    }

    fn mirror_base() -> Url {
        Url::parse("https://new-rutor.org/search/debian/").unwrap()
    }

    #[test]
    fn reads_https_mirror_download_only_rows() {
        let rows = parse(MIRROR_RESULTS, &mirror_base()).unwrap();
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].title, "Debian lessons");
        assert_eq!(rows[0].size, Some(348022374));
        assert_eq!(rows[0].published.as_deref(), Some("2010-03-18"));
        assert_eq!(
            rows[0].download,
            "https://new-rutor.org/parse/d.rutor.org/download/39424"
        );
        assert!(rows.iter().all(|row| row.site == RUTOR));
    }

    #[test]
    fn mirror_downloads_require_the_exact_host_path_and_topic() {
        let base = mirror_base();
        assert!(download(&base, "/parse/d.rutor.org/download/12", "12").is_some());
        assert!(download(
            &base,
            "https://www.new-rutor.org/parse/d.rutor.org/download/12",
            "12"
        )
        .is_some());
        for href in [
            "/parse/evil.example/download/12",
            "/parse/d.rutor.org/download/13",
            "/parse/d.rutor.org/download/12/extra",
            "/parse/d.rutor.org/download/12?url=http://127.0.0.1/",
            "/parse/d.rutor.org/download/12#other",
            "http://new-rutor.org/parse/d.rutor.org/download/12",
            "https://new-rutor.org.evil.example/parse/d.rutor.org/download/12",
            "https://rutor.info/parse/d.rutor.org/download/12",
            "https://user:pass@new-rutor.org/parse/d.rutor.org/download/12",
            "https://new-rutor.org:9443/parse/d.rutor.org/download/12",
        ] {
            assert!(download(&base, href, "12").is_none(), "{href}");
        }
    }

    #[test]
    fn mirror_results_keep_magnet_preference() {
        let body = r#"<div id="index"><table><tr><td>24 Ноя 26</td><td><a href="/parse/d.rutor.org/download/12">D</a><a href="magnet:?xt=urn:btih:029830a40e0fd9eca4cabb8f8c0e24a9e8c5a03f">M</a><a href="/torrent/12/linux">Linux</a></td><td>1 GB</td><td><span class="green">1</span><span class="red">0</span></td></tr></table></div>"#;
        let rows = parse(body, &mirror_base()).unwrap();
        assert_eq!(rows.len(), 1);
        assert!(rows[0].download.starts_with("magnet:"));
    }

    #[test]
    fn mirror_query_is_an_encoded_https_path() {
        assert_eq!(
            search_url(MIRROR, " окно в париж / + "),
            "https://new-rutor.org/search/%D0%BE%D0%BA%D0%BD%D0%BE%20%D0%B2%20%D0%BF%D0%B0%D1%80%D0%B8%D0%B6%20%2F%20%2B/"
        );
    }

    #[test]
    fn redirect_families_and_https_are_checked_before_following() {
        let primary = base();
        let mirror = mirror_base();
        assert!(validate_redirect(
            &primary,
            &primary,
            &Url::parse("https://www.rutor.info/search/debian").unwrap()
        )
        .is_ok());
        assert!(validate_redirect(
            &mirror,
            &mirror,
            &Url::parse("https://www.new-rutor.org/search/debian/").unwrap()
        )
        .is_ok());
        assert!(validate_redirect(&primary, &primary, &mirror).is_err());
        assert!(validate_redirect(&mirror, &mirror, &primary).is_err());
        let secure = Url::parse("https://rutor.info/search/debian").unwrap();
        assert!(validate_redirect(&secure, &secure, &primary).is_err());
    }

    fn response(body: &str) -> Vec<u8> {
        format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
        .into_bytes()
    }

    async fn outcome_from_primary(
        response: Vec<u8>,
        mirror_fails: bool,
    ) -> (Result<SiteAnswer>, Vec<Url>) {
        use std::sync::{Arc, Mutex};
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let proxy = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let proxy_url = format!("http://{}", proxy.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (mut socket, _) = proxy.accept().await.unwrap();
            let mut request = [0; 4096];
            socket.read(&mut request).await.unwrap();
            if !response.is_empty() {
                socket.write_all(&response).await.unwrap();
            }
        });
        let client = reqwest::Client::builder()
            .proxy(reqwest::Proxy::all(proxy_url).unwrap())
            .retry(reqwest::retry::never())
            .redirect(redirect_policy())
            .timeout(std::time::Duration::from_secs(2))
            .build()
            .unwrap();
        let calls = Arc::new(Mutex::new(Vec::new()));
        let recorded = calls.clone();
        let outcome = search_with_fetch(
            "http://rutor.info/search/0/0/100/0/{query}",
            "debian",
            |url| {
                recorded.lock().unwrap().push(url.clone());
                let client = client.clone();
                async move {
                    if origin_family(&url) == Some("primary") {
                        fetch(&client, url).await
                    } else if mirror_fails {
                        Err(FetchFailure::other(anyhow!("mirror fixture failed")))
                    } else {
                        parse(MIRROR_RESULTS, &url).map_err(FetchFailure::other)
                    }
                }
            },
        )
        .await;
        server.await.unwrap();
        let calls = calls.lock().unwrap().clone();
        (outcome, calls)
    }

    #[tokio::test]
    async fn a_real_request_failure_uses_the_https_mirror_once_with_notice() {
        let (outcome, calls) = outcome_from_primary(Vec::new(), false).await;
        let answer = outcome.unwrap();
        assert_eq!(answer.results.len(), 3);
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[1].as_str(), "https://new-rutor.org/search/debian/");
        let notice = answer.notice.unwrap();
        assert!(notice.contains("rutor.info"), "{notice}");
        assert!(notice.contains("new-rutor.org"), "{notice}");
        assert!(notice.contains("incomplete"), "{notice}");
    }

    #[tokio::test]
    async fn a_reset_while_reading_the_body_uses_the_mirror() {
        let response =
            b"HTTP/1.1 200 OK\r\nContent-Length: 64\r\nConnection: close\r\n\r\nx".to_vec();
        let (outcome, calls) = outcome_from_primary(response, false).await;
        let answer = outcome.unwrap();
        assert_eq!(answer.results.len(), 3);
        assert!(answer.notice.is_some());
        assert_eq!(calls.len(), 2);
    }

    #[tokio::test]
    async fn empty_success_does_not_query_a_mirror() {
        let (outcome, calls) = outcome_from_primary(
            response("<div id='index'><table><tr><td>Name</td></tr></table></div>"),
            false,
        )
        .await;
        let answer = outcome.unwrap();
        assert!(answer.results.is_empty());
        assert!(answer.notice.is_none());
        assert_eq!(calls.len(), 1);
    }

    #[tokio::test]
    async fn a_layout_error_does_not_query_a_mirror() {
        let (outcome, calls) =
            outcome_from_primary(response("<h1>Verification required</h1>"), false).await;
        assert!(outcome
            .err()
            .unwrap()
            .to_string()
            .contains("did not return"));
        assert_eq!(calls.len(), 1);
    }

    #[tokio::test]
    async fn an_http_error_does_not_query_a_mirror() {
        let (outcome, calls) = outcome_from_primary(
            b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                .to_vec(),
            false,
        )
        .await;
        assert!(outcome.err().unwrap().to_string().contains("503"));
        assert_eq!(calls.len(), 1);
    }

    #[tokio::test]
    async fn response_limits_do_not_query_a_mirror() {
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            MAX_BYTES + 1
        )
        .into_bytes();
        let (outcome, calls) = outcome_from_primary(response, false).await;
        assert!(outcome.err().unwrap().to_string().contains("too large"));
        assert_eq!(calls.len(), 1);
    }

    #[tokio::test]
    async fn a_cross_family_redirect_is_not_a_transport_fallback() {
        let response = b"HTTP/1.1 302 Found\r\nLocation: https://new-rutor.org/search/debian/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec();
        let (outcome, calls) = outcome_from_primary(response, false).await;
        assert!(format!("{:#}", outcome.err().unwrap()).contains("another origin family"));
        assert_eq!(calls.len(), 1);
    }

    #[tokio::test]
    async fn both_failure_causes_are_preserved() {
        let (outcome, calls) = outcome_from_primary(Vec::new(), true).await;
        let error = format!("{:#}", outcome.err().unwrap());
        assert!(error.contains("rutor.info"), "{error}");
        assert!(error.contains("mirror fixture failed"), "{error}");
        assert_eq!(calls.len(), 2);
    }

    #[test]
    fn reads_magnets_and_download_only_rows() {
        let body = r#"<div id="index"><table><tr><td>Добавлен</td><td>Название</td></tr>
<tr><td>24&nbsp;Ноя&nbsp;26</td><td><a href="//d.rutor.info/download/12">D</a><a href="magnet:?xt=urn:btih:029830a40e0fd9eca4cabb8f8c0e24a9e8c5a03f&amp;dn=Linux">M</a><a href="/torrent/12/linux">Линукс &amp; Debian</a></td><td>4</td><td>1.5&nbsp;GiB</td><td><span class="green">1 234</span><span class="red">2</span></td></tr>
<tr><td>11 Апр 15</td><td colspan="2"><a href="//d.rutor.info/download/13">D</a><a href="/torrent/13/other">Другой файл</a></td><td>331.90 MB</td><td><span class="green">0</span><span class="red">1</span></td></tr></table></div>"#;
        let rows = parse(body, &base()).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].title, "Линукс & Debian");
        assert_eq!(rows[0].size, Some(1610612736));
        assert_eq!(rows[0].seeders, Some(1234));
        assert_eq!(rows[0].published.as_deref(), Some("2026-11-24"));
        assert!(rows[0].download.starts_with("magnet:?xt="));
        assert!(!rows[0].download.contains("&amp;"));
        assert_eq!(rows[1].download, "http://d.rutor.info/download/13");
        assert_eq!(rows[1].size, Some(348022374));
    }

    #[test]
    fn rejects_untrusted_urls_and_invalid_magnets() {
        assert!(topic(&base(), "https://evil.example/torrent/12/a").is_none());
        assert!(download(&base(), "http://127.0.0.1/download/12", "12").is_none());
        assert!(download(&base(), "http://rutor.info.evil.example/download/12", "12").is_none());
        assert!(download(&base(), "/download/13", "12").is_none());
        assert!(magnet("magnet:?xt=urn:btih:bad").is_none());
        assert!(magnet("javascript:alert(1)").is_none());
    }

    #[test]
    fn distinguishes_missing_layout_from_empty_results() {
        assert!(parse("<h1>Browser verification required</h1>", &base()).is_err());
        assert!(parse(
            "<div id='index'><table><tr><td>Название</td></tr></table></div>",
            &base()
        )
        .unwrap()
        .is_empty());
    }

    #[test]
    fn encodes_search_as_a_path_segment() {
        assert_eq!(
            search_url("http://rutor.info/search/0/0/100/0/{query}", " кино + / & "),
            "http://rutor.info/search/0/0/100/0/%D0%BA%D0%B8%D0%BD%D0%BE%20%2B%20%2F%20%26"
        );
    }

    #[tokio::test]
    async fn unsupported_redirect_is_rejected_before_a_second_request() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let blocked = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let location = format!("http://{}/private", blocked.local_addr().unwrap());
        let proxy = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let proxy_url = format!("http://{}", proxy.local_addr().unwrap());
        let response = format!("HTTP/1.1 302 Found\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        let server = tokio::spawn(async move {
            let (mut socket, _) = proxy.accept().await.unwrap();
            let mut bytes = [0; 4096];
            socket.read(&mut bytes).await.unwrap();
            socket.write_all(response.as_bytes()).await.unwrap();
        });
        let client = reqwest::Client::builder()
            .proxy(reqwest::Proxy::all(proxy_url).unwrap())
            .redirect(redirect_policy())
            .build()
            .unwrap();
        let error = client
            .get("http://rutor.info/search/0/0/100/0/debian")
            .send()
            .await
            .unwrap_err();
        assert!(error.is_redirect(), "{error}");
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), blocked.accept())
                .await
                .is_err()
        );
        server.await.unwrap();
    }

    #[tokio::test]
    #[ignore]
    async fn live_public_search() {
        let settings = crate::settings::Settings::default();
        let client = reqwest::Client::new();
        let query = std::env::var("MULTRON_RUTOR_TEST_QUERY").unwrap_or_else(|_| "debian".into());
        let out = super::super::search(&client, &settings, &query, &[RUTOR.to_owned()]).await;
        assert!(
            out.errors.is_empty()
                || (out.errors.len() == 1
                    && out.errors[0].site == RUTOR
                    && out.errors[0]
                        .error
                        .starts_with("RuTor primary request failed:")
                    && out.errors[0]
                        .error
                        .ends_with("Results from HTTPS mirror new-rutor.org may be incomplete.")),
            "{:?}",
            out.errors
        );
        let minimum = std::env::var("MULTRON_RUTOR_TEST_MIN_RESULTS")
            .map(|value| {
                value
                    .parse::<usize>()
                    .expect("invalid minimum result count")
            })
            .unwrap_or(usize::from(query == "debian"));
        assert!(out.results.len() >= minimum, "{:?}", out.errors);
        println!("RuTor query {query:?}: {} results", out.results.len());
        for error in &out.errors {
            println!("{}: {}", error.site, error.error);
        }
        assert!(out
            .results
            .iter()
            .all(|row| row.download.starts_with("magnet:")
                || row.download.starts_with("http://d.rutor.info/download/")
                || row
                    .download
                    .starts_with("https://new-rutor.org/parse/d.rutor.org/download/")));
    }

    #[tokio::test]
    #[ignore]
    async fn live_https_mirror_search() {
        let query = std::env::var("MULTRON_RUTOR_TEST_QUERY").unwrap_or_else(|_| "debian".into());
        let minimum = std::env::var("MULTRON_RUTOR_TEST_MIN_RESULTS")
            .map(|value| {
                value
                    .parse::<usize>()
                    .expect("invalid minimum result count")
            })
            .unwrap_or(1);
        let client = client().unwrap();
        let url = Url::parse(&search_url(MIRROR, &query)).unwrap();
        let results = fetch(&client, url)
            .await
            .map_err(|failure| failure.cause)
            .unwrap();
        assert!(results.len() >= minimum);
        assert!(results.iter().all(|row| row.site == RUTOR));
        println!("HTTPS mirror query {query:?}: {} results", results.len());
    }
}
