import Foundation

// MARK: - Anki Template Renderer
// Handles {{Field}}, {{FrontSide}}, {{cloze:Text}}, conditionals {{#Field}}...{{/Field}} and {{^Field}}...{{/Field}},
// and the Anki filter : {{text:Field}}, {{type:Field}}

final class TemplateRenderer {

    // Render a template (qfmt/afmt) for a given note + card ordinal
    static func render(
        template: String,
        fields: [String: String],
        noteType: NoteType?,
        frontSide: String? = nil,
        mediaFolder: URL? = nil
    ) -> String {
        var result = template

        // Handle {{FrontSide}} replacement before anything else
        if let frontSide {
            result = result.replacingOccurrences(of: "{{FrontSide}}", with: frontSide)
            result = result.replacingOccurrences(of: "{{ FrontSide }}", with: frontSide)
        } else {
            // Remove FrontSide if not provided (question side)
            result = result.replacingOccurrences(of: "{{FrontSide}}", with: "")
            result = result.replacingOccurrences(of: "{{ FrontSide }}", with: "")
        }

        // Handle conditionals: {{#Field}}content{{/Field}} and {{^Field}}content{{/Field}}
        result = renderConditionals(result, fields: fields)

        // Handle cloze deletions: {{c1::text}} or {{c1::text::hint}}
        result = renderCloze(result, isQuestion: frontSide == nil)

        // Handle filters and field replacements
        // Pattern: {{filter:Field}} or {{Field}}
        let pattern = #"\{\{\s*([^}]+?)\s*\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }

        // Collect matches first (reverse order to avoid offset issues)
        let nsResult = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsResult.length)).reversed()

        let isQuestion = frontSide == nil
        for match in matches {
            let fullRange = match.range(at: 0)
            let innerRange = match.range(at: 1)
            let inner = nsResult.substring(with: innerRange).trimmingCharacters(in: .whitespaces)

            if inner.hasPrefix("#") || inner.hasPrefix("/") || inner.hasPrefix("^") { continue }
            if inner == "FrontSide" { continue }
            if inner.hasPrefix("c") && inner.dropFirst().first?.isNumber == true && inner.contains("::") { continue }

            let replacement = resolveField(expression: inner, fields: fields, isQuestion: isQuestion)
            let replacementNS = replacement as NSString
            if let range = Range(fullRange, in: result) {
                result.replaceSubrange(range, with: replacementNS as String)
            }
        }

        // Second pass: cloze inside field values (e.g., Text contains {{c1::...}} and template used {{cloze:Text}})
        // If cloze markers remain (from field injection), render them now.
        if result.contains("{{c") {
            result = renderCloze(result, isQuestion: isQuestion)
        }

        if let noteType, !noteType.css.isEmpty {
            result = wrapWithCSS(result, css: noteType.css)
        }

        result = convertSoundTags(result)
        result = tameEmbeddedMedia(result)

        return result
    }

    // MARK: - Field resolution

    private static func resolveField(expression: String, fields: [String: String], isQuestion: Bool = true) -> String {
        // Handle filters: text:, cloze:, etc.
        let parts = expression.components(separatedBy: ":")
        guard let fieldName = parts.last?.trimmingCharacters(in: .whitespaces) else { return "" }

        // Support cloze as part of expression like "cloze:Text" where mid is filter
        // If fieldName looks like "Text" but filter contains cloze, handle it.
        var value = fields[fieldName] ?? fields.first(where: { $0.key.lowercased() == fieldName.lowercased() })?.value ?? ""
        if value.isEmpty { return "" }

        for filter in parts.dropLast() {
            let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
            switch f {
            case "text":
                value = stripHTML(value)
            case "type":
                break
            case "hint":
                value = "<a class=\"hint\" href=\"#\" onclick=\"this.style.display='none';this.nextElementSibling.style.display='block';return false;\">[hint]</a><span style=\"display:none\">\(value)</span>"
            case "cloze":
                value = renderCloze(value, isQuestion: isQuestion)
            case "furigana", "kana", "kanji":
                // Remove ruby/furigana markup for clean display
                value = value.replacingOccurrences(of: " \\[.*?\\]", with: "", options: .regularExpression)
            default:
                break
            }
        }
        return value
    }

    // MARK: - Conditionals

    private static func renderConditionals(_ template: String, fields: [String: String]) -> String {
        var result = template
        // {{#Field}}...{{/Field}}  — show if field non-empty
        // {{^Field}}...{{/Field}}  — show if field empty
        for (fieldName, value) in fields {
            let isEmpty = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            // Positive conditional
            let openPos = "{{#\(fieldName)}}"
            let openPosSpaced = "{{# \(fieldName) }}"
            let close = "{{/\(fieldName)}}"
            let closeSpaced = "{{/ \(fieldName) }}"

            if !isEmpty {
                result = result.replacingOccurrences(of: openPos, with: "")
                result = result.replacingOccurrences(of: openPosSpaced, with: "")
                result = result.replacingOccurrences(of: close, with: "")
                result = result.replacingOccurrences(of: closeSpaced, with: "")
            } else {
                // Remove whole block
                result = removeConditionalBlock(result, fieldName: fieldName, positive: true)
            }

            // Negative conditional
            let openNeg = "{{^\(fieldName)}}"
            let openNegSpaced = "{{^ \(fieldName) }}"
            if isEmpty {
                result = result.replacingOccurrences(of: openNeg, with: "")
                result = result.replacingOccurrences(of: openNegSpaced, with: "")
                result = result.replacingOccurrences(of: close, with: "")
                result = result.replacingOccurrences(of: closeSpaced, with: "")
            } else {
                result = removeConditionalBlock(result, fieldName: fieldName, positive: false)
            }
        }
        return result
    }

    private static func removeConditionalBlock(_ template: String, fieldName: String, positive: Bool) -> String {
        var result = template
        let prefix = positive ? "#" : "^"
        // Use regex to remove {{#Field}}...{{/Field}} blocks
        let pattern = "\\{\\{\\s*\(NSRegularExpression.escapedPattern(for: prefix + fieldName))\\s*\\}\\}.*?\\{\\{\\s*/\\s*\(NSRegularExpression.escapedPattern(for: fieldName))\\s*\\}\\}"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        // Also handle spaced variants
        let altPattern = "\\{\\{\\s*\(NSRegularExpression.escapedPattern(for: prefix))\\s*\(NSRegularExpression.escapedPattern(for: fieldName))\\s*\\}\\}.*?\\{\\{\\s*/\\s*\(NSRegularExpression.escapedPattern(for: fieldName))\\s*\\}\\}"
        if let regex = try? NSRegularExpression(pattern: altPattern, options: [.dotMatchesLineSeparators]) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result
    }

    // MARK: - Cloze

    private static func renderCloze(_ template: String, isQuestion: Bool) -> String {
        var result = template
        // Anki cloze: {{c1::answer}} or {{c1::answer::hint}}
        // On question, show [...] or hint. On answer, show answer.
        let pattern = #"\{\{c(\d+)::(.*?)(?:::(.*?))?\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return result }

        let ns = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed()
        for match in matches {
            let fullRange = match.range(at: 0)
            let answerRange = match.range(at: 2)
            let hintRange = match.range(at: 3)

            let answer = answerRange.location != NSNotFound ? ns.substring(with: answerRange) : ""
            let hint = hintRange.location != NSNotFound ? ns.substring(with: hintRange) : ""

            let replacement: String
            if isQuestion {
                if !hint.isEmpty {
                    replacement = "<span class=\"cloze\">[\(hint)]</span>"
                } else {
                    replacement = "<span class=\"cloze\">[...]</span>"
                }
            } else {
                replacement = "<span class=\"cloze\">\(answer)</span>"
            }

            if let range = Range(fullRange, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func convertSoundTags(_ html: String) -> String {
        var result = html
        // [sound:filename.mp3] -> <audio controls src="filename.mp3">
        let pattern = #"\[sound:(.*?)\]"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed()
            for match in matches {
                let full = match.range(at: 0)
                let file = match.range(at: 1)
                let filename = ns.substring(with: file)
                let audio = "<audio controls src=\"\(filename)\"><source src=\"\(filename)\"></audio>"
                if let r = Range(full, in: result) {
                    result.replaceSubrange(r, with: audio)
                }
            }
        }
        return result
    }

    /// Anki decks in the wild embed `<audio autoplay>` pointing at a dictionary
    /// site — sometimes several per card. Left alone they fire on every card,
    /// overlap each other, and (over plain http) are blocked outright. Strip the
    /// autoplay, give them controls, and upgrade the scheme so a tap can work.
    private static func tameEmbeddedMedia(_ html: String) -> String {
        var result = html
        result = result.replacingOccurrences(
            of: #"\s+autoplay(\s*=\s*("[^"]*"|'[^']*'|[^\s>]+))?"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: #"(<audio\b)(?![^>]*\bcontrols\b)"#,
            with: "$1 controls preload=\"none\"",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: #"(src\s*=\s*["\']?)http://"#,
            with: "$1https://",
            options: [.regularExpression, .caseInsensitive]
        )
        return result
    }

    private static func wrapWithCSS(_ html: String, css: String) -> String {
        // We do NOT double-wrap if already has <html>
        if html.lowercased().contains("<html") { return html }
        return """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1.0"><style>\(css)
        .cloze { font-weight: bold; color: #2962FF; }
        .cloze b, .cloze i { color: #2962FF; }
        </style></head><body class="card">\(html)</body></html>
        """
    }

    // Build field dictionary from note
    static func fieldsDictionary(note: Note, noteType: NoteType?) -> [String: String] {
        guard let noteType else {
            // Fallback: Field1, Field2...
            var dict: [String: String] = [:]
            for (i, val) in note.fieldValues.enumerated() {
                dict["Field\(i+1)"] = val
                dict["field\(i+1)"] = val
            }
            return dict
        }
        var dict: [String: String] = [:]
        for (idx, name) in noteType.fieldNames.enumerated() {
            if idx < note.fieldValues.count {
                dict[name] = note.fieldValues[idx]
            } else {
                dict[name] = ""
            }
        }
        return dict
    }
}
