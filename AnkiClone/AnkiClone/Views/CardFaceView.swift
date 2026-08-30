import SwiftUI

// MARK: - Card faces
// The "smart" presentation of a note: the word on its own, its meaning, and its
// examples as separate, separately-playable blocks. Falls back to the deck's own
// HTML template whenever a note doesn't parse into that shape.

// MARK: Word header

struct WordHeaderView: View {
    let content: CardContent
    @ObservedObject var speech: SpeechService
    var compact = false
    var showPlayButton = true

    private var recordings: [String] { content.audioFilenames }

    var body: some View {
        VStack(spacing: compact ? 6 : 12) {
            if let pos = content.partOfSpeech, !compact {
                Text(pos.uppercased())
                    .font(.caption2.weight(.heavy))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }

            Text(content.headword)
                .font(compact ? .title3.weight(.bold) : .system(size: 38, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .lineLimit(3)
                .textSelection(.enabled)

            if let phonetic = content.phonetic, !phonetic.isBlank {
                Text(phonetic)
                    .font(compact ? .caption : .title3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if showPlayButton {
                Button {
                    speech.speakWord(content.spokenHeadword, language: content.language, recordings: recordings)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: speech.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                            .contentTransition(.symbolEffect(.replace))
                        Text(compact ? "Word" : "Hear the word")
                            .fontWeight(.semibold)
                    }
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, compact ? 14 : 20)
                    .padding(.vertical, compact ? 8 : 11)
                    .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("card.speakWord")
                .accessibilityLabel("Pronounce \(content.headword)")
                .sensoryFeedback(.impact(weight: .light), trigger: speech.currentItemID)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Answer detail

struct AnswerDetailView: View {
    let content: CardContent
    @ObservedObject var speech: SpeechService

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !content.definitions.isEmpty {
                CardSection(title: "Meaning", icon: "text.book.closed.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(content.definitions.enumerated()), id: \.offset) { index, definition in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if content.definitions.count > 1 {
                                    Text("\(index + 1)")
                                        .font(.caption2.weight(.bold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16, alignment: .trailing)
                                }
                                Text(definition)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }

            if !content.examples.isEmpty {
                CardSection(
                    title: "Examples",
                    icon: "quote.opening",
                    accessory: {
                        Button {
                            speech.speak(content.examples.map {
                                .init(id: $0.id, text: $0.text, language: $0.language ?? content.language, kind: .sentence)
                            })
                        } label: {
                            Label("Play all", systemImage: "play.circle.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("card.playAllExamples")
                        .foregroundStyle(Color.accentColor)
                    }
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(content.examples) { example in
                            ExampleRow(
                                example: example,
                                fallbackLanguage: content.language,
                                speech: speech,
                                isSpeaking: speech.currentItemID == example.id
                            )
                        }
                    }
                }
            }

            if !content.synonyms.isEmpty {
                CardSection(title: "Synonyms", icon: "arrow.triangle.swap") {
                    ChipRow(values: content.synonyms, tint: .green) { value in
                        speech.speakWord(value, language: content.language)
                    }
                }
            }

            if !content.antonyms.isEmpty {
                CardSection(title: "Opposites", icon: "arrow.left.arrow.right") {
                    ChipRow(values: content.antonyms, tint: .orange) { value in
                        speech.speakWord(value, language: content.language)
                    }
                }
            }

            ForEach(content.translations) { translation in
                CardSection(
                    title: translation.language.map(Language.displayName) ?? translation.label,
                    icon: "character.book.closed",
                    accessory: {
                        if let language = translation.language, speech.bestVoice(for: language) != nil {
                            Button {
                                speech.speak(translation.text, language: language)
                            } label: {
                                Image(systemName: "speaker.wave.2.fill").font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                ) {
                    Text(translation.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.layoutDirection, Language.isRightToLeft(translation.language) ? .rightToLeft : .leftToRight)
                }
            }

            if !content.extras.isEmpty {
                CardSection(title: "More", icon: "ellipsis.circle") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(content.extras) { extra in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(extra.label.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .tracking(0.6)
                                    .foregroundStyle(.tertiary)
                                Text(extra.text)
                                    .font(.subheadline)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}

// MARK: Pieces

struct ExampleRow: View {
    let example: CardContent.Example
    let fallbackLanguage: String
    @ObservedObject var speech: SpeechService
    let isSpeaking: Bool

    var body: some View {
        Button {
            speech.speak([.init(id: example.id, text: example.text, language: example.language ?? fallbackLanguage)])
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2")
                    .font(.footnote)
                    .foregroundStyle(isSpeaking ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                    .padding(.top, 2)
                Text(example.text)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSpeaking ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play example: \(example.text)")
    }
}

struct CardSection<Content: View, Accessory: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        icon: String,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption2)
                Text(title.uppercased())
                    .font(.caption2.weight(.heavy))
                    .tracking(0.9)
                Spacer()
                accessory()
            }
            .foregroundStyle(.secondary)
            content()
        }
    }
}

struct ChipRow: View {
    let values: [String]
    let tint: Color
    var onTap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(values, id: \.self) { value in
                Button { onTap(value) } label: {
                    Text(value)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(tint.opacity(0.14)))
                        .foregroundStyle(tint)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Wrapping row of chips — `HStack` clips, `Grid` can't size to content.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.width == 0 ? size.width : current.width + spacing + size.width
            if projected > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.indices.append(index)
            current.width = current.width == 0 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

extension Language {
    static func isRightToLeft(_ code: String?) -> Bool {
        guard let code else { return false }
        return ["fa", "ar", "he", "ur", "ps"].contains(base(of: code))
    }
}
