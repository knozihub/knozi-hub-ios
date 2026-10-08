import UIKit
import WebKit

/// JS string escaping, mirroring Android's jsStr(): backslash- and
/// quote-escaped, wrapped in double quotes.
enum JSEscape {
    static func string(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

enum BridgeError: Error {
    case badScheme
    case badPath
    case unknownMethod
}

/// How a dispatched call resolves.
enum BridgeOutcome {
    /// Call completion(result) immediately.
    case sync(String)
    /// The handler took ownership of completion (async work); do not call it here.
    case async
}

/// Synchronous JS -> native bridge.
///
/// Android exposes the four bridge objects (CleanConceptMic, KnoziGift,
/// KnoziTts, KnoziAuth) as @JavascriptInterface, whose calls are synchronous.
/// WKScriptMessageHandler is async-only, so bridge.js (injected at document
/// start) routes every call through prompt('knozi://<iface>/<method>?<args>'),
/// which HubViewController intercepts in WKUIDelegate and sends here. JS stays
/// blocked until the completion handler runs, so return values are synchronous
/// exactly like Android's — e.g. nativeStopBegin() -> "12345" / "-1", and the
/// 200k-char chunk loop in the page works unchanged.
///
/// Args are a URL-encoded JSON array. Methods that would block (photo-library
/// save) do their work on a background queue and wait, keeping the JS-side
/// contract synchronous.
final class BridgeDispatcher {
    static let shared = BridgeDispatcher()
    static let schemePrefix = "knozi://"

    private init() {}

    func dispatch(
        prompt: String,
        presenter: UIViewController,
        completion: @escaping (String?) -> Void
    ) {
        let outcome: BridgeOutcome
        do {
            outcome = try route(prompt: prompt, presenter: presenter)
        } catch {
            outcome = .sync("")
        }
        if case .sync(let result) = outcome {
            completion(result)
        }
    }

    private func route(prompt: String, presenter: UIViewController) throws -> BridgeOutcome {
        guard prompt.hasPrefix(Self.schemePrefix) else { throw BridgeError.badScheme }
        let rest = String(prompt.dropFirst(Self.schemePrefix.count)) // "mic/nativeStart?%5B%5D"
        let halves = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathParts = halves[0].split(separator: "/")
        guard pathParts.count == 2 else { throw BridgeError.badPath }
        let iface = String(pathParts[0])
        let method = String(pathParts[1])

        var args: [Any] = []
        if halves.count > 1,
           let decoded = String(halves[1]).removingPercentEncoding,
           let data = decoded.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data, options: []) as? [Any] {
            args = arr
        }
        func strArg(_ i: Int) -> String { (i < args.count ? args[i] as? String : nil) ?? "" }
        func numArg(_ i: Int) -> Int { (i < args.count ? (args[i] as? NSNumber)?.intValue : nil) ?? 0 }

        switch (iface, method) {
        // ---- CleanConceptMic (native voice recording) ----
        case ("mic", "ensureMicPermission"):
            MicBridge.shared.ensureMicPermission()
            return .sync("")
        case ("mic", "nativeMicState"):
            return .sync(MicBridge.shared.micState())
        case ("mic", "nativeStart"):
            return .sync(MicBridge.shared.start())
        case ("mic", "nativeStopBegin"):
            return .sync(MicBridge.shared.stopBegin())
        case ("mic", "nativeStopChunk"):
            return .sync(MicBridge.shared.stopChunk(offset: numArg(0), count: numArg(1)))

        // ---- KnoziGift (gallery save / share sheet / WhatsApp) ----
        case ("gift", "giftSaveBegin"):
            return .sync(GiftBridge.shared.saveBegin(totalLen: strArg(0), fileName: strArg(1)))
        case ("gift", "giftSaveChunk"):
            return .sync(GiftBridge.shared.saveChunk(piece: strArg(0)))
        case ("gift", "giftSaveEnd"):
            return .sync(GiftBridge.shared.saveEnd())
        case ("gift", "giftShareBegin"):
            return .sync(GiftBridge.shared.shareBegin(totalLen: strArg(0)))
        case ("gift", "giftShareChunk"):
            return .sync(GiftBridge.shared.shareChunk(piece: strArg(0)))
        case ("gift", "giftShareEnd"):
            // Void on Android; the result arrives later via
            // window.__kzGiftShareDone(bool). Same here.
            GiftBridge.shared.shareEnd(shareText: strArg(0), presenter: presenter)
            return .sync("")
        case ("gift", "openWhatsAppShare"):
            return .sync(GiftBridge.shared.openWhatsAppShare(text: strArg(0)))
        case ("gift", "shareRecapText"):
            // Void on Android (v1.124+); no callback. Same here.
            GiftBridge.shared.shareRecapText(title: strArg(0), text: strArg(1), presenter: presenter)
            return .sync("")

        // ---- KnoziTts (native speech for gift/trivia "Hear Knozi") ----
        case ("tts", "ttsSpeak"):
            TtsBridge.shared.speak(strArg(0))
            return .sync("")
        case ("tts", "ttsStop"):
            TtsBridge.shared.stop()
            return .sync("")

        // ---- KnoziAuth (Continue with Google) ----
        case ("auth", "openGoogleSignIn"):
            AuthBridge.shared.openGoogleSignIn()
            return .sync("")
        case ("auth", "pollGoogleTokens"):
            return .sync(AuthBridge.shared.pollGoogleTokens())

        default:
            throw BridgeError.unknownMethod
        }
    }
}
