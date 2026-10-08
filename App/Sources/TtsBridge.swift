import AVFoundation
import Foundation

/// iOS twin of Android's KnoziTts @JavascriptInterface.
///
/// Contract (identical to Android):
///   ttsSpeak(text) -> void — speaks, flushing anything currently playing.
///   ttsStop()       -> void — stops immediately.
///
/// On Android this bridge exists because the WebView has no
/// window.speechSynthesis; the page prefers window.KnoziTts when present and
/// falls back to speechSynthesis otherwise. We inject the bridge on iOS too so
/// the gift/trivia "Hear Knozi" path behaves identically on both platforms
/// (AVSpeechSynthesizer, en-US, rate 0.95 — matching Android's setSpeechRate).
final class TtsBridge {
    static let shared = TtsBridge()

    private let synth = AVSpeechSynthesizer()

    private init() {}

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // AVSpeechSynthesizer is main-thread bound.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.synth.stopSpeaking(at: .immediate) // QUEUE_FLUSH semantics
            let utterance = AVSpeechUtterance(string: trimmed)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
            utterance.pitchMultiplier = 1.0
            self.synth.speak(utterance)
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.synth.stopSpeaking(at: .immediate)
        }
    }
}
