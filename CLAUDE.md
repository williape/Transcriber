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
- **Hardened Runtime must stay OFF** (`ENABLE_HARDENED_RUNTIME = NO`) until Phase 7. With it on and no `com.apple.security.device.audio-input` entitlement, mic access is silently denied — no prompt, no Settings entry. For Phase 7 notarization, re-enable it WITH that entitlement.
- **Never hold an `AVAudioEngine` beyond one session.** An engine that has ever touched its `inputNode` keeps the input device open for as long as the object exists — `engine.stop()` is not enough. Symptoms: a Bluetooth headset gets pinned in narrowband HFP mode, so *other* apps' playback (Spotify) stays low-fidelity after dictation ends, and the orange mic-in-use indicator lingers. `MicrophoneCapture` therefore creates its engine in `start()` and releases it in `stop()`.
- **`log` is shadowed by a zsh function in this user's shell** — always use `/usr/bin/log`, and remember `--level debug` or `.info`/`.debug` messages won't appear.
- The user's terminal host is Apple Terminal; `open`-launched apps are their own TCC identity, so this is the safe launch path.
- Esc-to-dismiss works via a transient Carbon hotkey registered only while the session is `.recording` (the non-activating panel can never receive key events). Esc is consumed globally for that window — intentional trade-off. It is deliberately *not* registered for the other panel-visible states (`.downloadingModel`, `.transcribingFile`, `.finishing`, `.inserting`) where it has no action: swallowing Esc for the length of a long file transcription would break it for every other app.
- SDK API ground truth lives at `$(xcrun --show-sdk-path)/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface` — grep it rather than trusting blogs/memory for `SpeechAnalyzer` APIs.

## Rules

- 100% native Apple frameworks. **NO third-party packages, ever.**
- New Swift files: just create them under `Transcriber/` — the target uses folder-synchronized groups (`PBXFileSystemSynchronizedRootGroup`), no pbxproj edits needed.
- App is `LSUIElement` (menu-bar only, no Dock icon). **App Sandbox is intentionally OFF** — direct text insertion via CGEvent requires it (rules out Mac App Store; that's accepted).
- The floating panel must be a **non-activating `NSPanel`** and never become key window — direct insertion into the previously focused app depends on it. Dismissal is Esc / hotkey again / click outside / insertion complete, never "loss of focus."
- Global hotkey uses Carbon `RegisterEventHotKey` (no TCC permission, consumes the event) — not `NSEvent.addGlobalMonitorForEvents`.
- File transcription uses `analyzer.analyzeSequence(from: AVAudioFile)` + `finalizeAndFinish(through:)`; there is no `AssetInputSequenceProvider` API.
- `SpeechAnalyzer` is new — confirm exact signatures against the installed Xcode SDK headers, not blog posts.

## Architecture

Planned layout (plan §3) — single source of truth is `AppState`, an observable session state machine: `idle → recording(live) → finishing → inserting → idle`, plus parallel `transcribingFile(progress)` and `downloadingModel(progress)` modes; the menu bar icon reflects state.

- `MenuBar/StatusItemController` — `NSStatusItem`, menu, icon states
- `Hotkey/HotkeyManager` — `RegisterEventHotKey` wrapper (default ⌥Space, configurable)
- `Panel/` — non-activating `NSPanel` host + SwiftUI dictation view (committed text `.primary`, volatile `.secondary`)
- `Speech/` — `TranscriptionEngine` (SpeechAnalyzer + SpeechTranscriber), `MicrophoneCapture` (AVAudioEngine tap → AVAudioConverter to `SpeechAnalyzer.bestAvailableAudioFormat`), `ModelAssetManager` (`AssetInventory` model install), `FileTranscriber`
- `Output/OutputRouter` — clipboard write always; CGEvent ⌘V insertion when Accessibility (`AXIsProcessTrusted`) granted; pasteboard save/restore; clipboard-only fallback
- `Settings/` — SwiftUI settings + UserDefaults-backed preferences

## Permissions (TCC)

Only Microphone (prompted on first mic tap) and Accessibility (manual grant for insertion). No Speech Recognition or Input Monitoring permission needed. Reset during testing:

```sh
tccutil reset Microphone com.pwilliams.Transcriber
tccutil reset Accessibility com.pwilliams.Transcriber
```
