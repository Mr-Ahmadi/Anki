import SwiftUI
import SwiftData
import AVFoundation

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var decks: [Deck]
    @Query private var cards: [Card]
    @Query private var notes: [Note]

    @State private var showResetConfirm = false
    @State private var showImport = false
    @AppStorage("dailyNew") private var dailyNew = 20
    @AppStorage("dailyReview") private var dailyReview = 200
    @AppStorage("showIntervals") private var showIntervals = true
    @AppStorage("ttsAutoPlay") private var ttsAutoPlay = false
    @AppStorage("ttsRate") private var ttsRate: Double = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @StateObject private var speech = SpeechService()
    @State private var testText = "Hello, this is pronunciation test"

    var body: some View {
        NavigationStack {
            List {
                studySection
                pronunciationSection
                dataSection
                mediaSection
                dangerSection
                aboutSection
                featuresSection
            }
            .navigationTitle("Settings")
            .alert("Delete All Data?", isPresented: $showResetConfirm) {
                Button("Delete", role: .destructive) { deleteAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete \(cards.count) cards and \(decks.count) decks. This cannot be undone.")
            }
            .sheet(isPresented: $showImport) { ImportView() }
        }
    }

    private var studySection: some View {
        Section {
            Stepper(value: $dailyNew, in: 0...100, step: 5) {
                LabeledContent("New cards/day", value: "\(dailyNew)")
            }
            Stepper(value: $dailyReview, in: 0...1000, step: 10) {
                LabeledContent("Reviews/day", value: "\(dailyReview)")
            }
            Toggle(isOn: $showIntervals) {
                Label("Show next intervals", systemImage: "timer")
            }
            Toggle(isOn: $hapticsEnabled) {
                Label("Haptic feedback", systemImage: "iphone.radiowaves.left.and.right")
            }
        } header: {
            Label("Study Options", systemImage: "slider.horizontal.3").font(.caption.weight(.heavy)).foregroundStyle(.indigo)
        }
    }

    private var pronunciationSection: some View {
        Section {
            Toggle(isOn: $ttsAutoPlay) {
                Label("Auto-play pronunciation", systemImage: "speaker.wave.2.fill")
            }
            .tint(.indigo)
            .onChange(of: ttsAutoPlay) { _, v in speech.autoPlay = v }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Speech rate", systemImage: "speedometer")
                    Spacer()
                    Text(String(format: "%.2f", ttsRate))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $ttsRate, in: 0.3...0.65, step: 0.02) {
                    Text("Rate")
                } onEditingChanged: { _ in
                    speech.speechRate = Float(ttsRate)
                }
                .tint(.indigo)
                HStack {
                    Text("Slow").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("Fast").font(.caption2).foregroundStyle(.secondary)
                }
            }

            // Voice picker
            Picker("Voice", selection: Binding(
                get: { speech.selectedVoiceIdentifier ?? "default" },
                set: { speech.selectedVoiceIdentifier = $0 == "default" ? nil : $0 }
            )) {
                Text("Auto (detect language)").tag("default")
                ForEach(speech.availableVoices.prefix(20), id: \.identifier) { voice in
                    Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                }
            }
            .pickerStyle(.navigationLink)

            // Test area
            VStack(spacing: 10) {
                TextField("Test phrase", text: $testText)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 12) {
                    Button {
                        speech.speak(testText)
                    } label: {
                        Label(speech.isSpeaking ? "Speaking…" : "Test Pronunciation", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(testText.isEmpty || speech.isSpeaking)

                    Button("Stop", systemImage: "stop.circle") {
                        speech.stop()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!speech.isSpeaking)
                }
                .controlSize(.small)
            }
            .listRowBackground(Color(.secondarySystemGroupedBackground))
        } header: {
            Label("Pronunciation (Built-in TTS)", systemImage: "waveform").font(.caption.weight(.heavy)).foregroundStyle(.indigo)
        } footer: {
            Text("Uses iOS built-in AVSpeechSynthesizer. Auto-detects language (English, Japanese, Spanish, etc.) No internet required. Tap the speaker button on cards or enable auto-play.")
                .font(.caption2)
        }
    }

    private var dataSection: some View {
        Section("Data") {
            LabeledContent("Decks", value: "\(decks.count)")
            LabeledContent("Notes", value: "\(notes.count)")
            LabeledContent("Cards", value: "\(cards.count)")
            LabeledContent("Media", value: mediaCountText)
        }
    }

    private var mediaSection: some View {
        Section("Media") {
            Button { openMediaFolder() } label: {
                Label("Open Media Folder", systemImage: "folder.fill")
            }
            Button { clearMediaCache() } label: {
                Label("Clear Media Cache", systemImage: "trash")
            }
            .foregroundStyle(.orange)
        }
    }

    private var dangerSection: some View {
        Section("Danger Zone") {
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Label("Delete All Data", systemImage: "trash.fill")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "books.vertical.fill").foregroundStyle(.indigo)
                    Text("AnkiClone").font(.headline)
                }
                Text("An open-source replacement for Anki on iOS. Fully compatible with .apkg files, including scheduling, HTML templates, and media.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(destination: URL(string: "https://docs.ankiweb.net")!) {
                    Label("Anki Manual", systemImage: "book.fill")
                }
                .font(.caption.weight(.medium))
                Text("Anki® is a trademark of Damien Elmes. This app is not affiliated with Anki.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .listRowBackground(Color.clear)
        }
    }

    private var featuresSection: some View {
        Section("Supported Features") {
            FeatureRow(text: "ZIP .apkg import (collection.anki21 + media)")
            FeatureRow(text: "SM-2 / FSRS-lite scheduling (Again/Hard/Good/Easy)")
            FeatureRow(text: "Mustache templates: {{Field}}, {{#Field}}, {{FrontSide}}")
            FeatureRow(text: "Cloze deletions, [sound:], <img>, CSS")
            FeatureRow(text: "Subdecks (\"::\"), tags, suspended/buried")
            FeatureRow(text: "WKWebView rendering, inline audio")
            FeatureRow(text: "Built-in TTS pronunciation (AVSpeechSynthesizer)")
        }
    }

    private var mediaCountText: String {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AnkiMedia", isDirectory: true)
        guard let url, let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return "0 files" }
        let size = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]).reduce(0) { acc, u in
            let s = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return acc + s
        }) ?? 0
        let mb = Double(size) / 1024 / 1024
        return "\(files.count) files (\(String(format: "%.1f MB", mb)))"
    }

    private func deleteAll() {
        for deck in decks { modelContext.delete(deck) }
        for card in cards { modelContext.delete(card) }
        for note in notes { modelContext.delete(note) }
        if let types = try? modelContext.fetch(FetchDescriptor<NoteType>()) {
            for t in types { modelContext.delete(t) }
        }
        try? modelContext.save()
        clearMediaCache()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    private func clearMediaCache() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AnkiMedia", isDirectory: true)
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func openMediaFolder() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AnkiMedia", isDirectory: true)
        guard let url else { return }
        print("Media folder: \(url.path)")
        if let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            print("Files: \(files.map(\.lastPathComponent))")
        }
    }
}

private struct FeatureRow: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark.seal.fill")
            .foregroundStyle(.green)
            .font(.caption.weight(.medium))
    }
}
