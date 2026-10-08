import UIKit
import WebKit

/// Hosts the shared Knozi Hub web assets (index.html, knozi-abc.html,
/// knozi-storybook.html, owl-poses/, …) in a WKWebView.
///
/// This is the iOS twin of Android's MainActivity: same pages, same
/// localStorage, same JS. The native bridge surface is injected by
/// bridge.js at document start and intercepted below via prompt().
final class HubViewController: UIViewController, WKUIDelegate, WKNavigationDelegate {

    private var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // Android: setMediaPlaybackRequiresUserGesture(false)
        config.mediaTypesRequiringUserActionForPlayback = []
        // Android: setDomStorageEnabled(true) — the default data store persists
        // localStorage/cookies across launches, same as the Android WebView.
        config.websiteDataStore = .default()

        // Synchronous native bridge (see BridgeDispatcher). Injected before any
        // page script runs, in every frame.
        if let bridgeURL = Bundle.main.url(forResource: "bridge", withExtension: "js"),
           let bridgeSource = try? String(contentsOf: bridgeURL, encoding: .utf8) {
            config.userContentController.addUserScript(
                WKUserScript(source: bridgeSource,
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: false)
            )
        }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.bounces = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Native -> JS callbacks (gift share result, Google tokens).
        GiftBridge.shared.jsCallback = { [weak self] js in self?.evaluateBridgeCallback(js) }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onGoogleTokens(_:)),
            name: AuthBridge.googleTokensNotification,
            object: nil
        )

        // Same entry point as Android: file:///android_asset/index.html ->
        // bundle www/index.html, with read access to the whole www/ tree so
        // page hops (knozi-abc.html, knozi-storybook.html) and relative asset
        // loads keep working.
        if let wwwDir = Bundle.main.resourceURL?.appendingPathComponent("www"),
           FileManager.default.fileExists(atPath: wwwDir.path) {
            webView.loadFileURL(
                wwwDir.appendingPathComponent("index.html"),
                allowingReadAccessTo: wwwDir
            )
        } else {
            // sync-assets.sh did not run: a diagnostic, never a blank screen.
            webView.loadHTMLString(
                "<body style='font-family:-apple-system,sans-serif;padding:40px'>"
                    + "Knozi Hub web assets are missing. Run scripts/sync-assets.sh, then rebuild."
                    + "</body>",
                baseURL: nil
            )
        }
    }

    // MARK: - Native -> JS

    func evaluateBridgeCallback(_ js: String) {
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Called from SceneDelegate on backgrounding. Replicates what the pages'
    /// own visibilitychange -> hidden handlers do (cancel speech, pause every
    /// <audio>). Pausing twice — here and in the page handler, if WKWebView
    /// fires visibilitychange itself — is idempotent.
    func pauseAllAudio() {
        let js = "(function(){"
            + "try{if('speechSynthesis' in window)window.speechSynthesis.cancel();}catch(e){}"
            + "try{var a=document.querySelectorAll('audio');"
            + "for(var i=0;i<a.length;i++){try{if(!a[i].paused)a[i].pause();}catch(e){}}}catch(e){}"
            + "})();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc private func onGoogleTokens(_ note: Notification) {
        guard let access = note.userInfo?["access"] as? String, !access.isEmpty else { return }
        let refresh = note.userInfo?["refresh"] as? String ?? ""
        // Mirrors Android's deliverGoogleTokens(): window.__kzGoogleTokens(a, r).
        evaluateBridgeCallback(
            "window.__kzGoogleTokens(\(JSEscape.string(access)),\(JSEscape.string(refresh)))"
        )
    }

    // MARK: - WKUIDelegate: the synchronous bridge

    /// Intercepts bridge.js prompt() calls and answers them natively. JS stays
    /// blocked until completionHandler runs, preserving Android's synchronous
    /// @JavascriptInterface contracts.
    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        if prompt.hasPrefix(BridgeDispatcher.schemePrefix) {
            BridgeDispatcher.shared.dispatch(
                prompt: prompt, presenter: self, completion: completionHandler)
            return
        }
        // The app never uses prompt() for real input.
        completionHandler(defaultText)
    }

    /// The library uses confirm() for delete confirmations. Without this
    /// delegate method confirm() silently returns false and deletes never fire.
    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Defense in depth: a knozihub:// link tapped inside the page (e.g. the
        // OAuth redirect if it ever lands in-page) is routed to the auth bridge
        // instead of failing navigation.
        if let url = navigationAction.request.url, url.scheme == "knozihub" {
            AuthBridge.shared.handleDeepLink(url: url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
