import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ZIPFoundation

struct ImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var isImporting = false
    @State private var progressMessage = ""
    @State private var result: ImportResult?
    @State private var errorMessage: String?
    @State private var pendingURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if isImporting { importingView }
                else if let result { successView(result) }
                else if let errorMessage { errorView(errorMessage) }
                else { promptView }
            }
            .padding()
            .navigationTitle("Import Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPicker { url in
                    pendingURL = url
                    Task { await doImport(url: url) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .didReceiveApkgURL)) { note in
                if let url = note.object as? URL { Task { await doImport(url: url) } }
            }
        }
    }

    private var promptView: some View {
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.10)).frame(width: 88, height: 88)
                    Circle().fill(Color.blue.opacity(0.05)).frame(width: 120, height: 120)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(LinearGradient(colors: [.blue,.indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .padding(.top, 18)

                VStack(spacing: 8) {
                    Text("Import Anki Deck").font(.title2.weight(.bold))
                    Text("Supports .apkg and .colpkg files from Anki Desktop or AnkiWeb. Cards, scheduling, and media are preserved.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.subheadline)
                        .padding(.horizontal)
                }

                Button { showPicker = true } label: {
                    Label("Choose File", systemImage: "folder.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(.indigo)
                .shadow(color: .indigo.opacity(0.22), radius: 10, y: 6)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("How to export from Anki", systemImage: "info.circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Anki Desktop → File → Export → Anki Deck Package (.apkg)", systemImage: "1.circle.fill")
                            Label("Check “Include media” for images/audio", systemImage: "2.circle.fill")
                            Label("Or download .apkg from AnkiWeb Shared Decks", systemImage: "3.circle.fill")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                let samples = sampleApkgs()
                if !samples.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Try a sample deck", systemImage: "doc.zipper").font(.caption.weight(.semibold)).foregroundStyle(.indigo)
                        ForEach(samples, id: \.lastPathComponent) { url in
                            Button { Task { await doImport(url: url) } } label: {
                                HStack {
                                    Image(systemName: "doc.fill").foregroundStyle(.indigo)
                                    Text(url.deletingPathExtension().lastPathComponent).font(.subheadline.weight(.medium))
                                    Spacer()
                                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator).opacity(0.08), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Your data stays on-device. Media is saved to App Support/AnkiMedia.")
                    .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
        }
        .scrollIndicators(.hidden)
    }

    private var importingView: some View {
        VStack(spacing: 18) {
            ProgressView().scaleEffect(1.4).tint(.indigo)
            VStack(spacing: 6) {
                Text("Importing…").font(.headline)
                Text(progressMessage).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("This may take a moment for large decks.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func successView(_ r: ImportResult) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.green.opacity(0.12)).frame(width: 88, height: 88)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.green)
            }
            Text("Import Complete!").font(.title2.weight(.bold))
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Decks", value: "\(r.decksImported)")
                    LabeledContent("Notes", value: "\(r.notesImported)")
                    LabeledContent("Cards", value: "\(r.cardsImported)")
                    LabeledContent("Media", value: "\(r.mediaFiles) files")
                }
            }
            if !r.deckNames.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(r.deckNames, id: \.self) { name in
                            Label(name, systemImage: "rectangle.stack.fill").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            VStack(spacing: 10) {
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large).tint(.indigo).frame(maxWidth: .infinity)
                Button("Import Another") { self.result = nil; self.errorMessage = nil }.buttonStyle(.bordered).frame(maxWidth: .infinity)
            }
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.red.opacity(0.10)).frame(width: 88, height: 88)
                Image(systemName: "xmark.octagon.fill").font(.system(size: 54)).foregroundStyle(.red)
            }
            Text("Import Failed").font(.title2.weight(.bold))
            Text(msg).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            VStack(spacing: 10) {
                Button("Try Again") {
                    errorMessage = nil
                    if let url = pendingURL { Task { await doImport(url: url) } }
                }.buttonStyle(.borderedProminent).tint(.indigo)
                Button("Choose Different File") { showPicker = true }.buttonStyle(.bordered)
            }
        }
    }

    private func doImport(url: URL) async {
        await MainActor.run { isImporting = true; progressMessage = url.lastPathComponent; errorMessage = nil; result = nil }
        do {
            await MainActor.run { progressMessage = "Unzipping \(url.lastPathComponent)…" }
            try await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run { progressMessage = "Parsing collection…" }
            let importer = ApkgImporter(modelContext: modelContext)
            let res = try await importer.import(from: url)
            await MainActor.run { isImporting = false; result = res; UINotificationFeedbackGenerator().notificationOccurred(.success) }
        } catch {
            await MainActor.run { isImporting = false; errorMessage = error.localizedDescription; UINotificationFeedbackGenerator().notificationOccurred(.error) }
        }
    }

    /// Decks bundled with the app, so the sample list works on device too.
    private func sampleApkgs() -> [URL] {
        guard let directory = Bundle.main.url(forResource: "samples", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { ["apkg", "colpkg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [UTType(filenameExtension: "apkg") ?? .zip, .zip, .data]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
