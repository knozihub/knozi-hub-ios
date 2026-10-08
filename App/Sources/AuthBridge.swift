import Foundation
import UIKit

/// iOS twin of Android's KnoziAuth @JavascriptInterface (Continue with Google).
///
/// Google refuses OAuth inside an embedded WebView, so — exactly like Android —
/// we open the Supabase Google authorize URL in the system browser. Supabase
/// redirects to knozihub://auth#access_token=…&refresh_token=…, which comes back
/// here (SceneDelegate). Two delivery paths, mirroring Android:
///   warm: the page is loaded -> window.__kzGoogleTokens(access, refresh)
///         is evaluated immediately (like Android's deliverGoogleTokens).
///   cold: the deep link arrived before the page loaded -> tokens are stashed
///         and the page picks them up with pollGoogleTokens() at boot.
///
/// Contract (identical to Android):
///   openGoogleSignIn() -> void
///   pollGoogleTokens() -> "" when empty, else {"access_token": access, "refresh_token": refresh}
///   (fixed 2026-09-30 to match what the page's boot poll reads; was {"a","r"}).
/// NOTE — fixed 2026-09-30: the page's boot poll reads o.access_token /
/// o.refresh_token, and the shells now return those keys (was {"a","r"}).
final class AuthBridge {
    static let shared = AuthBridge()
    static let googleTokensNotification = Notification.Name("KZGoogleTokens")

    private let supabaseAuthBase = "https://tcokrefugjmvhspvbkco.supabase.co/auth/v1/authorize"

    private var pendingAccess: String?
    private var pendingRefresh: String?

    private init() {}

    func openGoogleSignIn() {
        var comps = URLComponents(string: supabaseAuthBase)
        comps?.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: "knozihub://auth"),
        ]
        guard let url = comps?.url else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    func pollGoogleTokens() -> String {
        guard let access = pendingAccess, !access.isEmpty else { return "" }
        let refresh = pendingRefresh ?? ""
        pendingAccess = nil
        pendingRefresh = nil
        return "{\"access_token\":\(JSEscape.string(access)),\"refresh_token\":\(JSEscape.string(refresh))}"
    }

    func handleDeepLink(url: URL) {
        guard url.scheme == "knozihub" else { return }
        // Supabase delivers tokens in the fragment: knozihub://auth#access_token=…&refresh_token=…
        let raw = url.fragment ?? url.query ?? ""
        var access: String?
        var refresh: String?
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            if key == "access_token" { access = value }
            else if key == "refresh_token" { refresh = value }
        }
        guard let a = access, !a.isEmpty else { return }
        let r = refresh ?? ""
        // Cold path: stash for pollGoogleTokens().
        pendingAccess = a
        pendingRefresh = r
        // Warm path: deliver straight into the loaded page.
        NotificationCenter.default.post(
            name: Self.googleTokensNotification,
            object: nil,
            userInfo: ["access": a, "refresh": r]
        )
    }
}
