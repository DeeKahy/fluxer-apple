import Foundation

/// Builds URLs for user content and static assets, mirroring the paths the
/// official client uses. Endpoints come from the instance bootstrap config;
/// these defaults are fluxer.app's.
public enum MediaURLs {
    public nonisolated(unsafe) static var userContentBase = URL(string: "https://fluxerusercontent.com")!
    public nonisolated(unsafe) static var staticBase = URL(string: "https://fluxerstatic.com")!

    /// Points media at a different instance's endpoints.
    public static func configure(with config: InstanceConfig) {
        userContentBase = config.mediaBase
        staticBase = config.staticBase
    }

    /// fluxerstatic.com serves default avatars 0 through 5.
    static let defaultAvatarCount: UInt64 = 6

    public static func avatar(userId: Snowflake, hash: String?, size: Int = 64) -> URL {
        guard let hash, !hash.isEmpty else {
            let index = userId.rawValue % defaultAvatarCount
            return staticBase.appending(path: "avatars/\(index).png")
        }
        return mediaURL(path: "avatars", id: userId, hash: hash, size: size)
    }

    public static func customEmoji(_ emoji: ReactionEmoji) -> URL? {
        guard let id = emoji.id else { return nil }
        var url = userContentBase.appending(path: "emojis/\(id).webp")
        url.append(queryItems: [URLQueryItem(name: "v", value: "5")])
        return url
    }

    public static func guildIcon(guildId: Snowflake, hash: String?, size: Int = 64) -> URL? {
        guard let hash, !hash.isEmpty else { return nil }
        return mediaURL(path: "icons", id: guildId, hash: hash, size: size)
    }

    private static func mediaURL(path: String, id: Snowflake, hash: String, size: Int) -> URL {
        // Animated hashes carry an a_ prefix; the static frame drops it.
        let cleaned = hash.hasPrefix("a_") ? String(hash.dropFirst(2)) : hash
        var url = userContentBase.appending(path: "\(path)/\(id)/\(cleaned).webp")
        url.append(queryItems: [URLQueryItem(name: "size", value: String(size))])
        return url
    }
}

extension User {
    /// Avatar image URL, falling back to the instance default avatars.
    public func avatarURL(size: Int = 64) -> URL {
        MediaURLs.avatar(userId: id, hash: avatar, size: size)
    }
}

extension Guild {
    public func iconURL(size: Int = 64) -> URL? {
        MediaURLs.guildIcon(guildId: id, hash: icon, size: size)
    }
}
