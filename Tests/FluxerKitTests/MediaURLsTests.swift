import Testing
import Foundation
@testable import FluxerKit

@Suite("MediaURLs custom emoji")
struct MediaURLsTests {
    @Test func staticEmojiUsesWebp() {
        let emoji = ReactionEmoji(id: Snowflake(1524913110333263872), name: "kek")
        let url = MediaURLs.customEmoji(emoji)
        #expect(url?.absoluteString == "https://fluxerusercontent.com/emojis/1524913110333263872.webp?v=5")
    }

    @Test func animatedEmojiUsesGif() {
        let emoji = ReactionEmoji(id: Snowflake(1524913110333263872), name: "kekcube", animated: true)
        let url = MediaURLs.customEmoji(emoji)
        #expect(url?.absoluteString == "https://fluxerusercontent.com/emojis/1524913110333263872.gif")
    }

    @Test func animatedFalseFallsBackToWebp() {
        let emoji = ReactionEmoji(id: Snowflake(42), name: "blob", animated: false)
        let url = MediaURLs.customEmoji(emoji)
        #expect(url?.absoluteString.hasSuffix(".webp?v=5") == true)
    }

    @Test func unicodeEmojiHasNoURL() {
        #expect(MediaURLs.customEmoji(ReactionEmoji(name: "😀")) == nil)
    }
}
