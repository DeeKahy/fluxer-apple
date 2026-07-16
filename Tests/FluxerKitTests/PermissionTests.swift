import Foundation
import Testing
@testable import FluxerKit

@Suite("Permission calculation")
struct PermissionTests {
    private let guildId = Snowflake(100)
    private let memberId = Snowflake(1)

    private func makeGuild(roles: [Role], ownerId: Snowflake = Snowflake(999)) -> Guild {
        let json = #"{"id": "\#(guildId)", "name": "Test", "owner_id": "\#(ownerId)"}"#
        var guild = try! JSONDecoder.fluxer.decode(Guild.self, from: Data(json.utf8))
        guild.roles = roles
        return guild
    }

    private func makeRole(id: Snowflake, _ permissions: Permissions) -> Role {
        let json = #"{"id": "\#(id)", "name": "role", "permissions": "\#(permissions.rawValue)"}"#
        return try! JSONDecoder.fluxer.decode(Role.self, from: Data(json.utf8))
    }

    private func everyoneRole(_ permissions: Permissions) -> Role {
        makeRole(id: guildId, permissions)
    }

    private func makeOverwrite(id: Snowflake, type: Int, allow: Permissions, deny: Permissions) -> PermissionOverwrite {
        let json = #"{"id": "\#(id)", "type": \#(type), "allow": "\#(allow.rawValue)", "deny": "\#(deny.rawValue)"}"#
        return try! JSONDecoder.fluxer.decode(PermissionOverwrite.self, from: Data(json.utf8))
    }

    private func makeChannel(overwrites: [PermissionOverwrite]) -> Channel {
        let json = #"{"id": "200", "type": 0, "guild_id": "\#(guildId)"}"#
        var channel = try! JSONDecoder.fluxer.decode(Channel.self, from: Data(json.utf8))
        channel.permissionOverwrites = overwrites
        return channel
    }

    @Test func ownerGetsEverything() {
        let guild = makeGuild(roles: [everyoneRole([])], ownerId: memberId)
        let result = PermissionCalculator.permissions(
            for: memberId, memberRoleIds: [], guild: guild, channel: nil
        )
        #expect(result.contains(.sendMessages))
        #expect(result.contains(.administrator))
    }

    @Test func everyoneRoleGrantsBase() {
        let guild = makeGuild(roles: [everyoneRole([.viewChannel, .sendMessages])])
        let result = PermissionCalculator.permissions(
            for: memberId, memberRoleIds: [], guild: guild, channel: nil
        )
        #expect(result.contains(.sendMessages))
        #expect(!result.contains(.manageMessages))
    }

    @Test func administratorShortCircuits() {
        let adminRole = makeRole(id: Snowflake(2), .administrator)
        let guild = makeGuild(roles: [everyoneRole([]), adminRole])
        let result = PermissionCalculator.permissions(
            for: memberId, memberRoleIds: [Snowflake(2)], guild: guild, channel: nil
        )
        #expect(result.contains(.sendMessages))
        #expect(result.contains(.banMembers))
    }

    @Test func everyoneOverwriteDeniesSend() {
        let guild = makeGuild(roles: [everyoneRole([.viewChannel, .sendMessages])])
        let channel = makeChannel(overwrites: [
            makeOverwrite(id: guildId, type: 0, allow: [], deny: .sendMessages),
        ])
        let result = PermissionCalculator.permissions(
            for: memberId, memberRoleIds: [], guild: guild, channel: channel
        )
        #expect(!result.contains(.sendMessages))
        #expect(result.contains(.viewChannel))
    }

    @Test func memberOverwriteBeatsRoleDeny() {
        let modRole = makeRole(id: Snowflake(3), [])
        let guild = makeGuild(roles: [everyoneRole([.viewChannel, .sendMessages]), modRole])
        let channel = makeChannel(overwrites: [
            makeOverwrite(id: Snowflake(3), type: 0, allow: [], deny: .sendMessages),
            makeOverwrite(id: memberId, type: 1, allow: .sendMessages, deny: []),
        ])
        let result = PermissionCalculator.permissions(
            for: memberId, memberRoleIds: [Snowflake(3)], guild: guild, channel: channel
        )
        #expect(result.contains(.sendMessages))
    }

    @Test func permissionStringsDecode() {
        let permissions = Permissions(string: String((1 << 11) | (1 << 52)))
        #expect(permissions.contains(.sendMessages))
        #expect(permissions.contains(.bypassSlowmode))
        #expect(!permissions.contains(.administrator))
    }
}
