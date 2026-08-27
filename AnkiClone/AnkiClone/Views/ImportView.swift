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
                if isImporting {
                    importingView
                } else if let result {
                    successView(result)
                } else if let errorMessage {
                    errorView(errorMessage)
                } else {
                    promptView
                }
            }
            .padding()
            .navigationTitle("Import Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPicker { url in
                    pendingURL = url
                    Task { await doImport(url: url) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .didReceiveApkgURL)) { note in
                if let url = note.object as? URL {
                    Task { await doImport(url: url) }
                }
            }
        }
    }

    private var promptView: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .padding(.top, 24)

            Text("Import Anki Deck")
                .font(.title2.weight(.bold))

            Text("Supports .apkg and .colpkg files exported from Anki Desktop or AnkiWeb. Includes cards, scheduling, and media.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button {
                showPicker = true
            } label: {
                Label("Choose File", systemImage: "folder.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)

            // Drop hint
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("How to export from Anki", systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                    Text("Anki Desktop → File → Export → *Anki Deck Package (.apkg)* → Include media")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Or download .apkg from AnkiWeb Shared Decks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Sample decks shortcut
            if let samples = sampleApkgs(), !samples.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Test with sample")
                        .font(.caption.weight(.semibold))
                    ForEach(samples, id: \.lastPathComponent) { url in
                        Button {
                            Task { await doImport(url: url) }
                        } label: {
                            Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc.zipper")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
    }

    private var importingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Importing…")
                .font(.headline)
            Text(progressMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func successView(_ r: ImportResult) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Import Complete!")
                .font(.title2.weight(.bold))
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Decks", value: "\(r.decksImported)")
                    LabeledContent("Notes", value: "\(r.notesImported)")
                    LabeledContent("Cards", value: "\(r.cardsImported)")
                    LabeledContent("Media", value: "\(r.mediaFiles) files")
                }
            }
            if !r.deckNames.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(r.deckNames, id: \.self) { name in
                            Label(name, systemImage: "rectangle.stack")
                                .font(.caption)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("Import Another") {
                self.result = nil
                self.errorMessage = nil
            }
            .buttonStyle(.bordered)
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            Text("Import Failed")
                .font(.title2.weight(.bold))
            Text(msg)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Try Again") {
                errorMessage = nil
                if let url = pendingURL { Task { await doImport(url: url) } }
            }
            .buttonStyle(.borderedProminent)
            Button("Choose Different File") { showPicker = true }
                .buttonStyle(.bordered)
        }
    }

    private func doImport(url: URL) async {
        await MainActor.run {
            isImporting = true
            progressMessage = url.lastPathComponent
            errorMessage = nil
            result = nil
        }

        do {
            // Simulate progress steps
            await MainActor.run { progressMessage = "Unzipping \(url.lastPathComponent)…" }
            try await Task.sleep(nanoseconds: 200_000_000)

            await MainActor.run { progressMessage = "Parsing collection…" }

            let importer = ApkgImporter(modelContext: modelContext)
            let res = try await importer.import(from: url)

            await MainActor.run {
                isImporting = false
                result = res
            }
        } catch {
            await MainActor.run {
                isImporting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sampleApkgs() -> [URL]? {
        // Look for samples relative to project — only works in simulator/dev
        let fm = FileManager.default
        // Try common locations
        let candidates = [
            URL(fileURLWithPath: "/Users/aliahmadi/Documents/Projects/Anki/samples"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("samples")
        ]
        for dir in candidates {
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                let apkgs = files.filter { $0.pathExtension.lowercased() == "apkg" }
                if !apkgs.isEmpty { return apkgs }
            }
        }
        return nil
    }
}

// MARK: - Document Picker

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
