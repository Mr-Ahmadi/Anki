import AVFoundation
import Foundation
import SwiftUI
import UIKit

// MARK: - SpeechService
// One shared speech engine for the whole app.
//
// Two things make this more than a wrapper around AVSpeechSynthesizer:
//
//  1. It speaks a *sequence of items* rather than one blob, and publishes which
//     item is currently sounding, so a card can highlight the sentence being
//     read and offer per-part playback (word alone, one example alone).
//  2. Each item carries its own language, so a Persian translation is spoken by
//     a Persian voice instead of being mangled by an English one — and a word
//     is spoken slower than a sentence, which is what you want when learning
//     pronunciation.
//
// When a deck ships recorded audio for a word (`[sound:aberrant.mp3]`), that
// recording is preferred over synthesis.

@MainActor
final class SpeechService: NSObject, ObservableObject {

    static let shared = SpeechService()

    // MARK: Types

    struct Item: Identifiable, Hashable {
        let id: UUID
        var text: String
        var language: String?
        var kind: Kind

        init(id: UUID = UUID(), text: String, language: String? = nil, kind: Kind = .sentence) {
            self.id = id
            self.text = text
            self.language = language
            self.kind = kind
        }
    }

    enum Kind: Hashable {
        /// A single word or short phrase — spoken slower, with a short lead-out.
        case word
        case sentence
    }

    enum AutoPlayMode: String, CaseIterable, Identifiable {
        case off, word, wordAndExamples

        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .word: return "Word only"
            case .wordAndExamples: return "Word + examples"
            }
        }
    }

    // MARK: Published state

    @Published private(set) var isSpeaking = false
    /// The item currently being spoken, for UI highlighting.
    @Published private(set) var currentItemID: UUID?

    @Published var autoPlay: AutoPlayMode {
        didSet { defaults.set(autoPlay.rawValue, forKey: Keys.autoPlay) }
    }
    /// Rate for single words. Slower than sentences by design.
    @Published var wordRate: Float {
        didSet {
            let clamped = Self.clampRate(wordRate)
            if clamped != wordRate { wordRate = clamped; return }
            defaults.set(clamped, forKey: Keys.wordRate)
        }
    }
    @Published var sentenceRate: Float {
        didSet {
            let clamped = Self.clampRate(sentenceRate)
            if clamped != sentenceRate { sentenceRate = clamped; return }
            defaults.set(clamped, forKey: Keys.sentenceRate)
        }
    }
    /// Explicit voice per language base code, e.g. ["en": "com.apple.voice…"].
    @Published var voiceOverrides: [String: String] {
        didSet { defaults.set(voiceOverrides, forKey: Keys.voiceOverrides) }
    }
    /// Prefer a deck's own recorded audio over synthesis when the file exists.
    @Published var preferRecordedAudio: Bool {
        didSet { defaults.set(preferRecordedAudio, forKey: Keys.preferRecorded) }
    }
    /// Language assumed for cards whose script gives nothing away.
    @Published var studyLanguage: String {
        didSet { defaults.set(studyLanguage, forKey: Keys.studyLanguage) }
    }

    // MARK: Private state

    private enum Keys {
        static let autoPlay = "speech.autoPlay"
        static let wordRate = "speech.wordRate"
        static let sentenceRate = "speech.sentenceRate"
        static let voiceOverrides = "speech.voiceOverrides"
        static let preferRecorded = "speech.preferRecordedAudio"
        static let studyLanguage = "speech.studyLanguage"
    }

    private let defaults = UserDefaults.standard
    private let synthesizer = AVSpeechSynthesizer()
    private var utteranceItems: [ObjectIdentifier: UUID] = [:]
    private var pendingTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var audioPlayerDelegate: AudioPlayerDelegate?
    private var observers: [NSObjectProtocol] = []
    private var sessionConfigured = false

    // MARK: Init

    override init() {
        // Pronunciation is the point of this app, so a new install speaks the
        // word when a card appears; examples stay on demand.
        autoPlay = AutoPlayMode(rawValue: defaults.string(forKey: Keys.autoPlay) ?? "") ?? .word
        let storedWord = defaults.float(forKey: Keys.wordRate)
        let storedSentence = defaults.float(forKey: Keys.sentenceRate)
        wordRate = storedWord > 0 ? Self.clampRate(storedWord) : Self.defaultWordRate
        sentenceRate = storedSentence > 0 ? Self.clampRate(storedSentence) : AVSpeechUtteranceDefaultSpeechRate
        voiceOverrides = defaults.dictionary(forKey: Keys.voiceOverrides) as? [String: String] ?? [:]
        preferRecordedAudio = defaults.object(forKey: Keys.preferRecorded) as? Bool ?? true
        studyLanguage = defaults.string(forKey: Keys.studyLanguage) ?? "en-US"
        super.init()
        synthesizer.delegate = self
        observeInterruptions()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    static let defaultWordRate: Float = max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate - 0.10)
    static let minimumRate: Float = max(AVSpeechUtteranceMinimumSpeechRate, 0.25)
    static let maximumRate: Float = min(AVSpeechUtteranceMaximumSpeechRate, 0.70)
    private static func clampRate(_ rate: Float) -> Float { min(max(rate, minimumRate), maximumRate) }

    // MARK: - Speaking

    /// Speak a sequence, in order, stopping anything already playing.
    func speak(_ items: [Item]) {
        let cleaned = items.compactMap { item -> Item? in
            var copy = item
            copy.text = Self.speakableText(item.text)
            return copy.text.isEmpty ? nil : copy
        }
        stop()
        guard !cleaned.isEmpty else { return }
        activateSession()
        isSpeaking = true
        for (index, item) in cleaned.enumerated() {
            let utterance = AVSpeechUtterance(string: item.text)
            utterance.rate = item.kind == .word ? wordRate : sentenceRate
            utterance.volume = 1.0
            utterance.pitchMultiplier = 1.0
            // Breathing room between sentences; a beat after a lone word.
            utterance.postUtteranceDelay = index == cleaned.count - 1 ? 0 : (item.kind == .word ? 0.45 : 0.30)
            utterance.voice = voice(for: item)
            utteranceItems[ObjectIdentifier(utterance)] = item.id
            synthesizer.speak(utterance)
        }
    }

    func speak(_ text: String, language: String? = nil, kind: Kind = .sentence) {
        speak([Item(text: text, language: language, kind: kind)])
    }

    /// Speak a word, preferring the deck's own recording when one exists.
    func speakWord(_ text: String, language: String? = nil, recordings: [String] = []) {
        if preferRecordedAudio, let url = Self.firstExistingMedia(in: recordings) {
            playAudio(at: url)
            return
        }
        speak([Item(text: text, language: language, kind: .word)])
    }

    /// Run `speak` after a short delay; cancelled by any later call or `stop()`.
    func speakAfterDelay(_ items: [Item], delay: TimeInterval = 0.35) {
        pendingTask?.cancel()
        guard !items.isEmpty else { return }
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.speak(items)
        }
    }

    func stop() {
        pendingTask?.cancel()
        pendingTask = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
        audioPlayer = nil
        utteranceItems.removeAll()
        isSpeaking = false
        currentItemID = nil
    }

    func toggle(_ items: [Item]) {
        if isSpeaking { stop() } else { speak(items) }
    }

    // MARK: - Recorded media

    nonisolated static var mediaDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AnkiMedia", isDirectory: true)
    }

    /// First filename in `names` that exists in the media folder as playable audio.
    nonisolated static func firstExistingMedia(in names: [String]) -> URL? {
        guard let directory = mediaDirectory else { return nil }
        let playable: Set<String> = ["mp3", "m4a", "wav", "aac", "aiff", "aif", "caf", "mp4", "ogg", "opus", "flac"]
        for name in names {
            let safe = name.replacingOccurrences(of: "/", with: "_")
            guard playable.contains(URL(fileURLWithPath: safe).pathExtension.lowercased()) else { continue }
            let url = directory.appendingPathComponent(safe)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func playAudio(at url: URL) {
        stop()
        activateSession()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let delegate = AudioPlayerDelegate { [weak self] in
                Task { @MainActor in
                    self?.isSpeaking = false
                    self?.currentItemID = nil
                }
            }
            player.delegate = delegate
            audioPlayerDelegate = delegate
            audioPlayer = player
            isSpeaking = true
            player.prepareToPlay()
            player.play()
        } catch {
            isSpeaking = false
        }
    }

    // MARK: - Voices

    /// Every installed voice, best quality first within each language.
    var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { lhs, rhs in
            if lhs.language != rhs.language { return lhs.language < rhs.language }
            if lhs.quality.rank != rhs.quality.rank { return lhs.quality.rank > rhs.quality.rank }
            return lhs.name < rhs.name
        }
    }

    func voices(forLanguage code: String) -> [AVSpeechSynthesisVoice] {
        let wanted = Language.base(of: code).lowercased()
        return availableVoices.filter { Language.base(of: $0.language).lowercased() == wanted }
    }

    /// Languages we actually have a voice for, sorted by display name.
    var installedLanguages: [String] {
        let codes = Set(AVSpeechSynthesisVoice.speechVoices().map { Language.normalize($0.language) })
        return codes.sorted { Language.displayName($0) < Language.displayName($1) }
    }

    func voiceName(for identifier: String) -> String? {
        AVSpeechSynthesisVoice.speechVoices().first { $0.identifier == identifier }?.name
    }

    /// Resolve the voice for an item: explicit override, else the best installed
    /// voice for the detected language, else the study language, else the system default.
    func voice(for item: Item) -> AVSpeechSynthesisVoice? {
        let code = item.language ?? Language.detect(item.text) ?? studyLanguage
        return bestVoice(for: code) ?? bestVoice(for: studyLanguage)
    }

    func bestVoice(for code: String) -> AVSpeechSynthesisVoice? {
        let base = Language.base(of: code).lowercased()
        if let override = voiceOverrides[base], let voice = AVSpeechSynthesisVoice(identifier: override) {
            return voice
        }
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { Language.base(of: $0.language).lowercased() == base }
        guard !candidates.isEmpty else { return AVSpeechSynthesisVoice(language: Language.normalize(code)) }
        let normalized = Language.normalize(code).lowercased()
        // Exact locale beats a same-language cousin; higher quality beats both.
        return candidates.max { lhs, rhs in
            let lhsExact = lhs.language.lowercased() == normalized ? 1 : 0
            let rhsExact = rhs.language.lowercased() == normalized ? 1 : 0
            if lhs.quality.rank != rhs.quality.rank { return lhs.quality.rank < rhs.quality.rank }
            return lhsExact < rhsExact
        }
    }

    /// True when the best available voice for a language is the basic one —
    /// the UI uses this to point at Settings › Accessibility › Spoken Content.
    func hasOnlyCompactVoice(for code: String) -> Bool {
        guard let voice = bestVoice(for: code) else { return false }
        return voice.quality == .default
    }

    // MARK: - Text preparation

    /// Reduce anything a card can hold to text that is safe to read aloud.
    ///
    /// Callers pass raw field or template HTML, so this has to survive markup,
    /// double-encoded markup, unterminated tags, sound and cloze scaffolding,
    /// URLs and the private-use glyphs that Word-exported decks are full of —
    /// none of which a voice should ever pronounce.
    nonisolated static func speakableText(_ raw: String) -> String {
        var text = HTMLText.plainText(CardContentAnalyzer.stripSoundTags(raw))
        // Belt and braces: `raw` may have been plain text that never went
        // through the block scanner, so strip markup patterns once more.
        text = HTMLText.strippingResidualTags(text)
        text = CardContentAnalyzer.stripSoundTags(text)
        text = text.replacingOccurrences(of: #"\[\.\.\.\]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[hint\]"#, with: " ", options: [.regularExpression, .caseInsensitive])
        // Never read a URL out loud.
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\bwww\.\S+"#, with: " ", options: .regularExpression)
        // Bullets, private-use glyphs and other non-speech scalars become pauses.
        text = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            if CardContentAnalyzer.bulletCharacters.contains(scalar) { return " " }
            switch scalar.value {
            case 0xE000...0xF8FF, 0xFFF9...0xFFFD, 0x200B...0x200F, 0xFE00...0xFE0F:
                return " "
            default:
                return scalar
            }
        }))
        text = text.collapsedWhitespace
        return String(text.prefix(1200))
    }

    // MARK: - Session

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            if !sessionConfigured {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                sessionConfigured = true
            }
            try session.setActive(true)
        } catch {
            // Non-fatal: playback still works without ducking.
        }
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        for name in [AVAudioSession.interruptionNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let service = self else { return }
                Task { @MainActor in service.stop() }
            })
        }
    }
}

// MARK: - Delegates

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSpeaking = true
            self.currentItemID = self.utteranceItems[key]
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.utteranceItems.removeValue(forKey: key)
            if self.utteranceItems.isEmpty {
                self.isSpeaking = false
                self.currentItemID = nil
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.utteranceItems.removeAll()
            self?.isSpeaking = false
            self?.currentItemID = nil
        }
    }
}

private final class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onFinish() }
}

private extension AVSpeechSynthesisVoiceQuality {
    /// premium > enhanced > default
    var rank: Int {
        switch self {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }
}
