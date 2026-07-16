import Foundation
import FluxerKit

/// Turns raw message content into an AttributedString: basic markdown
/// (bold, italics, strikethrough, inline code, links), clickable channel
/// mentions, named user mentions, and auto linked bare URLs.
enum MessageMarkdown {
    static let channelURLScheme = "fluxer"

    static func render(
        _ content: String,
        channelName: (Snowflake) -> String?,
        userName: (Snowflake) -> String?
    ) -> AttributedString {
        var text = content

        // <#123> becomes a tappable link routed back into the app.
        text = replace(in: text, pattern: #"<#(\d+)>"#) { id in
            let name = channelName(id) ?? "channel"
            return "[**#\(escapeMarkdown(name))**](\(channelURLScheme)://channel/\(id))"
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
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(content)
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
