import Foundation

/// Permission bitfield. The API serialises these as decimal strings.
/// Bit numbering mirrors packages/constants/src/ChannelConstants.ts upstream.
public struct Permissions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(string: String?) {
        self.rawValue = string.flatMap(UInt64.init) ?? 0
    }

    public static let createInstantInvite = Permissions(rawValue: 1 << 0)
    public static let kickMembers = Permissions(rawValue: 1 << 1)
    public static let banMembers = Permissions(rawValue: 1 << 2)
    public static let administrator = Permissions(rawValue: 1 << 3)
    public static let manageChannels = Permissions(rawValue: 1 << 4)
    public static let manageGuild = Permissions(rawValue: 1 << 5)
    public static let addReactions = Permissions(rawValue: 1 << 6)
    public static let viewChannel = Permissions(rawValue: 1 << 10)
    public static let sendMessages = Permissions(rawValue: 1 << 11)
    public static let manageMessages = Permissions(rawValue: 1 << 13)
    public static let embedLinks = Permissions(rawValue: 1 << 14)
    public static let attachFiles = Permissions(rawValue: 1 << 15)
    public static let readMessageHistory = Permissions(rawValue: 1 << 16)
    public static let mentionEveryone = Permissions(rawValue: 1 << 17)
    public static let connect = Permissions(rawValue: 1 << 20)
    public static let speak = Permissions(rawValue: 1 << 21)
    public static let manageRoles = Permissions(rawValue: 1 << 28)
    public static let moderateMembers = Permissions(rawValue: 1 << 40)
    public static let pinMessages = Permissions(rawValue: 1 << 51)
    public static let bypassSlowmode = Permissions(rawValue: 1 << 52)
    public static let viewChannelMembers = Permissions(rawValue: 1 << 54)

    public static let all = Permissions(rawValue: .max)
}

public struct Role: Codable, Hashable, Identifiable, Sendable {
    public let id: Snowflake
    public var name: String
    public var permissions: String?
    public var position: Int?
    public var color: Int?
    public var hoist: Bool?

    public var permissionSet: Permissions {
        Permissions(string: permissions)
    }
}

public struct PermissionOverwrite: Codable, Hashable, Sendable {
    /// 0 applies to a role, 1 to a member.
    public enum Kind: Int, Codable, Sendable {
        case role = 0
        case member = 1
    }

    public let id: Snowflake
    public var type: Kind
    public var allow: String
    public var deny: String

    public var allowSet: Permissions { Permissions(string: allow) }
    public var denySet: Permissions { Permissions(string: deny) }
}

public struct GuildMember: Codable, Hashable, Sendable {
    public var user: User?
    public var roles: [Snowflake]?
    public var nick: String?
    public var joinedAt: String?

    public var displayName: String {
        nick ?? user?.displayName ?? "Unknown"
    }
}

/// Computes effective permissions the same way the server does: owner gets
/// everything, role permissions union up, administrator short-circuits, then
/// channel overwrites apply in order everyone, roles, member.
public enum PermissionCalculator {
    public static func permissions(
        for memberId: Snowflake,
        memberRoleIds: [Snowflake],
        guild: Guild,
        channel: Channel?
    ) -> Permissions {
        if guild.ownerId == memberId {
            return .all
        }
        let roles = guild.roles ?? []
        var base: Permissions = []
        // The everyone role shares the guild's id.
        if let everyone = roles.first(where: { $0.id == guild.id }) {
            base.formUnion(everyone.permissionSet)
        }
        for roleId in memberRoleIds {
            if let role = roles.first(where: { $0.id == roleId }) {
                base.formUnion(role.permissionSet)
            }
        }
        if base.contains(.administrator) {
            return .all
        }
        guard let overwrites = channel?.permissionOverwrites, !overwrites.isEmpty else {
            return base
        }
        var result = base
        if let everyone = overwrites.first(where: { $0.type == .role && $0.id == guild.id }) {
            result.subtract(everyone.denySet)
            result.formUnion(everyone.allowSet)
        }
        var roleAllow: Permissions = []
        var roleDeny: Permissions = []
        for overwrite in overwrites where overwrite.type == .role && overwrite.id != guild.id {
            if memberRoleIds.contains(overwrite.id) {
                roleAllow.formUnion(overwrite.allowSet)
                roleDeny.formUnion(overwrite.denySet)
            }
        }
        result.subtract(roleDeny)
        result.formUnion(roleAllow)
        if let member = overwrites.first(where: { $0.type == .member && $0.id == memberId }) {
            result.subtract(member.denySet)
            result.formUnion(member.allowSet)
        }
        return result
    }
}
