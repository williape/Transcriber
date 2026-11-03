# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Transcriber — macOS menu bar dictation & transcription app (SwiftUI, macOS 26+)

Native menu-bar utility for live dictation and audio-file transcription using Apple's `SpeechAnalyzer` framework (WWDC25). Fully on-device after a one-time model download.

## Key documents

- `IMPLEMENTATION_PLAN.md` — the roadmap: architecture, phased milestones, permissions matrix, risks. **Keep its phase status current as work progresses.**
- `PRD - Native macOS Dictation & Transcription utility.md` — product requirements and API mapping. Where the two disagree, the plan's §1 "Decisions & corrections" wins.

## Build

```sh
xcodebuild -project Transcriber.xcodeproj -scheme Transcriber \
  -configuration Debug -derivedDataPath build build
```

App output: `build/Build/Products/Debug/Transcriber.app`

## Release / distribution

```sh
./Scripts/release.sh                # archive → Developer ID export → notarize → staple → DMG
./Scripts/release.sh --no-notarize  # same minus the two Apple round-trips (fast local check)
```

Output: `dist/Transcriber-<version>.dmg`. Signing config lives in `Config/Transcriber.entitlements` and `Config/ExportOptions.plist`; bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in the pbxproj to cut a new version. Notarization needs a `notarytool` keychain profile (default name `Transcriber`, override with `NOTARY_PROFILE`) — see the script's header for the one-time `store-credentials` command.

## Run / stop

Runtime behavior (hotkeys, mic, permission prompts) needs the user at the keyboard; Claude Code verifies compilation, the user does the per-phase manual check (plan §7).

```sh
pkill -x Transcriber; open build/Build/Products/Debug/Transcriber.app
```

## Tests

Unit tests use Swift Testing (`@Test` / `#expect`), UI tests use XCTest.

```sh
# All tests
xcodebuild -project Transcriber.xcodeproj -scheme Transcriber \
  -derivedDataPath build test

# Single test (unit target / one suite / one test)
xcodebuild ... test -only-testing:TranscriberTests
xcodebuild ... test -only-testing:TranscriberTests/TranscriberTests/example
```

## Logs

Use `os.Logger(subsystem: "com.pwilliams.Transcriber", ...)` everywhere.

```sh
log stream --predicate 'subsystem == "com.pwilliams.Transcriber"' --level debug
```

## Hard-won gotchas (from real debugging — don't rediscover these)

- **Never launch the app via ⌘R in Xcode.** Xcode-run instances (a) stay attached to the debugger and survive SIGKILL until stopped in Xcode, (b) run from DerivedData with a different path, creating **duplicate TCC records** that made microphone access fail with instant denial and no Settings listing. Always build/launch via `xcodebuild` + `open build/...` as above. If mic permission misbehaves: `tccutil reset Microphone com.pwilliams.Transcriber` and check for stray instances (`pgrep -lx Transcriber`; `ps -o stat=` showing `X` = debugger-attached).
- **Hardened Runtime is ON, and it only works because of the entitlement.** With it on and no `com.apple.security.device.audio-input` in `Config/Transcriber.entitlements`, mic access is silently denied — no prompt, no Settings entry. Never remove that key. (It was off through Phases 1–6 for exactly this reason; Phase 7 turned it on together with the entitlement.) The entitlements file lives in `Config/`, *not* `Transcriber/`, so the folder-synchronized group can't sweep it into the app bundle as a resource.
- **Never hold an `AVAudioEngine` beyond one session.** An engine that has ever touched its `inputNode` keeps the input device open for as long as the object exists — `engine.stop()` is not enough. Symptoms: a Bluetooth headset gets pinned in narrowband HFP mode, so *other* apps' playback (Spotify) stays low-fidelity after dictation ends, and the orange mic-in-use indicator lingers. `MicrophoneCapture` therefore creates its engine in `start()` and releases it in `stop()`.
- **Never let `AVAudioEngine` pick the input device.** It binds to whatever the system default input is when `inputNode` is first touched, and reports a device it can't open as a zero-channel format — no name, no status code. Conferencing apps (Zoom, Teams) install virtual audio drivers and make them the default input around a call; those present *no input streams*, so dictation started mid-call died with a bare "no microphone available". `MicrophoneCapture` now binds explicitly via `inputNode.auAudioUnit.setDeviceID(_:)` (only possible while the engine is stopped, and it must come *before* reading `outputFormat(forBus:)`) to devices enumerated by `AudioInputDevices`, working down the candidate list and naming each failure.
- **The engine's tap dies silently on `AVAudioEngineConfigurationChange`.** The device being swapped or reconfigured under a live session — exactly what a call starting or ending does — leaves the engine running and the tap delivering nothing. `MicrophoneCapture` observes the notification and rebuilds capture; the observer is registered with `object: nil` and identity-checked in the handler, because passing the engine as `object:` would have CoreFoundation hold it unretained and capturing it in the block would violate the rule above.
- **System audio = a private aggregate of mic + CoreAudio process tap, and AUHAL drops the tap unless told not to.** The aggregate presents mic and tap as two input *streams*; `AVAudioEngine`'s input node binds to it fine but its client format defaults to one channel, so only the mic arrives and the tap is discarded silently (device reports 2ch, `inputNode` 1ch). `MicrophoneCapture.exposeAllInputChannels` widens the AUHAL output-scope format (element 1) to the hardware channel count with an identity channel map — after `setDeviceID`, before reading the format. Teardown order matters too: release the engine, *then* destroy the aggregate, then the tap (`SystemAudioTap.destroy()`). Don't set `tapautostart` — it blocks the device's start until some app plays audio. **A denied System Audio Recording permission is silent**: tap and aggregate build fine, the tap channel just carries zeros — no error, no preflight API — so the app can't detect it; Settings points the user at Privacy & Security instead.
- **`NSAudioCaptureUsageDescription` has no `INFOPLIST_KEY_*` build setting** — Xcode silently drops it. It lives in `Config/Info.plist`, merged with the generated plist via `INFOPLIST_FILE`. Without it there's no System Audio Recording prompt.
- **`log` is shadowed by a zsh function in this user's shell** — always use `/usr/bin/log`, and remember `--level debug` or `.info`/`.debug` messages won't appear.
- The user's terminal host is Apple Terminal; `open`-launched apps are their own TCC identity, so this is the safe launch path.
- Esc-to-dismiss works via a transient Carbon hotkey registered only while the session is `.recording` (the non-activating panel can never receive key events). Esc is consumed globally for that window — intentional trade-off. It is deliberately *not* registered for the other panel-visible states (`.downloadingModel`, `.transcribingFile`, `.finishing`, `.inserting`) where it has no action: swallowing Esc for the length of a long file transcription would break it for every other app.
- The panel is dragged by intercepting `.leftMouseDown` in `FloatingPanel.sendEvent` and calling `performDrag(with:)`. `isMovableByWindowBackground` alone doesn't work: the `NSHostingView` filling the borderless panel swallows the mouse-down. The interception makes the entire surface a drag handle and consumes the click, so **any clickable control added to the panel must be hit-tested before the drag starts**. Scroll events are untouched. The dragged origin is persisted (`Preferences.panelOrigin`) and clamped back onto a live screen on restore; Settings → "Dictation panel → Reset Position" clears it.
- SDK API ground truth lives at `$(xcrun --show-sdk-path)/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface` — grep it rather than trusting blogs/memory for `SpeechAnalyzer` APIs.

## Rules

- 100% native Apple frameworks. **NO third-party packages, ever.**
- New Swift files: just create them under `Transcriber/` — the target uses folder-synchronized groups (`PBXFileSystemSynchronizedRootGroup`), no pbxproj edits needed.
- App is `LSUIElement` (menu-bar only, no Dock icon). **App Sandbox is intentionally OFF** — direct text insertion via CGEvent requires it (rules out Mac App Store; that's accepted).
- The floating panel must be a **non-activating `NSPanel`** and never become key window — direct insertion into the previously focused app depends on it. Dismissal is Esc / hotkey again / click outside / insertion complete, never "loss of focus." It is draggable anywhere on screen and remembers where the user left it.
- Global hotkey uses Carbon `RegisterEventHotKey` (no TCC permission, consumes the event) — not `NSEvent.addGlobalMonitorForEvents`.
- File transcription uses `analyzer.analyzeSequence(from: AVAudioFile)` + `finalizeAndFinish(through:)`; there is no `AssetInputSequenceProvider` API.
- `SpeechAnalyzer` is new — confirm exact signatures against the installed Xcode SDK headers, not blog posts.

## Architecture

Planned layout (plan §3) — single source of truth is `AppState`, an observable session state machine: `idle → recording(live) → finishing → inserting → idle`, plus parallel `transcribingFile(progress)` and `downloadingModel(progress)` modes; the menu bar icon reflects state.

- `MenuBar/StatusItemController` — `NSStatusItem`, menu, icon states
- `Hotkey/HotkeyManager` — `RegisterEventHotKey` wrapper (default ⌥Space, configurable)
- `Panel/` — non-activating `NSPanel` host + SwiftUI dictation view (committed text `.primary`, volatile `.secondary`)
- `Speech/` — `TranscriptionEngine` (SpeechAnalyzer + SpeechTranscriber), `MicrophoneCapture` (AVAudioEngine tap → AVAudioConverter to `SpeechAnalyzer.bestAvailableAudioFormat`), `AudioInputDevices` (CoreAudio input-device enumeration + candidate ordering), `ModelAssetManager` (`AssetInventory` model install), `FileTranscriber`
- `Output/OutputRouter` — clipboard write always; CGEvent ⌘V insertion when Accessibility (`AXIsProcessTrusted`) granted; pasteboard save/restore; clipboard-only fallback
- `Settings/` — SwiftUI settings + UserDefaults-backed preferences

## Permissions (TCC)

Only Microphone (prompted on first mic tap) and Accessibility (manual grant for insertion). No Speech Recognition or Input Monitoring permission needed. Reset during testing:

```sh
tccutil reset Microphone com.pwilliams.Transcriber
tccutil reset Accessibility com.pwilliams.Transcriber
tccutil reset AudioCapture com.pwilliams.Transcriber   # System Audio Recording (system audio toggle)
```
