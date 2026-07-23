# PRD: Native macOS Dictation & Transcription Utility

## 1. Project Overview

**Objective:** Build a lightweight, macOS-native, menu-bar-driven dictation and audio transcription utility. The app must function as a local-first system utility utilizing Apple's modern `SpeechAnalyzer` framework, providing a progressive UX for live dictation and batch processing for audio files. Inspirec by propritrary apps like SuperWhisper, Aqua Voice, Whispr Flow and VoiceInk. 

## 2. Constraints & System Boundaries

* **Target Environment:** macOS 26+ (Apple Silicon optimized).
* **Frameworks:** `Swift`, `SwiftUI`, `AppKit`, `AVFoundation`, `Speech`, `ApplicationServices` (for accessibility/keystrokes).
* **Strict Dependency Ban:** NO 3rd-party packages. Use 100% native Apple APIs.
* **Network & Privacy:** Fully offline. No server-side fallback. All audio processing and language model execution must occur strictly on-device using the system's asset catalog.

## 3. Core Capabilities & API Mapping

### Feature 1: Global Invocation & Lifecycle

* **Requirement:** The app lives in the Menu Bar and is invoked globally via a hotkey (e.g., `Option + Spacebar`).
* **Agentic Implementation details:**
* Use an `NSStatusItem` for the Menu Bar presence.
* Implement global hotkey registration using Carbon `RegisterEventHotKey`. (Do NOT use `NSEvent.addGlobalMonitorForEvents` — it requires an Input Monitoring/Accessibility TCC grant and cannot consume the event, so the keystroke would still reach the frontmost app. `RegisterEventHotKey` needs no permission and consumes the event.)
* Handle registration failure visibly (e.g., `⌥Space` may be taken by another app), and make the shortcut user-configurable.



### Feature 2: Live Progressive Dictation (Streaming)

* **Requirement:** Capture microphone audio and stream text to a floating UI with visual distinction between tentative and finalized words.
* **Agentic Implementation details:**
* **Audio Routing:** Tap the microphone using `AVAudioEngine`. Convert the `AVAudioPCMBuffer` to a format compatible with the analyzer using `SpeechAnalyzer.bestAvailableAudioFormat`.
* **Analysis Session:** Initialize a `SpeechAnalyzer` instance. Attach a `SpeechTranscriber` module (configured with `[.volatileResults]` option) and a `SpeechDetector` module (for native Voice Activity Detection).
* **Concurrency:** Feed converted audio into an `AsyncStream<AnalyzerInput>`. Start the analyzer via `start(inputSequence:)`.
* **State Management:** Iterate over `transcriber.results` in a background `Task`. Separate text into `volatile` (`result.isFinal == false`) and `committed` (`result.isFinal == true`) variables to prevent UI jitter.



### Feature 3: File-Based Batch Transcription

* **Requirement:** Allow users to drop audio files (e.g., webinars, voice memos) onto the app for rapid background transcription.
* **Agentic Implementation details:**
* Open the file with `AVAudioFile(forReading:)` and pass it to the analyzer via `SpeechAnalyzer.analyzeSequence(from:)`, then flush remaining results with `finalizeAndFinish(through:)`. (Note: there is no `AssetInputSequenceProvider` API — `analyzeSequence(from:)` is the shipped file-based entry point.)



### Feature 4: Output Routing

* **Requirement:** Automatically insert transcribed text into the user's active application or copy it to the clipboard.
* **Agentic Implementation details:**
* **Clipboard:** Write the final `committed` string to `NSPasteboard.general`.
* **Direct Insertion:** Use Accessibility APIs (`AXUIElement`) or `CGEvent` to simulate a `Cmd+V` paste or individual keystrokes into the previously focused application text field once transcription concludes.



## 4. UI/UX Specifications

* **Window Architecture:** Use a floating, borderless **non-activating `NSPanel`** (`.nonactivatingPanel`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`). Unlike Spotlight, the panel must NEVER become the key window: if it steals focus, the user's target text field loses focus and direct text insertion (Feature 4) breaks. Because the panel never has focus, "dismiss on loss of focus" becomes: dismiss on Esc, on pressing the hotkey again, on click outside, or when insertion completes.
* **Visuals:** Employ `NSVisualEffectView` for native system blur/translucency.
* **Typography:** System font (San Francisco). Render `volatile` text in a secondary color (e.g., `.secondary` or gray) and `committed` text in the primary text color (.primary).

---

## References
* [Apple Developer Documentation: Speech Framework](https://developer.apple.com/documentation/speech/)
* [Apple Developer Documentation: SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
* [SpeechAnalyzer Architectural Breakdown](https://blakecrosley.com/blog/speech-framework-vs-sfspeechrecognizer)

[WWDC25: Bring advanced speech-to-text to your app with SpeechAnalyzer](https://www.youtube.com/watch?v=0m6dimDDj8M&vl=en)
This presentation provides a technical code-along demonstrating how to correctly implement live transcription and integrate the new API modules natively into an app.