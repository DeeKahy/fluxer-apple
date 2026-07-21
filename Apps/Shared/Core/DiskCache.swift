import Foundation
import FluxerKit

/// Snapshot of chat state persisted between launches so the sidebar and
/// recent channels render instantly while the gateway reconnects.
struct CacheSnapshot: Codable {
    var guilds: [Guild]
    var privateChannels: [Channel]
    var messages: [Snowflake: [Message]]
    var knownUsers: [Snowflake: User]
}

enum DiskCache {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Fluxer", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "chat-cache.json")
    }

    static func load() -> CacheSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CacheSnapshot.self, from: data)
    }

    static func save(_ snapshot: CacheSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

extension AppSession {
    /// Restores the last snapshot for instant rendering. Gateway data
    /// replaces it wholesale once READY lands.
    func loadCachedState() {
        guard let snapshot = DiskCache.load() else { return }
        if guilds.isEmpty {
            guilds = snapshot.guilds
        }
        if privateChannels.isEmpty {
            privateChannels = snapshot.privateChannels
        }
        for (channelId, cached) in snapshot.messages where messages[channelId] == nil {
            messages[channelId] = cached
            // Cached content is a placeholder until the server confirms
            // what actually happened since it was written.
            staleChannels.insert(channelId)
            channelsWithFullHistory.remove(channelId)
        }
        for (id, user) in snapshot.knownUsers where knownUsers[id] == nil {
            knownUsers[id] = user
        }
    }

    /// Debounced snapshot write, called after READY and message changes.
    func scheduleCacheSave() {
        cacheSaveTask?.cancel()
        cacheSaveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            // Local placeholders (pending or failed sends) must not be
            // persisted: after a restart they would render as ordinary
            // messages with no retry state behind them.
            let localIds = Set(pendingSends.values.map(\.placeholderId))
                .union(failedSends.values.map(\.placeholderId))
            let trimmedMessages = messages.mapValues { list in
                Array(list.filter { !localIds.contains($0.id) }.suffix(50))
            }
            let snapshot = CacheSnapshot(
                guilds: guilds,
                privateChannels: privateChannels,
                messages: trimmedMessages,
                knownUsers: knownUsers
            )
            DiskCache.save(snapshot)
        }
    }
}
