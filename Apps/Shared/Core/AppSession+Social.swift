import Foundation
import FluxerKit

extension AppSession {
    // MARK: Presence

    /// Reads presences delivered inside READY: a top level array plus one
    /// per guild. Entries carry either user.id or user_id.
    func applyReadyPresences(_ data: JSONValue?) {
        for entry in data?["presences"]?.arrayValue ?? [] {
            applyPresence(entry)
        }
        for guild in data?["guilds"]?.arrayValue ?? [] {
            for entry in guild["presences"]?.arrayValue ?? [] {
                applyPresence(entry)
            }
        }
    }

    func applyPresence(_ entry: JSONValue?) {
        guard let entry else { return }
        let userId = entry["user"]?.snowflake("id") ?? entry.snowflake("user_id")
        guard let userId else { return }
        let status = entry["status"]?.stringValue ?? "offline"
        if status == "offline" {
            presences[userId] = nil
        } else {
            presences[userId] = status
        }
    }

    func presenceStatus(for userId: Snowflake?) -> String? {
        guard let userId else { return nil }
        return presences[userId]
    }

    // MARK: Permissions and slowmode

    /// Effective permissions for the signed-in user in a channel.
    func permissions(in channel: Channel) -> Permissions {
        guard let guildId = channel.guildId else { return .all }
        guard let me = currentUser,
              let guild = guilds.first(where: { $0.id == guildId })
        else { return .all }
        return PermissionCalculator.permissions(
            for: me.id,
            memberRoleIds: myMembers[guildId]?.roles ?? [],
            guild: guild,
            channel: channel
        )
    }

    /// Guild wide permissions, without channel overwrites.
    func guildPermissions(in guildId: Snowflake) -> Permissions {
        guard let me = currentUser,
              let guild = guilds.first(where: { $0.id == guildId })
        else { return [] }
        return PermissionCalculator.permissions(
            for: me.id,
            memberRoleIds: myMembers[guildId]?.roles ?? [],
            guild: guild,
            channel: nil
        )
    }

    func canSendMessages(in channel: Channel) -> Bool {
        permissions(in: channel).contains(.sendMessages)
    }

    func canAttachFiles(in channel: Channel) -> Bool {
        permissions(in: channel).contains(.attachFiles)
    }

    /// Seconds of slowmode that apply to the current user, 0 when exempt.
    func slowmodeInterval(in channel: Channel) -> Int {
        guard let interval = channel.rateLimitPerUser, interval > 0 else { return 0 }
        let perms = permissions(in: channel)
        if perms.contains(.bypassSlowmode) || perms.contains(.manageMessages) || perms.contains(.manageChannels) {
            return 0
        }
        return interval
    }

    func slowmodeRemaining(in channel: Channel) -> TimeInterval {
        guard let until = slowmodeUntil[channel.id] else { return 0 }
        return max(0, until.timeIntervalSinceNow)
    }

    // MARK: Members

    func loadMembers(for guild: Guild) async {
        guard guildMembers[guild.id] == nil else { return }
        do {
            let members = try await client.guildMembers(guild.id, limit: 200)
            for member in members {
                if let user = member.user {
                    knownUsers[user.id] = user
                }
            }
            guildMembers[guild.id] = members.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        } catch {
            reportTransient(error)
        }
    }

    // MARK: Friends

    var friends: [Relationship] {
        relationships.values.filter { $0.type == .friend }
            .sorted { displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending }
    }

    var pendingRequests: [Relationship] {
        relationships.values
            .filter { $0.type == .incomingRequest || $0.type == .outgoingRequest }
            .sorted { ($0.type.rawValue, $0.id) < ($1.type.rawValue, $1.id) }
    }

    var blockedUsers: [Relationship] {
        relationships.values.filter { $0.type == .blocked }
            .sorted { displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending }
    }

    func displayName(for relationship: Relationship) -> String {
        relationship.nickname
            ?? relationship.user?.displayName
            ?? knownUsers[relationship.id]?.displayName
            ?? "Unknown"
    }

    func sendFriendRequest(username: String) async -> Bool {
        // Accepts name or name#discriminator.
        let parts = username.split(separator: "#", maxSplits: 1)
        let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let discriminator = parts.count > 1 ? String(parts[1]) : nil
        guard !name.isEmpty else { return false }
        friendRequestError = nil
        do {
            try await client.sendFriendRequest(username: name, discriminator: discriminator)
            return true
        } catch {
            friendRequestError = Self.describe(error)
            return false
        }
    }

    /// Friend request to a user we already know the id of, from profiles.
    func sendFriendRequest(to userId: Snowflake) async -> Bool {
        friendRequestError = nil
        do {
            try await client.sendFriendRequest(to: userId)
            return true
        } catch {
            friendRequestError = Self.describe(error)
            return false
        }
    }

    func acceptRequest(_ relationship: Relationship) async {
        do {
            try await client.acceptFriendRequest(from: relationship.id)
        } catch {
            reportTransient(error)
        }
    }

    func removeRelationship(_ relationship: Relationship) async {
        do {
            try await client.removeRelationship(with: relationship.id)
            relationships[relationship.id] = nil
        } catch {
            reportTransient(error)
        }
    }

    /// Opens (or finds) the DM with a user and returns it for navigation.
    func openDM(with userId: Snowflake) async -> Channel? {
        if let existing = privateChannels.first(where: { channel in
            channel.type == .dm && (channel.recipients ?? []).contains { $0.id == userId }
        }) {
            return existing
        }
        do {
            let channel = try await client.openDM(with: userId)
            if !privateChannels.contains(where: { $0.id == channel.id }) {
                privateChannels.insert(channel, at: 0)
            }
            return channel
        } catch {
            reportTransient(error)
            return nil
        }
    }
}
