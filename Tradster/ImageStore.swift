import SwiftUI
import UIKit

// ---- images, fetched once --------------------------------------------------------------
// AsyncImage keeps nothing between views: a coin logo that scrolled out of the lazy thread and
// back, or a card that re-rendered, started over from a grey circle and fetched again — the
// flicker in the tiles and the book map. Here a logo is fetched once (URLCache on disk), decoded
// and scaled once off the main thread, and kept in memory (NSCache), so a view that appears
// again draws it in its very first frame. A logo that 404s is remembered too, so the fallback
// goes first instead of waiting on the dead one each time.

final class ImageStore: @unchecked Sendable {
    static let shared = ImageStore()
    private let memory = NSCache<NSString, UIImage>()
    private let dead = NSCache<NSString, NSNumber>()
    private let session: URLSession
    private let lock = NSLock()
    private var inflight: [String: Task<(UIImage?, Bool), Never>] = [:]

    init() {
        memory.countLimit = 500
        memory.totalCostLimit = 64 << 20
        let c = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tradster-images", isDirectory: true)
        c.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 150 << 20, directory: dir)
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.timeoutIntervalForRequest = 20
        session = URLSession(configuration: c)
    }

    private static func key(_ url: URL, _ px: Int) -> NSString { "\(url.absoluteString)#\(px)" as NSString }

    /// Synchronous, from memory only: what a view can draw in its first frame.
    func cached(_ url: URL, px: Int) -> UIImage? { memory.object(forKey: Self.key(url, px)) }
    func isDead(_ url: URL) -> Bool { dead.object(forKey: url.absoluteString as NSString) != nil }

    func load(_ url: URL, px: Int) async -> UIImage? {
        let k = Self.key(url, px)
        if let i = memory.object(forKey: k) { return i }
        if isDead(url) { return nil }
        let session = self.session
        let task: Task<(UIImage?, Bool), Never> = lock.withLock {
            if let t = inflight[k as String] { return t }
            let t = Task.detached(priority: .utility) { () -> (UIImage?, Bool) in
                var data: Data? = nil
                if url.isFileURL {
                    data = try? Data(contentsOf: url)
                } else {
                    do {
                        let (d, r) = try await session.data(from: url)
                        if let h = r as? HTTPURLResponse, h.statusCode >= 400 { return (nil, true) }   // gone for good
                        data = d
                    } catch { return (nil, false) }                                                   // no signal: try again later
                }
                guard let data, let img = UIImage(data: data) else { return (nil, true) }
                let side = CGFloat(px)
                let longest = max(img.size.width * img.scale, img.size.height * img.scale)
                if longest > side {
                    let f = side / longest
                    let target = CGSize(width: max(1, img.size.width * img.scale * f), height: max(1, img.size.height * img.scale * f))
                    return ((await img.byPreparingThumbnail(ofSize: target)) ?? img, false)
                }
                return ((await img.byPreparingForDisplay()) ?? img, false)
            }
            inflight[k as String] = t
            return t
        }
        let (img, gone) = await task.value
        lock.withLock { inflight[k as String] = nil }
        if let img {
            let cost = Int(img.size.width * img.scale * img.size.height * img.scale * 4)
            memory.setObject(img, forKey: k, cost: cost)
        } else if gone {
            dead.setObject(1, forKey: url.absoluteString as NSString)
        }
        return img
    }
}

/// An image from the store: drawn at once when it is in memory, otherwise the placeholder until
/// it arrives. Several URLs are tried in order (a logo, then its fallback).
struct CachedImage<Placeholder: View>: View {
    let urls: [URL]
    let px: Int
    var fill = false
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage?
    @State private var shown: [URL] = []

    init(urls: [URL], px: Int, fill: Bool = false, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.urls = urls; self.px = px; self.fill = fill; self.placeholder = placeholder
        _image = State(initialValue: Self.fromMemory(urls, px))
        _shown = State(initialValue: urls)
    }
    init(url: String?, fallback: String? = nil, px: Int, fill: Bool = false, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        let us = [url, fallback].compactMap { $0 }.filter { !$0.isEmpty }.compactMap { URL(string: $0) }
        self.init(urls: us, px: px, fill: fill, placeholder: placeholder)
    }
    private static func fromMemory(_ urls: [URL], _ px: Int) -> UIImage? {
        for u in urls { if let i = ImageStore.shared.cached(u, px: px) { return i } }
        return nil
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                placeholder()
            }
        }
        .task(id: urls) {
            if shown != urls { shown = urls; image = Self.fromMemory(urls, px) }
            guard image == nil else { return }
            for u in urls where !ImageStore.shared.isDead(u) {
                if let i = await ImageStore.shared.load(u, px: px) {
                    if !Task.isCancelled { image = i }
                    return
                }
            }
        }
    }
}
