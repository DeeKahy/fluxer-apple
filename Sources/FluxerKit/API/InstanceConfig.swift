import Foundation

/// Endpoints and captcha settings for one Fluxer instance, read from the
/// window.__FLUXER_BOOTSTRAP__ JSON the web app origin serves. fluxer.app's
/// values are the defaults so the app works out of the box.
public struct InstanceConfig: Codable, Sendable, Equatable {
    public var webOrigin: URL
    public var apiBase: URL
    public var gatewayURL: URL
    public var mediaBase: URL
    public var staticBase: URL
    public var captchaProvider: String?
    public var hcaptchaSiteKey: String?
    public var turnstileSiteKey: String?

    public static let fluxerApp = InstanceConfig(
        webOrigin: URL(string: "https://web.fluxer.app")!,
        apiBase: URL(string: "https://api.fluxer.app/v1")!,
        gatewayURL: URL(string: "wss://gateway.fluxer.app/?v=1&encoding=json")!,
        mediaBase: URL(string: "https://fluxerusercontent.com")!,
        staticBase: URL(string: "https://fluxerstatic.com")!,
        captchaProvider: "hcaptcha",
        hcaptchaSiteKey: "9cbad400-df84-4e0c-bda6-e65000be78aa",
        turnstileSiteKey: nil
    )

    /// Loads the bootstrap config from an instance's web origin. Accepts
    /// bare hosts and normalises the gateway URL parameters.
    public static func load(from input: String, session: URLSession = .shared) async throws -> InstanceConfig {
        var candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.contains("://") {
            candidate = "https://" + candidate
        }
        guard let origin = URL(string: candidate), let host = origin.host() else {
            throw APIError.invalidURL(input)
        }
        let (data, _) = try await session.data(from: origin)
        guard let html = String(data: data, encoding: .utf8) else {
            throw APIError.decodingFailed(underlying: "No Fluxer bootstrap found at \(host)")
        }
        return try parse(html: html, origin: origin)
    }

    /// Parses the bootstrap JSON out of the web app's HTML.
    public static func parse(html: String, origin: URL) throws -> InstanceConfig {
        guard let host = origin.host(),
              let range = html.range(of: "__FLUXER_BOOTSTRAP__=")
        else {
            throw APIError.decodingFailed(underlying: "No Fluxer bootstrap found at \(origin)")
        }
        // The JSON object runs to the closing script tag.
        let tail = html[range.upperBound...]
        let end = tail.range(of: "</script>")?.lowerBound ?? tail.endIndex
        let jsonText = String(tail[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        let bootstrap = try JSONDecoder().decode(JSONValue.self, from: Data(jsonText.utf8))

        let instance = bootstrap["instance"]
        let endpoints = instance?["endpoints"]
        func url(_ key: String, fallback: URL) -> URL {
            endpoints?[key]?.stringValue.flatMap(URL.init(string:)) ?? fallback
        }
        let apiPublic = url("api_public", fallback: origin)
        var gateway = url("gateway", fallback: URL(string: "wss://\(host)")!)
        if gateway.query() == nil {
            gateway = URL(string: gateway.absoluteString + "/?v=1&encoding=json") ?? gateway
        }
        let captcha = instance?["captcha"]
        return InstanceConfig(
            webOrigin: url("webapp", fallback: origin),
            apiBase: apiPublic.appending(path: "v1"),
            gatewayURL: gateway,
            mediaBase: url("media", fallback: apiPublic),
            staticBase: url("static_cdn", fallback: apiPublic),
            captchaProvider: captcha?["provider"]?.stringValue,
            hcaptchaSiteKey: captcha?["hcaptcha_site_key"]?.stringValue,
            turnstileSiteKey: captcha?["turnstile_site_key"]?.stringValue
        )
    }
}
