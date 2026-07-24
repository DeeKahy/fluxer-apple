import Foundation

/// One media rendition of a GIF (a given format like gif, webp, mp4).
/// Field names decode from snake_case (proxy_src) via the shared decoder.
public struct GifMediaFormat: Codable, Hashable, Sendable {
    public var src: String
    public var proxySrc: String?
    public var width: Int?
    public var height: Int?

    public init(src: String, proxySrc: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.src = src
        self.proxySrc = proxySrc
        self.width = width
        self.height = height
    }
}

/// A GIF search/trending result from the instance's GIF provider (KLIPY on
/// fluxer.app), shaped after packages/schema GifSchemas.GifResponse upstream.
public struct GifResult: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var slug: String?
    public var provider: String?
    public var title: String?
    /// Provider page URL, used as the share id source for register-share.
    public var url: String?
    /// Best-format direct and proxied media URLs the server picked.
    public var src: String?
    public var proxySrc: String?
    public var width: Int?
    public var height: Int?
    /// Format-name to media map, e.g. "gif", "tinygif", "webp", "mp4".
    public var media: [String: GifMediaFormat]?
    public var placeholder: String?

    public init(
        id: String,
        slug: String? = nil,
        provider: String? = nil,
        title: String? = nil,
        url: String? = nil,
        src: String? = nil,
        proxySrc: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        media: [String: GifMediaFormat]? = nil,
        placeholder: String? = nil
    ) {
        self.id = id
        self.slug = slug
        self.provider = provider
        self.title = title
        self.url = url
        self.src = src
        self.proxySrc = proxySrc
        self.width = width
        self.height = height
        self.media = media
        self.placeholder = placeholder
    }

    /// A small animated rendition for the picker grid, preferring the tiny
    /// formats to keep the grid light.
    public var previewURL: URL? {
        let candidates = [
            media?["tinygif"]?.proxySrc, media?["tinygif"]?.src,
            media?["nanogif"]?.proxySrc, media?["nanogif"]?.src,
            media?["gif"]?.proxySrc, proxySrc, src,
        ]
        return candidates.compactMap { $0 }.first.flatMap(URL.init(string:))
    }

    /// The URL to post into a message. Prefers a .gif so the client renders it
    /// inline animated without depending on server unfurling.
    public var sendURL: String? {
        let gif = media?["gif"]
        let candidates = [gif?.src, gif?.proxySrc, media?["webp"]?.src, src, proxySrc, url]
        if let dotGif = candidates.compactMap({ $0 }).first(where: { droppingQuery($0).hasSuffix(".gif") }) {
            return dotGif
        }
        return candidates.compactMap { $0 }.first
    }

    /// The share identifier for register-share: the slug if present, else id.
    public var shareId: String {
        if let slug, !slug.isEmpty { return slug }
        return id
    }

    private func droppingQuery(_ string: String) -> String {
        if let index = string.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            return String(string[..<index]).lowercased()
        }
        return string.lowercased()
    }
}
