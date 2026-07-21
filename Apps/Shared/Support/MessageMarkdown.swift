import Foundation
import SwiftUI
import FluxerKit

/// Turns raw message content into an AttributedString: basic markdown
/// (bold, italics, strikethrough, inline code, links), clickable channel
/// mentions, named user mentions, auto linked bare URLs, and spoilers.
enum MessageMarkdown {
    static let channelURLScheme = "fluxer"

    static func render(
        _ content: String,
        revealedSpoilers: Set<Int> = [],
        channelName: (Snowflake) -> String?,
        userName: (Snowflake) -> String?
    ) -> AttributedString {
        var text = content

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

    /// When a message is nothing but 1 to 8 custom emoji, returns their ids
    /// so the UI can draw the actual images at a friendly size.
    static func emojiOnlyIds(_ content: String) -> [Snowflake]? {
        guard let regex = try? NSRegularExpression(pattern: #"<a?:[A-Za-z0-9_~]+:(\d+)>"#) else { return nil }
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
        return matches.compactMap { match in
            Range(match.range(at: 1), in: trimmed).flatMap { Snowflake(string: String(trimmed[$0])) }
        }
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
