# Knozi Hub — iOS background track

A thin native iOS shell that hosts the **same web assets the Android app ships**
(`index.html`, `knozi-abc.html`, `knozi-storybook.html`, `owl-poses/`, …) in a
`WKWebView`. Android stays the daily driver: this track only *reads* the
Android assets at build time and never edits them.

```
ios-build/
├── App/
│   ├── Sources/            # Swift: lifecycle + WebView + native bridges
│   │   ├── AppDelegate.swift
│   │   ├── SceneDelegate.swift      # window, deep links, background-audio policy
│   │   ├── HubViewController.swift  # WKWebView host + prompt() bridge interception
│   │   ├── BridgeDispatcher.swift   # knozi://<iface>/<method> router
│   │   ├── MicBridge.swift          # CleanConceptMic (AVAudioRecorder)
│   │   ├── GiftBridge.swift         # KnoziGift (Photos save / share sheet / WhatsApp)
│   │   ├── TtsBridge.swift          # KnoziTts (AVSpeechSynthesizer)
│   │   └── AuthBridge.swift         # KnoziAuth (Continue with Google)
│   ├── Resources/
│   │   ├── bridge.js       # injected at document start; defines the 4 window.* objects
│   │   ├── Info.plist
│   │   └── www/            # staged by scripts/sync-assets.sh (not committed)
│   └── Assets.xcassets/    # placeholder AppIcon — replace before TestFlight
├── scripts/sync-assets.sh  # copies Android web assets (or latest public APK) into www/
├── project.yml             # xcodegen project definition
└── .github/workflows/ios-build.yml  # macOS CI: unsigned release IPA
```

## How the bridge works

Android's `@JavascriptInterface` calls are **synchronous**, and the page depends
on it (`nativeStart()` → `'started'`, `nativeStopBegin()` → int, the 200k-char
chunk loops, `giftSaveEnd()` → `'saved'`). `WKScriptMessageHandler` is
async-only, so `bridge.js` routes every call through
`prompt('knozi://<iface>/<method>?<urlencoded JSON args>')`, which
`HubViewController` intercepts in `WKUIDelegate`. JS stays blocked until the
native side answers — the contracts below are synchronous exactly like Android's,
and the shared page code runs **unchanged**.

## Bridge contract table

| JS call (as the page makes it) | Swift handler | Return contract | Notes |
|---|---|---|---|
| `CleanConceptMic.ensureMicPermission()` | `MicBridge.ensureMicPermission()` | void | Fire-and-forget `requestRecordPermission` |
| `CleanConceptMic.nativeMicState()` | `MicBridge.micState()` | `"granted"` / `"denied"` / `"blocked"` | `.undetermined`→`"denied"` (can still ask); `.denied`→`"blocked"` (Settings path), matching Android's semantics |
| `CleanConceptMic.nativeStart()` | `MicBridge.start()` | `"started"` / `"no_permission"` / `"error"` | 44.1 kHz mono PCM16 via `AVAudioRecorder` (`.wav` extension ⇒ real WAV header, no manual assembly). If permission isn't settled: asks *and* returns `"no_permission"`, like Android |
| `CleanConceptMic.nativeStopBegin()` | `MicBridge.stopBegin()` | total base64 chars, or `"-1"` | Header-only WAV (≤44 bytes, nothing captured) counts as empty → `"-1"`, mirroring Android's `pcm.length == 0` |
| `CleanConceptMic.nativeStopChunk(off, count)` | `MicBridge.stopChunk(offset:count:)` | base64 substring | Buffer released once fully consumed, like Android |
| `KnoziGift.giftSaveBegin(totalLen, fileName)` | `GiftBridge.saveBegin(totalLen:fileName:)` | `"ok"` / `"error"` | 8 MB cap, same as Android |
| `KnoziGift.giftSaveChunk(piece)` | `GiftBridge.saveChunk(piece:)` | `"ok"` / `"error"` | ~200k-char chunks; accumulated, decoded once |
| `KnoziGift.giftSaveEnd()` | `GiftBridge.saveEnd()` | `"saved"` / `"error"` | Saves PNG to Photos via `PHPhotoLibrary` add-only (`performChangesAndWait` on a background queue; JS call stays synchronous) |
| `KnoziGift.giftShareBegin(totalLen)` | `GiftBridge.shareBegin(totalLen:)` | `"ok"` / `"error"` | |
| `KnoziGift.giftShareChunk(piece)` | `GiftBridge.shareChunk(piece:)` | `"ok"` / `"error"` | |
| `KnoziGift.giftShareEnd(shareText)` | `GiftBridge.shareEnd(shareText:presenter:)` | void | Presents `UIActivityViewController` (Android's `ACTION_SEND` chooser twin); result arrives later via `window.__kzGiftShareDone(bool)` |
| `KnoziGift.openWhatsAppShare(text)` | `GiftBridge.openWhatsAppShare(text:)` | `"ok"` / `"error"` | `whatsapp://send?text=` when the app is installed, else generic `https://wa.me/?text=` — same fallback order as Android |
| `KnoziGift.shareRecapText(title, text)` | `GiftBridge.shareRecapText(title:text:presenter:)` | void | Weekly recap text share (Android v1.124+); fires the iOS share sheet — the twin of Android's `ACTION_SEND` chooser |
| `KnoziTts.ttsSpeak(text)` | `TtsBridge.speak(_:)` | void | `AVSpeechSynthesizer`, en-US, rate 0.95 (matches Android); flushes current speech |
| `KnoziTts.ttsStop()` | `TtsBridge.stop()` | void | |
| `KnoziAuth.openGoogleSignIn()` | `AuthBridge.openGoogleSignIn()` | void | Opens the Supabase Google authorize URL in the **system browser** (Google rejects embedded WebViews), like Android |
| `KnoziAuth.pollGoogleTokens()` | `AuthBridge.pollGoogleTokens()` | `""` or `{"a":…, "r":…}` | Byte-identical contract to Android — **see the key-mismatch note below** |
| `window.__kzGoogleTokens(a, r)` ← native | `AuthBridge` → `NotificationCenter` → `HubViewController` | — | Warm deep-link delivery, mirrors Android's `deliverGoogleTokens()` |
| `window.__kzGiftShareDone(ok)` ← native | `GiftBridge` completion | — | Async share-sheet result, mirrors Android's `giftShareResult()` |
| `confirm(…)` (library deletes) | `WKUIDelegate` confirm panel | bool | Without this, `confirm()` silently returns false and deletes never fire |
| App backgrounding | `SceneDelegate.sceneDidEnterBackground` → `TtsBridge.stop()` + `pauseAllAudio()` | — | Mirrors Android `onPause → webView.onPause()`: cancels speech, pauses every `<audio>`; no auto-resume |

### Not mapped 1:1 (deliberate)

- **Anti-tamper signature check** — Android refuses to run unless signed with the
  release key. On iOS, code signing + App Store review cover distribution
  integrity; no equivalent check is baked in.
- **`onSaveInstanceState` / `webView.saveState`** — iOS relaunches into a fresh
  `index.html`; `localStorage` persists in the default data store, so resume
  state and accounts survive.
- **`onBackPressed`** — iOS has no system back button; the web app already has
  its own ← Home navigation.

### Known shared-page quirk (found during the inventory, affects Android too)

`KnoziAuth.pollGoogleTokens()` returns `{"a": access, "r": refresh}` on
**both** shells, but the page's boot poll reads `o.access_token` /
`o.refresh_token` — so the *cold-start* Google sign-in path silently misses.
The *warm* path (`window.__kzGoogleTokens(access, refresh)` with positional
args) is unaffected. The iOS shell mirrors Android's exact contract on purpose;
the one-line fix belongs in the shared page (read both key shapes), which
repairs both platforms at once.

## Build it

Prerequisites: a Mac with Xcode 16+ (the Linux dev machine cannot compile iOS).

```bash
cd ios-build
./scripts/sync-assets.sh   # needs ANDROID_ASSETS_DIR, else pulls latest public APK
brew install xcodegen
xcodegen generate
open KnoziHub.xcodeproj    # or: xcodebuild -scheme KnoziHub -sdk iphoneos build
```

CI (`.github/workflows/ios-build.yml`) does the same on `macos-15` and uploads
an **unsigned** IPA artifact. It also asserts the `www/` folder structure
survived bundling (the pages rely on relative paths like `owl-poses/…`) and
fails loudly if xcodegen ever flattens it.

Keep versions in lockstep with Android: `CFBundleShortVersionString` /
`CFBundleVersion` in `Info.plist` (and `MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION` in `project.yml`) currently match Android v1.128 (131).

## Verification status

- No Swift toolchain exists on the Linux dev machine, so this was **carefully
  reviewed, not compiled**. The first CI run on `macos-15` is the real
  compile check — every API used (`AVAudioRecorder` LinearPCM, `PHPhotoLibrary`
  add-only, `UIActivityViewController`, `AVSpeechSynthesizer`,
  `WKUIDelegate` prompt interception) is stable, long-standing iOS API on the
  iOS 15+ deployment target.
- Bridge contracts were verified line-by-line against
  `apk-build/CleanConcept/app/src/main/java/com/knozi/hub/MainActivity.java`
  and every JS call site in the three player pages (2026-09-30 inventory).

## App Store — kids category notes (for later)

- The parent **math gate** already guards every parent-zone entry path in the
  web app — this is what Apple wants to see for a kids app ("parental gates").
- **No third-party tracking** in the shell: no analytics SDKs, no ad SDKs, no
  IDFA usage. `ITSAppUsesNonExemptEncryption = NO` is set (no custom crypto).
- The privacy "nutrition label" will need: microphone (voice recording),
  photos (add-only, saved pictures). The usage strings are already in
  `Info.plist`.
- Before TestFlight: add the real Curious Eye **AppIcon** (placeholder now),
  a launch screen, and confirm the privacy policy URL (knozihub.com) is live.
- COPPA: the UGC/community engine is still parked pending counsel — keep it
  that way for the 1.0 App Store submission.

## What only you can do

1. **Apple Developer enrollment** — $99/year, on your Apple ID. Only the
   account holder can enroll; nobody can do this for you.
2. **Signing & TestFlight** — once enrolled, create the App Store Connect
   record for `com.knozi.hub`, add signing to the workflow (import the
   certificate/provisioning profile as CI secrets), and the unsigned build
   above becomes a TestFlight build. The compile itself needs a Mac (or the
   macOS CI runner) — it cannot run on the Linux dev machine.
