# Implementation Plan: Native macOS Dictation & Transcription Utility

Companion to `PRD - Native macOS Dictation & Transcription utility.md`. Working name: **Transcriber** (rename any time before Phase 7).

## 0. Environment status (verified 2026-07-23)

| Requirement | Needed | You have | Status |
|---|---|---|---|
| macOS | 26.0+ | 26.5.2 | ✅ |
| Xcode | 26+ (SDK with `SpeechAnalyzer`) | 26.6 | ✅ |
| Apple Silicon | recommended | (assumed) | ✅ |
| Apple ID in Xcode | for a stable signing identity | verify in Xcode ▸ Settings ▸ Accounts | ⚠️ check |

A free Apple ID ("Personal Team") is enough for local development. A paid account is only needed for notarized distribution (Phase 7).

---

## 1. Decisions & corrections to the PRD

These deviate from or tighten the PRD; each has a reason.

1. **Hotkey: Carbon `RegisterEventHotKey`, not `NSEvent.addGlobalMonitorForEvents`.**
   The NSEvent global monitor requires the user to grant Input Monitoring/Accessibility *and* cannot consume the event (the keystroke still reaches the frontmost app). `RegisterEventHotKey` needs **no TCC permission**, consumes the event, and is still fully supported. Default shortcut `⌥Space`, user-configurable (note: `⌥Space` types a non-breaking space in some apps if registration fails — handle registration failure visibly).

2. **File transcription API: `analyzer.analyzeSequence(from: AVAudioFile)`.**
   The PRD's `AssetInputSequenceProvider` does not exist in the shipped API. The real flow: open the file with `AVAudioFile(forReading:)`, call `analyzeSequence(from:)`, then `finalizeAndFinish(through:)`.

3. **App Sandbox: OFF.**
   Direct text insertion (CGEvent paste into other apps) and Accessibility control are incompatible with the sandbox. This rules out Mac App Store distribution — acceptable for a personal/Developer ID utility. (If MAS ever matters, a sandboxed clipboard-only mode is the fallback.)

4. **Floating panel must be a *non-activating* `NSPanel`.**
   Critical detail the PRD's "behaves like Spotlight" hides: if the panel takes key focus, the user's target text field loses focus and direct insertion breaks. Use `NSPanel` with `.nonactivatingPanel`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`. Consequence: "dismiss on loss of focus" becomes "dismiss on Esc / hotkey again / click outside / insertion complete" — the panel never *has* focus.

5. **"Fully offline" nuance: one network touch at first run.**
   The speech model is downloaded once through Apple's system asset catalog (`AssetInventory`). After that everything is on-device. First-run UX must handle "model not yet installed."

6. **`NSSpeechRecognitionUsageDescription` is not required.** `SpeechAnalyzer` doesn't go through `SFSpeechRecognizer` authorization. Only microphone permission (and Accessibility for insertion) are needed.

7. **Xcode project is created once by hand in the Xcode GUI** (5 minutes, steps below). Hand-writing `project.pbxproj` is error-prone; every subsequent change (new files, build settings) can be done by Claude Code editing files, because we'll enable Xcode's **folder-based file system synchronized groups** (default in Xcode 16+) — files added to the source folder automatically join the target, no pbxproj surgery needed.

---

## 2. Precursor steps (user, in Xcode GUI — one-time, ~10 min)

1. **Xcode ▸ Settings ▸ Accounts**: ensure your Apple ID is added and a "Personal Team" (or paid team) exists.
2. **File ▸ New ▸ Project ▸ macOS ▸ App**:
   - Product Name: `Transcriber`
   - Team: your team · Organization Identifier: e.g. `com.pwilliams`
   - Interface: **SwiftUI** · Language: Swift · Testing: Swift Testing · ☐ Core Data
   - Save into `/Users/pwilliams/Documents/AI/transcriber/` (creates `Transcriber/` subfolder) · ✅ create git repository
3. **Target ▸ General**: Minimum Deployments → **macOS 26.0**.
4. **Target ▸ Signing & Capabilities**:
   - ✅ Automatically manage signing (stable signing identity ⇒ TCC permission grants survive rebuilds; ad-hoc signing would re-prompt constantly)
   - **Delete the "App Sandbox" capability** (see decision 3). Keep Hardened Runtime off for now.
5. **Target ▸ Info** — add keys:
   - `Application is agent (UIElement)` (`LSUIElement`) = **YES** → menu-bar-only, no Dock icon
   - `Privacy - Microphone Usage Description` = "Transcriber uses the microphone to transcribe your speech on-device."
6. Build & run once (⌘R) to confirm signing works, then quit Xcode. Everything after this is Claude Code territory.

**First Claude Code session then does:** verify `xcodebuild` build passes, add `.gitignore`, write `CLAUDE.md` (template in §6), commit the scaffold.

---

## 3. Architecture

```
Transcriber/
├── TranscriberApp.swift          // @main, AppDelegate adaptor, wiring
├── AppState.swift                // Observable session state machine
├── MenuBar/
│   └── StatusItemController.swift    // NSStatusItem, menu, icon states
├── Hotkey/
│   └── HotkeyManager.swift           // RegisterEventHotKey wrapper
├── Panel/
│   ├── FloatingPanel.swift           // non-activating NSPanel host
│   └── DictationView.swift           // SwiftUI: committed + volatile text, level meter
├── Speech/
│   ├── TranscriptionEngine.swift     // SpeechAnalyzer + SpeechTranscriber session
│   ├── MicrophoneCapture.swift       // AVAudioEngine tap + AVAudioConverter
│   ├── ModelAssetManager.swift       // AssetInventory install/locale checks
│   └── FileTranscriber.swift         // analyzeSequence(from: AVAudioFile)
├── Output/
│   └── OutputRouter.swift            // NSPasteboard + CGEvent ⌘V, AX trust check
└── Settings/
    ├── SettingsView.swift
    └── Preferences.swift             // UserDefaults-backed
```

**Session state machine** (single source of truth in `AppState`):
`idle → recording(live) → finishing → inserting → idle`, plus `transcribingFile(progress)` and `downloadingModel(progress)` as parallel modes. Menu bar icon reflects state.

**Core streaming pipeline** (Phase 3):

```swift
let transcriber = SpeechTranscriber(
    locale: locale,
    transcriptionOptions: [],
    reportingOptions: [.volatileResults],
    attributeOptions: [])
let analyzer = SpeechAnalyzer(modules: [transcriber])
let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
try await analyzer.start(inputSequence: stream)
// mic tap → AVAudioConverter to `format` → continuation.yield(AnalyzerInput(buffer:))
// separate Task: for try await result in transcriber.results { volatile vs final }
// stop: continuation.finish(); try await analyzer.finalizeAndFinishThroughEndOfInput()
```

**Insertion flow** (Phase 4): save pasteboard → write text → post ⌘V via `CGEvent` (requires Accessibility trust, checked with `AXIsProcessTrustedWithOptions`) → restore pasteboard after a short delay. Fallback when Accessibility not granted: leave text on clipboard and notify.

---

## 4. Phased milestones

Each phase ends buildable and manually verifiable. Claude Code can verify *compilation* itself (`xcodebuild`); runtime behavior (hotkeys, mic, permission prompts) needs you at the keyboard, so each phase lists a 1-minute manual check.

### Phase 1 — Menu bar skeleton + hotkey (no speech yet) — **✅ verified 2026-07-23**
- `NSStatusItem` with template mic icon; menu: Start Dictation, Transcribe File…, Settings…, Quit.
- `HotkeyManager` with `RegisterEventHotKey` (⌥Space), toggling a logged state; `AppState` machine in place; Preferences storage.
- **Verify:** icon appears, no Dock icon, ⌥Space toggles state (visible via icon change), app quits cleanly.

### Phase 2 — Floating panel — **✅ verified 2026-07-23**
- Non-activating `NSPanel` (decision 4) with `NSVisualEffectView` blur, hidden title bar, appears centered near bottom of active screen, all Spaces, Esc/hotkey dismisses. Placeholder text.
- **Verify:** panel appears over a full-screen app; focus stays in the previously active text field (type — your keystrokes must land in the target app, not the panel).

### Phase 3 — Live transcription — **✅ verified 2026-07-24** (note: required turning OFF Hardened Runtime, which the Xcode template had enabled — a hardened app without the audio-input entitlement gets mic access silently denied with no prompt and no Settings listing. Re-enable WITH `com.apple.security.device.audio-input` for Phase 7 notarization.)
- `ModelAssetManager`: check `SpeechTranscriber.installedLocales`; if missing, run `AssetInventory.assetInstallationRequest(supporting:)` with progress UI in the panel.
- `MicrophoneCapture` (AVAudioEngine tap, converter) + `TranscriptionEngine` per the pipeline sketch; mic permission prompt on first use.
- Panel renders committed text `.primary`, volatile `.secondary`, auto-scrolling.
- **Verify:** speak; gray words solidify to black; stop via hotkey; final text shown. Test with Wi-Fi off (after model install) to prove offline.

### Phase 4 — Output routing — **✅ verified 2026-07-24**
- `OutputRouter`: clipboard write always; direct insertion via CGEvent ⌘V when Accessibility granted; pasteboard save/restore; onboarding UI that deep-links to System Settings ▸ Privacy & Security ▸ Accessibility.
- Setting: insertion mode (paste / clipboard-only).
- **Verify:** dictate into TextEdit, Notes, Safari form field; text lands at the cursor; prior clipboard contents restored.

### Phase 5 — File transcription — **✅ verified 2026-07-24**
- Drag-and-drop onto the menu bar icon and an "Transcribe File…" open panel; accept common audio types (`.m4a`, `.mp3`, `.wav`, `.aac`, and video containers AVAudioFile can read).
- `FileTranscriber` using `analyzeSequence(from:)`; progress in menu/panel; result → window with text, Copy and Save (.txt) buttons. Handle long files (webinar-length) without blocking UI.
- **Verify:** drop a 30+ min voice memo; transcription completes; output saves.

### Phase 6 — Polish — **🔨 implemented 2026-07-24, awaiting manual verification**
- Live input level meter in panel (from mic tap RMS); recording start/stop sounds; locale picker (installed + downloadable locales); launch-at-login via `SMAppService`; menu bar icon animation while recording; robust error states (mic in use, model download failed, no speech detected via `SpeechDetector`).
- Also added: configurable dictation shortcut — click-to-record field in Settings (local event monitor; ⌘/⌥/⌃ required except F-keys; key names from the live keyboard layout via `UCKeyTranslate`); the old hotkey is unregistered during capture and restored if the new one fails to register.
- Implementation notes: menu bar recording animation is a variable-color `waveform` symbol driven by the live mic level (file transcription icon became `waveform.circle` to stay distinct). "No speech detected" is derived from an empty final transcript (panel notice, 1.5 s hold) rather than a parallel `SpeechDetector` module — same user-facing result, one less module. Launch-at-login registers whatever binary path is running, i.e. the Debug build under `build/` until Phase 7 produces an installed copy.
- **Verify:** exploratory pass through the full checklist in §7.

### Phase 7 — Distribution (optional)
- Developer ID signing + Hardened Runtime + notarization (`notarytool`), or stay with local Debug builds if it's personal-use only.

---

## 5. Permissions (TCC) matrix

| Permission | Needed for | When prompted | Notes |
|---|---|---|---|
| Microphone | live dictation | first mic tap (Phase 3) | via `NSMicrophoneUsageDescription` |
| Accessibility | CGEvent paste (Phase 4) | manual grant; app detects via `AXIsProcessTrusted` | user must toggle in System Settings |
| Input Monitoring | — | never | avoided by using Carbon hotkey |
| Speech Recognition | — | never | SpeechAnalyzer needs no SFSpeechRecognizer auth |

Reset during testing: `tccutil reset Microphone com.pwilliams.Transcriber` (same for `Accessibility`). Stable dev-cert signing keeps grants across rebuilds.

---

## 6. Claude Code workflow

`CLAUDE.md` to create in the project root during the first session:

```markdown
# Transcriber — macOS menu bar dictation app (SwiftUI, macOS 26+)

## Build
xcodebuild -project Transcriber.xcodeproj -scheme Transcriber \
  -configuration Debug -derivedDataPath build build
App output: build/Build/Products/Debug/Transcriber.app

## Run / stop (user usually verifies runtime behavior manually)
pkill -x Transcriber; open build/Build/Products/Debug/Transcriber.app

## Logs
Use os.Logger(subsystem: "com.pwilliams.Transcriber", ...) everywhere.
Tail: log stream --predicate 'subsystem == "com.pwilliams.Transcriber"' --level debug

## Rules
- 100% native Apple frameworks. NO third-party packages, ever.
- New Swift files: just create them under Transcriber/ — the target uses
  folder-synchronized groups, no pbxproj edits needed.
- App is LSUIElement (menu-bar only). App Sandbox is intentionally OFF.
- Panel must never become key window (non-activating) — insertion depends on it.
- IMPLEMENTATION_PLAN.md is the roadmap; keep its phase status current.
```

**Division of labor per iteration:** Claude Code writes code → builds with `xcodebuild` (catches compile errors itself) → relaunches the app → you do the 1-minute manual check for that phase → paste any `log stream` output or describe misbehavior back.

## 7. Manual test checklist (grows per phase)

- [ ] Menu bar icon present; no Dock icon; Quit works
- [ ] ⌥Space toggles dictation from any app, including full-screen Spaces
- [ ] Panel never steals focus; Esc dismisses
- [ ] Model download UX on fresh install; dictation works offline afterwards
- [ ] Volatile→committed rendering, no jitter
- [ ] Insertion into TextEdit / Notes / Safari / Slack; clipboard restored
- [ ] Clipboard-only fallback when Accessibility denied
- [ ] File drop: short clip + 30 min file; save .txt
- [ ] Mic-permission-denied and mic-busy error states
- [ ] Launch at login; survives logout/login

## 8. Risks & watch items

1. **API drift** — `SpeechAnalyzer` is new (WWDC25); exact signatures (e.g. `finalizeAndFinishThroughEndOfInput`, `AnalyzerInput`) should be confirmed against the Xcode 26.6 SDK headers when Phase 3 starts, not against blog posts.
2. **⌥Space conflicts** — some users/apps (e.g. Alfred defaults) use it; make the shortcut configurable early (Phase 1 stores it in Preferences).
3. **Secure input fields** — password fields block synthetic paste; detect and fall back to clipboard with a notification.
4. **AVAudioConverter format mismatch** — mic native format vs `bestAvailableAudioFormat` sample-rate conversion is the classic source of silent failures; log both formats at session start.
5. **Long-file memory** — for webinar-length files rely on `analyzeSequence(from:)` streaming internally; don't load buffers wholesale.
