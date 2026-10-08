import UIKit

/// Owns the window, the HubViewController, deep links, and the
/// background/foreground audio policy (mirrors Android's
/// onPause -> webView.onPause() / onResume -> webView.onResume()).
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private var hub: HubViewController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let hub = HubViewController()
        self.hub = hub
        window.rootViewController = hub
        window.makeKeyAndVisible()
        self.window = window

        // Cold start via the knozihub://auth deep link (Google sign-in):
        // stash the tokens; the page picks them up with pollGoogleTokens().
        for context in connectionOptions.urlContexts {
            AuthBridge.shared.handleDeepLink(url: context.url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        // Warm return from the system browser (Google sign-in): stash + deliver
        // straight into the loaded page via window.__kzGoogleTokens.
        for context in URLContexts {
            AuthBridge.shared.handleDeepLink(url: context.url)
        }
    }

    /// Mirrors Android onPause -> webView.onPause(), which the page observes as
    /// visibilitychange -> hidden. WKWebView usually fires that itself on
    /// backgrounding, but we also pause everything audible here so narration or
    /// music can never keep playing if the page is mid-clip.
    func sceneDidEnterBackground(_ scene: UIScene) {
        TtsBridge.shared.stop()
        hub?.pauseAllAudio()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // No auto-resume: matches Android. Hub clips are short and
        // tap-initiated; the storybook/episode readers restart narration
        // themselves on visible when appropriate.
    }
}
