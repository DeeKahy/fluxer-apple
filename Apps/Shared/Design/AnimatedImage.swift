import SwiftUI
import ImageIO
import FluxerKit

/// Decoded animation frames plus their timing, ready to drive with a
/// TimelineView. CGImage is immutable and safe to hand across isolation.
struct DecodedAnimation: @unchecked Sendable {
    let frames: [CGImage]
    /// Cumulative end time of each frame, in seconds.
    let frameEnds: [Double]
    let duration: Double
}

/// Loads and decodes animated images (GIF / animated WebP / APNG) into frames
/// with per-frame delays, cached in memory. Mirrors ImageLoader's retry and
/// in-flight dedup so a message list full of the same emoji fetches once.
actor AnimationLoader {
    static let shared = AnimationLoader()

    private final class Box {
        let value: DecodedAnimation?
        init(_ value: DecodedAnimation?) { self.value = value }
    }

    private let cache = NSCache<NSString, Box>()
    private var inFlight: [String: Task<DecodedAnimation?, Never>] = [:]

    init() {
        cache.countLimit = 300
    }

    func animation(for url: URL, maxPixelSize: Int) async -> DecodedAnimation? {
        // Key by size too: the same GIF is decoded small for the emoji grid
        // and larger for inline media, and those must not share a cache slot.
        let key = "\(maxPixelSize)|\(url.absoluteString)" as NSString
        if let box = cache.object(forKey: key) {
            return box.value
        }
        if let task = inFlight[key as String] {
            return await task.value
        }
        let task = Task<DecodedAnimation?, Never> {
            for attempt in 0..<2 {
                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(400))
                }
                if let (data, response) = try? await URLSession.shared.data(from: url),
                   let http = response as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode) {
                    return Self.decode(data, maxPixelSize: maxPixelSize)
                }
            }
            return nil
        }
        inFlight[key as String] = task
        let result = await task.value
        inFlight[key as String] = nil
        cache.setObject(Box(result), forKey: key)
        return result
    }

    private static func decode(_ data: Data, maxPixelSize: Int) -> DecodedAnimation? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        // Downsample frames to the display size to keep memory low for message
        // lists packed with animated emoji and inline GIFs.
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]

        var frames: [CGImage] = []
        var frameEnds: [Double] = []
        var clock = 0.0
        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, thumbOptions as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, index, nil)
            else { continue }
            frames.append(frame)
            clock += frameDelay(source, index)
            frameEnds.append(clock)
        }
        guard !frames.isEmpty else { return nil }
        return DecodedAnimation(frames: frames, frameEnds: frameEnds, duration: clock)
    }

    private static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.1
        }
        func delay(_ container: CFString, _ unclamped: CFString, _ clamped: CFString) -> Double? {
            guard let dict = props[container] as? [CFString: Any] else { return nil }
            if let value = dict[unclamped] as? Double, value > 0 { return value }
            if let value = dict[clamped] as? Double, value > 0 { return value }
            return nil
        }
        let gif = delay(kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime)
        let webp = delay(kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
        let png = delay(kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
        var value = gif ?? webp ?? png ?? 0.1
        // Browsers treat ultra-short frame delays as 100ms; match them.
        if value < 0.011 { value = 0.1 }
        return value
    }
}

/// Draws an animated image from a URL, driven off wall-clock time so it needs
/// no per-view timer state and pauses automatically when scrolled off screen.
/// Falls back to the placeholder while loading or if decoding fails.
struct AnimatedImage<Placeholder: View>: View {
    let url: URL?
    /// Longest edge the frames are downsampled to; small for emoji, larger
    /// for inline media.
    var maxPixelSize: Int = 128
    /// Fill (crop to a square, for emoji) or fit (preserve aspect, for media).
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var animation: DecodedAnimation?

    var body: some View {
        Group {
            if let animation, !animation.frames.isEmpty {
                if animation.frames.count > 1, animation.duration > 0 {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        frame(animation, at: context.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    image(animation.frames[0])
                }
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            animation = nil
            guard let url else { return }
            animation = await AnimationLoader.shared.animation(for: url, maxPixelSize: maxPixelSize)
        }
    }

    private func frame(_ animation: DecodedAnimation, at time: TimeInterval) -> some View {
        let position = time.truncatingRemainder(dividingBy: animation.duration)
        let index = animation.frameEnds.firstIndex { position < $0 } ?? animation.frames.count - 1
        return image(animation.frames[index])
    }

    private func image(_ frame: CGImage) -> some View {
        Image(decorative: frame, scale: 1)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: contentMode)
    }
}

/// Custom emoji image: animates when the emoji is animated, static otherwise.
struct EmojiImage<Placeholder: View>: View {
    let emoji: ReactionEmoji
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        let url = MediaURLs.customEmoji(emoji)
        if emoji.animated == true {
            AnimatedImage(url: url, placeholder: placeholder)
        } else {
            RemoteImage(url: url, placeholder: placeholder)
        }
    }
}
