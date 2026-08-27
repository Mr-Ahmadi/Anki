import SwiftUI
import WebKit
import AVFoundation

struct CardWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    var onHeightChange: ((CGFloat) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        // Observe content size if needed
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Avoid reloading if same html
        if context.coordinator.lastHTML == html { return }
        context.coordinator.lastHTML = html

        let header = """
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        """
        let fullHTML: String
        if html.lowercased().contains("<html") {
            fullHTML = html
        } else {
            fullHTML = """
            <html><head>\(header)<style>
            :root { color-scheme: light dark; }
            body {
                font-family: -apple-system, 'Helvetica Neue', sans-serif;
                font-size: 20px;
                line-height: 1.5;
                text-align: center;
                color: #1a1a1a;
                background: transparent;
                padding: 16px 12px;
                margin: 0;
                word-wrap: break-word;
                -webkit-text-size-adjust: 100%;
            }
            @media (prefers-color-scheme: dark) {
                body { color: #e8e8e8; }
                a { color: #5B8DEF; }
                hr#answer { border-color: #333 !important; }
            }
            img { max-width: 100%; height: auto; border-radius: 12px; margin: 8px 0; }
            a { color: #2962FF; text-decoration: none; font-weight: 600; }
            .cloze { color: #2962FF; font-weight: 800; background: rgba(41,98,255,0.08); padding: 1px 6px; border-radius: 6px; }
            .cloze b, .cloze i { color: #2962FF; }
            hr#answer, hr { border: none; border-top: 1.5px solid #e8e8e8; margin: 18px 0; }
            audio {
                width: 100%; margin: 12px 0; border-radius: 10px;
                background: #f2f2f7;
            }
            @media (prefers-color-scheme: dark) { audio { background: #2c2c2e; } }
            .card { max-width: 100%; }
            b, strong { font-weight: 700; }
            </style></head><body class="card">\(html)</body></html>
            """
        }
        webView.loadHTMLString(fullHTML, baseURL: baseURL ?? mediaBaseURL())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func mediaBaseURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AnkiMedia", isDirectory: true)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                // Intercept audio/image local files - allow
                if url.isFileURL { decisionHandler(.allow); return }
                // Allow media baseURL resources
                if url.scheme == "about" || url.scheme == "data" { decisionHandler(.allow); return }
                // For http/https links, open externally if it's a navigation (not resource load)
                if (url.scheme == "http" || url.scheme == "https") && navigationAction.navigationType == .linkActivated {
                    UIApplication.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Enable audio controls fix for Anki sound tags already converted to <audio>
            // No extra JS needed - WKWebView handles audio playback inline
        }
    }
}

// Simpler previewable view

struct CardContentView: View {
    let html: String
    var baseURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AnkiMedia", isDirectory: true)
    }

    var body: some View {
        CardWebView(html: html, baseURL: baseURL)
            .frame(minHeight: 220)
    }
}
