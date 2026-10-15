import Foundation
import Darwin

// Requires DelayFixture.py on 127.0.0.1:18766 and real bundled yt-dlp/FFmpeg.
@main struct DouyinTransferTests {
    static func expect(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { print("FAIL: \(label)"); exit(1) }; print("PASS: \(label)")
    }
    static func wait(_ seconds: Double, _ condition: () -> Bool) {
        let until = Date().addingTimeInterval(seconds)
        while !condition() && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        expect(condition(), "operation finishes within \(seconds)s")
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), tools = URL(fileURLWithPath: CommandLine.arguments[2])
        func make(_ name: String, primary: String) throws -> (DownloadLibrary, VideoJob) {
            let lib = DownloadLibrary(tools: tools, support: root.appendingPathComponent(name))
            let job = VideoJob(url: "https://www.douyin.com/video/123456789", platform: "抖音", quality: "best", mode: "video", destination: root.appendingPathComponent(name + "-downloads").path)
            func f(_ id: String, _ path: String, _ source: Int, height: Int = 1080) -> [String: Any] {
                ["format_id": id, "url": "http://127.0.0.1:18766/" + path, "ext": "mp4", "height": height, "width": 1920, "tbr": 800, "vcodec": "h264", "acodec": "aac", "source_preference": source, "vidtuck_mirror_group": height == 1080 ? "same-stream" : "lower-stream"]
            }
            let object: [String: Any] = ["id": name, "title": "Mirror fixture", "webpage_url": job.url,
                "formats": [f("primary", primary, 0), f("backup", "sample.mp4", -1), f("lower-quality", "wrong.mp4", 5, height: 720)]]
            let info = lib.support.appendingPathComponent("web-info-\(job.id).json")
            try JSONSerialization.data(withJSONObject: object).write(to: info)
            lib.state.jobs.append(job); lib.setMetadata(job.id, object: object, infoFile: info.path)
            return (lib, lib.state.jobs[0])
        }
        let (slow, _) = try make("slow-first-byte", primary: "delay.mp4")
        let started = Date(); slow.pump()
        wait(13) { slow.activeID == nil }
        expect(slow.state.jobs[0].state == "done" && Date().timeIntervalSince(started) < 12, "stalled initial connection switches once to an equivalent stream without waiting for socket retries")
        expect(slow.state.jobs[0].mediaHeight == 1080, "mirror retry preserves chosen resolution")
        let (failed, _) = try make("failed-primary", primary: "missing.mp4")
        failed.pump(); wait(10) { failed.activeID == nil }
        expect(failed.state.jobs[0].state == "done", "an early HTTP failure also tries its equivalent mirror")
        let (flowing, _) = try make("ongoing-transfer", primary: "stream.mp4")
        let flowingStart = Date(); flowing.pump(); wait(15) { flowing.activeID == nil }
        expect(flowing.state.jobs[0].state == "done" && Date().timeIntervalSince(flowingStart) > 6, "receiving bytes cancels the timer; a longer transfer is never restarted")
        let (paused, pauseJob) = try make("pause-during-connect", primary: "delay.mp4")
        paused.pump()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { paused.pause(pauseJob.id) }
        wait(9) { paused.activeID == nil }
        let until = Date().addingTimeInterval(5.5)
        while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        expect(paused.state.jobs[0].state == "paused" && paused.state.jobs[0].file.isEmpty, "pause cancels the connection timer and never starts a backup")
        let (removed, removeJob) = try make("remove-during-connect", primary: "delay.mp4")
        removed.pump(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { removed.remove(removeJob.id) }
        wait(9) { removed.activeID == nil }
        expect(removed.state.jobs.isEmpty, "removed jobs cannot be revived by a connection retry")
        let (restricted, restrictedJob) = try make("equivalent-only", primary: "delay.mp4")
        expect(restricted.douyinMirrorInfo(restrictedJob, excluding: "primary", write: true), "equivalent mirror can be selected")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: restrictedJob.infoFile!))) as! [String: Any]
        let formats = obj["formats"] as! [[String: Any]]
        expect(formats.count == 1 && formats[0]["format_id"] as? String == "backup", "failed source and lower-quality sources are excluded from retry")
        print("ALL DOUYIN TRANSFER TESTS PASSED")
    }
}
