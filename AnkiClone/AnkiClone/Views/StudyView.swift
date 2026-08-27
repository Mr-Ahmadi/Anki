import SwiftUI
import SwiftData
import AVFoundation

struct StudyView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var deck: Deck

    @Query private var allCards: [Card]
    @Query private var noteTypes: [NoteType]

    @StateObject private var speech = SpeechService()
    @State private var queue: [Card] = []
    @State private var currentIndex = 0
    @State private var isFront = true
    @State private var sessionNew = 0
    @State private var sessionCorrect = 0
    @State private var sessionTotal = 0
    @State private var sessionStart = Date()
    @State private var intervals: [Rating: String] = [:]
    @State private var scheduler = Scheduler()
    @State private var answerTime = Date()
    @State private var finished = false
    @State private var isAnswering = false
    @State private var cardRotation: Double = 0
    @State private var showAnswerButtons = false
    @State private var dragOffset: CGFloat = 0

    // Derived
    private var currentCard: Card? {
        guard !queue.isEmpty, currentIndex >= 0, currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }
    private var progress: Double {
        guard !queue.isEmpty else { return 0 }
        return Double(sessionTotal - queue.count) / Double(max(1, sessionTotal))
    }

    init(deck: Deck) {
        self.deck = deck
        let deckId = deck.ankiId
        self._allCards = Query(filter: #Predicate<Card> { $0.deckId == deckId }, sort: \Card.dueDate)
        self._noteTypes = Query()
    }

    var body: some View {
        Group {
            if queue.isEmpty && !finished {
                noCardsView
            } else if finished {
                finishedView
            } else {
                studyBody
            }
        }
        .navigationTitle(deck.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .onAppear {
            rebuildQueue(includeAll: false)
        }
        .onDisappear { speech.stop() }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isFront)
        .animation(.spring(response: 0.3), value: currentIndex)
        .sensoryFeedback(.selection, trigger: currentIndex)
    }

    // MARK: - Toolbar
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 8) {
                if !queue.isEmpty {
                    Text("\(min(currentIndex + 1, queue.count)) / \(sessionTotal)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                // TTS quick toggle
                Button {
                    speakCurrent()
                } label: {
                    Image(systemName: speech.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(speech.isSpeaking ? .blue : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .disabled(currentCard == nil)

                Menu {
                    Button { rebuildQueue(includeAll: false) } label: { Label("Rebuild Queue", systemImage: "arrow.triangle.2.circlepath") }
                    Button { rebuildQueue(includeAll: true) } label: { Label("Study All", systemImage: "books.vertical") }
                    Divider()
                    Button { speakCurrent() } label: { Label(speech.isSpeaking ? "Stop Pronunciation" : "Pronounce", systemImage: "speaker.wave.2") }
                    Button { speech.autoPlay.toggle() } label: { Label(speech.autoPlay ? "Disable Auto-Play" : "Enable Auto-Play", systemImage: speech.autoPlay ? "speaker.slash" : "speaker") }
                    Divider()
                    Button(role: .destructive) { suspendCurrent() } label: { Label("Suspend Card", systemImage: "pause.circle") }
                    Button(role: .destructive) { buryCurrent() } label: { Label("Bury Card", systemImage: "moon") }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - No cards
    private var noCardsView: some View {
        ContentUnavailableView {
            Label("All Caught Up!", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } description: {
            VStack(spacing: 8) {
                Text("You're all caught up in \"\(deck.displayName)\"")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 12) {
                    PillCount(value: deck.newCount, label: "New", color: .blue)
                    PillCount(value: deck.learnCount, label: "Learn", color: .red)
                    PillCount(value: deck.dueCount, label: "Due", color: .green)
                }
                .padding(.top, 4)
            }
        } actions: {
            VStack(spacing: 12) {
                Button {
                    withAnimation { rebuildQueue(includeAll: true) }
                } label: {
                    Label("Study Anyway (All Cards)", systemImage: "books.vertical.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)

                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
    }

    // MARK: - Study Body
    private var studyBody: some View {
        VStack(spacing: 0) {
            // Progress
            VStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.systemFill))
                        Capsule()
                            .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * progress)
                            .animation(.spring(response: 0.5), value: progress)
                    }
                }
                .frame(height: 6)
                .padding(.horizontal)

                HStack(spacing: 10) {
                    CountBadge(count: queue.filter { $0.type == 0 }.count, label: "New", color: .blue, icon: "plus.circle.fill")
                    CountBadge(count: queue.filter { $0.queue == 1 || $0.queue == 3 }.count, label: "Learn", color: .red, icon: "exclamationmark.circle.fill")
                    CountBadge(count: queue.filter { $0.queue == 2 }.count, label: "Due", color: .green, icon: "checkmark.circle.fill")
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                            .font(.caption2)
                        Text(timerString)
                            .font(.caption.weight(.medium).monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(.secondarySystemFill)))
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground))

            ScrollView {
                VStack(spacing: 18) {
                    if let card = currentCard {
                        cardView(for: card)
                    } else {
                        Text("Loading card…")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                }
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .gesture(swipeGesture)
    }

    @ViewBuilder
    private func cardView(for card: Card) -> some View {
        let note = card.note
        let noteType = note.flatMap { n in noteTypes.first { $0.ankiId == n.modelId } }
        let fields = note.map { TemplateRenderer.fieldsDictionary(note: $0, noteType: noteType) } ?? [:]
        let template = noteType?.templates[safe: card.ord] ?? noteType?.templates.first

        VStack(spacing: 16) {
            // Flip card container
            ZStack {
                // Front face
                cardFace(
                    html: template.map { TemplateRenderer.render(template: $0.qfmt, fields: fields, noteType: noteType) } ?? fallbackHTML(fields: fields, isFront: true),
                    speakableText: fields[noteType?.fieldNames.first ?? "Front"] ?? fields.values.first ?? ""
                )
                .opacity(isFront ? 1 : 0)
                .rotation3DEffect(.degrees(isFront ? 0 : 180), axis: (x: 0, y: 1, z: 0))

                // Back face
                cardFace(
                    html: {
                        if let tmpl = template {
                            let front = TemplateRenderer.render(template: tmpl.qfmt, fields: fields, noteType: noteType)
                            return TemplateRenderer.render(template: tmpl.afmt, fields: fields, noteType: noteType, frontSide: front)
                        } else {
                            return fallbackHTML(fields: fields, isFront: false)
                        }
                    }(),
                    speakableText: fields[noteType?.fieldNames.dropFirst().first ?? "Back"] ?? ""
                )
                .opacity(isFront ? 0 : 1)
                .rotation3DEffect(.degrees(isFront ? -180 : 0), axis: (x: 0, y: 1, z: 0))
            }
            .frame(minHeight: isFront ? 260 : 300)
            .rotation3DEffect(.degrees(cardRotation), axis: (x: 0, y: 1, z: 0))
            .offset(x: dragOffset)
            .gesture(
                DragGesture(minimumDistance: 20, coordinateSpace: .local)
                    .onChanged { v in
                        guard isFront else { return }
                        dragOffset = v.translation.width * 0.2
                    }
                    .onEnded { v in
                        withAnimation(.spring(response: 0.35)) { dragOffset = 0 }
                        if isFront && v.translation.width < -80 {
                            flipToAnswer()
                        } else if isFront && v.translation.width > 80 {
                            flipToAnswer()
                        }
                    }
            )
            .id("\(card.ankiId)-\(isFront ? "front" : "back")")

            // Action area
            if isFront {
                VStack(spacing: 12) {
                    Button {
                        flipToAnswer()
                    } label: {
                        Label("Show Answer", systemImage: "eye.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.blue)
                    .shadow(color: .blue.opacity(0.25), radius: 8, y: 4)
                    .padding(.horizontal)
                    .sensoryFeedback(.impact(weight: .medium), trigger: isFront)

                    Text("Tap card or swipe to reveal • Tap \(Image(systemName: "speaker.wave.2.fill")) to pronounce")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 12) {
                    ratingButtons

                    HStack {
                        Button { speakCurrent(isBack: true) } label: {
                            Label(speech.isSpeaking ? "Speaking…" : "Pronounce Answer", systemImage: "speaker.wave.2.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.indigo)
                        .disabled(speech.isSpeaking)

                        Spacer()

                        Button { flipToFront() } label: {
                            Label("Show Question", systemImage: "arrow.uturn.left")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }
            }

            // Meta
            HStack(spacing: 8) {
                if let tags = note?.tagList, !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color(.tertiarySystemFill)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("No tags")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("· \(card.interval)d · \(card.easeFactor/10)% · \(card.reps)x")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
        }
    }

    private func cardFace(html: String, speakableText: String) -> some View {
        VStack(spacing: 0) {
            CardWebView(html: html, baseURL: mediaBaseURL())
                .frame(minHeight: 220)
                .background(Color(.systemBackground))

            Divider().opacity(0.6)

            HStack(spacing: 12) {
                Button {
                    // Use cleaned speakable text or html
                    let text = speech.extractSpeakableText(from: html)
                    if !text.isEmpty {
                        speech.speak(text)
                    } else if !speakableText.isEmpty {
                        speech.speak(speakableText)
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: speech.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                            .font(.callout.weight(.semibold))
                        Text(speech.isSpeaking ? "Speaking" : "Pronounce")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(speech.isSpeaking ? .white : .blue)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(speech.isSpeaking ? Color.blue : Color.blue.opacity(0.12))
                    )
                    .overlay(
                        Capsule().stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                if isFront {
                    Text("FRONT")
                        .font(.caption2.weight(.heavy))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(.secondarySystemFill)))
                } else {
                    Text("BACK")
                        .font(.caption2.weight(.heavy))
                        .tracking(1.2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.green))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 6)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(.separator).opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal)
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture {
            if isFront { flipToAnswer() }
        }
    }

    private var ratingButtons: some View {
        HStack(spacing: 8) {
            ForEach(Rating.allCases) { rating in
                Button {
                    answer(rating)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: iconForRating(rating))
                            .font(.caption.weight(.bold))
                        Text(rating.label)
                            .font(.caption.weight(.heavy))
                            .lineLimit(1)
                        Text(intervals[rating] ?? "—")
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.22)))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(gradientForRating(rating))
                            .shadow(color: colorForRating(rating).opacity(0.3), radius: 6, y: 3)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isAnswering)
                .opacity(isAnswering ? 0.6 : 1)
                .scaleEffect(isAnswering ? 0.98 : 1)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var finishedView: some View {
        ScrollView {
            VStack(spacing: 24) {
                ZStack {
                    Circle().fill(Color.orange.opacity(0.12)).frame(width: 120, height: 120)
                    Circle().fill(Color.orange.opacity(0.08)).frame(width: 160, height: 160)
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .padding(.top, 24)

                VStack(spacing: 8) {
                    Text("Session Complete!")
                        .font(.title2.weight(.bold))
                    Text("Great job studying \"\(deck.displayName)\"")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    StatBox(value: "\(sessionTotal)", label: "Studied", icon: "books.vertical.fill", color: .blue)
                    StatBox(value: "\(sessionCorrect)", label: "Correct", icon: "checkmark.circle.fill", color: .green)
                    StatBox(value: accuracyText, label: "Accuracy", icon: "chart.line.uptrend.xyaxis", color: .orange)
                }
                .padding(.horizontal)

                GroupBox {
                    VStack(spacing: 12) {
                        HStack {
                            Label("New cards", systemImage: "plus.circle.fill")
                                .foregroundStyle(.blue)
                            Spacer()
                            Text("\(sessionNew)")
                                .font(.headline.monospacedDigit())
                        }
                        Divider()
                        HStack {
                            Label("Time", systemImage: "clock.fill")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(timerString)
                                .font(.headline.monospacedDigit())
                        }
                    }
                }
                .padding(.horizontal)

                VStack(spacing: 12) {
                    Button {
                        withAnimation { rebuildQueue(includeAll: true) }
                    } label: {
                        Label("Study More", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Done") { dismiss() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var accuracyText: String {
        guard sessionTotal > 0 else { return "—" }
        let pct = Double(sessionCorrect) / Double(sessionTotal) * 100
        return String(format: "%.0f%%", pct)
    }

    private var timerString: String {
        let elapsed = Int(Date().timeIntervalSince(sessionStart))
        let m = elapsed / 60
        let s = elapsed % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Helpers

    private func fallbackHTML(fields: [String: String], isFront: Bool) -> String {
        if isFront, let firstKey = fields.keys.sorted().first, let val = fields[firstKey] {
            return "<div style='font-size:22px; font-weight:600;'>\(val)</div>"
        } else {
            return fields.map { "<div><b>\($0.key)</b>: \($0.value)</div>" }.joined(separator: "<hr>")
        }
    }

    private func fallbackFieldView(fields: [String: String], isFront: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(fields.keys.sorted()), id: \.self) { key in
                if let val = fields[key], !val.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(val.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                            .font(.body)
                    }
                    Divider()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                guard !isFront, !isAnswering else { return }
                let h = value.translation.width
                let v = value.translation.height
                guard abs(h) > abs(v) else { return }
                if h < -60 {
                    // swipe left -> Good
                    answer(.good)
                } else if h > 60 {
                    // swipe right -> Again (undo) or Hard?
                    // Keep as Hard for convenience
                    answer(.hard)
                }
            }
    }

    private func mediaBaseURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AnkiMedia", isDirectory: true)
    }

    private func iconForRating(_ r: Rating) -> String {
        switch r {
        case .again: return "xmark.circle.fill"
        case .hard: return "exclamationmark.circle.fill"
        case .good: return "checkmark.circle.fill"
        case .easy: return "star.circle.fill"
        }
    }

    private func gradientForRating(_ r: Rating) -> LinearGradient {
        switch r {
        case .again: return LinearGradient(colors: [.red, .red.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .hard: return LinearGradient(colors: [.orange, .orange.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .good: return LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .easy: return LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func colorForRating(_ r: Rating) -> Color {
        switch r {
        case .again: return .red
        case .hard: return .orange
        case .good: return .green
        case .easy: return .blue
        }
    }

    // MARK: - Flip logic
    private func flipToAnswer() {
        guard isFront else { return }
        speech.stop()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            cardRotation = 8
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                isFront = false
                cardRotation = 0
                showAnswerButtons = true
            }
            updateIntervals()
            haptic(.medium)
            if speech.autoPlay {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    speakCurrent(isBack: true)
                }
            }
        }
    }

    private func flipToFront() {
        withAnimation(.spring(response: 0.35)) {
            isFront = true
            showAnswerButtons = false
        }
        speech.stop()
    }

    private func speakCurrent(isBack: Bool = false) {
        guard let card = currentCard, let note = card.note else { return }
        let noteType = noteTypes.first { $0.ankiId == note.modelId }
        let fields = TemplateRenderer.fieldsDictionary(note: note, noteType: noteType)
        // Prefer speakable extraction from rendered HTML for accuracy, fallback to fields
        if let tmpl = noteType?.templates[safe: card.ord] ?? noteType?.templates.first {
            let html: String
            if isBack {
                let front = TemplateRenderer.render(template: tmpl.qfmt, fields: fields, noteType: noteType)
                html = TemplateRenderer.render(template: tmpl.afmt, fields: fields, noteType: noteType, frontSide: front)
            } else {
                html = TemplateRenderer.render(template: tmpl.qfmt, fields: fields, noteType: noteType)
            }
            let text = speech.extractSpeakableText(from: html)
            if !text.isEmpty {
                speech.speak(text)
                return
            }
        }
        speech.speakFields(fields)
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    // MARK: - Queue management (crash-safe)
    private func rebuildQueue(includeAll: Bool) {
        // Stop speech when rebuilding
        speech.stop()
        let now = Date()

        // Safely filter suspended cards
        var filtered = allCards.filter { $0.queue >= 0 }

        if !includeAll {
            let learn = filtered.filter { $0.queue == 1 || $0.queue == 3 }
                .sorted { $0.dueDate < $1.dueDate }
            let due = filtered.filter { $0.queue == 2 && $0.dueDate <= now }
                .sorted { $0.dueDate < $1.dueDate }
            let new = filtered.filter { $0.type == 0 && $0.queue == 0 }
                .shuffled()
                .prefix(20)

            var q: [Card] = []
            q.reserveCapacity(learn.count + due.count + new.count)
            q.append(contentsOf: learn.prefix(20))
            q.append(contentsOf: due.prefix(200))
            q.append(contentsOf: new)

            if q.isEmpty && !filtered.isEmpty {
                // Show at least something (e.g., not-yet-due review cards)
                q = Array(filtered.sorted { $0.dueDate < $1.dueDate }.prefix(20))
            }
            queue = q
        } else {
            queue = filtered.sorted { $0.dueDate < $1.dueDate }
        }

        // Reset state atomically to avoid index-out-of-range during SwiftUI update
        currentIndex = 0
        isFront = true
        showAnswerButtons = false
        cardRotation = 0
        dragOffset = 0
        finished = queue.isEmpty
        sessionStart = Date()
        answerTime = Date()
        sessionNew = 0
        sessionCorrect = 0
        sessionTotal = queue.count
        isAnswering = false
        updateIntervals()
        haptic(.light)

        // Auto-play first card if enabled
        if speech.autoPlay, !queue.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                speakCurrent()
            }
        }
    }

    private func updateIntervals() {
        // Guard against empty queue or invalid index - prevents crash on next-word switch
        guard !queue.isEmpty, currentIndex >= 0, currentIndex < queue.count else {
            intervals = [:]
            return
        }
        guard let card = currentCard else {
            intervals = [:]
            return
        }
        intervals = scheduler.nextIntervals(for: card)
        answerTime = Date()
    }

    private func advanceToNextCard() {
        // Safe advancement with bounds check
        guard !queue.isEmpty else {
            finished = true
            return
        }
        // Small delay for animation
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isFront = true
            showAnswerButtons = false
            cardRotation = 0
            dragOffset = 0
        }
        // Ensure index valid after queue mutation
        if currentIndex >= queue.count {
            currentIndex = max(0, queue.count - 1)
        }
        if queue.isEmpty {
            finished = true
        } else {
            updateIntervals()
            if speech.autoPlay {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    speakCurrent()
                }
            }
        }
        isAnswering = false
        haptic(.light)
    }

    private func answer(_ rating: Rating) {
        // Prevent double-tap race
        guard !isAnswering else { return }
        guard !queue.isEmpty, currentIndex >= 0, currentIndex < queue.count else { return }
        guard let card = currentCard else { return }

        isAnswering = true
        speech.stop()

        let elapsedMs = Int(Date().timeIntervalSince(answerTime) * 1000)
        let wasCorrect = rating != .again
        let previousType = card.type

        // Capture reps before apply for logging
        let lastInterval = card.interval
        let result = scheduler.answer(card: card, rating: rating, answeredAt: Date())
        scheduler.apply(result: result, to: card)

        // Log
        let log = ReviewLog(cardId: card.ankiId, ease: rating.rawValue, interval: result.newInterval, lastInterval: lastInterval, factor: result.newEaseFactor, timeMs: elapsedMs, type: previousType)
        modelContext.insert(log)
        do { try modelContext.save() } catch { print("Save failed: \(error)") }

        // Stats
        if previousType == 0 { sessionNew += 1 }
        if wasCorrect { sessionCorrect += 1 }

        // Haptic per rating
        switch rating {
        case .again: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .hard: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .good: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .easy: UINotificationFeedbackGenerator().notificationOccurred(.success)
        }

        // Queue mutation - crash-safe
        if rating == .again && (result.newType == 1 || result.newType == 3) {
            // Re-queue learning card a few positions ahead
            // Guard index valid before remove
            if currentIndex < queue.count {
                let cardToReinsert = queue.remove(at: currentIndex)
                let insertAt = min(currentIndex + 3, queue.count)
                queue.insert(cardToReinsert, at: insertAt)
                // Stay at same index (next card slid into place)
                if currentIndex >= queue.count {
                    // Wrapped - should not happen with reinsert but handle
                    currentIndex = 0
                }
                if queue.isEmpty {
                    finished = true
                    isAnswering = false
                } else {
                    // Delay slightly for visual comfort then update
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        advanceToNextCard()
                    }
                }
            } else {
                isAnswering = false
            }
        } else {
            // Remove completed card
            if currentIndex < queue.count {
                queue.remove(at: currentIndex)
            }
            // Adjust index if needed - if we removed last element, wrap to 0
            if !queue.isEmpty && currentIndex >= queue.count {
                currentIndex = 0
                // Also need to trigger view refresh for wrapped card
                // Small rotation nudge to indicate new loop
                withAnimation(.spring(response: 0.3)) { cardRotation = -6 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.spring(response: 0.3)) { cardRotation = 0 }
                }
            }
            if queue.isEmpty {
                withAnimation(.spring(response: 0.5)) {
                    finished = true
                    isAnswering = false
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    advanceToNextCard()
                }
            }
        }
    }

    private func suspendCurrent() {
        guard let card = currentCard else { return }
        guard currentIndex >= 0, currentIndex < queue.count else { return }
        speech.stop()
        card.queue = -1
        try? modelContext.save()
        queue.remove(at: currentIndex)
        if queue.isEmpty {
            finished = true
        } else {
            if currentIndex >= queue.count { currentIndex = 0 }
            isFront = true
            updateIntervals()
        }
        haptic(.medium)
    }

    private func buryCurrent() {
        guard let card = currentCard else { return }
        guard currentIndex >= 0, currentIndex < queue.count else { return }
        speech.stop()
        card.queue = -2
        try? modelContext.save()
        queue.remove(at: currentIndex)
        if queue.isEmpty {
            finished = true
        } else {
            if currentIndex >= queue.count { currentIndex = 0 }
            isFront = true
            updateIntervals()
        }
        haptic(.medium)
    }
}

// MARK: - Supporting views

private struct CountBadge: View {
    let count: Int
    let label: String
    let color: Color
    let icon: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text("\(count)").font(.caption.weight(.bold).monospacedDigit())
            Text(label).font(.caption2.weight(.medium))
        }
        .foregroundStyle(count == 0 ? .secondary : color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(count == 0 ? 0.08 : 0.14)))
        .overlay(Capsule().stroke(color.opacity(0.18), lineWidth: 1))
    }
}

private struct PillCount: View {
    let value: Int
    let label: String
    let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 56)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.15), lineWidth: 1))
    }
}

private struct StatBox: View {
    let value: String
    let label: String
    let icon: String
    let color: Color
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            Text(value).font(.title2.weight(.bold).monospacedDigit())
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(.separator).opacity(0.1), lineWidth: 1))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
