import Cocoa
import CryptoKit
import ImageIO

/// Downloads only the poster supplied by this task's extractor or visible video.
/// Local JPEG copies avoid expired CDN URLs and reloading images on progress ticks.
final class CoverStore {
    let directory: URL
    var changed: (() -> Void)?
    private var images: [String: String] = [:]
    private var pending = Set<String>()
    private var failed = Set<String>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: config)
    }()
    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func image(for job: VideoJob) -> String {
        guard let url = URL(string: job.thumbnail), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { return "" }
        let key = SHA256.hash(data: Data(job.thumbnail.utf8)).map { String(format: "%02x", $0) }.joined()
        if let image = images[key] { return image }
        let target = directory.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: target), !data.isEmpty {
            let value = "data:image/jpeg;base64," + data.base64EncodedString(); images[key] = value; return value
        }
        guard !pending.contains(key), !failed.contains(key) else { return "" }
        pending.insert(key)
        var request = URLRequest(url: url)
        request.setValue(job.url, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.5 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, _ in
            var jpeg: Data?
            if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), let data = data, data.count <= 12 * 1024 * 1024,
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.83])
            }
            if let jpeg = jpeg { try? jpeg.write(to: target, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pending.remove(key)
                if let jpeg = jpeg { self.images[key] = "data:image/jpeg;base64," + jpeg.base64EncodedString() }
                else { self.failed.insert(key) }
                self.changed?()
            }
        }.resume()
        return ""
    }
}
