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

    private var filteredDecks: [Deck] {
        if searchText.isEmpty { return decks }
        let q = searchText.lowercased()
        return decks.filter { $0.name.lowercased().contains(q) || $0.desc.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if decks.isEmpty {
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
            .navigationDestination(item: $selectedDeck) { deck in
                StudyView(deck: deck)
            }
            .alert("Delete Deck?", isPresented: $showDeleteConfirm, presenting: deckToDelete) { deck in
                Button("Delete", role: .destructive) { deleteDeck(deck) }
                Button("Cancel", role: .cancel) {}
            } message: { deck in
                Text("This will delete \"\(deck.name)\" and all \(deck.cards.count) cards. This cannot be undone.")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button { showAddDeck = true } label: { Label("New Deck", systemImage: "plus.circle.fill") }
                Button { showImport = true } label: { Label("Import .apkg", systemImage: "square.and.arrow.down") }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.body.weight(.semibold))
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 10) {
                Button { showAddDeck = true } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color(.secondarySystemFill)))
                }
                Button { showImport = true } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.indigo)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Decks Yet", systemImage: "rectangle.stack.badge.plus")
                .foregroundStyle(.indigo)
        } description: {
            VStack(spacing: 8) {
                Text("Import an .apkg file to get started.")
                    .font(.subheadline)
                Text("Supports Anki decks with scheduling, media, and HTML templates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } actions: {
            VStack(spacing: 12) {
                Button { showImport = true } label: {
                    Label("Import .apkg", systemImage: "square.and.arrow.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.indigo)

                Button { showAddDeck = true } label: {
                    Label("Create Empty Deck", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Text("Try the samples in the project folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)
        }
    }

    private var deckList: some View {
        List {
            // Hero Summary
            Section {
                VStack(spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Welcome back")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.6)
                            Text("\(totalDue) due today")
                                .font(.title2.weight(.bold))
                                .contentTransition(.numericText())
                        }
                        Spacer()
                        ZStack {
                            Circle().fill(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 56, height: 56)
                            Image(systemName: "flame.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                        .shadow(color: .indigo.opacity(0.35), radius: 10, y: 4)
                    }

                    HStack(spacing: 10) {
                        SummaryPill(value: "\(decks.reduce(0) { $0 + $1.totalCount })", label: "Total", color: .primary, icon: "rectangle.stack.fill")
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
                        .padding(.horizontal, 0)
                )
                .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)

            Section {
                ForEach(filteredDecks) { deck in
                    DeckRow(deck: deck) {
                        selectedDeck = deck
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deckToDelete = deck
                            showDeleteConfirm = true
                        } label: { Label("Delete", systemImage: "trash.fill") }
                        Button {
                            selectedDeck = deck
                        } label: { Label("Study", systemImage: "play.fill") }
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
                        .font(.caption.weight(.heavy))
                        .tracking(0.6)
                    Spacer()
                    Text("\(filteredDecks.count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                }
                .textCase(nil)
            }
            .listSectionSeparator(.hidden)

            Section {
                Button { showImport = true } label: {
                    Label("Import .apkg / .colpkg", systemImage: "square.and.arrow.down.circle.fill")
                        .font(.subheadline.weight(.medium))
                }
                .tint(.indigo)
                Button { showAddDeck = true } label: {
                    Label("Create New Deck", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.medium))
                }
                .tint(.indigo)
            }
            .listRowBackground(Color(.secondarySystemGroupedBackground))
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.secondarySystemGroupedBackground))
        .animation(.spring(response: 0.35), value: filteredDecks.count)
    }

    private var addDeckSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Japanese Vocabulary", text: $newDeckName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Deck Name")
                } footer: {
                    Text("Use \"::\" for subdecks. Example: \"Languages::Japanese\"")
                }

                Section {
                    HStack {
                        Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                        Text("Decks group cards for focused study. You can import shared decks or create your own.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showAddDeck = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createDeck()
                        showAddDeck = false
                    }
                    .disabled(newDeckName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var totalDue: Int { decks.reduce(0) { $0 + $1.dueCount } }
    private var totalNew: Int { decks.reduce(0) { $0 + $1.newCount } }
    private var totalLearn: Int { decks.reduce(0) { $0 + $1.learnCount } }

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
    let value: String
    let label: String
    let color: Color
    let icon: String
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

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: gradientForDeck, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 48, height: 48)
                    .shadow(color: gradientForDeck.first?.opacity(0.35) ?? .clear, radius: 8, y: 4)
                Image(systemName: iconForDeck)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(deck.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if let parent = deck.parentPath {
                    Text(parent)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text("\(deck.totalCount) cards")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if deck.totalCount > 0 {
                        Circle().fill(Color(.separator)).frame(width: 3, height: 3)
                        Text(deck.dueCount > 0 ? "Due now" : "All caught up")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(deck.dueCount > 0 ? .green : .secondary)
                    }
                }
            }

            Spacer()

            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    CountPill(count: deck.newCount, color: .blue, label: "new")
                    CountPill(count: deck.learnCount, color: .red, label: "lrn")
                    CountPill(count: deck.dueCount, color: .green, label: "due")
                }
                Button(action: onStudy) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.caption2)
                        Text("Study").font(.caption.weight(.heavy))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(deck.totalCount == 0 ? Color.gray : Color.indigo)
                            .shadow(color: (deck.totalCount == 0 ? Color.clear : Color.indigo.opacity(0.35)), radius: 6, y: 3)
                    )
                }
                .buttonStyle(.plain)
                .disabled(deck.totalCount == 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator).opacity(0.08), lineWidth: 1)
        )
    }

    private var gradientForDeck: [Color] {
        let hash = abs(deck.name.hashValue)
        let palettes: [[Color]] = [
            [.indigo, .purple], [.blue, .cyan], [.green, .mint],
            [.orange, .pink], [.red, .orange], [.teal, .blue]
        ]
        return palettes[hash % palettes.count]
    }
    private var iconForDeck: String {
        let hash = abs(deck.name.hashValue)
        let icons = ["books.vertical.fill", "character.book.closed.fill", "graduationcap.fill", "star.fill", "globe", "brain.head.profile"]
        return icons[hash % icons.count]
    }
}

struct CountPill: View {
    let count: Int
    let color: Color
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            Text("\(count)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(count == 0 ? .secondary : color)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 32)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(count == 0 ? 0.06 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(count == 0 ? 0.08 : 0.18), lineWidth: 1)
        )
    }
}
