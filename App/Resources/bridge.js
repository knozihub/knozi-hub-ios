/* Knozi Hub iOS native bridge (bridge.js).
 *
 * Injected by HubViewController at document start, before any page script runs.
 *
 * Android exposes CleanConceptMic / KnoziGift / KnoziTts / KnoziAuth as
 * @JavascriptInterface objects whose calls are SYNCHRONOUS. WKWebView's
 * WKScriptMessageHandler is async-only, so every method here is routed through
 * prompt('knozi://<iface>/<method>?<urlencoded JSON args>'), which the native
 * side intercepts in WKUIDelegate (see BridgeDispatcher.swift). JS blocks until
 * the native side answers, so return values are synchronous exactly like
 * Android's — the page's contracts (e.g. nativeStart() -> 'started',
 * nativeStopBegin() -> int, the 200k-char chunk loops, giftSaveEnd() -> 'saved')
 * work unchanged.
 *
 * The app never uses prompt() for real user input, so there is no conflict.
 */
(function () {
  if (window.__kzIOSBridgeInstalled) return;
  window.__kzIOSBridgeInstalled = true;

  function kzCall(iface, method, args) {
    try {
      var payload = encodeURIComponent(JSON.stringify(args || []));
      var res = window.prompt('knozi://' + iface + '/' + method + '?' + payload);
      return (res === null || res === undefined) ? '' : String(res);
    } catch (e) {
      return '';
    }
  }

  function kzIface(iface, methods) {
    var o = {};
    for (var i = 0; i < methods.length; i++) {
      (function (m) {
        o[m] = function () {
          return kzCall(iface, m, Array.prototype.slice.call(arguments));
        };
      })(methods[i]);
    }
    return o;
  }

  window.CleanConceptMic = kzIface('mic', [
    'ensureMicPermission',
    'nativeMicState',
    'nativeStart',
    'nativeStopBegin',
    'nativeStopChunk'
  ]);

  window.KnoziGift = kzIface('gift', [
    'giftSaveBegin',
    'giftSaveChunk',
    'giftSaveEnd',
    'giftShareBegin',
    'giftShareChunk',
    'giftShareEnd',
    'openWhatsAppShare',
    'shareRecapText'
  ]);

  window.KnoziTts = kzIface('tts', [
    'ttsSpeak',
    'ttsStop'
  ]);

  window.KnoziAuth = kzIface('auth', [
    'openGoogleSignIn',
    'pollGoogleTokens'
  ]);
})();
