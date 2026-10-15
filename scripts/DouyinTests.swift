import Cocoa
import WebKit

@main struct DouyinTests {
    static func expect(_ ok: @autoclosure () -> Bool, _ label: String) {
        guard ok() else { print("FAIL: \(label)"); exit(1) }; print("PASS: \(label)")
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let id = "7669433433201986868", page = DouyinMetadata.canonical(id)
        expect(DouyinMetadata.videoID(page) == id && DouyinMetadata.videoID(URL(string: "https://www.iesdouyin.com/share/video/\(id)/")!) == id, "detail and share pages retain the exact target ID")
        expect(DouyinMetadata.videoID(URL(string: "https://douyin.com.evil.test/video/\(id)")!) == nil, "unrelated hosts cannot supply a target ID")
        let video: [String: Any] = ["width": 1080, "height": 1920, "duration": 4000,
            "cover": ["url_list": ["https://images.example/target.jpg"]],
            "music": ["url_list": ["https://media.example/audio.mp4"]],
            "download_addr": ["url_list": ["https://media.example/watermarked.mp4"]],
            "bit_rate": [["bit_rate": 2000000, "is_h265": 0, "play_addr": ["height": 720, "width": 405, "url_list": ["https://media.example/720.mp4"]]]],
            "play_addr": ["url_list": ["https://media.example/1080.mp4", "file:///tmp/untrusted.mp4"]]]
        let item: [String: Any] = ["aweme_id": id, "desc": "目标视频", "video": video]
        let response: [String: Any] = ["recommendations": [["aweme_id": "123", "video": video]], "aweme_detail": item]
        let object = DouyinMetadata.object(response, id: id, page: page)!
        let formats = object["formats"] as! [[String: Any]]
        let redirectVideo: [String: Any] = ["height": 1080, "width": 1920, "play_addr": ["url_list": ["https://v26-web.douyinvod.com/target.mp4", "https://www.douyin.com/aweme/v1/play/?video_id=target"]]]
        let mirrorObject = DouyinMetadata.object(["aweme_id": id, "video": redirectVideo], id: id, page: page)!
        let mirrors = mirrorObject["formats"] as! [[String: Any]]
        expect(mirrors[0]["vidtuck_mirror_group"] as? String == mirrors[1]["vidtuck_mirror_group"] as? String, "mirrors retain their original encoded-stream address group")
        expect(mirrors.count == 2 && (mirrors[0]["source_preference"] as! Int) > (mirrors[1]["source_preference"] as! Int), "same-quality direct CDN address is preferred while redirect remains available")
        expect(formats.count == 2 && formats.allSatisfy { ($0["url"] as? String ?? "").contains("/720.mp4") || ($0["url"] as? String ?? "").contains("/1080.mp4") }, "only playback formats are selected; posters, music, downloads and local URLs are excluded")
        expect(object["title"] as? String == "目标视频" && object["duration"] as? Double == 4 && object["thumbnail"] as? String == "https://images.example/target.jpg", "metadata and poster belong to the target video")
        expect(formats[0]["height"] as? Int == 720 && formats[0]["vcodec"] as? String == "h264", "format resolution and codec survive parsing")
        expect(DouyinMetadata.object(response, id: "999", page: page) == nil, "recommendation data cannot resolve a different target")
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["loaderData": response]), as: UTF8.self)
        expect(DouyinMetadata.pageObject(Data("<script>window._ROUTER_DATA = \(raw);</script>".utf8), id: id, page: page) != nil, "share-page JSON is parsed without executing webpage code")
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        expect(DouyinMetadata.pageObject(Data("<script id='RENDER_DATA'>\(encoded)</script>".utf8), id: id, page: page) != nil, "percent-encoded rendering metadata is supported")
        expect(DouyinMetadata.pageObject(Data("<html>login or verification required</html>".utf8), id: id, page: page) == nil, "login pages produce no false media result")

        // Exercise the native handoff and late-cover lifecycle without accessing a site.
        _ = NSApplication.shared
        let owner = AppController()
        owner.library = DownloadLibrary(tools: root, support: root.appendingPathComponent("state"))
        owner.library.state.autoDownload = false
        var current: BrowserController!
        owner.library.resolveDouyin = { job, completion in
            let b = BrowserController(url: URL(string: job.url)!, jobID: job.id, owner: owner)
            b.automatic = true; b.autoCompletion = completion
            b.window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
            b.window.isReleasedWhenClosed = false
            b.web = WKWebView(frame: .zero)
            owner.browsers.append(b); current = b
        }
        owner.library.cancelDouyin = { _ in current.finishAutomatic(false) }
        var noCover = object; noCover["thumbnail"] = ""
        owner.library.add(page.absoluteString)
        let jobID = owner.library.state.jobs[0].id
        let before = Date()
        current.useAutomaticMetadata(noCover)
        expect(Date().timeIntervalSince(before) < 0.5 && owner.library.activeID == nil && owner.library.state.jobs[0].state == "ready", "missing poster never holds the queue or delays the media handoff")
        expect(current.enrichingCover && !current.autoClosed, "poster enrichment continues independently after handoff")
        owner.library.mutate(jobID) { $0.state = "downloading"; $0.progress = 42; $0.detail = "transfer in progress" }
        current.useAutomaticMetadata(object)
        expect(owner.library.state.jobs[0].state == "downloading" && owner.library.state.jobs[0].progress == 42 && owner.library.state.jobs[0].detail == "transfer in progress", "late poster updates never reset transfer state or progress")
        expect(!owner.library.state.jobs[0].thumbnail.isEmpty && current.autoClosed, "late poster is stored and the hidden browser closes")
        current.useAutomaticMetadata(noCover)
        expect(owner.library.state.jobs[0].progress == 42 && !owner.library.state.jobs[0].thumbnail.isEmpty, "duplicate or late callbacks cannot overwrite the accepted result")
        owner.library.mutate(jobID) { $0.state = "done" }
        owner.library.add(page.absoluteString)
        let pausedID = owner.library.state.jobs[0].id
        let pausedBrowser = current!
        owner.library.pause(pausedID)
        pausedBrowser.useAutomaticMetadata(object)
        expect(owner.library.activeID == nil && owner.library.state.jobs[0].state == "paused" && pausedBrowser.autoClosed, "pause cancels every resolver and ignores delayed media")
        owner.library.remove(pausedID)
        owner.library.add(page.absoluteString)
        let removedID = owner.library.state.jobs[0].id
        let removedBrowser = current!
        owner.library.remove(removedID)
        removedBrowser.useAutomaticMetadata(object)
        expect(owner.library.activeID == nil && !owner.library.state.jobs.contains(where: { $0.id == removedID }), "removing an analyzing job cannot resurrect it from a delayed callback")
        print("ALL DOUYIN TESTS PASSED")
    }
}
