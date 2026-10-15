import Foundation

/// Only accepts metadata whose video ID matches the requested detail page.
enum DouyinMetadata {
    static let mobileAgent = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
    static func videoID(_ url: URL) -> String? {
        guard InputParser.platform(url.absoluteString) == "抖音" else { return nil }
        if let range = url.path.range(of: "(?:^/video/|^/share/video/)[0-9]+", options: .regularExpression) {
            return String(url.path[range]).split(separator: "/").last.map(String.init)
        }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {
            $0.name == "modal_id" && ($0.value ?? "").range(of: "^[0-9]+$", options: .regularExpression) != nil
        })?.value
    }
    static func canonical(_ id: String) -> URL { URL(string: "https://www.douyin.com/video/\(id)")! }
    static func object(_ value: Any, id: String, page: URL) -> [String: Any]? {
        func target(_ value: Any, depth: Int = 0) -> [String: Any]? {
            guard depth < 15 else { return nil }
            if let d = value as? [String: Any] {
                let key = String(describing: d["aweme_id"] ?? d["awemeId"] ?? d["id"] ?? "")
                if key == id, d["video"] is [String: Any] { return d }
                for child in d.values { if let found = target(child, depth: depth + 1) { return found } }
            } else if let a = value as? [Any] {
                for child in a.prefix(200) { if let found = target(child, depth: depth + 1) { return found } }
            }
            return nil
        }
        guard let item = target(value), let video = item["video"] as? [String: Any] else { return nil }
        func addresses(_ value: Any?) -> [String] {
            if let s = value as? String { return [s] }
            guard let d = value as? [String: Any] else { return [] }
            return (d["url_list"] ?? d["urlList"]) as? [String] ?? (d["url"] as? String).map { [$0] } ?? []
        }
        func webURL(_ s: String) -> Bool {
            guard let u = URL(string: s) else { return false }
            return ["http", "https"].contains(u.scheme ?? "") && u.host != nil && u.user == nil && u.password == nil
        }
        var formats: [[String: Any]] = [], seen = Set<String>()
        func add(_ value: Any?, parent: [String: Any]) {
            let d = value as? [String: Any] ?? [:]
            let mirrorGroup = "stream-\(formats.count)"
            for (index, url) in addresses(value).enumerated() where webURL(url) && seen.insert(url).inserted {
                var f: [String: Any] = ["format_id": "direct-\(formats.count)", "url": url, "ext": "mp4",
                    "http_headers": ["Referer": page.absoluteString, "User-Agent": mobileAgent]]
                // These are mirrors of the same encoded stream. Prefer the site's
                // first direct CDN URL over its slower /aweme/v1/play redirect.
                // source_preference is a tie-breaker after quality/codec/bitrate.
                let parsed = URL(string: url)!
                let redirect = InputParser.platform(url) == "抖音" && parsed.path.hasPrefix("/aweme/v1/play")
                f["source_preference"] = redirect ? -100 : -index
                f["vidtuck_mirror_group"] = mirrorGroup
                for k in ["height", "width"] {
                    if let n = (d[k] ?? parent[k] ?? video[k]) as? NSNumber, n.intValue > 0 { f[k] = n.intValue }
                }
                if let size = (d["data_size"] ?? d["dataSize"]) as? NSNumber, size.intValue > 0 { f["filesize"] = size }
                if let rate = (parent["bit_rate"] ?? parent["bitRate"]) as? NSNumber { f["tbr"] = rate.doubleValue / 1000 }
                if let codec = (parent["is_h265"] ?? parent["isH265"]) as? NSNumber { f["vcodec"] = codec.boolValue ? "hevc" : "h264" }
                formats.append(f)
            }
        }
        for rate in (video["bit_rate"] ?? video["bitRateList"]) as? [[String: Any]] ?? [] {
            add(rate["play_addr"] ?? rate["playAddr"], parent: rate)
        }
        for key in ["play_addr", "playAddr", "play_addr_h264", "playAddrH264", "play_addr_265", "playAddrH265"] { add(video[key], parent: video) }
        // Download/cover/music addresses are deliberately excluded from media selection.
        guard !formats.isEmpty else { return nil }
        let cover = ["cover", "origin_cover", "originCover", "dynamic_cover", "dynamicCover"].flatMap { addresses(video[$0]) }.first(where: webURL) ?? ""
        let rawTitle = (item["desc"] ?? item["item_title"] ?? item["itemTitle"]) as? String ?? ""
        return ["id": id, "title": rawTitle.isEmpty ? "抖音视频 \(id)" : rawTitle,
            "webpage_url": page.absoluteString, "extractor": "douyin-direct", "extractor_key": "Generic",
            "duration": ((video["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000,
            "thumbnail": cover, "formats": formats]
    }
    static func pageObject(_ data: Data, id: String, page: URL) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data), let result = object(json, id: id, page: page) { return result }
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        for pattern in [#"window\._ROUTER_DATA\s*=\s*(.*?)</script>"#, #"<script[^>]*\bid=["']RENDER_DATA["'][^>]*>(.*?)</script>"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let range = Range(m.range(at: 1), in: html) else { continue }
            let raw = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            for text in [raw, raw.removingPercentEncoding ?? raw] {
                if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let result = object(json, id: id, page: page) { return result }
            }
        }
        return nil
    }
}

/// Races the existing browser path; it never adds serial waiting before fallback.
/// No external parsing service, signature generation or CAPTCHA handling is used.
final class DouyinDirectRequest: NSObject, URLSessionTaskDelegate {
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var completion: (([String: Any]) -> Void)?
    private var stopped = false
    private var resolved: ((String) -> Void)?
    init(url: URL, cookies: [HTTPCookie], resolved: ((String) -> Void)? = nil, completion: @escaping ([String: Any]) -> Void) {
        super.init()
        self.completion = completion; self.resolved = resolved
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 8
        config.httpShouldSetCookies = true
        config.httpCookieStorage?.setCookies(cookies.filter {
            InputParser.platform("https://" + $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == "抖音"
        }, for: URL(string: "https://www.douyin.com/")!, mainDocumentURL: nil)
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        let target = DouyinMetadata.videoID(url).map { URL(string: "https://www.iesdouyin.com/share/video/\($0)/")! } ?? url
        fetch(target, expectedID: DouyinMetadata.videoID(url), api: false)
    }
    private func fetch(_ url: URL, expectedID: String?, api: Bool) {
        guard !stopped else { return }
        var request = URLRequest(url: url)
        request.setValue(DouyinMetadata.mobileAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
        task = session.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self = self, !self.stopped else { return }
                let final = response?.url ?? url
                guard InputParser.platform(final.absoluteString) == "抖音",
                      let id = expectedID ?? DouyinMetadata.videoID(final) else { self.cancel(); return }
                let page = DouyinMetadata.canonical(id)
                let resolved = self.resolved; self.resolved = nil; resolved?(id)
                if let r = response as? HTTPURLResponse, (200..<300).contains(r.statusCode), let data = data, data.count < 6_000_000,
                   let result = DouyinMetadata.pageObject(data, id: id, page: page) {
                    let done = self.completion; self.cancel(); done?(result)
                } else if !api {
                    self.fetch(URL(string: "https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=\(id)")!, expectedID: id, api: true)
                } else { self.cancel() }
            }
        }
        task?.resume()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = request.url.map { InputParser.platform($0.absoluteString) == "抖音" } == true
        if allowed, !stopped, let url = request.url, let id = DouyinMetadata.videoID(url) {
            let callback = resolved; resolved = nil; callback?(id)
        }
        completionHandler(allowed ? request : nil)
    }
    func cancel() {
        stopped = true; completion = nil; resolved = nil; task?.cancel(); task = nil
        session?.invalidateAndCancel()
    }
}
