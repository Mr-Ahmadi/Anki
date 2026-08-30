import AVFoundation
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var decks: [Deck]
    @Query private var cards: [Card]
    @Query private var notes: [Note]

    @ObservedObject private var speech = SpeechService.shared

    @AppStorage("dailyNew") private var dailyNew = 20
    @AppStorage("dailyReview") private var dailyReview = 200
    @AppStorage("study.showIntervals") private var showIntervals = true
    @AppStorage("study.useSmartLayout") private var useSmartLayout = true

    @State private var showResetConfirm = false
    @State private var showClearMediaConfirm = false
    @State private var mediaSummary = MediaSummary()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Stepper(value: $dailyNew, in: 0...200, step: 5) {
                        LabeledContent("New cards / day", value: "\(dailyNew)")
                    }
                    Stepper(value: $dailyReview, in: 0...2000, step: 10) {
                        LabeledContent("Reviews / day", value: "\(dailyReview)")
                    }
                    Toggle(isOn: $showIntervals) {
                        Label("Show next intervals", systemImage: "timer")
                    }
                    Toggle(isOn: $useSmartLayout) {
                        Label("Clean card layout", systemImage: "textformat")
                    }
                } header: {
                    Text("Studying")
                } footer: {
                    Text("Clean layout separates a word, its meaning and its examples so each can be read and played on its own. Cards it can't parse fall back to the deck's own template.")
                }

                Section("Pronunciation") {
                    NavigationLink {
                        PronunciationSettings(speech: speech)
                    } label: {
                        LabeledContent {
                            Text(speech.autoPlay == .off ? "Manual" : speech.autoPlay.label)
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Voice & speed", systemImage: "waveform")
                        }
                    }
                    .accessibilityIdentifier("settings.pronunciation")
                }

                Section("Library") {
                    LabeledContent("Decks", value: "\(decks.count)")
                    LabeledContent("Notes", value: "\(notes.count)")
                    LabeledContent("Cards", value: "\(cards.count)")
                    LabeledContent("Media", value: mediaSummary.description)
                }

                Section {
                    Button(role: .destructive) { showClearMediaConfirm = true } label: {
                        Label("Clear media files", systemImage: "photo.badge.arrow.down")
                    }
                    Button(role: .destructive) { showResetConfirm = true } label: {
                        Label("Delete all decks & cards", systemImage: "trash")
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Everything stays on this device. Nothing is uploaded.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.shortVersion)
                    Link(destination: URL(string: "https://docs.ankiweb.net")!) {
                        Label("Anki manual", systemImage: "book")
                    }
                    Text("Anki® is a trademark of Damien Elmes. This app is not affiliated with or endorsed by Anki.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .task { mediaSummary = MediaSummary.load() }
            .confirmationDialog(
                "Delete all decks and cards?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) { deleteAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(cards.count) cards in \(decks.count) decks will be removed. This can't be undone.")
            }
            .confirmationDialog(
                "Clear imported media?",
                isPresented: $showClearMediaConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear \(mediaSummary.description)", role: .destructive) { clearMedia() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Images and audio will be removed. Re-import a deck to restore them.")
            }
        }
    }

    private func deleteAll() {
        for card in cards { modelContext.delete(card) }
        for note in notes { modelContext.delete(note) }
        for deck in decks { modelContext.delete(deck) }
        if let types = try? modelContext.fetch(FetchDescriptor<NoteType>()) {
            for type in types { modelContext.delete(type) }
        }
        if let logs = try? modelContext.fetch(FetchDescriptor<ReviewLog>()) {
            for log in logs { modelContext.delete(log) }
        }
        try? modelContext.save()
        clearMedia()
    }

    private func clearMedia() {
        guard let directory = SpeechService.mediaDirectory else { return }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        mediaSummary = MediaSummary.load()
    }
}

// MARK: - Pronunciation settings

struct PronunciationSettings: View {
    @ObservedObject var speech: SpeechService
    @State private var sampleWord = "pronunciation"

    private var languageForVoices: String { speech.studyLanguage }

    var body: some View {
        List {
            Section {
                Picker("Play automatically", selection: $speech.autoPlay) {
                    ForEach(SpeechService.AutoPlayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Toggle(isOn: $speech.preferRecordedAudio) {
                    Label("Use the deck's own audio", systemImage: "waveform.badge.mic")
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("When a deck ships a recording for a word, it is played instead of the synthesised voice.")
            }

            Section {
                RateSlider(title: "Word speed", systemImage: "textformat.abc", value: $speech.wordRate)
                RateSlider(title: "Sentence speed", systemImage: "text.quote", value: $speech.sentenceRate)
            } header: {
                Text("Speed")
            } footer: {
                Text("Words are read slower than example sentences by default — easier to copy a pronunciation from.")
            }

            Section {
                Picker("Card language", selection: $speech.studyLanguage) {
                    ForEach(speech.installedLanguages, id: \.self) { code in
                        Text(Language.displayName(code)).tag(code)
                    }
                }
                voicePicker
            } header: {
                Text("Voice")
            } footer: {
                if speech.hasOnlyCompactVoice(for: languageForVoices) {
                    Text("Only the compact voice is installed for this language. For a much clearer voice, open Settings › Accessibility › Spoken Content › Voices and download an Enhanced or Premium voice.")
                } else {
                    Text("Text in another script — a Persian or Japanese translation, say — is spoken by that language's voice automatically.")
                }
            }

            Section("Try it") {
                TextField("Word or sentence", text: $sampleWord)
                    .autocorrectionDisabled()
                HStack {
                    Button {
                        speech.speak(sampleWord, language: speech.studyLanguage, kind: .word)
                    } label: {
                        Label("As a word", systemImage: "play.circle")
                    }
                    Spacer()
                    Button {
                        speech.speak(sampleWord, language: speech.studyLanguage, kind: .sentence)
                    } label: {
                        Label("As a sentence", systemImage: "play.circle.fill")
                    }
                }
                .buttonStyle(.borderless)
                if speech.isSpeaking {
                    Button(role: .destructive) { speech.stop() } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                }
            }
        }
        .navigationTitle("Pronunciation")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var voicePicker: some View {
        let voices = speech.voices(forLanguage: languageForVoices)
        let base = Language.base(of: languageForVoices).lowercased()
        Picker("Voice", selection: Binding(
            get: { speech.voiceOverrides[base] ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    speech.voiceOverrides.removeValue(forKey: base)
                } else {
                    speech.voiceOverrides[base] = newValue
                }
            }
        )) {
            Text("Best available").tag("")
            ForEach(voices, id: \.identifier) { voice in
                Text(voiceLabel(voice)).tag(voice.identifier)
            }
        }
        .disabled(voices.isEmpty)
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "\(voice.name) — Premium"
        case .enhanced: return "\(voice.name) — Enhanced"
        default: return voice.name
        }
    }
}

private struct RateSlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(percentLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(get: { Double(value) }, set: { value = Float($0) }),
                in: Double(SpeechService.minimumRate)...Double(SpeechService.maximumRate)
            ) {
                Text(title)
            } minimumValueLabel: {
                Image(systemName: "tortoise").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "hare").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var percentLabel: String {
        let fraction = (value - SpeechService.minimumRate) / (SpeechService.maximumRate - SpeechService.minimumRate)
        return "\(Int(fraction * 100))%"
    }
}

// MARK: - Helpers

struct MediaSummary {
    var fileCount = 0
    var byteCount: Int64 = 0

    var description: String {
        guard fileCount > 0 else { return "None" }
        let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        return "\(fileCount) files · \(size)"
    }

    static func load() -> MediaSummary {
        guard let directory = SpeechService.mediaDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]
              )
        else { return MediaSummary() }
        let bytes = files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return MediaSummary(fileCount: files.count, byteCount: bytes)
    }
}

extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
