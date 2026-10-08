import Photos
import UIKit

/// iOS twin of Android's KnoziGift @JavascriptInterface.
///
/// Contract (identical to Android):
///   giftSaveBegin(totalLen, fileName) -> "ok" | "error"   (8 MB cap)
///   giftSaveChunk(piece)              -> "ok" | "error"   (page sends ~200k-char chunks)
///   giftSaveEnd()                     -> "saved" | "error" (saves the PNG to Photos)
///   giftShareBegin(totalLen)          -> "ok" | "error"
///   giftShareChunk(piece)             -> "ok" | "error"
///   giftShareEnd(shareText)           -> void; the result arrives later via
///                                        window.__kzGiftShareDone(bool)
///   openWhatsAppShare(text)           -> "ok" | "error"
///
/// The page streams PNGs as base64 in ~200k-char chunks because single huge
/// bridge strings are unreliable (same lesson as Android). We accumulate the
/// base64 string and decode once, exactly like Android.
final class GiftBridge {
    static let shared = GiftBridge()

    /// Set by HubViewController: evaluates JS in the page (used for
    /// window.__kzGiftShareDone).
    var jsCallback: ((String) -> Void)?

    private static let maxBytes = 8 * 1024 * 1024

    private var saveBase64 = ""
    // Accepted for contract parity with Android (which stores it as the
    // MediaStore DISPLAY_NAME); iOS Photos has no filename concept, so it is
    // intentionally unused beyond validation.
    private var saveFileName = "knozi-gift.png"
    private var saveActive = false

    private var shareBase64 = ""
    private var shareActive = false

    private init() {}

    // MARK: - Gallery save

    func saveBegin(totalLen: String, fileName: String) -> String {
        guard let total = Int(totalLen), total > 0, total <= Self.maxBytes else {
            return "error"
        }
        saveBase64 = ""
        saveBase64.reserveCapacity(total)
        saveFileName = fileName.isEmpty ? "knozi-gift.png" : fileName
        saveActive = true
        return "ok"
    }

    func saveChunk(piece: String) -> String {
        guard saveActive else { return "error" }
        saveBase64 += piece
        return saveBase64.count <= Self.maxBytes ? "ok" : "error"
    }

    func saveEnd() -> String {
        guard saveActive else { return "error" }
        saveActive = false
        let b64 = saveBase64
        saveBase64 = ""
        guard !b64.isEmpty, let data = Data(base64Encoded: b64), !data.isEmpty else {
            return "error"
        }
        // PHPhotoLibrary.performChangesAndWait must not run on the main thread
        // (prompt interception is main-thread), so do the blocking save on a
        // background queue and wait — the JS call stays synchronous.
        let box = BoolBox(false)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = self.saveImageToPhotos(data)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 30)
        return box.value ? "saved" : "error"
    }

    private func saveImageToPhotos(_ data: Data) -> Bool {
        guard ensureAddOnlyAuthorization() else { return false }
        guard let image = UIImage(data: data) else { return false }
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return true
        } catch {
            return false
        }
    }

    private func ensureAddOnlyAuthorization() -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            let done = DispatchSemaphore(value: 0)
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                status = newStatus
                done.signal()
            }
            _ = done.wait(timeout: .now() + 60)
        }
        // .addOnly has no "limited" state; only .authorized can save.
        return status == .authorized
    }

    // MARK: - Share sheet

    func shareBegin(totalLen: String) -> String {
        guard let total = Int(totalLen), total > 0, total <= Self.maxBytes else {
            return "error"
        }
        shareBase64 = ""
        shareBase64.reserveCapacity(total)
        shareActive = true
        return "ok"
    }

    func shareChunk(piece: String) -> String {
        guard shareActive else { return "error" }
        shareBase64 += piece
        return shareBase64.count <= Self.maxBytes ? "ok" : "error"
    }

    func shareEnd(shareText: String, presenter: UIViewController) {
        guard shareActive else {
            notifyShareDone(false)
            return
        }
        shareActive = false
        let b64 = shareBase64
        shareBase64 = ""
        guard !b64.isEmpty,
              let data = Data(base64Encoded: b64), !data.isEmpty else {
            notifyShareDone(false)
            return
        }
        // Write to a temp file and hand it to the iOS share sheet —
        // the twin of Android's ACTION_SEND chooser.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("knozi-gift-share-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try data.write(to: tmpURL, options: .atomic)
        } catch {
            notifyShareDone(false)
            return
        }
        var items: [Any] = [tmpURL]
        if !shareText.isEmpty { items.append(shareText) }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.completionWithItemsHandler = { [weak self] _, completed, _, _ in
            try? FileManager.default.removeItem(at: tmpURL)
            self?.notifyShareDone(completed)
        }
        // iPad: a share sheet needs a popover anchor.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX, y: presenter.view.bounds.midY,
                width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true)
    }

    private func notifyShareDone(_ ok: Bool) {
        // Mirrors Android's giftShareResult(): window.__kzGiftShareDone(bool).
        // The page installs this handler before calling giftShareEnd.
        jsCallback?("window.__kzGiftShareDone(\(ok ? "true" : "false"))")
    }

    /// Weekly recap text share (Android v1.124): fires the system share sheet
    /// so the parent picks WhatsApp, Messages, email, etc. directly.
    /// Void on Android — no callback. Same here.
    func shareRecapText(title: String, text: String, presenter: UIViewController) {
        var items: [Any] = []
        if !text.isEmpty { items.append(text) }
        guard !items.isEmpty else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad: a share sheet needs a popover anchor.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX, y: presenter.view.bounds.midY,
                width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true)
    }

    // MARK: - WhatsApp direct share

    /// Opens WhatsApp itself with the text pre-filled (one tap to the contact
    /// picker), mirroring Android's openWhatsAppShare. Falls back to the
    /// generic wa.me link when the WhatsApp app isn't installed.
    func openWhatsAppShare(text: String) -> String {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let app = UIApplication.shared
        if let waURL = URL(string: "whatsapp://send?text=\(encoded)"),
           app.canOpenURL(waURL) {
            app.open(waURL, options: [:], completionHandler: nil)
            return "ok"
        }
        if let webURL = URL(string: "https://wa.me/?text=\(encoded)") {
            app.open(webURL, options: [:], completionHandler: nil)
            return "ok"
        }
        return "error"
    }
}

/// Tiny mutable box so a background queue can hand a Bool back across a
/// semaphore wait without tripping Swift concurrency diagnostics.
private final class BoolBox {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}
