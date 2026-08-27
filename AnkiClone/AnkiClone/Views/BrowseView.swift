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
    }

    var filtered: [Card] {
        var list = cards

        // Deck filter
        if let id = selectedDeckId {
            list = list.filter { $0.deckId == id }
        }

        // Status filter
        switch selectedFilter {
        case .all: break
        case .due: list = list.filter { $0.queue == 2 && $0.dueDate <= Date() }
        case .new: list = list.filter { $0.type == 0 }
        case .learning: list = list.filter { $0.queue == 1 || $0.queue == 3 }
        case .suspended: list = list.filter { $0.queue < 0 }
        }

        // Search
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
                // Filters
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(BrowseFilter.allCases) { f in
                            FilterChip(title: f.rawValue, selected: selectedFilter == f) {
                                selectedFilter = f
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                if !decks.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            FilterChip(title: "All Decks", selected: selectedDeckId == nil) {
                                selectedDeckId = nil
                            }
                            ForEach(decks) { deck in
                                FilterChip(title: deck.displayName, selected: selectedDeckId == deck.ankiId) {
                                    selectedDeckId = deck.ankiId
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    }
                }

                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label("No Cards", systemImage: "magnifyingglass")
                    } description: {
                        Text(searchText.isEmpty ? "No cards match this filter." : "No results for \"\(searchText)\"")
                    }
                } else {
                    List {
                        Section {
                            Text("\(filtered.count) card\(filtered.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .listRowBackground(Color.clear)
                        }

                        ForEach(filtered) { card in
                            BrowseRow(card: card, noteTypes: noteTypes)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedCard = card }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        suspend(card)
                                    } label: {
                                        Label(card.queue < 0 ? "Unsuspend" : "Suspend", systemImage: "pause.circle")
                                    }
                                    Button {
                                        delete(card)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Browse")
            .searchable(text: $searchText, prompt: "Search cards, tags, decks")
            .navigationDestination(item: $selectedCard) { card in
                CardDetailView(card: card, noteTypes: noteTypes)
            }
        }
    }

    private func suspend(_ card: Card) {
        card.queue = card.queue < 0 ? 2 : -1
        do { try modelContext.save() } catch { print("Suspend save failed: \(error)") }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func delete(_ card: Card) {
        modelContext.delete(card)
        do { try modelContext.save() } catch { print("Delete save failed: \(error)") }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

struct FilterChip: View {
    let title: String
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(selected ? Color.indigo : Color(.secondarySystemFill))
                )
                .foregroundStyle(selected ? .white : .primary)
                .overlay(Capsule().stroke(selected ? Color.indigo.opacity(0.3) : Color.clear, lineWidth: 1))
                .shadow(color: selected ? Color.indigo.opacity(0.25) : .clear, radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }
}

struct BrowseRow: View {
    let card: Card
    let noteTypes: [NoteType]

    var body: some View {
        HStack(spacing: 12) {
            // Status dot
            Circle()
                .fill(colorForCard)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                // Show first field as front
                let front = card.note?.fieldValues.first ?? "—"
                Text(stripHTML(front))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                let back = card.note?.fieldValues.dropFirst().first ?? ""
                if !back.isEmpty {
                    Text(stripHTML(back))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(card.deck?.displayName ?? "Deck \(card.deckId)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(.secondarySystemFill)))

                    if let tags = card.note?.tagList, !tags.isEmpty {
                        Text(tags.prefix(2).joined(separator: " "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(statusLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(colorForCard)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(colorForCard.opacity(0.12)))

                Text("ivl \(card.interval)d")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(card.dueDate, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusLabel: String {
        if card.queue < 0 { return "suspended" }
        switch card.type {
        case 0: return "new"
        case 1: return "learn"
        case 3: return "relearn"
        case 2: return card.dueDate <= Date() ? "due" : "review"
        default: return "—"
        }
    }

    private var colorForCard: Color {
        if card.queue < 0 { return .gray }
        switch card.type {
        case 0: return .blue
        case 1, 3: return .red
        case 2: return card.dueDate <= Date() ? .green : .orange
        default: return .secondary
        }
    }

    private func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CardDetailView: View {
    let card: Card
    let noteTypes: [NoteType]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Rendered preview
                if let note = card.note,
                   let nt = noteTypes.first(where: { $0.ankiId == note.modelId }),
                   let tmpl = nt.templates.first(where: { $0.ord == card.ord }) ?? nt.templates.first {
                    let fields = TemplateRenderer.fieldsDictionary(note: note, noteType: nt)

                    GroupBox("Question Preview") {
                        CardWebView(html: TemplateRenderer.render(template: tmpl.qfmt, fields: fields, noteType: nt), baseURL: mediaBaseURL())
                            .frame(minHeight: 180)
                    }

                    GroupBox("Answer Preview") {
                        let q = TemplateRenderer.render(template: tmpl.qfmt, fields: fields, noteType: nt)
                        CardWebView(html: TemplateRenderer.render(template: tmpl.afmt, fields: fields, noteType: nt, frontSide: q), baseURL: mediaBaseURL())
                            .frame(minHeight: 220)
                    }

                    GroupBox("Fields") {
                        ForEach(Array(nt.fieldNames.enumerated()), id: \.offset) { idx, name in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(idx < note.fieldValues.count ? note.fieldValues[idx] : "")
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                            if idx < nt.fieldNames.count - 1 { Divider() }
                        }
                    }
                }

                GroupBox("Card Info") {
                    LabeledContent("ID", value: "\(card.ankiId)")
                    LabeledContent("Deck", value: card.deck?.name ?? "\(card.deckId)")
                    LabeledContent("Type", value: ["New","Learn","Review","Relearn"][min(card.type,3)])
                    LabeledContent("Queue", value: "\(card.queue)")
                    LabeledContent("Due", value: card.dueDate.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Interval", value: "\(card.interval) days")
                    LabeledContent("Ease", value: "\(card.easeFactor/10)%")
                    LabeledContent("Reps", value: "\(card.reps)")
                    LabeledContent("Lapses", value: "\(card.lapses)")
                }

                GroupBox("Raw Template") {
                    if let note = card.note,
                       let nt = noteTypes.first(where: { $0.ankiId == note.modelId }),
                       let tmpl = nt.templates.first(where: { $0.ord == card.ord }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("qfmt:").font(.caption.weight(.bold))
                            Text(tmpl.qfmt).font(.caption.monospaced()).textSelection(.enabled)
                            Divider()
                            Text("afmt:").font(.caption.weight(.bold))
                            Text(tmpl.afmt).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Card Detail")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func mediaBaseURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AnkiMedia", isDirectory: true)
    }
}
