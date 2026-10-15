import Foundation
import Darwin

struct VideoJob: Codable {
    var id = UUID().uuidString
    var url: String
    var platform: String
    var title = "正在读取视频信息…"
    var state = "pending"
    var quality: String
    var mode: String
    var destination: String
    var thumbnail = ""
    var duration: Double = 0
    var resolutions: [Int] = []
    var progress: Double = 0
    var detail = "等待解析"
    var error = ""
    var file = ""
    var created = Date().timeIntervalSince1970
    var infoFile: String? = nil
    var mediaWidth: Int? = nil
    var mediaHeight: Int? = nil
    var mediaExt: String? = nil
    var fileSize: Int64? = nil
}

struct LibraryState: Codable {
    var jobs: [VideoJob] = []
    var destination: String
    var quality = "best"
    var mode = "video"
    var autoDownload: Bool? = true
}

enum InputParser {
    static func urls(_ input: String) -> [String] {
        let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var seen = Set<String>()
        return detector.matches(in: input, range: NSRange(input.startIndex..., in: input)).compactMap {
            guard let range = Range($0.range, in: input) else { return nil }
            let s = String(input[range]).trimmingCharacters(in: CharacterSet(charactersIn: "，。；、）】》」\"'<>"))
            guard let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil,
                  u.user == nil, u.password == nil, seen.insert(s).inserted else { return nil }
            return s
        }
    }
    static func platform(_ value: String) -> String {
        let h = URL(string: value)?.host?.lowercased() ?? ""
        func isHost(_ d: String) -> Bool { h == d || h.hasSuffix("." + d) }
        if isHost("youtube.com") || isHost("youtu.be") { return "YouTube" }
        if isHost("bilibili.com") || isHost("b23.tv") { return "B站" }
        if isHost("douyin.com") || isHost("iesdouyin.com") { return "抖音" }
        if isHost("xiaohongshu.com") || isHost("xhslink.com") { return "小红书" }
        return "其他"
    }
    static func safeLog(_ value: String) -> String {
        var s = value
        for pattern in ["https?://[^\\s]+", "(?i)(cookie|authorization|xsec_token|msToken|token)[:=]\\s*[^\\s,;]+"] {
            s = s.replacingOccurrences(of: pattern, with: "[链接或凭据已隐藏]", options: .regularExpression)
        }
        return String(s.suffix(2400))
    }
    static func isVideoPage(_ url: URL) -> Bool {
        let path = url.path
        switch platform(url.absoluteString) {
        case "YouTube":
            return url.host?.lowercased() == "youtu.be" && path.count > 1 || path == "/watch" && (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "v" && !($0.value ?? "").isEmpty } ?? false) || ["/shorts/", "/live/", "/embed/"].contains { path.hasPrefix($0) && path.count > $0.count }
        case "B站": return path.range(of: "^/video/(?:BV|av)[A-Za-z0-9]+", options: [.regularExpression, .caseInsensitive]) != nil
        case "抖音": return path.range(of: "^/video/[0-9]+", options: .regularExpression) != nil || (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "modal_id" && ($0.value ?? "").range(of: "^[0-9]+$", options: .regularExpression) != nil } ?? false)
        case "小红书": return path.range(of: "^/(?:explore|discovery/item)/[a-f0-9]+", options: .regularExpression) != nil
        default: return false
        }
    }
}

final class ToolCommand {
    let process = Process()
    private var cancelled = false
    private let lock = NSLock()
    private var didTimeout = false
    func stop() {
        lock.lock(); cancelled = true; lock.unlock()
        if process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self, self.process.isRunning else { return }
                kill(self.process.processIdentifier, SIGKILL)
            }
        }
    }
    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Double = 150,
             onLine: @escaping (String) -> Void = { _ in }, completion: @escaping (Int32, Data, String) -> Void) {
        let output = Pipe(), errors = Pipe()
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardOutput = output; process.standardError = errors; process.standardInput = FileHandle.nullDevice
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                lock.lock()
                if cancelled { lock.unlock(); DispatchQueue.main.async { completion(-15, Data(), "已暂停") }; return }
                try process.run()
                lock.unlock()
            } catch {
                lock.unlock()
                DispatchQueue.main.async { completion(-1, Data(), error.localizedDescription) }; return
            }
            let group = DispatchGroup(), dataLock = NSLock()
            var stdout = Data(), stderr = Data()
            func read(_ handle: FileHandle, isError: Bool) {
                var pending = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    dataLock.lock()
                    if isError { stderr.append(chunk); if stderr.count > 131072 { stderr = stderr.suffix(131072) } }
                    else { stdout.append(chunk); if stdout.count > 33554432 { stdout = stdout.suffix(33554432) } }
                    dataLock.unlock()
                    pending.append(chunk)
                    while let end = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending[..<end], as: UTF8.self)
                        pending.removeSubrange(...end)
                        DispatchQueue.main.async { onLine(line) }
                    }
                    if pending.count > 1048576 { pending.removeAll() }
                }
                if !pending.isEmpty { let line = String(decoding: pending, as: UTF8.self); DispatchQueue.main.async { onLine(line) } }
            }
            group.enter(); DispatchQueue.global().async { read(output.fileHandleForReading, isError: false); group.leave() }
            group.enter(); DispatchQueue.global().async { read(errors.fileHandleForReading, isError: true); group.leave() }
            let deadline = DispatchWorkItem { [weak self] in
                guard let self = self, self.process.isRunning else { return }
                self.didTimeout = true; self.stop()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            process.waitUntilExit(); group.wait(); deadline.cancel()
            let code = process.terminationStatus
            let err = didTimeout ? "请求超时，请检查网络后重试。\n" + String(decoding: stderr, as: UTF8.self) : String(decoding: stderr, as: UTF8.self)
            DispatchQueue.main.async { completion(code, stdout, err) }
        }
    }
}

final class DownloadLibrary {
    let support: URL
    let tools: URL
    var state: LibraryState
    var changed: (() -> Void)?
    var toast: ((String) -> Void)?
    var command: ToolCommand?
    var activeID: String?
    var engineVersion = "检查中"
    var updating = false
    var resolveDouyin: ((VideoJob, @escaping (Bool) -> Void) -> Void)?
    var cancelDouyin: ((String) -> Void)?
    let fm = FileManager.default

    init(tools: URL, support: URL? = nil) {
        self.tools = tools
        // Keep the original storage identifier so rebranding preserves existing data.
        self.support = support ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StreamNest")
        try? fm.createDirectory(at: self.support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let defaultPath = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("VidTuck").path
        state = LibraryState(destination: defaultPath)
        if let data = try? Data(contentsOf: self.support.appendingPathComponent("library.json")), let saved = try? JSONDecoder().decode(LibraryState.self, from: data) { state = saved }
        for i in state.jobs.indices {
            if state.jobs[i].title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { state.jobs[i].title = "网页视频" }
            if ["pending", "analyzing", "queued", "downloading"].contains(state.jobs[i].state) {
                state.jobs[i].state = "paused"; state.jobs[i].detail = "上次任务已暂停，可继续"
            }
            // Browser media URLs and session snapshots are deliberately transient.
            if let path = state.jobs[i].infoFile { state.jobs[i].infoFile = nil; if !URL(fileURLWithPath: path).lastPathComponent.hasPrefix("extractor-info-") && state.jobs[i].state != "done" { state.jobs[i].state = "failed"; state.jobs[i].error = "网页媒体链接已过期，请重新读取网页。" } }
        }
        if let files = try? fm.contentsOfDirectory(at: self.support, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix("web-info-") || f.lastPathComponent.hasPrefix("extractor-info-") { try? fm.removeItem(at: f) }
        }
    }
    var executable: URL {
        let updated = support.appendingPathComponent("tools/yt-dlp")
        if fm.isExecutableFile(atPath: updated.path) { return updated }
        // The official directory build keeps its runtime in place between calls.
        // The one-file build unpacks fresh dylibs on every invocation on macOS.
        let runtime = tools.appendingPathComponent("yt-dlp-runtime/yt-dlp_macos")
        return fm.isExecutableFile(atPath: runtime.path) ? runtime : tools.appendingPathComponent("yt-dlp")
    }
    var environment: [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = tools.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        e["PYTHONIOENCODING"] = "utf-8"; e["LC_ALL"] = "en_US.UTF-8"
        return e
    }
    func save() {
        if let data = try? JSONEncoder().encode(state) {
            let u = support.appendingPathComponent("library.json"); try? data.write(to: u, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
        }
    }
    func emit() { save(); changed?() }
    func mutate(_ id: String, _ fn: (inout VideoJob) -> Void) {
        guard let i = state.jobs.firstIndex(where: { $0.id == id }) else { return }; fn(&state.jobs[i]); emit()
    }
    func add(_ input: String) {
        let urls = InputParser.urls(input)
        guard !urls.isEmpty else { toast?("没有找到有效链接，请粘贴视频网址或分享文案。"); return }
        var added = 0
        for u in urls.prefix(50) {
            if state.jobs.contains(where: { $0.url == u && !["done", "failed"].contains($0.state) }) { continue }
            state.jobs.insert(VideoJob(url: u, platform: InputParser.platform(u), quality: state.quality, mode: state.mode, destination: state.destination), at: 0); added += 1
        }
        emit(); toast?(added > 0 ? "已加入 \(added) 个链接，正在解析" : "这些链接已在队列中"); pump()
    }
    func baseArgs(_ job: VideoJob) -> [String] {
        var a = ["--ignore-config", "--no-playlist", "--no-colors", "--socket-timeout", "20", "--retries", "2", "--extractor-retries", "1", "--ffmpeg-location", tools.path, "--js-runtimes", "deno:" + tools.appendingPathComponent("deno").path]
        let c = cookieURL(job.platform)
        if fm.fileExists(atPath: c.path) { a += ["--cookies", c.path] }
        return a
    }
    func cookieURL(_ platform: String) -> URL {
        let key = ["YouTube": "youtube", "B站": "bilibili", "抖音": "douyin", "小红书": "xhs"][platform] ?? "other"
        return support.appendingPathComponent("cookies-\(key).txt")
    }
    func pump() {
        guard activeID == nil, !updating else { return }
        if let job = state.jobs.reversed().first(where: { $0.state == "queued" }) { download(job); return }
        if let job = state.jobs.reversed().first(where: { $0.state == "pending" }) { analyze(job) }
    }
    func analyze(_ job: VideoJob) {
        activeID = job.id
        mutate(job.id) { $0.state = "analyzing"; $0.detail = "正在读取标题与清晰度…"; $0.error = "" }
        // Douyin's browser resolver already handles public and short links. Try it
        // immediately instead of waiting for an unsuccessful extractor request first.
        if job.platform == "抖音", let resolve = resolveDouyin {
            mutate(job.id) { $0.detail = "正在后台读取抖音视频…" }
            resolve(job) { [weak self] success in
                guard let self = self, self.activeID == job.id else { return }
                guard self.state.jobs.first(where: { $0.id == job.id })?.state == "analyzing" else {
                    self.activeID = nil; self.pump(); return
                }
                if success {
                    // A resolver reports success only after setMetadata changes state.
                    self.activeID = nil; self.pump()
                } else {
                    self.mutate(job.id) { $0.detail = "正在尝试备用解析…" }
                    self.analyzeWithExtractor(job)
                }
            }
            return
        }
        analyzeWithExtractor(job)
    }
    func analyzeWithExtractor(_ job: VideoJob) {
        let cmd = ToolCommand(); command = cmd
        cmd.run(executable: executable, arguments: baseArgs(job) + ["--dump-single-json", "--skip-download", "--", job.url], environment: environment) { [weak self] code, data, error in
            guard let self = self else { return }; self.command = nil
            if self.state.jobs.first(where: { $0.id == job.id })?.state != "analyzing" { self.activeID = nil; self.pump(); return }
            if code == 0, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["_type"] as? String != "playlist", (object["formats"] as? [Any])?.isEmpty == false || object["url"] != nil {
                // Reuse the full format list instead of extracting the same page twice.
                var infoFile: String?
                if ["YouTube", "B站", "小红书"].contains(job.platform) {
                    let file = self.support.appendingPathComponent("extractor-info-\(job.id).json")
                    do {
                        try data.write(to: file, options: .atomic)
                        try self.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                        infoFile = file.path
                    } catch { try? self.fm.removeItem(at: file) }
                }
                self.setMetadata(job.id, object: object, infoFile: infoFile)
            } else {
                let raw = error.isEmpty ? String(decoding: data, as: UTF8.self) : error
                self.mutate(job.id) { $0.state = "failed"; $0.title = "需要重新解析"; $0.detail = "解析未完成"; $0.error = self.friendlyError(raw) }
            }
            self.activeID = nil
            self.pump()
        }
    }
    func setMetadata(_ id: String, object: [String: Any], infoFile: String? = nil) {
        let automatic = state.autoDownload != false
        mutate(id) {
            let title = (object["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            $0.title = title.isEmpty ? "网页视频" : title
            $0.duration = (object["duration"] as? NSNumber)?.doubleValue ?? 0
            let thumbnails = object["thumbnails"] as? [[String: Any]] ?? []
            $0.thumbnail = object["thumbnail"] as? String ?? thumbnails.last?["url"] as? String ?? ""
            let formats = object["formats"] as? [[String: Any]] ?? []
            $0.resolutions = Array(Set(formats.compactMap { ($0["height"] as? NSNumber)?.intValue })).sorted(by: >)
            let cap = Int($0.quality) ?? Int.max
            let best = formats.filter { (($0["height"] as? NSNumber)?.intValue ?? 0) > 0 && (($0["height"] as? NSNumber)?.intValue ?? 0) <= cap }.max { (($0["height"] as? NSNumber)?.intValue ?? 0) < (($1["height"] as? NSNumber)?.intValue ?? 0) }
            $0.mediaWidth = (best?["width"] as? NSNumber)?.intValue ?? (object["width"] as? NSNumber)?.intValue
            $0.mediaHeight = (best?["height"] as? NSNumber)?.intValue ?? (object["height"] as? NSNumber)?.intValue
            $0.mediaExt = $0.mode == "audio" ? "m4a" : best?["ext"] as? String ?? object["ext"] as? String
            $0.state = automatic ? "queued" : "ready"; $0.error = ""; $0.detail = infoFile == nil || infoFile?.contains("/extractor-info-") == true ? "解析完成，选择清晰度后下载" : "已从网页读取 · 清晰度取决于网页提供的媒体"; $0.infoFile = infoFile
        }
    }
    func start(_ id: String) {
        if let job = state.jobs.first(where: { $0.id == id }), job.state == "failed", let path = job.infoFile, isTransientInfo(path) { try? fm.removeItem(atPath: path) }
        mutate(id) {
            if $0.state == "ready" || $0.state == "paused" { $0.state = $0.title == "正在读取视频信息…" ? "pending" : "queued"; $0.detail = "等待下载" }
            else if $0.state == "failed" { $0.state = "pending"; $0.error = ""; $0.infoFile = nil }
        }; pump()
    }
    func startAll() {
        for i in state.jobs.indices where state.jobs[i].state == "ready" || state.jobs[i].state == "paused" { state.jobs[i].state = state.jobs[i].title == "正在读取视频信息…" ? "pending" : "queued"; state.jobs[i].detail = "等待下载" }
        emit(); pump()
    }
    func pause(_ id: String) {
        mutate(id) { $0.state = "paused"; $0.detail = "已暂停 · 点击继续" }
        if activeID == id { command?.stop() }
        cancelDouyin?(id)
    }
    func remove(_ id: String) {
        if activeID == id { command?.stop() }
        if let job = state.jobs.first(where: { $0.id == id }), let path = job.infoFile, isTransientInfo(path) { try? fm.removeItem(atPath: path) }
        state.jobs.removeAll { $0.id == id }; emit()
        cancelDouyin?(id)
    }
    func isTransientInfo(_ path: String) -> Bool {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        return file.deletingLastPathComponent() == support.standardizedFileURL &&
            (file.lastPathComponent.hasPrefix("web-info-") || file.lastPathComponent.hasPrefix("extractor-info-"))
    }
    func formatSelector(_ quality: String) -> String {
        let cap = Int(quality).map { "[height<=\($0)]" } ?? ""
        return "bv*\(cap)+ba/b\(cap)"
    }
    func download(_ job: VideoJob, allowCachedRetry: Bool = true, allowMirrorRetry: Bool = true) {
        let temporary = support.appendingPathComponent("download-temp/\(job.id)")
        do {
            try fm.createDirectory(atPath: job.destination, withIntermediateDirectories: true)
            try fm.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        catch { mutate(job.id) { $0.state = "failed"; $0.error = "无法写入保存目录，请更换目录后重新添加任务。" }; pump(); return }
        activeID = job.id
        mutate(job.id) { $0.state = "downloading"; $0.detail = job.platform == "抖音" && !allowMirrorRetry ? "正在连接备用视频源…" : "正在连接视频源…"; $0.error = "" }
        // Distinct audio basename prevents yt-dlp reusing/deleting a completed video as its extraction input.
        let template = job.mode == "audio" ? "%(title).120B [%(id)s].audio.%(ext)s" : "%(title).120B [%(id)s].%(ext)s"
        var args = baseArgs(job) + ["--newline", "--progress", "--no-simulate", "--no-overwrites", "--windows-filenames", "--trim-filenames", "180", "-P", job.destination, "-P", "temp:" + temporary.path, "-o", template, "--progress-template", "download:__PROGRESS__%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes,progress.total_bytes_estimate)s", "--print", "before_dl:__MEDIA__%(width)s|%(height)s|%(ext)s", "--print", "after_move:__FILE__%(filepath)s"]
        if job.mode == "audio" { args += ["-f", "ba/b", "-x", "--audio-format", "m4a"] }
        else { args += ["-f", formatSelector(job.quality), "--format-sort", "lang,quality,res,fps,hdr:12,vcodec:h264,channels,acodec:aac", "--merge-output-format", "mp4/mkv"] }
        args += ["--print", "before_dl:__FORMAT__%(format_id)s"]
        var usingExtractorCache = false
        if let path = job.infoFile, fm.fileExists(atPath: path) {
            let extractorCache = URL(fileURLWithPath: path).lastPathComponent.hasPrefix("extractor-info-")
            let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
            if !extractorCache || Date().timeIntervalSince(modified) < 600 {
                args += ["--load-info-json", path]; usingExtractorCache = extractorCache
            } else {
                if isTransientInfo(path) { try? fm.removeItem(atPath: path) }
                mutate(job.id) { $0.infoFile = nil }; args += ["--", job.url]
            }
        } else { args += ["--", job.url] }
        let cmd = ToolCommand(); command = cmd
        var firstBytes = false, selectedFormat = ""
        // A stalled first connection should not spend 20 seconds retrying the
        // same CDN. Switch once to an equivalent mirror, never after bytes flow.
        let startup = DispatchWorkItem { [weak self, weak cmd] in
            guard let self = self, let cmd = cmd, self.command === cmd, !firstBytes,
                  self.state.jobs.first(where: { $0.id == job.id })?.state == "downloading",
                  self.douyinMirrorInfo(job, excluding: selectedFormat, write: false) else { return }
            cmd.stop()
        }
        if job.platform == "抖音" && allowMirrorRetry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: startup)
        }
        cmd.run(executable: executable, arguments: args, environment: environment, timeout: 21600, onLine: { [weak self, weak cmd] line in
            guard let self = self, let cmd = cmd, self.command === cmd, self.state.jobs.first(where: { $0.id == job.id })?.state == "downloading" else { return }
            if line.hasPrefix("__PROGRESS__") {
                let fields = String(line.dropFirst(12)).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                let p = Double((fields.first ?? "0").replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
                if fields.count >= 4, (Int64(fields[3]) ?? 0) > 0 { firstBytes = true; startup.cancel() }
                self.mutate(job.id) {
                    $0.progress = max(0, min(100, p))
                    let bytes = fields.count >= 5 ? [Int64(fields[3]), Int64(fields[4])] : []
                    let size = bytes.count == 2 && bytes[0] != nil && bytes[1] != nil ? "\(Self.byteLabel(bytes[0]!)) / \(Self.byteLabel(bytes[1]!)) · " : ""
                    $0.detail = fields.count >= 3 ? "\(size)\(fields[1].trimmingCharacters(in: .whitespaces)) · 剩余 \(fields[2].trimmingCharacters(in: .whitespaces))" : "正在下载…"
                }
            } else if line.hasPrefix("__FORMAT__") {
                selectedFormat = String(line.dropFirst(10)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("__MEDIA__") {
                let fields = String(line.dropFirst(9)).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if fields.count == 3, job.mode == "audio" || (Int(fields[1]) ?? 0) > 0 { self.mutate(job.id) { $0.mediaWidth = Int(fields[0]); $0.mediaHeight = Int(fields[1]); $0.mediaExt = job.mode == "audio" ? "m4a" : fields[2] } }
            } else if line.hasPrefix("__FILE__") {
                self.mutate(job.id) { $0.file = String(line.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines) }
            } else if line.contains("[Merger]") || line.contains("[ExtractAudio]") || line.contains("[Fixup") {
                self.mutate(job.id) { $0.detail = "正在合并与处理媒体…" }
            }
        }) { [weak self, weak cmd] code, _, error in
            startup.cancel()
            guard let self = self, let cmd = cmd, self.command === cmd else { return }
            self.activeID = nil; self.command = nil
            guard let current = self.state.jobs.first(where: { $0.id == job.id }), current.state == "downloading" else { self.pump(); return }
            let canonicalFile = URL(fileURLWithPath: current.file).standardizedFileURL.resolvingSymlinksInPath()
            let canonicalDir = URL(fileURLWithPath: job.destination).standardizedFileURL.resolvingSymlinksInPath()
            let size = (try? self.fm.attributesOfItem(atPath: current.file)[.size] as? NSNumber)?.intValue ?? 0
            if code == 0 && !current.file.isEmpty && size > 0 && canonicalFile.path.hasPrefix(canonicalDir.path + "/") {
                self.mutate(job.id) { $0.state = "done"; $0.progress = 100; $0.detail = "已保存到本机"; $0.fileSize = Int64(size); $0.mediaExt = canonicalFile.pathExtension; $0.infoFile = nil }
                self.toast?("下载完成：" + current.title)
                if let p = job.infoFile { try? self.fm.removeItem(atPath: p) }
                try? self.fm.removeItem(at: temporary)
            } else if job.platform == "抖音", allowMirrorRetry, !firstBytes,
                      self.douyinMirrorInfo(job, excluding: selectedFormat, write: true) {
                self.download(current, allowCachedRetry: allowCachedRetry, allowMirrorRetry: false)
                return
            } else if usingExtractorCache && allowCachedRetry {
                // Signed URLs can expire or be rejected. Refresh once from the original page.
                if let path = job.infoFile, self.isTransientInfo(path) { try? self.fm.removeItem(atPath: path) }
                self.mutate(job.id) { $0.infoFile = nil; $0.file = ""; $0.progress = 0 }
                if let retry = self.state.jobs.first(where: { $0.id == job.id }) { self.download(retry, allowCachedRetry: false) }
                return
            } else { self.mutate(job.id) { $0.state = "failed"; $0.error = self.friendlyError(error.isEmpty ? "未获得完整媒体文件，请重新解析。" : error); $0.detail = "下载未完成" } }
            self.pump()
        }
    }
    // Restrict a retry to mirrors of the *same* encoded stream. Resolution,
    // bitrate, codec and size must agree; no lower-quality fallback is introduced.
    @discardableResult func douyinMirrorInfo(_ job: VideoJob, excluding selected: String, write: Bool) -> Bool {
        guard job.platform == "抖音", !selected.isEmpty, let path = job.infoFile,
              URL(fileURLWithPath: path).lastPathComponent.hasPrefix("web-info-"), isTransientInfo(path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let formats = object["formats"] as? [[String: Any]],
              let chosen = formats.first(where: { $0["format_id"] as? String == selected }),
              let group = chosen["vidtuck_mirror_group"] as? String, !group.isEmpty else { return false }
        let keys = ["height", "width", "tbr", "vcodec", "filesize"]
        let mirrors = formats.filter { f in
            f["vidtuck_mirror_group"] as? String == group &&
            f["format_id"] as? String != selected && f["url"] as? String != chosen["url"] as? String &&
            keys.allSatisfy { String(describing: f[$0] ?? "") == String(describing: chosen[$0] ?? "") }
        }
        guard !mirrors.isEmpty else { return false }
        if !write { return true }
        object["formats"] = mirrors
        do {
            try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: path), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch { return false }
    }
    static func byteLabel(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        if value >= 1_000_000_000 { return String(format: "%.1f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB", value / 1_000_000) }
        return String(format: "%.0f KB", value / 1_000)
    }
    func friendlyError(_ raw: String) -> String {
        let lower = raw.lowercased()
        let hint: String
        if lower.contains("cookies") || lower.contains("login") || lower.contains("sign in") || lower.contains("403") || lower.contains("412") || lower.contains("verify") || lower.contains("captcha") {
            hint = "网站要求登录或验证。可打开网页辅助，在你自己的账号完成登录后读取此页。"
        } else if lower.contains("unsupported url") { hint = "当前解析器未识别此链接。请使用单条视频分享链接，或打开网页辅助。" }
        else if lower.contains("requested format") { hint = "没有符合所选清晰度的媒体。请改为最高可用后重试。" }
        else if lower.contains("timed out") || lower.contains("network") || lower.contains("connection") || lower.contains("超时") { hint = "连接失败或超时，请检查网络后重试。" }
        else { hint = "网站未返回可用视频，可重试、更新解析器或使用网页辅助。" }
        let lines = raw.components(separatedBy: .newlines).filter { !$0.isEmpty }.suffix(3).joined(separator: "\n")
        return hint + "\n" + InputParser.safeLog(lines)
    }
    func checkVersion() {
        let cmd = ToolCommand()
        cmd.run(executable: executable, arguments: ["--version"], environment: environment, timeout: 30) { [weak self, cmd] code, data, _ in
            _ = cmd; self?.engineVersion = code == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : "不可用"; self?.changed?()
        }
    }
    func updateEngine() {
        guard activeID == nil, !updating else { toast?("请先等待当前任务完成，或暂停任务后再更新。"); return }
        updating = true; changed?(); toast?("正在从 yt-dlp 官方更新解析器…")
        let dir = support.appendingPathComponent("tools"), target = support.appendingPathComponent("tools/yt-dlp")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: tools.appendingPathComponent("yt-dlp"), to: target) }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        } catch { updating = false; toast?("无法准备更新：" + error.localizedDescription); changed?(); return }
        let cmd = ToolCommand(); command = cmd
        cmd.run(executable: target, arguments: ["--ignore-config", "--update-to", "nightly"], environment: environment, timeout: 240) { [weak self] code, _, error in
            guard let self = self else { return }; self.updating = false; self.command = nil
            self.toast?(code == 0 ? "解析器更新完成" : "更新失败：" + InputParser.safeLog(error)); self.checkVersion(); self.pump()
        }
    }
}
