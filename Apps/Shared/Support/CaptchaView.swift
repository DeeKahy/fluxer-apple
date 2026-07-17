import SwiftUI
import WebKit
import FluxerKit

/// Hosts the hCaptcha widget in a web view so the person signing in can
/// solve the challenge. The solved token is handed back through onToken.
/// The page is loaded with the official web app origin because hCaptcha
/// site keys only run on their allowed domains.
struct CaptchaView {
    let config: InstanceConfig
    let onToken: @Sendable (String) -> Void

    fileprivate func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(MessageHandler(onToken: onToken), name: "captcha")
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(pageHTML, baseURL: config.webOrigin)
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #endif
        return webView
    }

    private final class MessageHandler: NSObject, WKScriptMessageHandler {
        let onToken: @Sendable (String) -> Void

        init(onToken: @escaping @Sendable (String) -> Void) {
            self.onToken = onToken
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if let token = message.body as? String, !token.isEmpty {
                onToken(token)
            }
        }
    }

    private var pageHTML: String {
        let useTurnstile = config.captchaProvider == "turnstile" && config.turnstileSiteKey != nil
        let script = useTurnstile
            ? "https://challenges.cloudflare.com/turnstile/v0/api.js"
            : "https://js.hcaptcha.com/1/api.js"
        let widget = useTurnstile
            ? "<div class=\"cf-turnstile\" data-sitekey=\"\(config.turnstileSiteKey ?? "")\" data-callback=\"onCaptchaSolved\"></div>"
            : "<div class=\"h-captcha\" data-sitekey=\"\(config.hcaptchaSiteKey ?? "")\" data-callback=\"onCaptchaSolved\"></div>"
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            body { margin: 0; display: flex; justify-content: center; align-items: center;
                   min-height: 100vh; background: transparent; }
          </style>
          <script src="\(script)" async defer></script>
        </head>
        <body>
          \(widget)
          <script>
            function onCaptchaSolved(token) {
              window.webkit.messageHandlers.captcha.postMessage(token);
            }
          </script>
        </body>
        </html>
        """
    }
}

#if os(iOS)
extension CaptchaView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
extension CaptchaView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
