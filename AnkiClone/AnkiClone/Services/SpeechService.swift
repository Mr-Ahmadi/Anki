import AVFoundation
import Foundation
import SwiftUI
import NaturalLanguage

// MARK: - SpeechService
// Uses AVFoundation built-in TTS (AVSpeechSynthesizer) for pronunciation.
// Auto-detects language, supports manual selection, rate/pitch control.

@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published var selectedVoiceIdentifier: String? {
        didSet { UserDefaults.standard.set(selectedVoiceIdentifier, forKey: "ttsVoiceId") }
    }
    @Published var speechRate: Float {
        didSet { UserDefaults.standard.set(speechRate, forKey: "ttsRate") }
    }
    @Published var autoPlay: Bool {
        didSet { UserDefaults.standard.set(autoPlay, forKey: "ttsAutoPlay") }
    }

    private var synthesizer = AVSpeechSynthesizer()
    private var currentText: String = ""

    override init() {
        self.selectedVoiceIdentifier = UserDefaults.standard.string(forKey: "ttsVoiceId")
        let savedRate = UserDefaults.standard.float(forKey: "ttsRate")
        self.speechRate = savedRate == 0 ? AVSpeechUtteranceDefaultSpeechRate : savedRate
        self.autoPlay = UserDefaults.standard.object(forKey: "ttsAutoPlay") as? Bool ?? false
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
    }

    // MARK: - Public API

    func speak(_ rawText: String, languageHint: String? = nil) {
        let text = cleanText(rawText)
        guard !text.isEmpty else { return }
        // Stop any current speech immediately
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = speechRate
        utterance.volume = 1.0
        utterance.prefersAssistiveTechnologySettings = false

        if let hint = languageHint, let voice = AVSpeechSynthesisVoice(language: hint) {
            utterance.voice = voice
        } else if let id = selectedVoiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        } else if let detected = detectLanguage(for: text), let voice = AVSpeechSynthesisVoice(language: detected) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        currentText = text
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    func toggle(_ text: String, languageHint: String? = nil) {
        if isSpeaking {
            stop()
        } else {
            speak(text, languageHint: languageHint)
        }
    }

    var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { $0.language < $1.language }
    }

    var groupedVoices: [String: [AVSpeechSynthesisVoice]] {
        Dictionary(grouping: availableVoices) { $0.language }
    }

    func voiceName(for identifier: String) -> String {
        AVSpeechSynthesisVoice.speechVoices().first(where: { $0.identifier == identifier })?.name ?? "System Default"
    }

    // Extract speakable text from HTML + sound tags
    func extractSpeakableText(from html: String, fields: [String: String] = [:]) -> String {
        var text = html
        // If html looks like raw field values joined, use it directly
        // Remove HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode entities
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        // Remove cloze markers
        text = text.replacingOccurrences(of: "[...]", with: "")
        text = text.replacingOccurrences(of: "\\[sound:.*?\\]", with: "", options: .regularExpression)
        // Collapse whitespace
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Convenience: speak from fields dict (uses first non-empty field that looks like word/sentence)
    func speakFields(_ fields: [String: String], preferredKeys: [String] = ["Front","Word","Expression","Sentence","Text","Back"]) {
        for key in preferredKeys {
            if let val = fields[key], !val.trimmingCharacters(in: .whitespaces).isEmpty {
                speak(val)
                return
            }
        }
        // fallback: longest field
        if let best = fields.values.filter({ !$0.isEmpty }).max(by: { $0.count < $1.count }) {
            speak(best)
        }
    }

    // MARK: - Private

    private func cleanText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[sound:.*?\\]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func detectLanguage(for text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return nil }
        // Map NLLanguage to BCP47 for AVSpeech
        switch lang {
        case .english: return "en-US"
        case .spanish: return "es-ES"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .italian: return "it-IT"
        case .portuguese: return "pt-BR"
        case .russian: return "ru-RU"
        case .arabic: return "ar-SA"
        default:
            // Handle Chinese and others via rawValue
            let raw = lang.rawValue
            if raw.hasPrefix("zh") { return "zh-CN" }
            if raw.hasPrefix("nl") { return "nl-NL" }
            if raw.hasPrefix("tr") { return "tr-TR" }
            return raw
        }
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
