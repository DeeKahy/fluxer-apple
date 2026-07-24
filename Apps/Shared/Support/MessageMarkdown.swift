import Foundation
import SwiftUI
import FluxerKit

/// Turns raw message content into an AttributedString: basic markdown
/// (bold, italics, strikethrough, inline code, links), clickable channel
/// mentions, named user mentions, auto linked bare URLs, and spoilers.
enum MessageMarkdown {
    static let channelURLScheme = "fluxer"

    /// A link to a channel, or to a specific message inside one, parsed from
    /// a web URL like https://web.fluxer.app/channels/{guild}/{channel}/{message}.
    struct MessageLink: Hashable {
        let channelId: Snowflake
        /// nil for a plain channel link, set for a jump to one message.
        let messageId: Snowflake?
    }

    static func render(
        _ content: String,
        revealedSpoilers: Set<Int> = [],
        webHost: String? = nil,
        channelName: (Snowflake) -> String?,
        userName: (Snowflake) -> String?
    ) -> AttributedString {
        // Web links to a channel or message render as their own chip below the
        // text, so strip the raw URL out here before the bare-URL linker turns
        // it into an ugly full link.
        var text = textWithoutLinks(content, webHost: webHost)

        // ||spoiler|| markers. Revealed ones just lose the bars and render
        // normally. Hidden ones are replaced whole with a tappable link,
        // so the content never reaches the later transforms and the block
        // characters can't collide with markdown syntax.
        if let regex = try? NSRegularExpression(
            pattern: #"\|\|(.+?)\|\|"#,
            options: [.dotMatchesLineSeparators]
        ) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            for (index, match) in matches.enumerated().reversed() {
                guard let fullRange = Range(match.range, in: text),
                      let innerRange = Range(match.range(at: 1), in: text)
                else { continue }
                if revealedSpoilers.contains(index) {
                    text.replaceSubrange(fullRange, with: String(text[innerRange]))
                } else {
                    let width = min(max(text[innerRange].count, 4), 24)
                    let bar = String(repeating: "\u{2588}", count: width)
                    text.replaceSubrange(
                        fullRange,
                        with: "[\(bar)](\(channelURLScheme)://spoiler/\(index))"
                    )
                }
            }
        }

        // <#123> becomes a tappable link routed back into the app.
        text = replace(in: text, pattern: #"<#(\d+)>"#) { id in
            let name = channelName(id) ?? "channel"
            return "[**#\(escapeMarkdown(name))**](\(channelURLScheme)://channel/\(id))"
        }

        // Custom emoji tokens render as their name; emoji-only messages
        // are handled separately with real images.
        if let regex = try? NSRegularExpression(pattern: #"<a?:([A-Za-z0-9_~]+):\d+>"#) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range).reversed() {
                guard let fullRange = Range(match.range, in: text),
                      let nameRange = Range(match.range(at: 1), in: text)
                else { continue }
                text.replaceSubrange(fullRange, with: "`:\(text[nameRange]):`")
            }
        }

        // <@123> and <@!123> become a highlighted name.
        text = replace(in: text, pattern: #"<@!?(\d+)>"#) { id in
            let name = userName(id) ?? "someone"
            return "**@\(escapeMarkdown(name))**"
        }

        // Bare URLs get linked; ones already inside a markdown link are
        // left alone by requiring the character before not to be ( or ].
        if let regex = try? NSRegularExpression(pattern: #"(?<![\(\]])(https?://[^\s<>]+)"#) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range).reversed()
            for match in matches {
                guard let swiftRange = Range(match.range(at: 1), in: text) else { continue }
                let url = String(text[swiftRange])
                text.replaceSubrange(swiftRange, with: "[\(url)](\(url))")
            }
        }

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(content)

        // Hidden spoiler bars should look like redactions, not links.
        let spoilerRanges = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let link = run.link,
                  link.scheme == channelURLScheme,
                  link.host() == "spoiler"
            else { return nil }
            return run.range
        }
        for range in spoilerRanges {
            attributed[range].foregroundColor = Theme.faint
        }
        return attributed
    }

    /// When a message is nothing but 1 to 8 custom emoji, returns them as
    /// tokens (id, name, animated flag) so the UI can draw the real images at
    /// a friendly size and animate the animated ones.
    static func emojiOnlyTokens(_ content: String) -> [ReactionEmoji]? {
        guard let regex = try? NSRegularExpression(pattern: #"<(a)?:([A-Za-z0-9_~]+):(\d+)>"#) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let matches = regex.matches(in: trimmed, range: range)
        guard !matches.isEmpty, matches.count <= 8 else { return nil }
        var rest = trimmed
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: rest) else { return nil }
            rest.removeSubrange(swiftRange)
        }
        guard rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return matches.compactMap { match -> ReactionEmoji? in
            guard let idRange = Range(match.range(at: 3), in: trimmed),
                  let id = Snowflake(string: String(trimmed[idRange])),
                  let nameRange = Range(match.range(at: 2), in: trimmed)
            else { return nil }
            let animated = match.range(at: 1).location != NSNotFound
            return ReactionEmoji(id: id, name: String(trimmed[nameRange]), animated: animated)
        }
    }

    /// Channel and message links found in message content, in order, without
    /// duplicates, capped at three. `webHost` is the current instance's web
    /// origin host so links to that instance (and any fluxer.app host) are
    /// recognized while foreign links stay plain.
    static func messageLinks(_ content: String, webHost: String?) -> [MessageLink] {
        var seen = Set<MessageLink>()
        var result: [MessageLink] = []
        for match in linkMatches(in: content, webHost: webHost) {
            if seen.insert(match.link).inserted {
                result.append(match.link)
            }
            if result.count == 3 { break }
        }
        return result
    }

    /// When a message is nothing but a single image/GIF URL, returns it so the
    /// UI can render the media inline instead of a bare link. Matches any
    /// http(s) URL whose path ends in .gif, plus any URL on the instance media
    /// host (proxied GIFs carry no file extension).
    static func soleMediaURL(_ content: String, mediaHost: String?) -> URL? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        if url.path.lowercased().hasSuffix(".gif") { return url }
        if let mediaHost, url.host()?.caseInsensitiveCompare(mediaHost) == .orderedSame {
            return url
        }
        return nil
    }

    /// The message text with recognized channel/message links removed, so a
    /// message that is only such links renders as chips with no empty line.
    static func textWithoutLinks(_ content: String, webHost: String?) -> String {
        var text = content
        for match in linkMatches(in: text, webHost: webHost).reversed() {
            text.replaceSubrange(match.range, with: "")
        }
        return text
    }

    private static let linkRegex = try? NSRegularExpression(
        pattern: #"https?://([^/\s]+)/channels/(?:@me|\d+)/(\d+)(?:/(\d+))?/?"#
    )

    /// Matches every recognized channel/message web link with its string range.
    private static func linkMatches(
        in text: String,
        webHost: String?
    ) -> [(range: Range<String.Index>, link: MessageLink)] {
        guard let regex = linkRegex else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var results: [(Range<String.Index>, MessageLink)] = []
        for match in regex.matches(in: text, range: range) {
            guard let fullRange = Range(match.range, in: text),
                  let hostRange = Range(match.range(at: 1), in: text),
                  isAllowedWebHost(String(text[hostRange]), configured: webHost),
                  let channelRange = Range(match.range(at: 2), in: text),
                  let channelId = Snowflake(string: String(text[channelRange]))
            else { continue }
            var messageId: Snowflake?
            if let messageRange = Range(match.range(at: 3), in: text) {
                messageId = Snowflake(string: String(text[messageRange]))
            }
            results.append((fullRange, MessageLink(channelId: channelId, messageId: messageId)))
        }
        return results
    }

    /// A link belongs in-app when its host matches this instance's web origin,
    /// or is any fluxer.app host (covers canary and self-hosted defaults).
    private static func isAllowedWebHost(_ host: String, configured: String?) -> Bool {
        if let configured, host.caseInsensitiveCompare(configured) == .orderedSame {
            return true
        }
        let lower = host.lowercased()
        return lower == "fluxer.app" || lower.hasSuffix(".fluxer.app")
    }

    /// Invite codes found in message content, from fluxer.gg links or full
    /// invite URLs. Order preserved, duplicates removed, capped at three.
    static func inviteCodes(_ content: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:https?://)?fluxer\.gg/([A-Za-z0-9_-]+)"#
        ) else { return [] }
        let range = NSRange(content.startIndex..., in: content)
        var seen = Set<String>()
        var codes: [String] = []
        for match in regex.matches(in: content, range: range) {
            guard let codeRange = Range(match.range(at: 1), in: content) else { continue }
            let code = String(content[codeRange])
            if seen.insert(code).inserted {
                codes.append(code)
            }
            if codes.count == 3 { break }
        }
        return codes
    }

    /// Splits content into plain segments, quoted runs, and fenced code
    /// blocks.
    enum Segment: Equatable {
        case text(String)
        case quote(String)
        case codeBlock(String)
    }

    static func segments(_ content: String) -> [Segment] {
        let hasQuote = content.hasPrefix(">") || content.contains("\n>")
        guard content.contains("```") || hasQuote else { return [.text(content)] }
        var result: [Segment] = []
        let parts = content.components(separatedBy: "```")
        for (index, part) in parts.enumerated() {
            if index % 2 == 0 {
                let trimmed = part.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty {
                    result.append(contentsOf: splitQuotes(trimmed))
                }
            } else {
                // Drop a leading language tag line.
                var code = part
                if let newline = code.firstIndex(of: "\n"),
                   code[code.startIndex..<newline].allSatisfy({ $0.isLetter || $0.isNumber }) {
                    code = String(code[code.index(after: newline)...])
                }
                let trimmed = code.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty {
                    result.append(.codeBlock(trimmed))
                }
            }
        }
        return result.isEmpty ? [.text(content)] : result
    }

    /// Pulls "> " quoted lines out of a plain segment. Consecutive quoted
    /// lines merge into one quote block, and ">>> " quotes everything from
    /// that line to the end of the segment.
    private static func splitQuotes(_ text: String) -> [Segment] {
        guard text.hasPrefix(">") || text.contains("\n>") else { return [.text(text)] }
        var result: [Segment] = []
        var plain: [String] = []
        var quoted: [String] = []

        func flushPlain() {
            let joined = plain.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { result.append(.text(joined)) }
            plain = []
        }
        func flushQuoted() {
            let joined = quoted.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { result.append(.quote(joined)) }
            quoted = []
        }

        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if line.hasPrefix(">>> ") {
                flushPlain()
                flushQuoted()
                var rest = [String(line.dropFirst(4))]
                rest.append(contentsOf: lines[(index + 1)...])
                let joined = rest.joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !joined.isEmpty { result.append(.quote(joined)) }
                return result
            } else if line.hasPrefix("> ") {
                flushPlain()
                quoted.append(String(line.dropFirst(2)))
            } else if line == ">" {
                flushPlain()
                quoted.append("")
            } else {
                flushQuoted()
                plain.append(line)
            }
        }
        flushPlain()
        flushQuoted()
        return result.isEmpty ? [.text(text)] : result
    }

    private static func replace(
        in text: String,
        pattern: String,
        with replacement: (Snowflake) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let range = NSRange(result.startIndex..., in: result)
        for match in regex.matches(in: result, range: range).reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let idRange = Range(match.range(at: 1), in: result),
                  let id = Snowflake(string: String(result[idRange]))
            else { continue }
            result.replaceSubrange(fullRange, with: replacement(id))
        }
        return result
    }

    private static func escapeMarkdown(_ text: String) -> String {
        var escaped = text
        for character in ["*", "_", "`", "~", "[", "]"] {
            escaped = escaped.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return escaped
    }
}
