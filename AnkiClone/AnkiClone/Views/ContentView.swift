import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var decks: [Deck]
    @Query private var cards: [Card]
    @State private var selectedTab = 0
    @State private var showImport = false

    private var totalDue: Int {
        cards.filter { $0.queue == 2 && $0.dueDate <= Date() }.count
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DeckListView()
                .tabItem {
                    Label("Decks", systemImage: selectedTab == 0 ? "rectangle.stack.fill" : "rectangle.stack")
                }
                .tag(0)
                .badge(totalDue > 0 ? totalDue : 0)

            BrowseView()
                .tabItem {
                    Label("Browse", systemImage: "magnifyingglass")
                }
                .tag(1)

            StatsView()
                .tabItem {
                    Label("Stats", systemImage: selectedTab == 2 ? "chart.bar.fill" : "chart.bar")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: selectedTab == 3 ? "gearshape.fill" : "gearshape")
                }
                .tag(3)
        }
        .tint(.indigo)
        // Modern tab bar appearance (iOS 17 translucency)
        .onAppear {
            let tabBar = UITabBar.appearance()
            tabBar.isTranslucent = true
        }
        .sheet(isPresented: $showImport) { ImportView() }
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "apkg" || url.pathExtension.lowercased() == "colpkg" {
                showImport = true
                // Delay posting to ensure sheet is presented
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: .didReceiveApkgURL, object: url)
                }
            }
        }
    }
}

extension Notification.Name {
    static let didReceiveApkgURL = Notification.Name("didReceiveApkgURL")
}

#Preview {
    ContentView()
        .modelContainer(for: [Deck.self, Note.self, Card.self, NoteType.self, ReviewLog.self], inMemory: true)
}
