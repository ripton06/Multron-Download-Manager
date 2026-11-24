use anyhow::{bail, Result};
use scraper::{ElementRef, Html, Selector};
use url::Url;

use super::{SearchResult, MAX_RESULTS, RUTOR};

pub fn search_url(template: &str, query: &str) -> String {
    let encoded: String = url::form_urlencoded::byte_serialize(query.trim().as_bytes()).collect();
    template.replace("{query}", &encoded.replace('+', "%20"))
}

pub fn validate_origin(url: &Url) -> Result<()> {
    if !matches!(url.scheme(), "http" | "https")
        || !matches!(url.host_str(), Some("rutor.info" | "www.rutor.info"))
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
    {
        bail!("RuTor redirected to an unsupported address");
    }
    Ok(())
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
    if !matches!(url.scheme(), "http" | "https")
        || !matches!(
            url.host_str(),
            Some("rutor.info" | "www.rutor.info" | "d.rutor.info")
        )
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
        || url.path() != format!("/download/{id}")
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

    fn base() -> Url {
        Url::parse("http://rutor.info/search/0/0/100/0/test").unwrap()
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
    #[ignore]
    async fn live_public_search() {
        let settings = crate::settings::Settings::default();
        let client = reqwest::Client::new();
        let out = super::super::search(&client, &settings, "debian", &[RUTOR.to_owned()]).await;
        assert!(out.errors.is_empty(), "{:?}", out.errors);
        assert!(!out.results.is_empty());
        assert!(out
            .results
            .iter()
            .all(|row| row.download.starts_with("magnet:")
                || row.download.starts_with("http://d.rutor.info/download/")));
    }
}
