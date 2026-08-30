import Foundation

// MARK: - HTMLText
// A tiny, dependency-free HTML scanner that turns Anki field HTML into
// *blocks* of plain text that remember the markup context they came from
// (italic, list item, class names, …). CardContentAnalyzer uses that context
// to tell a definition apart from an example sentence.

struct HTMLBlock {
    var text: String
    var isItalic = false
    var isBold = false
    var isListItem = false
    var isLink = false
    /// CSS classes seen on any ancestor of this text, lowercased.
    var classes: Set<String> = []
    /// `color:` value from an ancestor inline style, lowercased and stripped.
    var color: String?
    /// Nesting depth of block-level elements — used only for ordering stability.
    var depth = 0

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum HTMLText {

    /// Block-level tags that end the current text block.
    private static let blockTags: Set<String> = [
        "div", "p", "br", "hr", "li", "ul", "ol", "tr", "td", "th", "table",
        "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "section", "article", "figure",
    ]

    /// Tags whose *content* should be dropped entirely.
    private static let dropTags: Set<String> = ["style", "script", "head", "title", "audio", "video", "source"]

    // MARK: - Public

    /// Flatten HTML to a single plain-text string (entities decoded, whitespace collapsed).
    static func plainText(_ html: String) -> String {
        let joined = blocks(html).map(\.text).joined(separator: " ")
        return strippingResidualTags(joined).collapsedWhitespace
    }

    /// A tag: `<`, a letter, then anything up to the matching `>`. Requiring a
    /// letter immediately after `<` is what keeps "5 < 6" and "a<b" intact.
    private static let residualTagPattern = "</?[A-Za-z][A-Za-z0-9]*(\\s[^<>]*)?/?>"

    /// Remove markup that only *became* markup after entity decoding.
    ///
    /// Fields exported from web scrapers are routinely double-encoded, so
    /// `&lt;div&gt;` survives the structural pass as literal text and would then
    /// be read aloud as "less than div greater than". Decoding and stripping
    /// alternate until the text stops changing.
    static func strippingResidualTags(_ text: String) -> String {
        var current = text
        // Each round decodes one layer of encoding and strips whatever markup
        // that exposed; triple-encoded fields need more than one pass.
        for _ in 0..<3 {
            let stripped = decodeEntities(current)
                .replacingOccurrences(of: residualTagPattern, with: " ", options: .regularExpression)
            if stripped == current { break }
            current = stripped
        }
        return current
    }

    /// Split HTML into context-carrying blocks. Empty blocks are omitted.
    ///
    /// A block is the text between two block-level boundaries (`</div>`, `<br>`, `<li>`, …).
    /// Inline markup inside it is kept as *runs*, and the block's italic/bold/link flags
    /// are decided by which style covers most of the text — so a sentence wrapped in
    /// `<i>…<a>word</a>…</i>` still reads as one italic sentence rather than five fragments.
    static func blocks(_ html: String) -> [HTMLBlock] {
        var out: [HTMLBlock] = []
        var stack: [OpenTag] = []
        var runs: [(text: String, italic: Bool, bold: Bool, link: Bool)] = []
        var buffer = ""
        var dropDepth = 0
        var blockDepth = 0
        var blockClasses: Set<String> = []
        var blockColor: String?
        var inListItem = false

        /// Close the current run, snapshotting the inline styles that apply to it.
        func endRun() {
            let text = decodeEntities(buffer)
            buffer = ""
            guard !text.collapsedWhitespace.isEmpty else {
                // A run of pure whitespace (often `&nbsp;` between two inline
                // tags) still separates the words on either side of it.
                if !text.isEmpty, !runs.isEmpty { runs.append((" ", false, false, false)) }
                return
            }
            var italic = false, bold = false, link = false
            for tag in stack {
                switch tag.name {
                case "i", "em": italic = true
                case "b", "strong": bold = true
                case "a": link = true
                default: break
                }
                if tag.style.contains("italic") { italic = true }
                if tag.style.contains("bold") || tag.style.range(of: #"font-weight\s*:\s*[6-9]"#, options: .regularExpression) != nil {
                    bold = true
                }
                blockClasses.formUnion(tag.classes)
                if let c = tag.color { blockColor = c }
            }
            runs.append((text, italic, bold, link))
        }

        func flush() {
            endRun()
            defer { runs = []; blockClasses = []; blockColor = nil }
            let text = runs.map(\.text).joined().collapsedWhitespace
            guard !text.isEmpty else { return }
            let total = max(1, runs.reduce(0) { $0 + $1.text.collapsedWhitespace.count })
            func majority(_ key: (Int) -> Bool) -> Bool {
                let covered = runs.enumerated().reduce(0) { sum, pair in
                    key(pair.offset) ? sum + pair.element.text.collapsedWhitespace.count : sum
                }
                return Double(covered) / Double(total) > 0.6
            }
            out.append(HTMLBlock(
                text: text,
                isItalic: majority { runs[$0].italic },
                isBold: majority { runs[$0].bold },
                isListItem: inListItem,
                isLink: majority { runs[$0].link },
                classes: blockClasses,
                color: blockColor,
                depth: blockDepth
            ))
        }

        let scalars = Array(html)
        var i = 0
        while i < scalars.count {
            let ch = scalars[i]
            // Only `<` followed by a name, `/`, `!` or `?` opens a tag; a bare
            // `<` is prose ("5 < 6") and must survive as text.
            let opensTag: Bool = {
                guard ch == "<", i + 1 < scalars.count else { return false }
                let next = scalars[i + 1]
                return next.isLetter || next == "/" || next == "!" || next == "?"
            }()
            if opensTag {
                // Comment?
                if scalars.count > i + 3, scalars[i + 1] == "!", scalars[i + 2] == "-", scalars[i + 3] == "-" {
                    var j = i + 4
                    while j + 2 < scalars.count, !(scalars[j] == "-" && scalars[j + 1] == "-" && scalars[j + 2] == ">") { j += 1 }
                    i = min(scalars.count, j + 3)
                    continue
                }
                // Find the end of the tag.
                var j = i + 1
                var inQuote: Character?
                while j < scalars.count {
                    let c = scalars[j]
                    if let q = inQuote {
                        if c == q { inQuote = nil }
                    } else if c == "\"" || c == "'" {
                        inQuote = c
                    } else if c == ">" {
                        break
                    }
                    j += 1
                }
                guard j < scalars.count else { break } // unterminated tag — drop the rest
                let raw = String(scalars[(i + 1)..<j])
                i = j + 1

                let isClosing = raw.hasPrefix("/")
                let body = isClosing ? String(raw.dropFirst()) : raw
                let name = body.prefix(while: { !$0.isWhitespace && $0 != "/" }).lowercased()
                guard !name.isEmpty else { continue }

                if dropTags.contains(name) {
                    if !isClosing { flush() }
                    if isClosing { dropDepth = max(0, dropDepth - 1) } else if !body.hasSuffix("/") { dropDepth += 1 }
                    continue
                }
                if dropDepth > 0 { continue }

                let isBlock = blockTags.contains(name)
                if isBlock { flush() }

                if isClosing {
                    if let idx = stack.lastIndex(where: { $0.name == name }) {
                        if !isBlock { endRun() }
                        stack.removeSubrange(idx...)
                    }
                    if isBlock { blockDepth = max(0, blockDepth - 1) }
                } else if !body.hasSuffix("/") && !voidTags.contains(name) {
                    if !isBlock { endRun() }
                    stack.append(OpenTag(name: name, attributes: body))
                    if isBlock { blockDepth += 1 }
                }
                inListItem = stack.contains { $0.name == "li" }
                continue
            }
            if dropDepth == 0 { buffer.append(ch) }
            i += 1
        }
        flush()
        return out.filter { !$0.isEmpty }
    }

    private static let voidTags: Set<String> = ["img", "br", "hr", "input", "meta", "link", "source"]

    // MARK: - Entities

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var t = s
        let simple: [(String, String)] = [
            ("&nbsp;", " "), ("&#160;", " "), ("&#xa0;", " "),
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#34;", "\""),
            ("&apos;", "'"), ("&#39;", "'"), ("&#x27;", "'"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
            ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&ldquo;", "“"), ("&rdquo;", "”"),
            ("&bull;", "•"), ("&middot;", "·"), ("&times;", "×"), ("&deg;", "°"),
            ("&amp;", "&"), // last: so "&amp;lt;" doesn't become "<"
        ]
        for (from, to) in simple {
            t = t.replacingOccurrences(of: from, with: to, options: .caseInsensitive)
        }
        // Numeric entities: &#233; and &#xE9;
        guard t.contains("&#"),
              let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);", options: .caseInsensitive)
        else { return t }
        let ns = t as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let isHex = !ns.substring(with: match.range(at: 1)).isEmpty
            let digits = ns.substring(with: match.range(at: 2))
            if let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                result.append(Character(scalar))
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    // MARK: - Helper type

    private struct OpenTag {
        let name: String
        let classes: Set<String>
        let style: String
        let color: String?

        init(name: String, attributes: String) {
            self.name = name
            let lower = attributes.lowercased()
            self.classes = Set(Self.attribute("class", in: lower)?
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init) ?? [])
            let style = Self.attribute("style", in: lower) ?? ""
            self.style = style
            if let range = style.range(of: #"color\s*:\s*([^;]+)"#, options: .regularExpression) {
                let value = style[range].split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces)
                self.color = value
            } else {
                self.color = nil
            }
        }

        private static func attribute(_ name: String, in attributes: String) -> String? {
            guard let range = attributes.range(
                of: "\(name)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
                options: .regularExpression
            ) else { return nil }
            let raw = attributes[range].split(separator: "=", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }
}

// MARK: - String helpers

extension StringProtocol {
    /// Collapse every run of whitespace (including NBSP) into one space and trim.
    var collapsedWhitespace: String {
        String(self)
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip HTML tags without any block analysis. Cheap, for list rows and search.
    var strippingHTML: String { HTMLText.plainText(String(self)) }

    var isBlank: Bool { String(self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
