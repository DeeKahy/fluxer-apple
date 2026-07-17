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
}
