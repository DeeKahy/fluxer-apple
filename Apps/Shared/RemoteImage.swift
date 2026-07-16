import SwiftUI

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

/// Image loader with an in-memory cache and a retry, because AsyncImage
/// permanently shows its placeholder when a load is cancelled mid-scroll,
/// which happens constantly in lazy message lists.
actor ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSURL, PlatformImage>()
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]

    init() {
        cache.countLimit = 500
    }

    func image(for url: URL) async -> PlatformImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        if let task = inFlight[url] {
            return await task.value
        }
        let task = Task<PlatformImage?, Never> {
            for attempt in 0..<2 {
                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(400))
                }
                if let image = await fetch(url) {
                    return image
                }
            }
            return nil
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL)
        }
        return image
    }

    private func fetch(_ url: URL) async -> PlatformImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return PlatformImage(data: data)
    }
}

/// Drop-in AsyncImage replacement backed by ImageLoader.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                #if os(macOS)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                #else
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                #endif
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { return }
            image = await ImageLoader.shared.image(for: url)
        }
    }
}
