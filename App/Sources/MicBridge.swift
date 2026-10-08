import AVFoundation
import Foundation

/// iOS twin of Android's CleanConceptMic @JavascriptInterface.
///
/// Contract (identical to Android):
///   ensureMicPermission() -> void — pre-requests the mic permission.
///   nativeMicState()      -> "granted" | "denied" | "blocked"
///       "denied"  = not granted but we can still ask (Android: rationale path;
///                   iOS: .undetermined).
///       "blocked" = permanently denied -> the page shows the Settings path
///                   (Android: "blocked"; iOS: .denied).
///   nativeStart()         -> "started" | "no_permission" | "error"
///       When the permission isn't settled we fire the system dialog AND return
///       "no_permission" immediately — the page shows "allow, then try again",
///       exactly like Android.
///   nativeStopBegin()     -> total base64 WAV length (chars), or -1 when empty.
///   nativeStopChunk(off, count) -> substring of the base64 WAV; the buffer is
///       released once the final chunk is served. The page steps `off` by
///       200000 over `total`, mirroring the Android chunk protocol.
///
/// Recording is 44.1 kHz mono 16-bit PCM, WAV-encoded — AVAudioRecorder writes
/// a real WAV header when the file has a .wav extension with LinearPCM
/// settings, so no manual header assembly is needed (Android hand-builds it).
final class MicBridge {
    static let shared = MicBridge()

    private var recorder: AVAudioRecorder?
    private var wavBase64: String?
    private let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("knozi-mic.wav")

    private init() {}

    func ensureMicPermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }

    func micState() -> String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return "granted"
        case .denied:
            // Permanently denied: only Settings can fix it.
            return "blocked"
        case .undetermined:
            // Never asked: we can still ask.
            return "denied"
        @unknown default:
            return "denied"
        }
    }

    func start() -> String {
        let session = AVAudioSession.sharedInstance()
        guard session.recordPermission == .granted else {
            // Not settled: ask now, report no_permission — the page tells the
            // parent to allow the mic and retry, same as Android.
            session.requestRecordPermission { _ in }
            return "no_permission"
        }
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker])
            try session.setActive(true)
            try? FileManager.default.removeItem(at: fileURL)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            stopRecorder()
            recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder?.prepareToRecord()
            return recorder?.record() == true ? "started" : "error"
        } catch {
            stopRecorder()
            return "error"
        }
    }

    func stopBegin() -> String {
        stopRecorder()
        do {
            let data = try Data(contentsOf: fileURL)
            // 44 bytes = WAV header only, no audio captured (mirrors Android's
            // pcm.length == 0 -> -1).
            guard data.count > 44 else {
                wavBase64 = ""
                return "-1"
            }
            let b64 = data.base64EncodedString()
            wavBase64 = b64
            return String(b64.count)
        } catch {
            wavBase64 = ""
            return "-1"
        }
    }

    func stopChunk(offset: Int, count: Int) -> String {
        guard let s = wavBase64, !s.isEmpty, offset >= 0, offset < s.count else {
            return ""
        }
        let start = s.index(s.startIndex, offsetBy: offset)
        let remaining = s.distance(from: start, to: s.endIndex)
        let end = s.index(start, offsetBy: min(max(count, 0), remaining))
        let piece = String(s[start..<end])
        if end == s.endIndex {
            wavBase64 = nil // fully consumed, like Android
        }
        return piece
    }

    private func stopRecorder() {
        recorder?.stop()
        recorder = nil
    }
}
