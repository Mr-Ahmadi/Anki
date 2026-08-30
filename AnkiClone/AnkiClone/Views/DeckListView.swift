import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct DeckListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Deck.name, order: .forward) private var decks: [Deck]
    @State private var showImport = false
    @State private var showAddDeck = false
    @State private var newDeckName = ""
    @State private var selectedDeck: Deck?
    @State private var deckToDelete: Deck?
    @State private var showDeleteConfirm = false
    @State private var searchText = ""

    /// Anki always ships a "Default" deck; hide it while it is empty.
    private var visibleDecks: [Deck] {
        decks.filter { !($0.name == "Default" && $0.totalCount == 0) }
    }

    private var filteredDecks: [Deck] {
        let decks = visibleDecks
        if searchText.isEmpty { return decks }
        let q = searchText.lowercased()
        return decks.filter { $0.name.lowercased().contains(q) || $0.desc.lowercased().contains(q) }
    }
    private var totalDue: Int { visibleDecks.reduce(0) { $0 + $1.dueCount } }
    private var totalNew: Int { visibleDecks.reduce(0) { $0 + $1.newCount } }
    private var totalLearn: Int { visibleDecks.reduce(0) { $0 + $1.learnCount } }
    private var totalCards: Int { visibleDecks.reduce(0) { $0 + $1.totalCount } }
    /// Everything that can be studied right now — new, learning and due alike.
    private var totalReady: Int { totalNew + totalLearn + totalDue }

    private var readySubtitle: String {
        if totalReady == 0 { return "Enjoy a break, or study ahead from a deck" }
        if totalDue > 0 { return "\(totalDue) due for review · \(totalNew) still new" }
        return "All new cards — a good day to start"
    }

    var body: some View {
        NavigationStack {
            Group {
                if visibleDecks.isEmpty {
                    emptyState
                } else {
                    deckList
                }
            }
            .navigationTitle("AnkiClone")
            .searchable(text: $searchText, prompt: "Search decks")
            .toolbar { toolbar }
            .sheet(isPresented: $showImport) { ImportView() }
            .sheet(isPresented: $showAddDeck) { addDeckSheet }
            .navigationDestination(item: $selectedDeck) { deck in StudyView(deck: deck) }
            .alert("Delete Deck?", isPresented: $showDeleteConfirm, presenting: deckToDelete) { deck in
                Button("Delete", role: .destructive) { deleteDeck(deck) }
                Button("Cancel", role: .cancel) { deckToDelete = nil }
            } message: { deck in
                Text("This will delete “\(deck.displayName)” and all \(deck.totalCount) cards. This cannot be undone.")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showImport = true } label: { Label("Import deck…", systemImage: "square.and.arrow.down") }
                Button { showAddDeck = true } label: { Label("New deck", systemImage: "plus") }
            } label: {
                Image(systemName: "plus.circle.fill")
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Color.indigo.opacity(0.10)).frame(width: 110, height: 110)
                    Circle().fill(Color.indigo.opacity(0.06)).frame(width: 150, height: 150)
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .padding(.top, 36)

                VStack(spacing: 8) {
                    Text("No Decks Yet")
                        .font(.title2.weight(.bold))
                    Text("Import an .apkg from Anki or create a new deck to start studying.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Text("Supports scheduling, media & HTML templates.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                VStack(spacing: 10) {
                    Button { showImport = true } label: {
                        Label("Import .apkg / .colpkg", systemImage: "square.and.arrow.down.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    
                    Button { showAddDeck = true } label: {
                        Label("Create Empty Deck", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("What you can import", systemImage: "sparkles")
                            .font(.caption.weight(.semibold)).foregroundStyle(.indigo)
                        Label("Shared decks from AnkiWeb", systemImage: "globe")
                        Label("Exports from Anki Desktop", systemImage: "macbook")
                        Label("Includes images + audio", systemImage: "photo.on.rectangle.angled")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Text("Samples in /samples are available on Simulator")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var deckList: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(greetingText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.6)
                            Text(totalReady == 0 ? "All caught up!" : "\(totalReady) cards ready")
                                .font(.title2.weight(.bold))
                                .contentTransition(.numericText())
                            Text(readySubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: totalReady > 0 ? [.indigo, .purple] : [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 56, height: 56)
                            Image(systemName: totalReady > 0 ? "flame.fill" : "checkmark.seal.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                        .shadow(color: (totalReady > 0 ? Color.indigo : Color.green).opacity(0.30), radius: 10, y: 4)
                    }

                    HStack(spacing: 10) {
                        SummaryPill(value: "\(totalCards)", label: "Total", color: .primary, icon: "rectangle.stack.fill")
                        SummaryPill(value: "\(totalNew)", label: "New", color: .blue, icon: "sparkles")
                        SummaryPill(value: "\(totalDue)", label: "Due", color: .green, icon: "checkmark.seal.fill")
                        SummaryPill(value: "\(totalLearn)", label: "Learn", color: .red, icon: "exclamationmark.circle.fill")
                    }
                }
                .padding(.vertical, 6)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
                )
                .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)

            Section {
                ForEach(filteredDecks) { deck in
                    DeckRow(deck: deck) { selectedDeck = deck }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deckToDelete = deck
                                showDeleteConfirm = true
                            } label: { Label("Delete", systemImage: "trash.fill") }
                            Button { selectedDeck = deck } label: { Label("Study", systemImage: "play.fill") }
                                .tint(.indigo)
                        }
                        .contextMenu {
                            Button { selectedDeck = deck } label: { Label("Study", systemImage: "play.fill") }
                            Button(role: .destructive) { deckToDelete = deck; showDeleteConfirm = true } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            } header: {
                HStack {
                    Text("My Decks")
                        .font(.caption.weight(.heavy)).tracking(0.6)
                    Spacer()
                    Text("\(filteredDecks.count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                }
                .textCase(nil)
            }
            .listSectionSeparator(.hidden)

            Section {
                Button { showImport = true } label: {
                    Label("Import .apkg / .colpkg", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.medium))
                }.tint(.indigo)
                Button { showAddDeck = true } label: {
                    Label("Create New Deck", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.medium))
                }.tint(.indigo)
            }
            .listRowBackground(Color(.secondarySystemGroupedBackground))
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.secondarySystemGroupedBackground))
        .animation(.spring(response: 0.34), value: filteredDecks.count)
        .refreshable { /* future: reload stats */ }
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var addDeckSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Japanese Vocabulary", text: $newDeckName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: { Text("Deck Name") } footer: {
                    Text("Use “::” for subdecks. Example: “Languages::Japanese”")
                }
                Section {
                    Label("Decks group cards for focused study. You can import shared decks or create your own.", systemImage: "info.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showAddDeck = false; newDeckName = "" } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createDeck(); showAddDeck = false }
                        .disabled(newDeckName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func createDeck() {
        let name = newDeckName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let deck = Deck(ankiId: Int64(Date().timeIntervalSince1970 * 1000), name: name)
        modelContext.insert(deck)
        try? modelContext.save()
        newDeckName = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    private func deleteDeck(_ deck: Deck) {
        modelContext.delete(deck)
        try? modelContext.save()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

private struct SummaryPill: View {
    let value: String; let label: String; let color: Color; let icon: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(value).font(.headline.weight(.bold).monospacedDigit())
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.separator).opacity(0.08), lineWidth: 1))
    }
}

struct DeckRow: View {
    @Bindable var deck: Deck
    var onStudy: () -> Void

    private var subtitle: String {
        let cards = deck.totalCount == 1 ? "1 card" : "\(deck.totalCount) cards"
        if deck.totalCount == 0 { return "Empty deck" }
        let ready = deck.dueCount + deck.learnCount + deck.newCount
        return ready == 0 ? "\(cards) · all caught up" : "\(cards) · \(ready) ready"
    }

    var body: some View {
        Button(action: onStudy) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: gradientForDeck, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                    Image(systemName: iconForDeck)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(deck.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let parent = deck.parentPath {
                        Text(parent)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        CountPill(count: deck.newCount, color: .blue, label: "new")
                        CountPill(count: deck.learnCount, color: .orange, label: "lrn")
                        CountPill(count: deck.dueCount, color: .green, label: "due")
                    }
                    .padding(.top, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(deck.totalCount == 0)
        .opacity(deck.totalCount == 0 ? 0.55 : 1)
        .accessibilityIdentifier("deck.row")
        .accessibilityLabel("\(deck.displayName), \(subtitle)")
    }

    // `String.hashValue` is seeded per process, so it would give a deck a
    // different colour on every launch. This hash is stable across launches.
    private var stableHash: Int {
        var hash = 5381
        for byte in deck.name.utf8 { hash = (hash &* 33) &+ Int(byte) }
        return abs(hash)
    }
    private var gradientForDeck: [Color] {
        let palettes: [[Color]] = [[.indigo, .purple], [.blue, .cyan], [.green, .mint],
                                   [.orange, .pink], [.red, .orange], [.teal, .blue]]
        return palettes[stableHash % palettes.count]
    }
    private var iconForDeck: String {
        let icons = ["books.vertical.fill", "character.book.closed.fill", "graduationcap.fill",
                     "star.fill", "globe", "brain.head.profile"]
        return icons[stableHash % icons.count]
    }
}

struct CountPill: View {
    let count: Int
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Text("\(count)").font(.caption2.weight(.bold).monospacedDigit())
            Text(label).font(.caption2)
        }
        .foregroundStyle(count == 0 ? Color.secondary : color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(count == 0 ? 0.07 : 0.14)))
    }
}
