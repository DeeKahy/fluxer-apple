import SwiftUI
import WebKit

/// Hosts the hCaptcha widget in a web view so the person signing in can
/// solve the challenge. The solved token is handed back through onToken.
/// The page is loaded with the official web app origin because hCaptcha
/// site keys only run on their allowed domains.
struct CaptchaView {
    static let hcaptchaSiteKey = "9cbad400-df84-4e0c-bda6-e65000be78aa"
    static let webOrigin = URL(string: "https://web.fluxer.app")!

    let onToken: @Sendable (String) -> Void

    fileprivate func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(MessageHandler(onToken: onToken), name: "captcha")
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(Self.pageHTML, baseURL: Self.webOrigin)
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

    private static let pageHTML = """
    <!doctype html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        body { margin: 0; display: flex; justify-content: center; align-items: center;
               min-height: 100vh; background: transparent; }
      </style>
      <script src="https://js.hcaptcha.com/1/api.js" async defer></script>
    </head>
    <body>
      <div class="h-captcha"
           data-sitekey="\(hcaptchaSiteKey)"
           data-callback="onCaptchaSolved"></div>
      <script>
        function onCaptchaSolved(token) {
          window.webkit.messageHandlers.captcha.postMessage(token);
        }
      </script>
    </body>
    </html>
    """
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
