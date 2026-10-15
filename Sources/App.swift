import Cocoa
import WebKit

final class AppController: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var library: DownloadLibrary!
    var browsers: [BrowserController] = []
    var quitting = false
    var uiTestMode = false
    var supportOverride: URL?
    var covers: CoverStore!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let resources = Bundle.main.resourceURL!
        if let icon = NSImage(contentsOf: resources.appendingPathComponent("AppIcon.icns")) {
            NSApp.applicationIconImage = icon
        }
        library = DownloadLibrary(tools: resources.appendingPathComponent("tools"), support: supportOverride)
        covers = CoverStore(directory: library.support.appendingPathComponent("covers"))
        covers.changed = { [weak self] in self?.render() }
        library.changed = { [weak self] in self?.render() }
        library.toast = { [weak self] in self?.send("toast", $0) }
        library.resolveDouyin = { [weak self] job, completion in
            guard let self = self, let url = URL(string: job.url) else { completion(false); return }
            let browser = BrowserController(url: url, jobID: job.id, owner: self)
            browser.automatic = true; browser.autoCompletion = completion
            self.browsers.append(browser); browser.show()
        }
        library.cancelDouyin = { [weak self] id in
            self?.browsers.filter { $0.automatic && $0.jobID == id }.forEach { $0.finishAutomatic(false) }
        }
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "native")
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 379), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 300)
        window.title = "VidTuck"
        window.isReleasedWhenClosed = false
        window.titleVisibility = .visible; window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.165, alpha: 1)
        window.contentView = web; window.delegate = self; window.center()
        let html = resources.appendingPathComponent("index.html")
        web.loadFileURL(html, allowingReadAccessTo: resources)
        makeMenu()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        library.checkVersion()
    }
    func makeMenu() {
        let menu = NSMenu(), app = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 VidTuck", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 VidTuck", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 VidTuck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu; menu.addItem(app)
        let edit = NSMenuItem(), editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(pasteLink), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu; menu.addItem(edit)
        let w = NSMenuItem(), wm = NSMenu(title: "窗口")
        wm.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        w.submenu = wm; menu.addItem(w); NSApp.windowsMenu = wm; NSApp.mainMenu = menu
    }
    @objc func pasteLink() { send("paste", NSPasteboard.general.string(forType: .string) ?? "") }
    @objc func showSettings() { send("settings", "") }
    @objc func about() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "VidTuck", .applicationVersion: version, .credits: NSAttributedString(string: "为喜欢的视频，留一个位置。\n独立实现的本地下载工具 · yt-dlp + FFmpeg\n支持情况以实际解析与下载结果为准。")])
    }
    func send(_ type: String, _ payload: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": type, "payload": payload]), let value = String(data: data, encoding: .utf8) else { return }
        web?.evaluateJavaScript("window.receive(\(value))", completionHandler: nil)
    }
    func render() {
        guard let data = try? JSONEncoder().encode(library.state), var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        obj["engineVersion"] = library.engineVersion; obj["updating"] = library.updating
        obj["loggedIn"] = ["YouTube", "B站", "抖音", "小红书"].filter { FileManager.default.fileExists(atPath: library.cookieURL($0).path) }
        if var jobs = obj["jobs"] as? [[String: Any]] {
            for i in jobs.indices {
                if let job = library.state.jobs.first(where: { $0.id == jobs[i]["id"] as? String }) {
                    jobs[i]["cover"] = covers.image(for: job)
                }
            }
            obj["jobs"] = jobs
        }
        send("state", obj)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.isFileURL && url.standardizedFileURL.path.hasPrefix(Bundle.main.resourceURL!.standardizedFileURL.path + "/") { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === web, message.frameInfo.request.url?.isFileURL == true,
              let d = message.body as? [String: Any], let action = d["action"] as? String else { return }
        let id = d["id"] as? String ?? ""
        switch action {
        case "ready": render()
        case "add": library.add(d["text"] as? String ?? "")
        case "paste": send("paste", NSPasteboard.general.string(forType: .string) ?? "")
        case "start": library.start(id)
        case "startAll": library.startAll()
        case "pause": library.pause(id)
        case "remove": library.remove(id)
        case "clearDone": library.state.jobs.removeAll { $0.state == "done" }; library.emit()
        case "autoDownload": library.state.autoDownload = d["value"] as? Bool ?? true; library.emit()
        case "options":
            let q = d["quality"] as? String ?? library.state.quality, m = d["mode"] as? String ?? library.state.mode
            guard ["best", "2160", "1080", "720", "480"].contains(q), ["video", "audio"].contains(m) else { return }
            if !id.isEmpty {
                library.mutate(id) { if !["downloading", "analyzing", "done"].contains($0.state) { $0.quality = q; $0.mode = m } }
            } else { library.state.quality = q; library.state.mode = m; library.emit() }
        case "folder": chooseFolder()
        case "openFolder":
            let u = URL(fileURLWithPath: library.state.destination)
            if FileManager.default.fileExists(atPath: u.path) { NSWorkspace.shared.open(u) }
            else { library.toast?("首次下载后会自动创建保存文件夹。") }
        case "reveal":
            if let j = library.state.jobs.first(where: { $0.id == id }), !j.file.isEmpty, FileManager.default.fileExists(atPath: j.file) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: j.file)]) }
            else { library.toast?("文件已被移动或删除。") }
        case "play":
            if let j = library.state.jobs.first(where: { $0.id == id }), !j.file.isEmpty, FileManager.default.fileExists(atPath: j.file) {
                if !NSWorkspace.shared.open(URL(fileURLWithPath: j.file)) { library.toast?("系统没有可打开此格式的播放器，可点击“显示文件”后选择兼容播放器。") }
            } else { library.toast?("文件已被移动或删除。") }
        case "browse":
            if let job = library.state.jobs.first(where: { $0.id == id }) { openBrowser(job.url, jobID: id) }
            else { openBrowser(d["url"] as? String ?? "https://www.douyin.com/", jobID: nil) }
        case "update": library.updateEngine()
        case "importCookies": importCookies(platform: d["platform"] as? String ?? "")
        case "clearLogin": clearLogin()
        case "testSnapshot": if uiTestMode { snapshot(d["path"] as? String ?? "") }
        default: break
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.title = "选择视频保存位置"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: library.state.destination)
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url, let self = self else { return }
            self.library.state.destination = url.path; self.library.emit(); self.library.toast?("新任务将保存到所选文件夹。")
        }
    }
    func openBrowser(_ value: String, jobID: String?) {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme ?? ""), InputParser.platform(value) != "其他" else { library.toast?("网页辅助暂限 YouTube、B站、抖音和小红书链接。"); return }
        let b = BrowserController(url: url, jobID: jobID, owner: self); browsers.append(b); b.show()
    }
    func importCookies(platform: String) {
        guard ["YouTube", "B站", "抖音", "小红书"].contains(platform) else { return }
        let p = NSOpenPanel(); p.title = "导入 \(platform) 的 Netscape 格式 cookies.txt"; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        p.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let u = p.url, let self = self else { return }
            do {
                let data = try Data(contentsOf: u)
                guard data.count < 5242880, let text = String(data: data, encoding: .utf8), text.contains("Netscape HTTP Cookie File") || text.contains("HTTP Cookie File") else { self.library.toast?("请选择 Netscape 格式的 cookies.txt。"); return }
                // Keep only cookies for the platform selected in this dialog.
                let lines = text.components(separatedBy: .newlines).filter { line in
                    let f = line.replacingOccurrences(of: "#HttpOnly_", with: "").split(separator: "\t", omittingEmptySubsequences: false)
                    return f.count == 7 && BrowserController.cookieDomain(String(f[0]), matches: platform)
                }
                guard !lines.isEmpty else { self.library.toast?("文件中没有这个平台的 Cookie。"); return }
                let target = self.library.cookieURL(platform)
                try ("# Netscape HTTP Cookie File\n" + lines.joined(separator: "\n") + "\n").write(to: target, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                self.library.emit(); self.library.toast?("已导入 \(platform) 的本地登录信息。")
            } catch { self.library.toast?("导入失败：" + error.localizedDescription) }
        }
    }
    func clearLogin() {
        let alert = NSAlert(); alert.messageText = "清除 VidTuck 保存的登录状态？"; alert.informativeText = "只清除本应用的网页数据与 Cookie，不影响其他浏览器。"; alert.addButton(withTitle: "清除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn, let self = self else { return }
            for p in ["YouTube", "B站", "抖音", "小红书"] { try? FileManager.default.removeItem(at: self.library.cookieURL(p)) }
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { self.library.emit(); self.library.toast?("本应用的登录状态已清除。") }
        }
    }
    func snapshot(_ path: String) {
        guard !path.isEmpty else { return }
        web.takeSnapshot(with: nil) { img, _ in
            guard let img = img, let tiff = img.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if library?.activeID != nil || library?.updating == true {
            let a = NSAlert(); a.messageText = "暂停当前任务并退出？"; a.informativeText = "已下载的分片会保留，下次打开可以继续。"; a.addButton(withTitle: "暂停并退出"); a.addButton(withTitle: "继续运行")
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        if let id = library?.activeID { library.pause(id) }; library?.command?.stop(); library?.save()
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
}

final class BrowserController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate, WKScriptMessageHandler {
    weak var owner: AppController?
    let jobID: String?
    var web: WKWebView!
    var window: NSWindow!
    var address: NSTextField!
    var status: NSTextField!
    var readButton: NSButton!
    var initialURL: URL
    var lastPageTitle = "网页视频"
    var automatic = false
    var autoCompletion: ((Bool) -> Void)?
    var autoPoll: DispatchWorkItem?
    var autoDeadline: DispatchWorkItem?
    var enrichingCover = false
    var autoClosed = false
    var directRequest: DouyinDirectRequest?
    init(url: URL, jobID: String?, owner: AppController) {
        self.initialURL = url; self.jobID = jobID; self.owner = owner; super.init()
    }
    func show() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "VidTuck · 网页辅助"; window.delegate = self; window.isReleasedWhenClosed = false
        let root = NSView(); window.contentView = root
        let top = NSView(); top.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(top)
        let back = NSButton(title: "←", target: self, action: #selector(goBack)); back.bezelStyle = .rounded
        address = NSTextField(string: initialURL.absoluteString); address.placeholderString = "视频页面网址"; address.target = self; address.action = #selector(navigate)
        let go = NSButton(title: "前往", target: self, action: #selector(navigate)); go.bezelStyle = .rounded
        readButton = NSButton(title: "读取此页", target: self, action: #selector(readPage)); readButton.bezelStyle = .rounded; readButton.keyEquivalent = "\r"
        let stack = NSStackView(views: [back, address, go, readButton]); stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false; top.addSubview(stack)
        status = NSTextField(labelWithString: "可在此登录自己的账号，播放目标视频后点“读取此页”。登录信息仅保存在本机。"); status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; status.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(status)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .default()
        if automatic {
            config.mediaTypesRequiringUserActionForPlayback = .all
            config.userContentController.add(self, name: "douyinData")
            if let scriptURL = Bundle.main.url(forResource: "douyin-early", withExtension: "js"), let source = try? String(contentsOf: scriptURL, encoding: .utf8) {
                config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
        }
        web = WKWebView(frame: .zero, configuration: config); web.navigationDelegate = self; web.uiDelegate = self
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
        web.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(web)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor), top.leadingAnchor.constraint(equalTo: root.leadingAnchor), top.trailingAnchor.constraint(equalTo: root.trailingAnchor), top.heightAnchor.constraint(equalToConstant: 54),
            stack.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -14), stack.centerYAnchor.constraint(equalTo: top.centerYAnchor), address.widthAnchor.constraint(greaterThanOrEqualToConstant: 450),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            web.topAnchor.constraint(equalTo: top.bottomAnchor), web.leadingAnchor.constraint(equalTo: root.leadingAnchor), web.trailingAnchor.constraint(equalTo: root.trailingAnchor), web.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10)
        ])
        window.center()
        if automatic {
            window.isExcludedFromWindowsMenu = true
            root.layoutSubtreeIfNeeded()
            let deadline = DispatchWorkItem { [weak self] in self?.finishAutomatic(false) }
            autoDeadline = deadline; DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: deadline)
            scheduleAutomatic()
        } else { window.makeKeyAndOrderFront(nil) }
        if automatic {
            web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.autoClosed, self.autoCompletion != nil else { return }
                self.directRequest = DouyinDirectRequest(url: self.initialURL, cookies: cookies, resolved: { [weak self] id in self?.followResolvedID(id) }) { [weak self] object in
                    self?.useAutomaticMetadata(object)
                }
            }
        }
        web.load(URLRequest(url: initialURL))
    }
    func followResolvedID(_ id: String) {
        guard automatic, !autoClosed, autoCompletion != nil, DouyinMetadata.videoID(initialURL) == nil,
              let owner = owner, let jobID = jobID,
              owner.library.state.jobs.first(where: { $0.id == jobID })?.state == "analyzing" else { return }
        if web.url?.host == "www.douyin.com", web.url.flatMap({ DouyinMetadata.videoID($0) }) == id { return }
        // Skip the mobile share page once its redirect has identified the video.
        web.load(URLRequest(url: DouyinMetadata.canonical(id)))
    }
    func scheduleAutomatic() {
        guard automatic, !autoClosed, autoCompletion != nil || enrichingCover else { return }
        autoPoll?.cancel()
        let poll = DispatchWorkItem { [weak self] in
            guard let self = self, let owner = self.owner, let id = self.jobID,
                  let job = owner.library.state.jobs.first(where: { $0.id == id }),
                  self.enrichingCover ? !["paused", "failed"].contains(job.state) : job.state == "analyzing" else { self?.finishAutomatic(false); return }
            guard let page = self.web.url, InputParser.platform(page.absoluteString) == "抖音", InputParser.isVideoPage(page) else { self.scheduleAutomatic(); return }
            // Muting before requesting playback prevents hidden pages from playing sound.
            self.web.evaluateJavaScript("document.querySelectorAll('video').forEach(v=>{v.muted=true;v.play().catch(()=>{})}); true") { [weak self] _, _ in
                guard let self = self, !self.autoClosed else { return }
                self.extract(page: page, platform: "抖音", owner: owner)
            }
        }
        autoPoll = poll; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: poll)
    }
    func finishAutomatic(_ success: Bool, enrichCover: Bool = false) {
        guard automatic, !autoClosed else { return }
        let completion = autoCompletion; autoCompletion = nil
        directRequest?.cancel(); directRequest = nil
        autoPoll?.cancel(); autoDeadline?.cancel()
        if success && enrichCover {
            enrichingCover = true
            let deadline = DispatchWorkItem { [weak self] in self?.finishAutomatic(false) }
            autoDeadline = deadline; DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: deadline)
            completion?(true)
            scheduleAutomatic()
            return
        }
        autoClosed = true; enrichingCover = false
        web.configuration.userContentController.removeScriptMessageHandler(forName: "douyinData")
        web.stopLoading(); web.loadHTMLString("", baseURL: nil)
        window.close()
        completion?(success)
    }
    func useAutomaticMetadata(_ object: [String: Any]) {
        guard automatic, !autoClosed, let owner = owner, let id = jobID,
              let job = owner.library.state.jobs.first(where: { $0.id == id }),
              let pageText = object["webpage_url"] as? String, let page = URL(string: pageText),
              let videoID = DouyinMetadata.videoID(page),
              DouyinMetadata.videoID(initialURL).map({ $0 == videoID }) ?? true else { return }
        if enrichingCover {
            guard !["paused", "failed"].contains(job.state) else { finishAutomatic(false); return }
            enrichMetadata(object, jobID: id, owner: owner)
            return
        }
        guard autoCompletion != nil, job.state == "analyzing" else { return }
        let file = owner.library.support.appendingPathComponent("web-info-\(id).json")
        do {
            try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            owner.library.mutate(id) { $0.url = pageText; $0.platform = "抖音" }
            owner.library.setMetadata(id, object: object, infoFile: file.path)
            if owner.uiTestMode {
                let evidence: [String: Any] = ["id": id, "time": Date().timeIntervalSince1970, "source": object["extractor"] as? String ?? "unknown", "hasCover": !(object["thumbnail"] as? String ?? "").isEmpty]
                if let data = try? JSONSerialization.data(withJSONObject: evidence) { try? data.write(to: owner.library.support.appendingPathComponent("resolution-\(id).json")) }
            }
            finishAutomatic(true, enrichCover: (object["thumbnail"] as? String ?? "").isEmpty)
        } catch { finishAutomatic(false) }
    }
    func enrichMetadata(_ object: [String: Any], jobID: String, owner: AppController) {
        guard let thumbnail = object["thumbnail"] as? String, !thumbnail.isEmpty else { scheduleAutomatic(); return }
        owner.library.mutate(jobID) {
            if $0.thumbnail.isEmpty { $0.thumbnail = thumbnail }
            if let title = object["title"] as? String, !title.isEmpty { $0.title = title }
            if $0.duration == 0 { $0.duration = (object["duration"] as? NSNumber)?.doubleValue ?? 0 }
        }
        finishAutomatic(false)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard automatic, !autoClosed, message.name == "douyinData", message.frameInfo.isMainFrame,
              let page = web.url, let frame = message.frameInfo.request.url,
              DouyinMetadata.videoID(frame) == DouyinMetadata.videoID(page),
              let id = DouyinMetadata.videoID(page),
              let object = DouyinMetadata.object(message.body, id: id, page: DouyinMetadata.canonical(id)) else { return }
        var result = object; result["extractor"] = "douyin-interface"
        useAutomaticMetadata(result)
    }
    @objc func goBack() { web.goBack() }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let u = navigationAction.request.url, ["http", "https"].contains(u.scheme ?? "") { webView.load(navigationAction.request) }
        return nil
    }
    @objc func navigate() {
        guard let url = URL(string: address.stringValue), ["http", "https"].contains(url.scheme ?? "") else { status.stringValue = "请输入有效的网页地址。"; return }
        web.load(URLRequest(url: url))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { address.stringValue = web.url?.absoluteString ?? "" }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { status.stringValue = "页面加载失败：" + error.localizedDescription }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = navigationAction.request.url, ["http", "https", "about"].contains(u.scheme ?? "") else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    static func cookieDomain(_ raw: String, matches platform: String) -> Bool {
        let domain = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let allowed = ["YouTube": ["youtube.com", "google.com"], "B站": ["bilibili.com", "b23.tv"], "抖音": ["douyin.com", "iesdouyin.com"], "小红书": ["xiaohongshu.com", "xhslink.com"]][platform] ?? []
        return allowed.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }
    @objc func readPage() {
        guard let owner = owner, let page = web.url, InputParser.platform(page.absoluteString) != "其他" else { status.stringValue = "请打开四个目标平台中的一条视频页面。"; return }
        guard InputParser.isVideoPage(page) else { status.stringValue = "当前不是单条视频页面。请先登录并打开目标视频，再读取此页。"; return }
        let platform = InputParser.platform(page.absoluteString)
        if let id = jobID, owner.library.activeID == id { status.stringValue = "请先暂停该任务，再从网页读取。"; return }
        status.stringValue = "正在读取当前页面…"; readButton.isEnabled = false
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            let lines = cookies.filter { Self.cookieDomain($0.domain, matches: platform) }.map { c -> String in
                let fields = [c.domain, c.domain.hasPrefix(".") ? "TRUE" : "FALSE", c.path, c.isSecure ? "TRUE" : "FALSE", String(Int(c.expiresDate?.timeIntervalSince1970 ?? 0)), c.name, c.value]
                return fields.map { $0.replacingOccurrences(of: "\t", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "") }.joined(separator: "\t")
            }
            if !lines.isEmpty {
                let target = owner.library.cookieURL(platform)
                try? ("# Netscape HTTP Cookie File\n" + lines.joined(separator: "\n") + "\n").write(to: target, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
            self.extract(page: page, platform: platform, owner: owner)
        }
    }
    func extract(page: URL, platform: String, owner: AppController) {
        // Read only the visible document and known video state, never browser credentials.
        let js = #"""
        (() => {
          let found = [], seen = new Set(), targetTitle = "", targetDuration = 0, targetCover = "";
          const push = (url, height=0, width=0) => {
            if(typeof url !== 'string' || !/^https?:\/\//i.test(url) || seen.has(url)) return;
            if(!/\.mp4(?:[?/#]|$)|\.m3u8(?:[?/#]|$)|douyinvod|sns-video|xhscdn.*video|\/aweme\/v1\/play/i.test(url)) return;
            seen.add(url); found.push({url,height,width});
          };
          const walk = (v, depth=0) => {
            if(depth>14 || !v) return;
            if(typeof v==='string') { push(v); return; }
            if(Array.isArray(v)) { v.slice(0,100).forEach(x=>walk(x,depth+1)); return; }
            if(typeof v==='object') {
              const h=Number(v.height)||0, w=Number(v.width)||0;
              for(const k of ['masterUrl','url','src','playUrl','play_url']) push(v[k],h,w);
              for(const k of ['url_list','backupUrls']) if(Array.isArray(v[k])) v[k].forEach(u=>push(u,h,w));
              Object.keys(v).slice(0,160).forEach(k=>walk(v[k],depth+1));
            }
          };
          let state=window.__INITIAL_STATE__;
          const noteId=location.pathname.match(/(?:explore|item)\/([a-f\d]+)/)?.[1];
          if(noteId && state?.note?.noteDetailMap?.[noteId]?.note) { const note=state.note.noteDetailMap[noteId].note; walk(note.video); targetCover=note.video?.cover?.url_list?.[0]||note.imageList?.[0]?.urlDefault||''; }
          const videoId=location.pathname.match(/video\/(\d+)/)?.[1]||new URLSearchParams(location.search).get('modal_id');
          const targetSeen=new WeakSet();
          const imageURL=v=>typeof v==='string'?v:v?.url_list?.[0]||v?.urlList?.[0]||v?.url||'';
          const findTarget=(v,depth=0)=>{
            if(!v||typeof v!=='object'||v instanceof Node||depth>12||targetSeen.has(v))return;
            targetSeen.add(v);
            if(String(v.aweme_id||v.awemeId||v.id||'')===videoId&&v.video){
              targetTitle=v.desc||v.item_title||v.itemTitle||'';targetDuration=(Number(v.video.duration)||0)/1000;
              targetCover=imageURL(v.video.cover)||imageURL(v.video.origin_cover||v.video.originCover)||imageURL(v.video.dynamic_cover||v.video.dynamicCover);walk(v.video);return;
            }
            Object.values(v).slice(0,160).forEach(x=>findTarget(x,depth+1));
          };
          if(videoId){findTarget(window.__streamNestVideo);findTarget(window._ROUTER_DATA?.loaderData);findTarget(state);try{findTarget(JSON.parse(decodeURIComponent(document.querySelector('#RENDER_DATA')?.textContent||'')))}catch{}}
          // Bind fallback to the visible player, never a recommendation or unrelated resource request.
          const visible=Array.from(document.querySelectorAll('video')).filter(v=>{const r=v.getBoundingClientRect();return r.width>80&&r.height>80&&r.bottom>0&&r.top<innerHeight});
          const primary=visible.find(v=>!v.paused)||visible.sort((a,b)=>b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight)[0];
          if(primary){
            push(primary.currentSrc||primary.src,primary.videoHeight,primary.videoWidth);
            // Only inspect props attached to this player's ancestor chain. Every accepted
            // metadata object must match the detail page ID, including its poster.
            if(videoId){let e=primary;for(let i=0;e&&i<10;i++,e=e.parentElement){
              const key=Object.keys(e).find(k=>k.startsWith('__reactProps$'));
              if(key)findTarget(e[key]);
              if(targetCover)break;
            }}
          }
          if(!found.length) document.querySelectorAll('meta[property="og:video"],meta[property="og:video:url"]').forEach(v=>push(v.content));
          return {title:targetTitle||document.querySelector('h1')?.textContent||document.querySelector('meta[property="og:title"]')?.content||document.title||'抖音视频',thumbnail:targetCover||primary?.poster||document.querySelector('meta[property="og:image"]')?.content||'',media:found.slice(0,16),duration:targetDuration||(Number.isFinite(primary?.duration)?primary.duration:0)};
        })()
        """#
        web.evaluateJavaScript(js) { [weak self] result, error in
            guard let self = self else { return }; self.readButton.isEnabled = true
            if self.automatic {
                guard !self.autoClosed, let target = self.jobID,
                      let job = owner.library.state.jobs.first(where: { $0.id == target }),
                      self.enrichingCover ? !["paused", "failed"].contains(job.state) : self.autoCompletion != nil && job.state == "analyzing" else { self.finishAutomatic(false); return }
                guard self.web.url == page, let r = result as? [String: Any] else { self.scheduleAutomatic(); return }
                if self.enrichingCover { self.enrichMetadata(r, jobID: target, owner: owner); return }
                guard let media = r["media"] as? [[String: Any]], !media.isEmpty else { self.scheduleAutomatic(); return }
            }
            var id = self.jobID
            if id == nil || !owner.library.state.jobs.contains(where: { $0.id == id }) {
                let j = VideoJob(url: page.absoluteString, platform: platform, quality: owner.library.state.quality, mode: owner.library.state.mode, destination: owner.library.state.destination)
                id = j.id; owner.library.state.jobs.insert(j, at: 0)
            }
            guard let jobID = id else { return }
            // YouTube/Bilibili use separate streams. Always use their extractor to pair audio correctly.
            if ["抖音", "小红书"].contains(platform), let r = result as? [String: Any], let media = r["media"] as? [[String: Any]], !media.isEmpty {
                let rawTitle = (r["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let title = rawTitle.isEmpty ? "网页视频" : rawTitle
                var formats: [[String: Any]] = []
                for (i, m) in media.enumerated() {
                    guard let u = m["url"] as? String, let url = URL(string: u), ["http", "https"].contains(url.scheme ?? "") else { continue }
                    var f: [String: Any] = ["format_id": "web-\(i)", "url": u, "ext": "mp4", "http_headers": ["Referer": page.absoluteString, "User-Agent": self.web.customUserAgent ?? ""]]
                    if let h = m["height"] as? Int, h > 0 { f["height"] = h }
                    if let w = m["width"] as? Int, w > 0 { f["width"] = w }
                    if u.contains(".m3u8") { f["protocol"] = "m3u8_native" }
                    formats.append(f)
                }
                guard !formats.isEmpty else { if self.automatic { self.scheduleAutomatic() }; self.status.stringValue = "未读到可下载媒体，请先播放视频。"; return }
                let object: [String: Any] = ["id": String(jobID.prefix(8)), "title": title, "webpage_url": page.absoluteString, "extractor": "web-assist", "extractor_key": "Generic", "duration": r["duration"] as? Double ?? 0, "formats": formats, "thumbnail": r["thumbnail"] as? String ?? ""]
                if self.automatic { self.useAutomaticMetadata(object); return }
                let u = owner.library.support.appendingPathComponent("web-info-\(jobID).json")
                do {
                    try JSONSerialization.data(withJSONObject: object).write(to: u, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
                    owner.library.mutate(jobID) { $0.url = page.absoluteString; $0.platform = platform }
                    owner.library.setMetadata(jobID, object: object, infoFile: u.path)
                    owner.library.pump()
                    self.status.stringValue = "已读取 \(formats.count) 个媒体候选，请回主窗口下载。实际音画完整性以下载结果为准。"
                } catch { self.status.stringValue = "保存媒体信息失败：" + error.localizedDescription; if self.automatic { self.finishAutomatic(false); return } }
            } else {
                owner.library.mutate(jobID) { $0.url = page.absoluteString; $0.platform = platform; $0.infoFile = nil; $0.state = "pending"; $0.error = "" }
                owner.library.pump(); self.status.stringValue = "已保存此平台的本地登录状态，正在主窗口重新解析。"
            }
            owner.window.makeKeyAndOrderFront(nil)
        }
    }
    func windowWillClose(_ notification: Notification) { if automatic { finishAutomatic(false) }; owner?.browsers.removeAll { $0 === self } }
}
