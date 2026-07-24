import Testing
import Foundation
@testable import FluxerKit

@Suite("GifResult")
struct GifTests {
    private func decode(_ json: String) throws -> GifResult {
        try JSONDecoder.fluxer.decode(GifResult.self, from: Data(json.utf8))
    }

    @Test func decodesSnakeCaseMedia() throws {
        let gif = try decode("""
        {
          "id": "abc",
          "slug": "funny-cat-abc",
          "provider": "klipy",
          "title": "cat",
          "url": "https://klipy.com/gif/funny-cat-abc",
          "src": "https://cdn.klipy.com/best.mp4",
          "proxy_src": "https://fluxerusercontent.com/proxy/best.mp4",
          "width": 480,
          "height": 270,
          "media": {
            "gif": {"src": "https://cdn.klipy.com/x.gif", "proxy_src": "https://fluxerusercontent.com/p/x.gif", "width": 480, "height": 270},
            "tinygif": {"src": "https://cdn.klipy.com/tiny.gif", "proxy_src": "https://fluxerusercontent.com/p/tiny.gif", "width": 120, "height": 68}
          }
        }
        """)
        #expect(gif.id == "abc")
        #expect(gif.media?["gif"]?.proxySrc == "https://fluxerusercontent.com/p/x.gif")
        #expect(gif.shareId == "funny-cat-abc")
    }

    @Test func sendURLPrefersGifExtension() throws {
        // Best src is an mp4, but sendURL must pick the .gif format.
        let gif = try decode("""
        {"id":"1","src":"https://cdn.klipy.com/best.mp4",
         "media":{"gif":{"src":"https://cdn.klipy.com/x.gif","proxy_src":"https://p/x.gif","width":1,"height":1}}}
        """)
        #expect(gif.sendURL == "https://cdn.klipy.com/x.gif")
    }

    @Test func sendURLFallsBackWhenNoGifFormat() throws {
        let gif = try decode("""
        {"id":"1","src":"https://cdn.klipy.com/best.mp4","proxy_src":"https://p/best.mp4"}
        """)
        #expect(gif.sendURL == "https://cdn.klipy.com/best.mp4")
    }

    @Test func previewPrefersTiny() throws {
        let gif = try decode("""
        {"id":"1","proxy_src":"https://p/big.gif",
         "media":{"tinygif":{"src":"https://cdn/tiny.gif","proxy_src":"https://p/tiny.gif","width":1,"height":1}}}
        """)
        #expect(gif.previewURL?.absoluteString == "https://p/tiny.gif")
    }

    @Test func shareIdFallsBackToId() throws {
        let gif = try decode(#"{"id":"only-id"}"#)
        #expect(gif.shareId == "only-id")
    }
}
