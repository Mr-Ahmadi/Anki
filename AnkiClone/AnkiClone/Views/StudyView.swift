import SwiftUI
import SwiftData

// MARK: - StudyView

struct StudyView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var deck: Deck

    @Query private var deckCards: [Card]
    @Query private var noteTypes: [NoteType]

    @ObservedObject private var speech = SpeechService.shared

    @AppStorage("dailyNew") private var dailyNewLimit = 20
    @AppStorage("dailyReview") private var dailyReviewLimit = 200
    @AppStorage("study.useSmartLayout") private var useSmartLayout = true
    @AppStorage("study.showIntervals") private var showIntervals = true

    /// FIFO queue — the card being studied is always `queue.first`.
    @State private var queue: [Card] = []
    @State private var isFront = true
    @State private var intervals: [Rating: String] = [:]
    @State private var isAnswering = false
    @State private var finished = false
    @State private var studiedAll = false

    @State private var sessionTotal = 0
    @State private var sessionAnswered = 0
    @State private var sessionCorrect = 0
    @State private var sessionNew = 0
    @State private var sessionStart = Date()
    @State private var shownAt = Date()

    @State private var undoStack: [AnswerSnapshot] = []
    @State private var showVoiceSheet = false
    @State private var analyzedContent: CardContent?

    private let scheduler = Scheduler()

    init(deck: Deck) {
        self.deck = deck
        let deckId = deck.ankiId
        _deckCards = Query(filter: #Predicate<Card> { $0.deckId == deckId }, sort: \Card.dueDate)
        _noteTypes = Query()
    }

    // MARK: Derived

    private var currentCard: Card? { queue.first }

    private var currentNoteType: NoteType? {
        guard let modelId = currentCard?.note?.modelId else { return nil }
        return noteTypes.first { $0.ankiId == modelId }
    }

    /// Parsing a note's HTML is not free, and SwiftUI re-evaluates `body` many
    /// times per card. The result is computed once when the card changes.
    private var currentContent: CardContent? { analyzedContent }

    private var currentTemplate: CardTemplateData? {
        guard let card = currentCard, let noteType = currentNoteType else { return nil }
        return noteType.templates.first { $0.ord == card.ord } ?? noteType.templates.first
    }

    private var progress: Double {
        guard sessionTotal > 0 else { return 0 }
        return min(1, Double(sessionAnswered) / Double(sessionTotal))
    }

    /// Whether the smart layout can represent this note faithfully.
    private var canUseSmartLayout: Bool {
        guard useSmartLayout, let content = currentContent else { return false }
        guard content.isVocabulary else { return false }
        // Cloze cards and cards with images must go through the deck's own template.
        let html = (currentTemplate?.qfmt ?? "") + (currentTemplate?.afmt ?? "")
        if html.contains("{{cloze:") || html.contains("{{type:") { return false }
        let fields = currentCard?.note?.fieldValues.joined() ?? ""
        if fields.range(of: "<img", options: .caseInsensitive) != nil { return false }
        return true
    }

    // MARK: Body

    var body: some View {
        Group {
            if finished {
                SessionSummaryView(
                    deckName: deck.displayName,
                    answered: sessionAnswered,
                    correct: sessionCorrect,
                    newCards: sessionNew,
                    start: sessionStart,
                    canStudyMore: !studiedAll,
                    onStudyMore: { buildQueue(ignoringLimits: true) },
                    onDone: { dismiss() }
                )
            } else if queue.isEmpty {
                CaughtUpView(
                    deck: deck,
                    onStudyAhead: { buildQueue(ignoringLimits: true) },
                    onDone: { dismiss() }
                )
            } else {
                studyBody
            }
        }
        .navigationTitle(deck.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showVoiceSheet) {
            NavigationStack { PronunciationSettings(speech: speech) }
                .presentationDetents([.medium, .large])
        }
        .onAppear { if queue.isEmpty && !finished { buildQueue(ignoringLimits: false) } }
        .onDisappear { speech.stop() }
    }

    // MARK: Study body

    private var studyBody: some View {
        VStack(spacing: 0) {
            progressHeader

            ScrollView {
                VStack(spacing: 12) {
                    if let card = currentCard {
                        cardFace(for: card)
                            .id(card.ankiId)
                            .transition(.opacity)
                        metaFooter(for: card)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)

            // Answering stays reachable no matter how long the card is.
            actionArea
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .background(.bar)
        }
        .toolbar(.hidden, for: .tabBar)
        .animation(.easeInOut(duration: 0.22), value: isFront)
        .animation(.easeInOut(duration: 0.22), value: currentCard?.ankiId)
    }

    private var progressHeader: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, geometry.size.width * progress))
                }
            }
            .frame(height: 4)

            HStack(spacing: 10) {
                QueuePill(count: queue.filter { $0.type == 0 }.count, label: "new", color: .blue)
                QueuePill(count: queue.filter { $0.queue == 1 || $0.queue == 3 }.count, label: "learning", color: .orange)
                QueuePill(count: queue.filter { $0.queue == 2 }.count, label: "due", color: .green)
                Spacer()
                Text("\(sessionAnswered)/\(sessionTotal)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private func cardFace(for card: Card) -> some View {
        VStack(spacing: 0) {
            if canUseSmartLayout, let content = currentContent {
                smartFace(content: content)
            } else {
                templateFace(for: card)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { if isFront { reveal() } }
    }

    @ViewBuilder
    private func smartFace(content: CardContent) -> some View {
        VStack(spacing: 0) {
            WordHeaderView(content: content, speech: speech, compact: !isFront)
                .padding(.horizontal, 18)
                .padding(.top, isFront ? 36 : 20)
                .padding(.bottom, isFront ? 36 : 18)

            if !isFront {
                Divider()
                AnswerDetailView(content: content, speech: speech)
                    .padding(18)
            }
        }
    }

    @ViewBuilder
    private func templateFace(for card: Card) -> some View {
        let fields = card.note.map { TemplateRenderer.fieldsDictionary(note: $0, noteType: currentNoteType) } ?? [:]
        let question = currentTemplate.map {
            TemplateRenderer.render(template: $0.qfmt, fields: fields, noteType: currentNoteType)
        } ?? fallbackHTML(fields: fields, front: true)
        let html: String = {
            guard !isFront else { return question }
            guard let template = currentTemplate else { return fallbackHTML(fields: fields, front: false) }
            return TemplateRenderer.render(
                template: template.afmt, fields: fields, noteType: currentNoteType, frontSide: question
            )
        }()

        VStack(spacing: 0) {
            SizedCardWebView(html: html, baseURL: SpeechService.mediaDirectory, minHeight: isFront ? 150 : 200)
                .padding(.vertical, 6)

            if let content = currentContent, !content.headword.isBlank {
                Divider()
                HStack(spacing: 12) {
                    Button {
                        speech.speakWord(content.spokenHeadword, language: content.language, recordings: content.audioFilenames)
                    } label: {
                        Label("Word", systemImage: "speaker.wave.2.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if !isFront, !content.examples.isEmpty {
                        Button {
                            speech.speak(content.examples.map {
                                .init(id: $0.id, text: $0.text, language: $0.language ?? content.language)
                            })
                        } label: {
                            Label("Examples", systemImage: "quote.opening")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                    if speech.isSpeaking {
                        Button { speech.stop() } label: {
                            Image(systemName: "stop.circle.fill").font(.body)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        if isFront {
            Button { reveal() } label: {
                Text("Show Answer")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isAnswering)
            .accessibilityIdentifier("card.showAnswer")
        } else {
            HStack(spacing: 8) {
                ForEach(Rating.allCases) { rating in
                    Button { answer(rating) } label: {
                        VStack(spacing: 3) {
                            Text(rating.label)
                                .font(.subheadline.weight(.bold))
                            if showIntervals {
                                Text(intervals[rating] ?? " ")
                                    .font(.caption2.monospacedDigit())
                                    .opacity(0.85)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(rating.tint)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isAnswering)
                    .accessibilityIdentifier("rating.\(rating.label.lowercased())")
                    .accessibilityLabel(rating.label)
                }
            }
            .opacity(isAnswering ? 0.6 : 1)
        }
    }

    private func metaFooter(for card: Card) -> some View {
        HStack(spacing: 8) {
            if let tags = card.note?.tagList, !tags.isEmpty {
                Text(tags.prefix(3).map { "#\($0)" }.joined(separator: " "))
                    .lineLimit(1)
            }
            Spacer()
            Text(cardStateLabel(card))
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
    }

    private func cardStateLabel(_ card: Card) -> String {
        switch card.type {
        case 0: return "New card"
        case 1, 3: return "Learning · \(card.reps) reviews"
        default: return "\(card.interval)d interval · ease \(card.easeFactor / 10)% · \(card.reps) reviews"
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 4) {
                if speech.isSpeaking {
                    Button { speech.stop() } label: { Image(systemName: "stop.circle.fill") }
                        .accessibilityLabel("Stop audio")
                }
                Menu {
                    Section {
                        Button {
                            speech.autoPlay = speech.autoPlay == .off ? .word : .off
                        } label: {
                            Label(
                                speech.autoPlay == .off ? "Turn on auto-play" : "Turn off auto-play",
                                systemImage: speech.autoPlay == .off ? "speaker.wave.2" : "speaker.slash"
                            )
                        }
                        Button { showVoiceSheet = true } label: {
                            Label("Voice & speed…", systemImage: "slider.horizontal.3")
                        }
                    }
                    Section {
                        Toggle(isOn: $useSmartLayout) {
                            Label("Clean layout", systemImage: "textformat")
                        }
                        Toggle(isOn: $showIntervals) {
                            Label("Show intervals", systemImage: "timer")
                        }
                    }
                    Section {
                        Button { undoLastAnswer() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                            .disabled(undoStack.isEmpty)
                        Button { setQueueState(-1, label: "suspended") } label: {
                            Label("Suspend card", systemImage: "pause.circle")
                        }
                        Button { setQueueState(-2, label: "buried") } label: {
                            Label("Bury card", systemImage: "moon.zzz")
                        }
                    }
                    Section {
                        Button { buildQueue(ignoringLimits: false) } label: {
                            Label("Restart session", systemImage: "arrow.clockwise")
                        }
                        Button { buildQueue(ignoringLimits: true) } label: {
                            Label("Study all cards", systemImage: "books.vertical")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: Queue

    private func buildQueue(ignoringLimits: Bool) {
        speech.stop()
        let now = Date()
        let available = deckCards.filter { $0.queue >= 0 }

        var built: [Card]
        if ignoringLimits {
            built = available.sorted { lhs, rhs in
                if lhs.type != rhs.type { return lhs.type > rhs.type }
                return lhs.dueDate < rhs.dueDate
            }
        } else {
            // Anki's "learn ahead" window: a learning card due in the next few
            // minutes is worth showing rather than ending the session early.
            let learnAhead = now.addingTimeInterval(20 * 60)
            let learning = available.filter { ($0.queue == 1 || $0.queue == 3) && $0.dueDate <= learnAhead }
                .sorted { $0.dueDate < $1.dueDate }
            let due = available.filter { $0.queue == 2 && $0.dueDate <= now }
                .sorted { $0.dueDate < $1.dueDate }
                .prefix(max(0, dailyReviewLimit))
            let new = available.filter { $0.type == 0 && $0.queue == 0 }
                .sorted { $0.due < $1.due }
                .prefix(max(0, dailyNewLimit))
            built = learning + due + new
        }

        studiedAll = ignoringLimits
        queue = built
        sessionTotal = built.count
        sessionAnswered = 0
        sessionCorrect = 0
        sessionNew = 0
        sessionStart = now
        isFront = true
        isAnswering = false
        finished = false
        undoStack = []
        loadCurrentCard()
        autoPlayIfNeeded(front: true)
    }

    /// Recompute everything that depends on which card is at the front of the queue.
    private func loadCurrentCard() {
        shownAt = Date()
        guard let card = currentCard else {
            intervals = [:]
            analyzedContent = nil
            return
        }
        intervals = scheduler.nextIntervals(for: card)
        analyzedContent = card.note.map {
            CardContentAnalyzer.analyze(note: $0, noteType: currentNoteType)
        }
    }

    // MARK: Actions

    private func reveal() {
        guard isFront, !isAnswering else { return }
        speech.stop()
        withAnimation { isFront = false }
        loadCurrentCard()
        autoPlayIfNeeded(front: false)
    }

    private func autoPlayIfNeeded(front: Bool) {
        guard speech.autoPlay != .off, let content = currentContent, content.isVocabulary else { return }
        if front {
            if speech.preferRecordedAudio, let url = SpeechService.firstExistingMedia(in: content.audioFilenames) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard isFront, currentCard != nil else { return }
                    speech.playAudio(at: url)
                }
                return
            }
            speech.speakAfterDelay(
                [.init(text: content.spokenHeadword, language: content.language, kind: .word)],
                delay: 0.35
            )
        } else if speech.autoPlay == .wordAndExamples {
            var items: [SpeechService.Item] = [
                .init(text: content.spokenHeadword, language: content.language, kind: .word)
            ]
            items += content.examples.prefix(2).map {
                .init(id: $0.id, text: $0.text, language: $0.language ?? content.language)
            }
            speech.speakAfterDelay(items, delay: 0.3)
        }
    }

    private func answer(_ rating: Rating) {
        guard !isAnswering, let card = queue.first else { return }
        isAnswering = true
        speech.stop()

        undoStack.append(AnswerSnapshot(card: card, queue: queue, sessionTotal: sessionTotal))
        if undoStack.count > 20 { undoStack.removeFirst() }

        let previousType = card.type
        let previousInterval = card.interval
        let result = scheduler.answer(card: card, rating: rating, answeredAt: Date())
        scheduler.apply(result: result, to: card)

        modelContext.insert(ReviewLog(
            cardId: card.ankiId,
            ease: rating.rawValue,
            interval: result.newInterval,
            lastInterval: previousInterval,
            factor: result.newEaseFactor,
            timeMs: Int(Date().timeIntervalSince(shownAt) * 1000),
            type: previousType
        ))
        try? modelContext.save()

        sessionAnswered += 1
        if previousType == 0 { sessionNew += 1 }
        if rating != .again { sessionCorrect += 1 }

        queue.removeFirst()
        // A lapsed or still-learning card comes back later in the same session.
        if result.newQueue == 1 || result.newQueue == 3 {
            queue.insert(card, at: min(3, queue.count))
            sessionTotal += 1
        }

        if queue.isEmpty {
            withAnimation { finished = true }
            isAnswering = false
            return
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation { isFront = true }
            loadCurrentCard()
            isAnswering = false
            autoPlayIfNeeded(front: true)
        }
    }

    private func undoLastAnswer() {
        guard let snapshot = undoStack.popLast() else { return }
        speech.stop()
        snapshot.restore()
        queue = snapshot.queue
        sessionAnswered = max(0, sessionAnswered - 1)
        sessionTotal = snapshot.sessionTotal
        try? modelContext.save()
        finished = false
        isFront = false
        isAnswering = false
        loadCurrentCard()
    }

    private func setQueueState(_ value: Int, label: String) {
        guard let card = currentCard else { return }
        speech.stop()
        card.queue = value
        try? modelContext.save()
        queue.removeFirst()
        sessionTotal = max(sessionAnswered, sessionTotal - 1)
        if queue.isEmpty {
            withAnimation { finished = true }
        } else {
            withAnimation { isFront = true }
            loadCurrentCard()
        }
    }

    private func fallbackHTML(fields: [String: String], front: Bool) -> String {
        let ordered = fields.sorted { $0.key < $1.key }
        if front, let first = ordered.first {
            return "<div style=\"font-size:26px;font-weight:600\">\(first.value)</div>"
        }
        return ordered.map { "<div><b>\($0.key)</b><br>\($0.value)</div>" }.joined(separator: "<hr>")
    }
}

// MARK: - Undo snapshot

private struct AnswerSnapshot {
    let card: Card
    let queue: [Card]
    let sessionTotal: Int

    let type: Int
    let queueState: Int
    let due: Int64
    let dueDate: Date
    let interval: Int
    let easeFactor: Int
    let reps: Int
    let lapses: Int
    let left: Int

    init(card: Card, queue: [Card], sessionTotal: Int) {
        self.card = card
        self.queue = queue
        self.sessionTotal = sessionTotal
        type = card.type
        queueState = card.queue
        due = card.due
        dueDate = card.dueDate
        interval = card.interval
        easeFactor = card.easeFactor
        reps = card.reps
        lapses = card.lapses
        left = card.left
    }

    func restore() {
        card.type = type
        card.queue = queueState
        card.due = due
        card.dueDate = dueDate
        card.interval = interval
        card.easeFactor = easeFactor
        card.reps = reps
        card.lapses = lapses
        card.left = left
    }
}

// MARK: - Supporting views

private struct QueuePill: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color.opacity(count == 0 ? 0.3 : 1)).frame(width: 6, height: 6)
            Text("\(count)").font(.caption.weight(.bold).monospacedDigit())
            Text(label).font(.caption2)
        }
        .foregroundStyle(count == 0 ? .secondary : .primary)
    }
}

private struct CaughtUpView: View {
    let deck: Deck
    let onStudyAhead: () -> Void
    let onDone: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("All caught up", systemImage: "checkmark.circle.fill")
        } description: {
            Text("Nothing is due in \(deck.displayName) right now. \(deck.totalCount) cards in this deck.")
        } actions: {
            VStack(spacing: 10) {
                Button("Study ahead", action: onStudyAhead)
                    .buttonStyle(.borderedProminent)
                Button("Done", action: onDone)
                    .buttonStyle(.bordered)
            }
        }
    }
}

private struct SessionSummaryView: View {
    let deckName: String
    let answered: Int
    let correct: Int
    let newCards: Int
    let start: Date
    let canStudyMore: Bool
    let onStudyMore: () -> Void
    let onDone: () -> Void

    private var accuracy: String {
        guard answered > 0 else { return "—" }
        return "\(Int(Double(correct) / Double(answered) * 100))%"
    }

    private var elapsed: String {
        let seconds = Int(Date().timeIntervalSince(start))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 40)

                VStack(spacing: 6) {
                    Text("Session complete").font(.title2.weight(.bold))
                    Text(deckName).font(.subheadline).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    SummaryTile(value: "\(answered)", label: "Reviewed")
                    SummaryTile(value: accuracy, label: "Correct")
                    SummaryTile(value: elapsed, label: "Time")
                }
                .padding(.horizontal)

                if newCards > 0 {
                    Text("\(newCards) new card\(newCards == 1 ? "" : "s") learned")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    if canStudyMore {
                        Button("Study more", action: onStudyMore)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                    }
                    Button("Done", action: onDone)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .padding(.bottom, 40)
        }
    }
}

private struct SummaryTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.bold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

extension Rating {
    var tint: Color {
        switch self {
        case .again: return .red
        case .hard: return .orange
        case .good: return .green
        case .easy: return .blue
        }
    }
}
