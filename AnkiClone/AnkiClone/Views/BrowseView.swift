import SwiftUI
import SwiftData

struct BrowseView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Card.dueDate) private var cards: [Card]
    @Query private var notes: [Note]
    @Query private var noteTypes: [NoteType]
    @Query(sort: \Deck.name) private var decks: [Deck]

    @State private var searchText = ""
    @State private var selectedFilter: BrowseFilter = .all
    @State private var selectedDeckId: Int64? = nil
    @State private var selectedCard: Card?

    enum BrowseFilter: String, CaseIterable, Identifiable {
        case all = "All", due = "Due", new = "New", learning = "Learning", suspended = "Suspended"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .due: return "checkmark.circle.fill"
            case .new: return "sparkles"
            case .learning: return "exclamationmark.circle.fill"
            case .suspended: return "pause.circle.fill"
            }
        }
    }

    var filtered: [Card] {
        var list = cards
        if let id = selectedDeckId { list = list.filter { $0.deckId == id } }
        switch selectedFilter {
        case .all: break
        case .due: list = list.filter { $0.queue == 2 && $0.dueDate <= Date() }
        case .new: list = list.filter { $0.type == 0 }
        case .learning: list = list.filter { $0.queue == 1 || $0.queue == 3 }
        case .suspended: list = list.filter { $0.queue < 0 }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter { card in
                guard let note = card.note else { return false }
                return note.fieldValues.contains { $0.lowercased().contains(q) }
                    || note.tags.lowercased().contains(q)
                    || card.deck?.name.lowercased().contains(q) == true
            }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header filters
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(BrowseFilter.allCases) { f in
                            FilterChip(title: f.rawValue, icon: f.icon, selected: selectedFilter == f) {
                                withAnimation(.spring(response: 0.3)) { selectedFilter = f }
                            }
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                }
                .background(Color(.secondarySystemGroupedBackground))

                if !decks.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            FilterChip(title: "All Decks", icon: "rectangle.stack", selected: selectedDeckId == nil) {
                                selectedDeckId = nil
                            }
                            ForEach(decks) { deck in
                                FilterChip(title: deck.displayName, icon: "folder", selected: selectedDeckId == deck.ankiId) {
                                    withAnimation(.spring(response: 0.3)) { selectedDeckId = deck.ankiId }
                                }
                            }
                        }
                        .padding(.horizontal).padding(.bottom, 8)
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                }

                Divider().opacity(0.08)

                if cards.isEmpty {
                    ContentUnavailableView {
                        Label("No Cards", systemImage: "tray")
                    } description: {
                        Text("Import a deck to browse cards.")
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView {
                        Label("No Results", systemImage: "magnifyingglass")
                    } description: {
                        Text(searchText.isEmpty ? "No cards match this filter." : "No results for “\(searchText)”")
                    } actions: {
                        Button("Clear Filters") {
                            selectedFilter = .all; selectedDeckId = nil; searchText = ""
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    List {
                        Section {
                            HStack {
                                Label("\(filtered.count) card\(filtered.count == 1 ? "" : "s")", systemImage: "rectangle.stack")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                if selectedFilter != .all || selectedDeckId != nil || !searchText.isEmpty {
                                    Button("Clear") {
                                        selectedFilter = .all; selectedDeckId = nil; searchText = ""
                                    }
                                    .font(.caption.weight(.semibold))
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                        }
                        ForEach(filtered) { card in
                            BrowseRow(card: card, noteTypes: noteTypes)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedCard = card }
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions {
                                    Button(role: .destructive) { suspend(card) } label: {
                                        Label(card.queue < 0 ? "Unsuspend" : "Suspend", systemImage: "pause.circle")
                                    }
                                    Button { delete(card) } label: { Label("Delete", systemImage: "trash") }.tint(.red)
                                }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(Color(.secondarySystemGroupedBackground))
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .navigationTitle("Browse")
            .searchable(text: $searchText, prompt: "Search cards, tags, decks")
            .navigationDestination(item: $selectedCard) { card in CardDetailView(card: card, noteTypes: noteTypes) }
        }
    }

    private func suspend(_ card: Card) {
        card.queue = card.queue < 0 ? 2 : -1
        try? modelContext.save()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    private func delete(_ card: Card) {
        CollectionMaintenance.delete(card: card, in: modelContext)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

struct FilterChip: View {
    let title: String
    var icon: String? = nil
    let selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.caption2.weight(.semibold)) }
                Text(title).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(selected ? Color.indigo : Color(.secondarySystemFill)))
            .foregroundStyle(selected ? .white : .primary)
            .overlay(Capsule().stroke(selected ? Color.indigo.opacity(0.3) : Color.clear, lineWidth: 1))
            .shadow(color: selected ? Color.indigo.opacity(0.22) : .clear, radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }
}

struct BrowseRow: View {
    let card: Card
    let noteTypes: [NoteType]
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(colorForCard).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 4) {
                let front = card.note?.fieldValues.first ?? "—"
                Text(stripHTML(front)).font(.subheadline.weight(.medium)).lineLimit(1)
                let back = card.note?.fieldValues.dropFirst().first ?? ""
                if !back.isEmpty {
                    Text(stripHTML(back)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(card.deck?.displayName ?? "Deck \(card.deckId)")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color(.secondarySystemFill)))
                    if let tags = card.note?.tagList, !tags.isEmpty {
                        Text(tags.prefix(2).joined(separator: " ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(statusLabel).font(.caption2.weight(.semibold)).foregroundStyle(colorForCard)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(colorForCard.opacity(0.12)))
                Text("ivl \(card.interval)d").font(.caption2).foregroundStyle(.secondary)
                Text(card.dueDate, style: .date).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground)).shadow(color: .black.opacity(0.05), radius: 8, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(.separator).opacity(0.07), lineWidth: 1))
        .padding(.vertical, 1)
    }
    private var statusLabel: String {
        if card.queue < 0 { return "suspended" }
        switch card.type { case 0: return "new"; case 1: return "learn"; case 3: return "relearn"; case 2: return card.dueDate <= Date() ? "due" : "review"; default: return "—" }
    }
    private var colorForCard: Color {
        if card.queue < 0 { return .gray }
        switch card.type { case 0: return .blue; case 1,3: return .red; case 2: return card.dueDate <= Date() ? .green : .orange; default: return .secondary }
    }
    private func stripHTML(_ s: String) -> String { s.strippingHTML }
}


// MARK: - Card detail

struct CardDetailView: View {
    let card: Card
    let noteTypes: [NoteType]

    @ObservedObject private var speech = SpeechService.shared
    @State private var showRawFields = false

    private var noteType: NoteType? {
        guard let modelId = card.note?.modelId else { return nil }
        return noteTypes.first { $0.ankiId == modelId }
    }

    private var template: CardTemplateData? {
        noteType?.templates.first { $0.ord == card.ord } ?? noteType?.templates.first
    }

    private var content: CardContent? {
        card.note.map { CardContentAnalyzer.analyze(note: $0, noteType: noteType) }
    }

    var body: some View {
        List {
            if let content, content.isVocabulary {
                Section {
                    WordHeaderView(content: content, speech: speech)
                        .padding(.vertical, 12)
                        .listRowBackground(Color.clear)
                }
                Section {
                    AnswerDetailView(content: content, speech: speech)
                        .padding(.vertical, 6)
                }
            }

            Section("Rendered card") {
                if let template, let note = card.note {
                    let fields = TemplateRenderer.fieldsDictionary(note: note, noteType: noteType)
                    let question = TemplateRenderer.render(template: template.qfmt, fields: fields, noteType: noteType)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("QUESTION").font(.caption2.weight(.heavy)).foregroundStyle(.secondary)
                        SizedCardWebView(html: question, baseURL: SpeechService.mediaDirectory, minHeight: 70)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ANSWER").font(.caption2.weight(.heavy)).foregroundStyle(.secondary)
                        SizedCardWebView(
                            html: TemplateRenderer.render(
                                template: template.afmt, fields: fields, noteType: noteType, frontSide: question
                            ),
                            baseURL: SpeechService.mediaDirectory,
                            minHeight: 90
                        )
                    }
                } else {
                    Text("This note has no card template.").foregroundStyle(.secondary)
                }
            }

            Section("Scheduling") {
                LabeledContent("Deck", value: card.deck?.displayName ?? "\(card.deckId)")
                LabeledContent("State", value: ["New", "Learning", "Review", "Relearning"][min(max(card.type, 0), 3)])
                LabeledContent("Due", value: card.dueDate.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Interval", value: card.interval == 0 ? "—" : "\(card.interval) days")
                LabeledContent("Ease", value: card.easeFactor > 0 ? "\(card.easeFactor / 10)%" : "—")
                LabeledContent("Reviews", value: "\(card.reps)")
                LabeledContent("Lapses", value: "\(card.lapses)")
            }

            Section(isExpanded: $showRawFields) {
                if let note = card.note {
                    let names = noteType?.fieldNames ?? (0..<note.fieldValues.count).map { "Field \($0 + 1)" }
                    ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                        let value = index < note.fieldValues.count ? note.fieldValues[index] : ""
                        if !value.isBlank {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(value.strippingHTML).font(.callout).textSelection(.enabled)
                            }
                        }
                    }
                }
            } header: {
                Text("Note fields")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(content?.headword.isBlank == false ? content!.headword : "Card")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { speech.stop() }
    }
}
