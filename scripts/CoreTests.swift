import Foundation
import Darwin

@main struct CoreTests {
    static func expect(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { print("FAIL: \(label)"); exit(1) }; print("PASS: \(label)")
    }
    static func wait(_ timeout: Double, until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        expect(predicate(), "asynchronous task completes within \(Int(timeout))s")
    }
    static func main() throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[1]), tools = URL(fileURLWithPath: args[2])
        let urls = InputParser.urls("分享 https://www.xiaohongshu.com/explore/abc?xsec_token=a%2Bb%3D， https://youtu.be/xyz https://youtu.be/xyz file:///tmp/a javascript:alert(1)")
        expect(urls.count == 2 && urls[0].contains("xsec_token=a%2Bb%3D"), "share text preserves signed query and removes duplicates")
        expect(InputParser.platform("https://www.youtube.com.evil.test/x") == "其他", "platform matching respects host boundaries")
        expect(InputParser.platform("https://v.douyin.com/a/") == "抖音", "short link platform recognition")
        expect(!InputParser.isVideoPage(URL(string: "https://www.xiaohongshu.com/explore")!) && InputParser.isVideoPage(URL(string: "https://www.xiaohongshu.com/explore/6411cf99000000001300b6d9")!), "web assist rejects feed pages and binds to a video detail")
        expect(!InputParser.safeLog("ERROR https://x.test/?token=secret cookie=private").contains("secret"), "error log hides query credentials")
        // Exercise fallback completion and cancellation without depending on a live platform.
        let fallback = DownloadLibrary(tools: tools, support: root.appendingPathComponent("fallback-state"))
        let fixtureTools = fallback.support.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: fixtureTools, withIntermediateDirectories: true)
        let failingTool = fixtureTools.appendingPathComponent("yt-dlp")
        try "#!/bin/sh\ntouch \"\(fixtureTools.appendingPathComponent("extractor-called").path)\"\nexit 1\n".write(to: failingTool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failingTool.path)
        let synthetic = { VideoJob(url: "http://127.0.0.1:18764/not-found.mp4", platform: "抖音", quality: "best", mode: "video", destination: root.appendingPathComponent("downloads").path) }
        fallback.state.autoDownload = false
        fallback.resolveDouyin = { job, completion in
            fallback.setMetadata(job.id, object: ["title": "Background result", "url": "http://127.0.0.1:18764/sample.mp4"])
            completion(true)
        }
        var j = synthetic(); fallback.state.jobs.append(j); fallback.pump()
        wait(30) { fallback.activeID == nil }
        expect(fallback.state.jobs.last?.state == "ready", "background fallback resolves and releases queue")
        expect(!FileManager.default.fileExists(atPath: fixtureTools.appendingPathComponent("extractor-called").path), "Douyin starts browser resolution without waiting for the extractor")
        fallback.resolveDouyin = { _, completion in completion(false) }
        j = synthetic(); fallback.state.jobs.append(j); fallback.pump()
        wait(30) { fallback.activeID == nil }
        expect(fallback.state.jobs.last?.state == "failed", "background failure exposes a retryable error")
        expect(FileManager.default.fileExists(atPath: fixtureTools.appendingPathComponent("extractor-called").path), "browser failure still tries the alternate extractor")
        var pending: ((Bool) -> Void)?
        fallback.resolveDouyin = { _, completion in pending = completion }
        fallback.cancelDouyin = { _ in let completion = pending; pending = nil; completion?(false) }
        j = synthetic(); fallback.state.jobs.append(j); fallback.pump()
        wait(30) { pending != nil }
        fallback.pause(j.id)
        expect(fallback.activeID == nil && fallback.state.jobs.last?.state == "paused", "pausing background extraction releases queue and preserves pause")
        j = synthetic(); fallback.state.jobs.append(j); fallback.pump()
        wait(30) { pending != nil }
        fallback.remove(j.id)
        expect(fallback.activeID == nil && !fallback.state.jobs.contains { $0.id == j.id }, "removing background extraction releases queue")
        let lib = DownloadLibrary(tools: tools, support: root.appendingPathComponent("core-state"))
        lib.state.autoDownload = false
        lib.state.destination = root.appendingPathComponent("downloads").path
        lib.add("http://127.0.0.1:18764/sample.mp4")
        wait(90) { lib.activeID == nil && lib.state.jobs.first?.state != "pending" }
        expect(lib.state.jobs.first?.state == "ready", "real yt-dlp parses HTTP video")
        let id = lib.state.jobs[0].id
        var sawTransferSize = false
        lib.changed = { if lib.state.jobs.contains(where: { $0.state == "downloading" && $0.detail.contains(" / ") }) { sawTransferSize = true } }
        lib.start(id)
        wait(90) { lib.activeID == nil }
        expect(lib.state.jobs[0].state == "done" && FileManager.default.fileExists(atPath: lib.state.jobs[0].file), "video completion requires actual file")
        expect(sawTransferSize, "download progress includes actual transferred and total bytes")
        let file = lib.state.jobs[0].file
        let actualSize = (try FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.int64Value
        expect(lib.state.jobs[0].fileSize == actualSize && lib.state.jobs[0].mediaExt == "mp4", "completed media records actual size and extension")
        lib.remove(id)
        expect(FileManager.default.fileExists(atPath: file), "removing task preserves downloaded video")
        lib.state.mode = "audio"
        lib.add("http://127.0.0.1:18764/sample.mp4")
        wait(90) { lib.activeID == nil }
        expect(lib.state.jobs[0].state == "ready", "second task parses")
        lib.start(lib.state.jobs[0].id)
        wait(90) { lib.activeID == nil }
        expect(lib.state.jobs[0].state == "done" && lib.state.jobs[0].file.hasSuffix(".m4a"), "real FFmpeg extracts M4A audio")
        expect(FileManager.default.fileExists(atPath: file), "audio extraction does not delete a previously downloaded video")
        lib.add("http://127.0.0.1:18764/not-found.mp4")
        wait(90) { lib.activeID == nil }
        expect(lib.state.jobs[0].state == "failed" && !lib.state.jobs[0].error.isEmpty, "404 is an actionable failure, never success")
        let saved = lib.state.jobs.count
        lib.state.jobs.append(VideoJob(url: "https://youtu.be/unfinished", platform: "YouTube", quality: "best", mode: "video", destination: lib.state.destination))
        lib.save()
        let restored = DownloadLibrary(tools: tools, support: root.appendingPathComponent("core-state"))
        expect(restored.state.jobs.count == saved + 1 && restored.state.jobs.last?.state == "paused", "restart restores queue and pauses unfinished tasks")
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("core-state/library.json").path)[.posixPermissions] as? NSNumber
        expect(permissions?.intValue == 0o600, "saved task data is owner-readable only")
        let auto = DownloadLibrary(tools: tools, support: root.appendingPathComponent("auto-state"))
        auto.state.destination = root.appendingPathComponent("auto-downloads").path
        auto.add("http://127.0.0.1:18764/sample.mp4")
        wait(90) { auto.state.jobs.first?.state == "done" || auto.state.jobs.first?.state == "failed" }
        expect(auto.state.jobs.first?.state == "done", "paste-style add automatically analyzes and downloads")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(auto.state)) as! [String: Any]
        legacy.removeValue(forKey: "autoDownload")
        var legacyJobs = legacy["jobs"] as! [[String: Any]]
        for i in legacyJobs.indices { for key in ["mediaWidth", "mediaHeight", "mediaExt", "fileSize"] { legacyJobs[i].removeValue(forKey: key) } }
        legacy["jobs"] = legacyJobs
        let decoded = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: legacy))
        expect(decoded.jobs.count == auto.state.jobs.count && decoded.autoDownload != false, "legacy task data remains readable with new optional fields")
        print("ALL CORE TESTS PASSED")
    }
}
