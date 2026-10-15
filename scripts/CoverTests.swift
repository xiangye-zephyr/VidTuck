import Cocoa

@main struct CoverTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = CoverStore(directory: root)
        var job = VideoJob(url: "http://127.0.0.1:18764/sample.mp4", platform: "其他", quality: "best", mode: "video", destination: root.path)
        job.thumbnail = "http://127.0.0.1:18764/cover-fixture.png"
        var changed = false
        store.changed = { changed = true }
        precondition(store.image(for: job).isEmpty)
        let until = Date().addingTimeInterval(10)
        while !changed && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let image = store.image(for: job)
        precondition(image.hasPrefix("data:image/jpeg;base64,"), "poster is decoded and converted to JPEG")
        let data = Data(base64Encoded: String(image.dropFirst(23)))!
        precondition(NSImage(data: data) != nil)
        precondition(store.image(for: job) == image, "progress rerenders reuse same image")
        let reopened = CoverStore(directory: root)
        precondition(reopened.image(for: job) == image, "restart reads cached cover synchronously")
        job.thumbnail = "javascript:alert(1)"
        precondition(store.image(for: job).isEmpty, "unsupported scheme is ignored")
        job.thumbnail = "http://127.0.0.1:18764/sample.mp4"
        changed = false; precondition(store.image(for: job).isEmpty)
        let until2 = Date().addingTimeInterval(10)
        while !changed && Date() < until2 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(store.image(for: job).isEmpty, "non-image response uses default background")
        job.thumbnail = "http://127.0.0.1:18764/no-cover.jpg"
        changed = false; precondition(store.image(for: job).isEmpty)
        let until3 = Date().addingTimeInterval(10)
        while !changed && Date() < until3 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(store.image(for: job).isEmpty, "404 uses default background")
        print("PASS: cover conversion, reuse, restart cache, invalid scheme, invalid image and 404 fallback")
    }
}
