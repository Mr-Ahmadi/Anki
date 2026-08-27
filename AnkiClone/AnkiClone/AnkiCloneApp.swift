import SwiftUI
import SwiftData

@main
struct AnkiCloneApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Deck.self,
            NoteType.self,
            Note.self,
            Card.self,
            ReviewLog.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(sharedModelContainer)
        }
    }
}
