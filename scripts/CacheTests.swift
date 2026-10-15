import Foundation
@main struct CacheTests {
    static func expect(_ ok: @autoclosure () -> Bool, _ label: String) { guard ok() else { print("FAIL:",label); exit(1) }; print("PASS:",label) }
    static func wait(_ library: DownloadLibrary) {
        let deadline = Date().addingTimeInterval(60)
        while library.activeID != nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
        expect(library.activeID == nil, "queue finishes within deadline")
    }
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), tools=URL(fileURLWithPath:CommandLine.arguments[2]), fm=FileManager.default
        let lib=DownloadLibrary(tools:tools,support:root.appendingPathComponent("state"));lib.state.autoDownload=false
        func prepare(_ destination:String, mode:String = "video", platform:String = "YouTube") -> String {
            let job=VideoJob(url:"http://127.0.0.1:18764/sample.mp4",platform:platform,quality:"best",mode:mode,destination:root.appendingPathComponent(destination).path)
            lib.state.jobs.insert(job,at:0);lib.pump();wait(lib);return job.id
        }
        let id=prepare("normal")
        expect(lib.state.jobs[0].state == "ready", "metadata is ready without starting a manual download")
        let info=lib.state.jobs[0].infoFile!
        expect(info.contains("/extractor-info-") && fm.fileExists(atPath:info), "first extraction is retained for immediate reuse")
        let permissions = try fm.attributesOfItem(atPath:info)[.posixPermissions] as? NSNumber
        expect(permissions?.intValue == 0o600,"transient signed metadata stays private")
        let restored=DownloadLibrary(tools:tools,support:root.appendingPathComponent("state"))
        expect(restored.state.jobs[0].state == "ready" && restored.state.jobs[0].infoFile == nil && !fm.fileExists(atPath:info), "restart clears signed cache and leaves original page usable")
        // Recreate cache; stale or invalid signed URLs must recover from the original page.
        lib.remove(id)
        let retryID=prepare("retry"), retryPath=lib.state.jobs[0].infoFile!
        var data=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:retryPath))) as! [String:Any]
        data["url"]="http://127.0.0.1:18764/expired.mp4"
        if var formats=data["formats"] as? [[String:Any]] { for i in formats.indices { formats[i]["url"]="http://127.0.0.1:18764/expired.mp4" };data["formats"]=formats }
        try JSONSerialization.data(withJSONObject:data).write(to:URL(fileURLWithPath:retryPath))
        lib.start(retryID);wait(lib)
        expect(lib.state.jobs[0].state == "done" && fm.fileExists(atPath:lib.state.jobs[0].file),"rejected cached URL falls back once to fresh extraction and real download")
        expect(!fm.fileExists(atPath:retryPath),"failed or completed cached metadata is removed")
        let staleID=prepare("stale"), stalePath=lib.state.jobs[0].infoFile!
        try fm.setAttributes([.modificationDate:Date().addingTimeInterval(-601)],ofItemAtPath:stalePath)
        lib.start(staleID);wait(lib)
        expect(lib.state.jobs[0].state == "done" && !fm.fileExists(atPath:stalePath),"a delayed download refreshes metadata instead of using expired cache")
        let removeID=prepare("remove"), removePath=lib.state.jobs[0].infoFile!
        lib.remove(removeID)
        expect(!fm.fileExists(atPath:removePath),"removing a task clears only its temporary metadata")
        let audioID=prepare("audio", mode:"audio")
        lib.start(audioID);wait(lib)
        expect(lib.state.jobs[0].state == "done" && lib.state.jobs[0].file.hasSuffix(".m4a"),"cached format data still supports extracting real M4A audio")
        let xhsID=prepare("xhs", platform:"小红书"), xhsPath=lib.state.jobs[0].infoFile!
        // A second page extraction must not be required after successful metadata extraction.
        var xhsData=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:xhsPath))) as! [String:Any]
        xhsData["webpage_url"]="http://127.0.0.1:18764/not-found-page"
        try JSONSerialization.data(withJSONObject:xhsData).write(to:URL(fileURLWithPath:xhsPath))
        lib.mutate(xhsID) { $0.url="http://127.0.0.1:18764/not-found-page" }
        lib.start(xhsID);wait(lib)
        expect(lib.state.jobs[0].state == "done" && fm.fileExists(atPath:lib.state.jobs[0].file) && !fm.fileExists(atPath:xhsPath),"Xiaohongshu downloads from retained media without reading the page again and clears its cache")
        let qualityFile=root.appendingPathComponent("quality.json")
        let fixture:[String:Any] = ["id":"quality-fixture","title":"Quality fixture","extractor":"generic","extractor_key":"Generic","webpage_url":"http://127.0.0.1:18764/sample.mp4","height":1080,"width":1920,"format_id":"high","requested_formats":[["url":"http://127.0.0.1:18764/sample.mp4","height":1080,"width":1920,"format_id":"high","ext":"mp4"]],"formats":[["url":"http://127.0.0.1:18764/sample.mp4","height":480,"width":852,"format_id":"low","ext":"mp4"],["url":"http://127.0.0.1:18764/sample.mp4","height":1080,"width":1920,"format_id":"high","ext":"mp4"]]]
        try JSONSerialization.data(withJSONObject:fixture).write(to:qualityFile)
        let command=ToolCommand();var finished=false;var selected=""
        command.run(executable:lib.executable,arguments:["--ignore-config","--load-info-json",qualityFile.path,"--simulate","-f",lib.formatSelector("480"),"--print","%(height)s"],environment:lib.environment) {code,data,_ in selected=code == 0 ? String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines):"failed";finished=true}
        let deadline=Date().addingTimeInterval(30)
        while !finished && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.03))}
        expect(finished && selected == "480","changing quality reselects formats instead of retaining the previously selected highest format")
        print("ALL CACHE TESTS PASSED")
    }
}
