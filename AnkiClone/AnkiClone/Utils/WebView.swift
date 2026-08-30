import SwiftUI
import WebKit

// MARK: - CardWebView
// Renders a card's Anki HTML with its own CSS and media.
//
// Two things every deck in the wild needs and plain WKWebView doesn't give you:
//
//  * **Self-sizing.** A card is one item in a scrolling column, so the web view
//    must be exactly as tall as its content — a fixed frame either clips long
//    answers or leaves a hole under short ones.
//  * **Readable in dark mode.** Shared decks hardcode `color: black` inline
//    (the TOEFL sample does it on every field). On a dark background that is
//    invisible. After load we lighten only the colours that are too dark to
//    read, keeping their hue so the deck's own colour-coding survives.

struct CardWebView: UIViewRepresentable {
    let html: String
    var baseURL: URL?
    /// Reports the rendered content height so the container can size itself.
    var onHeightChange: ((CGFloat) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(context.coordinator, name: Coordinator.heightMessage)
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.instrumentation, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.setContentHuggingPriority(.required, for: .vertical)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onHeightChange = onHeightChange
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        let document = html.lowercased().contains("<html") ? html : Self.wrap(html)
        webView.loadHTMLString(document, baseURL: baseURL ?? SpeechService.mediaDirectory)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.heightMessage)
        webView.stopLoading()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onHeightChange: onHeightChange) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let heightMessage = "cardHeight"

        var loadedHTML: String?
        var onHeightChange: ((CGFloat) -> Void)?
        private var lastReportedHeight: CGFloat = 0

        init(onHeightChange: ((CGFloat) -> Void)?) {
            self.onHeightChange = onHeightChange
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.heightMessage, let value = message.body as? NSNumber else { return }
            let height = CGFloat(value.doubleValue)
            // Ignore sub-point jitter from font loading.
            guard height > 0, abs(height - lastReportedHeight) > 1 else { return }
            lastReportedHeight = height
            onHeightChange?(height)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
            if navigationAction.navigationType == .linkActivated,
               url.scheme == "http" || url.scheme == "https" {
                UIApplication.shared.open(url)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
    }

    // MARK: - Page scaffolding

    /// Injected after the document loads: reports height and repairs unreadable colours.
    private static let instrumentation = """
    (function () {
      function report() {
        var body = document.body;
        if (!body) { return; }
        var height = Math.max(
          body.scrollHeight, body.offsetHeight,
          document.documentElement.scrollHeight, document.documentElement.offsetHeight
        );
        window.webkit.messageHandlers.cardHeight.postMessage(height);
      }

      // Shared decks hardcode dark text inline. Lift only what is too dark to
      // read on a dark background, preserving hue so colour coding survives.
      function repairContrast() {
        if (!window.matchMedia('(prefers-color-scheme: dark)').matches) { return; }
        var nodes = document.querySelectorAll('*');
        for (var i = 0; i < nodes.length; i++) {
          var node = nodes[i];
          var parsed = /rgba?\\(([^)]+)\\)/.exec(window.getComputedStyle(node).color);
          if (!parsed) { continue; }
          var parts = parsed[1].split(',').map(parseFloat);
          var r = parts[0] / 255, g = parts[1] / 255, b = parts[2] / 255;
          var max = Math.max(r, g, b), min = Math.min(r, g, b);
          var lightness = (max + min) / 2;
          if (lightness > 0.45) { continue; }
          if (max - min < 0.08) {
            node.style.color = '#F2F2F7';
          } else {
            var hue, delta = max - min;
            if (max === r) { hue = ((g - b) / delta) % 6; }
            else if (max === g) { hue = (b - r) / delta + 2; }
            else { hue = (r - g) / delta + 4; }
            hue = Math.round(hue * 60);
            if (hue < 0) { hue += 360; }
            var saturation = Math.round((delta / (1 - Math.abs(2 * lightness - 1))) * 100);
            node.style.color = 'hsl(' + hue + ',' + Math.min(saturation, 90) + '%,72%)';
          }
        }
      }

      repairContrast();
      report();
      if (window.ResizeObserver) { new ResizeObserver(report).observe(document.body); }
      window.addEventListener('load', function () { repairContrast(); report(); });
      document.querySelectorAll('img').forEach(function (img) {
        img.addEventListener('load', report);
        img.addEventListener('error', report);
      });
      setTimeout(report, 120);
      setTimeout(report, 500);
    })();
    """

    static func wrap(_ body: String) -> String {
        """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
        :root { color-scheme: light dark; --ink: #10131A; --muted: #6B7280; --accent: #4C5BD4; --rule: #E6E8EE; }
        @media (prefers-color-scheme: dark) {
          :root { --ink: #F2F2F7; --muted: #9BA1AC; --accent: #93A6FF; --rule: #33363D; }
        }
        * { box-sizing: border-box; }
        html { -webkit-text-size-adjust: 100%; }
        body {
          font: 400 20px/1.55 -apple-system, system-ui, "SF Pro Text", "Helvetica Neue", sans-serif;
          color: var(--ink);
          background: transparent;
          margin: 0;
          padding: 16px 18px;
          text-align: center;
          overflow-wrap: break-word;
          -webkit-font-smoothing: antialiased;
        }
        .card { max-width: 680px; margin: 0 auto; background: transparent; }
        a { color: var(--accent); text-decoration: none; font-weight: 500; }
        img { max-width: 100%; height: auto; border-radius: 12px; margin: 10px 0; }
        hr, hr#answer { border: none; border-top: 1px solid var(--rule); margin: 18px 0; }
        audio { width: 100%; max-width: 320px; height: 36px; margin: 8px 0; }
        ul, ol { text-align: left; padding-left: 1.2em; margin: 10px 0; }
        li { margin: 4px 0; }
        sub, sup { font-size: 0.7em; }
        .cloze { color: var(--accent); font-weight: 700; }
        .hint { color: var(--muted); font-style: italic; }
        </style>
        </head><body class="card">\(body)</body></html>
        """
    }
}

// MARK: - SizedCardWebView

/// `CardWebView` that grows to fit its content, with a floor so an empty or
/// still-loading card doesn't collapse.
struct SizedCardWebView: View {
    let html: String
    var baseURL: URL?
    var minHeight: CGFloat = 90
    var maxHeight: CGFloat = 2600

    @State private var height: CGFloat = 0

    var body: some View {
        CardWebView(html: html, baseURL: baseURL) { measured in
            let clamped = min(max(measured, minHeight), maxHeight)
            guard abs(clamped - height) > 1 else { return }
            height = clamped
        }
        .frame(height: max(height, minHeight))
        .animation(.easeOut(duration: 0.18), value: height)
    }
}
