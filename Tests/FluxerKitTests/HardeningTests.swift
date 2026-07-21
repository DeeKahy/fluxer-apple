import Foundation
import Testing
@testable import FluxerKit

@Suite("Instance bootstrap parsing")
struct InstanceConfigTests {
    private let sampleHTML = """
    <html><head><script>window.__FLUXER_BOOTSTRAP__={"config":{"releaseChannel":"stable"},\
    "instance":{"api_code_version":1,\
    "captcha":{"hcaptcha_site_key":"key-123","provider":"hcaptcha","turnstile_site_key":null},\
    "endpoints":{"api_public":"https://api.example.com","gateway":"wss://gateway.example.com",\
    "media":"https://media.example.com","static_cdn":"https://static.example.com",\
    "webapp":"https://web.example.com"}}}</script></head><body></body></html>
    """

    @Test func parsesEndpointsAndCaptcha() throws {
        let config = try InstanceConfig.parse(
            html: sampleHTML,
            origin: URL(string: "https://example.com")!
        )
        #expect(config.apiBase.absoluteString == "https://api.example.com/v1")
        #expect(config.gatewayURL.absoluteString.hasPrefix("wss://gateway.example.com"))
        #expect(config.gatewayURL.query()?.contains("encoding=json") == true)
        #expect(config.mediaBase.absoluteString == "https://media.example.com")
        #expect(config.staticBase.absoluteString == "https://static.example.com")
        #expect(config.captchaProvider == "hcaptcha")
        #expect(config.hcaptchaSiteKey == "key-123")
        #expect(config.turnstileSiteKey == nil)
    }

    @Test func rejectsPagesWithoutBootstrap() {
        #expect(throws: APIError.self) {
            try InstanceConfig.parse(
                html: "<html><body>not fluxer</body></html>",
                origin: URL(string: "https://example.com")!
            )
        }
    }
}

@Suite("Message list extraction")
struct ExtractMessagesTests {
    private let message = #"{"id": "1", "channel_id": "2", "content": "hi"}"#

    @Test func handlesBareArray() {
        let data = Data("[\(message)]".utf8)
        #expect(APIClient.extractMessages(from: data).count == 1)
    }

    @Test func handlesItemsWrapper() {
        let data = Data(#"{"items": [\#(message)]}"#.utf8)
        #expect(APIClient.extractMessages(from: data).count == 1)
    }

    @Test func handlesPerEntryMessageWrapper() {
        let data = Data(#"[{"message": \#(message), "saved_at": "2026-01-01T00:00:00Z"}]"#.utf8)
        #expect(APIClient.extractMessages(from: data).count == 1)
    }

    @Test func skipsUndecodableEntries() {
        let data = Data(#"[\#(message), {"garbage": true}]"#.utf8)
        #expect(APIClient.extractMessages(from: data).count == 1)
    }

    @Test func emptyOnNonJSON() {
        #expect(APIClient.extractMessages(from: Data("oops".utf8)).isEmpty)
    }

    /// Saved messages arrive as {id, channel_id, message_id, status, message}
    /// entries. The wrapper itself half-decodes as a Message (it has id and
    /// channel_id), so the extractor must prefer the inner message.
    @Test func savedEntryYieldsInnerMessageNotWrapper() {
        let data = Data(#"""
        [{"id": "900", "channel_id": "2", "message_id": "1", "status": "available",
          "message": {"id": "1", "channel_id": "2", "content": "the real one",
                      "author": {"id": "7", "username": "kaj"}}}]
        """#.utf8)
        let messages = APIClient.extractMessages(from: data)
        #expect(messages.count == 1)
        #expect(messages.first?.id.stringValue == "1")
        #expect(messages.first?.content == "the real one")
    }

    /// A saved entry whose message the user can no longer see carries
    /// message: null and must be skipped, not decoded from the wrapper.
    @Test func savedEntryWithNullMessageIsSkipped() {
        let data = Data(#"""
        [{"id": "900", "channel_id": "2", "message_id": "1",
          "status": "missing_permissions", "message": null}]
        """#.utf8)
        #expect(APIClient.extractMessages(from: data).isEmpty)
    }

    /// Channel pins arrive as {items: [{message, pinned_at}], has_more}.
    @Test func handlesPinsShape() {
        let data = Data(#"""
        {"items": [{"message": {"id": "1", "channel_id": "2", "content": "pinned"},
                    "pinned_at": "2026-07-01T10:00:00Z"}],
         "has_more": false}
        """#.utf8)
        let messages = APIClient.extractMessages(from: data)
        #expect(messages.count == 1)
        #expect(messages.first?.content == "pinned")
    }

    /// Mentions arrive as a bare array of full message objects.
    @Test func handlesMentionsShape() {
        let data = Data(#"""
        [{"id": "1", "channel_id": "2", "content": "hey @you",
          "author": {"id": "7", "username": "kaj"},
          "timestamp": "2026-07-01T10:00:00Z",
          "mentions": [{"id": "8", "username": "you"}],
          "mention_roles": [], "mention_everyone": false,
          "pinned": false, "tts": false, "type": 0, "flags": 0}]
        """#.utf8)
        let messages = APIClient.extractMessages(from: data)
        #expect(messages.count == 1)
        #expect(messages.first?.author?.username == "kaj")
        #expect(messages.first?.timestamp != nil)
    }
}

struct ExtractSearchResultsTests {
    @Test func parsesResultsShape() {
        let data = Data(#"""
        {"messages": [{"id": "1", "channel_id": "2", "content": "found me"}],
         "channels": [{"id": "2", "type": 0, "name": "general"}],
         "total": 41, "hits_per_page": 25, "page": 1}
        """#.utf8)
        let results = APIClient.extractSearchResults(from: data)
        #expect(results.messages.count == 1)
        #expect(results.channels.first?.name == "general")
        #expect(results.total == 41)
        #expect(!results.indexing)
    }

    @Test func parsesIndexingShape() {
        let results = APIClient.extractSearchResults(from: Data(#"{"indexing": true}"#.utf8))
        #expect(results.indexing)
        #expect(results.messages.isEmpty)
    }

    @Test func emptyOnGarbage() {
        let results = APIClient.extractSearchResults(from: Data("nope".utf8))
        #expect(results.messages.isEmpty)
        #expect(!results.indexing)
    }
}
