# PRD: Native macOS Dictation & Transcription Utility

Single product spec for **Transcriber**. Covers the original dictation utility (Phases 1–6) and the transcription history & audio retention work (Phase 8), which was previously a separate PRD and is folded in here.

Companion: `IMPLEMENTATION_PLAN.md` — the roadmap, phase status and manual-test checklist. Where this document and the plan disagree on an implementation detail, the plan's §1 "Decisions & corrections" wins.

Last consolidated: 2026-08-01.

---

## 1. Project overview

**Objective:** a lightweight, macOS-native, menu-bar-driven dictation and audio transcription utility. A local-first system utility built on Apple's `SpeechAnalyzer` framework, with a progressive UX for live dictation, batch processing for audio files, and a persistent, privacy-first record of what was dictated. Inspired by proprietary apps like SuperWhisper, Aqua Voice, Whispr Flow and VoiceInk.

### Goals

- **G1.** Dictate into any app from a global hotkey, with text appearing progressively as it is spoken.
- **G2.** Transcribe dropped audio files (voice memos, webinars) without blocking the UI.
- **G3.** Never lose a transcript — a dictation that failed to insert (Accessibility off, secure input, wrong app focused, clipboard clobbered) is recoverable.
- **G4.** Re-use past transcripts: search, copy, re-insert, export.
- **G5.** Optionally retain the source audio so a transcript can be **verified** against what was said, and **re-transcribed** (e.g. in a different locale, or after a model update).
- **G6.** Keep the user in full control of what is kept, for how long, and how much disk it consumes — with a one-click "don't record this one" escape hatch.
- **G7.** Stay 100% on-device and 100% Apple-framework.

### Non-goals

- Cloud sync, multi-device history, or any server-side fallback.
- LLM post-processing of transcripts ("modes"/prompts, à la SuperWhisper). Separate future PRD.
- Speaker diarization, system-audio/meeting capture, or a waveform editor.
- Encryption at rest (see §11.4 — FileVault is the answer; a Keychain-keyed store is deferred).
- Full-text search ranking, tags, or folders. Search is substring + date grouping.
- History for file transcriptions (§4.6).

---

## 2. Constraints & system boundaries

- **Target environment:** macOS 26+ (Apple Silicon optimized).
- **Frameworks:** `Swift`, `SwiftUI`, `AppKit`, `AVFoundation`, `Speech`, `SwiftData`, `ApplicationServices` (accessibility/keystrokes), Carbon `HIToolbox` (hotkey).
- **Strict dependency ban:** NO 3rd-party packages. 100% native Apple APIs.
- **Network & privacy:** fully offline in normal operation. All audio processing and language model execution happens on-device. The one network touch is the first-run speech-model download through the system asset catalog (`AssetInventory`).
- **App Sandbox is OFF.** Direct text insertion via `CGEvent` and Accessibility control are incompatible with the sandbox. This rules out Mac App Store distribution — accepted for a Developer ID / personal utility.
- **`LSUIElement`** — menu-bar only, no Dock icon.

---

## 3. Competitive reference: SuperWhisper

What it does, and what we do differently.

| Aspect | SuperWhisper | Transcriber |
|---|---|---|
| History list | Sidebar of previous dictations; right-click ▸ "Process Again" re-runs with the *currently active* mode | Same idea; re-transcribe uses the locale picked in the re-transcribe sheet, not implicitly the current setting |
| Audio retention | Saved to disk **by default, no documented opt-out** | **Off by default, explicit opt-in.** Same neighbourhood on disk (`~/Documents/Transcriber`, `0700`) — the difference is consent, not concealment |
| Retention policy | No documented auto-delete; pruning is manual | Age-based expiry + total-size cap, both enforced automatically |
| Incognito | — | "Pause History" menu toggle; automatic skip while secure input is active |
| Reprocessing | Yes (re-transcribe from stored audio) | Yes, but only for entries that still have audio |

The retention-by-default criticism is well documented ([Voibe](https://www.getvoibe.com/resources/is-superwhisper-safe/), [Tota](https://www.heytota.com/is-superwhisper-private)) and is the main thing worth deliberately not copying: a dictation tool bound to a global hotkey will eventually hear a password, a medical detail, or someone else's confidence.

---

## 4. Decisions

Each is a judgment call with a reason; §16 lists what was rejected.

1. **Hotkey uses Carbon `RegisterEventHotKey`, not `NSEvent.addGlobalMonitorForEvents`.** The NSEvent global monitor needs an Input Monitoring/Accessibility grant *and* cannot consume the event, so the keystroke would still reach the frontmost app. `RegisterEventHotKey` needs no TCC permission and consumes the event. Default `⌥Space`, user-configurable, with visible handling of registration failure.
2. **The dictation panel is a non-activating `NSPanel` that never becomes key window.** If it took focus, the user's target text field would lose it and direct insertion would break. Consequence: "dismiss on loss of focus" becomes "dismiss on Esc / hotkey again / click outside / insertion complete".
3. **File transcription uses `analyzer.analyzeSequence(from: AVAudioFile)` + `finalizeAndFinish(through:)`.** There is no `AssetInputSequenceProvider` API.
4. **Transcript history is ON by default; audio retention is OFF by default.** Text is small, low-risk, and delivers G3/G4 on its own. Audio is the sensitive, bulky part and should be a deliberate choice (§3).
5. **Retained audio is exactly the audio the analyzer heard** — the already-converted analyzer-format buffers are teed into the recorder. No second converter, no extra render-thread work, and the recording's timeline is sample-aligned with the `CMTimeRange`s in the results. Speech-grade mono (typically 16 kHz) is also precisely what a future re-transcription wants.
6. **Container/codec: AAC-LC mono in `.m4a`**, via `AVAudioFile(forWriting:settings:)` at 24 kbit/s → ≈3 KB/s → **≈10.8 MB per hour**; a 20-second dictation is ~60 KB.
7. **History covers dictation only.** File transcriptions keep their result-window behaviour with no persistence: the source audio is already a file the user owns and placed deliberately, so an entry would only duplicate a transcript they can regenerate at will. This drops the `kind` discriminator, the source-file bookmark, and every "did the source file move?" failure mode.
8. **Store: SwiftData**, one `@Model` per entry, versioned schema from day one, audio kept as loose files referenced by filename. Gives search/sort/predicate and `@Query`-driven SwiftUI for free.
9. **Audio files are written on a dedicated serial queue, never on the audio render thread.** The tap callback hands off a buffer reference and returns.
10. **A failed recorder never fails a dictation.** Any write/encode/disk error disables retention for that session, logs, and surfaces a one-time notice. Transcription continues untouched.
11. **Cancelled (Esc) and empty ("No speech detected") sessions create no history entry** and delete any partial audio. A *truncated* session (`transcriptionIncomplete`) **does** create an entry, flagged as partial.
12. **The History window is a standard `NSWindow`**, not the non-activating panel — it needs key focus for search and text selection.

---

## 5. Core capabilities & API mapping

### Feature 1 — Global invocation & lifecycle

- The app lives in the menu bar (`NSStatusItem`) and is invoked globally by hotkey.
- Global hotkey registration via Carbon `RegisterEventHotKey` (§4.1). Registration failure is surfaced visibly (`⌥Space` may be taken by another app).
- The shortcut is user-configurable through a click-to-record field in Settings: a local event monitor, ⌘/⌥/⌃ required except for F-keys, key names derived from the live keyboard layout via `UCKeyTranslate`. The old hotkey is unregistered during capture and restored if the new one fails to register.
- The menu bar icon reflects session state, animating (a mic-level-driven `waveform` symbol) while recording.
- Menu: Start Dictation · Transcribe File… · History… (⌘Y) · Recent Transcripts ▸ · Copy Last Transcript · Pause History · Settings… · Quit.
- Launch at login via `SMAppService`.

### Feature 2 — Live progressive dictation (streaming)

- **Audio routing:** tap the microphone with `AVAudioEngine`; convert each `AVAudioPCMBuffer` to `SpeechAnalyzer.bestAvailableAudioFormat` with `AVAudioConverter`.
- **Analysis session:** a `SpeechAnalyzer` with a `SpeechTranscriber` module configured with `reportingOptions: [.volatileResults]`.
- **Concurrency:** converted audio is yielded into an `AsyncStream<AnalyzerInput>`; the analyzer is started with `start(inputSequence:)`; results are consumed in a background `Task`.
- **State management:** results are split into `volatile` (`isFinal == false`) and `committed` (`isFinal == true`) to prevent UI jitter.
- **Model assets:** `ModelAssetManager` checks `SpeechTranscriber.installedLocales` and, when missing, runs `AssetInventory.assetInstallationRequest(supporting:)` with progress shown in the panel.
- **Error states:** mic in use, mic permission denied, model download failed, and "no speech detected" (derived from an empty final transcript, shown as a panel notice).
- A live input level meter (mic-tap RMS) and optional start/stop sounds accompany the session.

### Feature 3 — File-based batch transcription

- Drag-and-drop onto the menu bar icon, plus a "Transcribe File…" open panel. Accepts common audio types (`.m4a`, `.mp3`, `.wav`, `.aac`) and video containers `AVAudioFile` can read.
- `AVAudioFile(forReading:)` → `analyzeSequence(from:)` → `finalizeAndFinish(through:)`, streaming so webinar-length files never load wholesale.
- Progress is reflected in the menu bar icon (`waveform.circle`) and panel; the result opens in a window with Copy and Save (.txt).
- File transcriptions write **no** history entry (§4.7).

### Feature 4 — Output routing

- **Clipboard:** the final committed string is always written to `NSPasteboard.general`.
- **Direct insertion:** when Accessibility trust is granted (`AXIsProcessTrusted`), a `CGEvent` ⌘V is posted into the previously focused app; the pasteboard is snapshotted before and restored after.
- **Fallback:** without Accessibility trust — or while secure input is active — text stays on the clipboard and the user is notified. Onboarding UI deep-links to System Settings ▸ Privacy & Security ▸ Accessibility.
- Insertion mode is a preference: *paste* or *clipboard-only*. Outcomes are `inserted` / `copiedToClipboard` / `none`, and are recorded on the history entry.

### Feature 5 — Transcript history

- **F5.1** Every completed dictation writes one entry: text, created-at, duration, locale, timeline segments, target app, delivery outcome.
- **F5.2** File transcriptions write no entry; the result-window behaviour is unchanged.
- **F5.3** Entries persist across app restarts, rebuilds and reinstalls to the same bundle ID.
- **F5.4** Writing an entry must not block the `inserting → idle` transition; the next dictation is never gated on the store.
- **F5.5** With "Keep finished dictations" off, or history paused, no entry is written and no audio is retained.
- **F5.6** The target app is captured at session *start* (the panel is non-activating, so the frontmost app at start is still the insertion target at the end).

### Feature 6 — Audio retention

- **F6.1** When enabled, a dictation's audio is written to `.m4a` alongside the entry (§7).
- **F6.2** Recording starts and stops with the microphone tap, so the file covers exactly the transcribed span.
- **F6.3** The entry records byte size and duration; the History UI shows both.
- **F6.4** Audio can be deleted independently of the transcript (pruning, or per-entry "Delete Audio").
- **F6.5** Retention is skipped for any session where `IsSecureEventInputEnabled()` is true at session start (a password field is focused), regardless of the setting.

### Feature 7 — History window & playback

- **F7.1** Opened from the menu bar ("History…", ⌘Y) and from Settings.
- **F7.2** `NavigationSplitView`: searchable list on the left, detail on the right.
- **F7.3** List rows: relative date, target-app icon + name, duration, audio indicator, first ~80 chars of transcript. Grouped by Today / Yesterday / This Week / month.
- **F7.4** Search filters transcript text and app name, case- and diacritic-insensitive, incrementally.
- **F7.5** Detail pane: full selectable transcript, metadata line, audio player when present, action bar.
- **F7.6** Actions: **Copy**, **Insert Again**, **Save Transcript…** (.txt), **Save Audio…**, **Re-transcribe…**, **Reveal in Finder**, **Pin**, **Delete** (⌫, confirmed for multi-select), **Delete Audio Only**.
- **F7.7** Multi-select for delete and for Copy (concatenated, newline-separated).
- **F7.8** Empty states: no history yet; no search matches; history disabled (with a link to Settings).
- **F7.9** The list updates live — an entry written while the window is open appears without reopening.
- **F7.10** **Insert Again** routes through `FrontmostAppTracker` + `OutputRouter.reinsert()`, which re-activates the last non-Transcriber app and waits for that activation before pasting. The live-dictation insertion path can't be reused, because both the History window and the menu bar take focus.
- **F7.11** Playback: `AVAudioPlayer` transport with play/pause (Space), scrubber, elapsed/total, and 1×/1.5×/2× rate. Playback stops when the entry is deselected, deleted, or the window closes.
- **F7.12** Missing/unreadable audio → the player is replaced by "Audio no longer available" and the entry's audio reference is cleared.
- **F7.13** The sentence currently playing is highlighted from the stored segment ranges, which are sample-aligned with the recording. *Per-word click-to-seek was deliberately dropped* — SwiftUI `Text` offers no per-run hit testing, so it needs a custom flow `Layout` or a fake-link-URL trick, and the scrubber already covers navigation.

### Feature 8 — Re-transcribe

- **F8.1** Available for entries that still have retained audio.
- **F8.2** A sheet offers the locale (defaulting to the entry's original) and Replace vs. Save As New Entry.
- **F8.3** Runs through the existing `FileTranscriber` against the `.m4a` — no new transcription path.
- **F8.4** Reuses the existing busy-gating: refused with an explanation while a dictation or file transcription is in flight.
- **F8.5** Progress is shown in the History window, not the dictation panel; the menu bar icon reflects `.transcribingFile` as usual.
- **F8.6** A re-transcription saved as a **new** entry gets its own **copy** of the audio. Sharing one file between two entries would mean deleting either strands the other, and a dictation's `.m4a` is small enough that a copy is the cheaper correctness story.
- **F8.7** Segments are **cleared** on re-transcription: `FileTranscriber` doesn't report ranges, and keeping the old ones would highlight the wrong words during playback.

### Feature 9 — Retention, privacy & quick access controls

- **F9.1** Toggle: **Keep finished dictations** (default on).
- **F9.2** Toggle: **Also keep the audio recording** (default **off**), with the per-hour size estimate shown inline.
- **F9.3** Picker: **Delete after** — Never (default) / 7 / 30 / 90 / 365 days.
- **F9.4** Picker: **Limit audio to** — No limit / 500 MB / 1 GB (default) / 5 GB. Over the cap, oldest audio is deleted first; **transcripts are kept**. This cap applies as soon as audio retention is switched on, i.e. it is the one prune that runs without the user having chosen an expiry policy — which is what makes the pin exemption worth having.
- **F9.5** **Pin** an entry: exempt from both age expiry and the size cap. Framed strictly as "protect from deletion", not as a favourite — favourites want filters, sections and tags, which §1 rules out.
- **F9.6** Storage readout: entry count, total audio size, **Reveal Folder**.
- **F9.7** **Delete All…** — destructive, double-confirmed, removes entries and audio.
- **F9.8** **Export…** — writes a folder of Markdown files plus a `history.json` manifest, so the SwiftData store is never lock-in.
- **F9.9** Menu bar toggle **Pause History**. While paused, no entries and no audio. Resets to off on relaunch — a pause is for right now, not forever.
- **F9.10** Menu bar submenu **Recent Transcripts**, fixed at the last 5; selecting one inserts it via `OutputRouter`.
- **F9.11** Menu bar item **Copy Last Transcript** (no new global hotkey).
- **F9.12** Pruning runs at launch and after each history write, off the main actor. Age-expiry deletes the entry **and** its audio; size-cap deletes audio only, marking the entry `audioPrunedAt`. All pruning is logged with counts and bytes reclaimed.
- **F9.13** Launch reconciliation: audio files with no owning entry and an mtime older than 60 s are deleted; entries whose audio file is missing have their reference cleared.

---

## 6. UI/UX specifications

- **Dictation panel:** floating, borderless **non-activating `NSPanel`** (`.nonactivatingPanel`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`), centred near the bottom of the active screen. It must NEVER become key window (§4.2). Dismiss on Esc, hotkey again, click outside, or insertion complete.
  - Esc-to-dismiss works through a transient Carbon hotkey registered only while the session is `.recording` — the panel can never receive key events. Esc is consumed globally for that window; it is deliberately *not* registered for `.downloadingModel`, `.transcribingFile`, `.finishing` or `.inserting`, where swallowing Esc for the length of a long transcription would break it for every other app.
- **Visuals:** `NSVisualEffectView` for native system blur/translucency.
- **Typography:** system font (San Francisco). `volatile` text renders in `.secondary`, `committed` text in `.primary`, auto-scrolling.
- **History and transcript-result windows** are standard `NSWindow`s and do take focus.
- **Settings is one page**, not tabs: a page holding a handful of rows costs a click and a mode to be in for no benefit, and it stays short enough to read at a glance. If it starts to sprawl, the answer is a collapsible section, not tabs.

---

## 7. Storage layout

The app is **not** sandboxed, so these are real paths, not container paths:

```
~/Documents/Transcriber/          (mode 0700)
├── History.store                 // SwiftData (+ -wal, -shm)
└── Recordings/
    ├── 2026-07-30 10-45-12.m4a   // one per dictation, local wall-clock time
    └── …
```

- The directory is created lazily on first write with `POSIXPermissions: 0o700`, and the mode is re-asserted on an existing directory (`createDirectory` silently leaves an existing mode alone).
- **`~/Documents/Transcriber`, not `~/Library/Application Support/<bundle id>`** (user's call, 2026-07-30): this is *their* dictation, and they want to see, back up and prune it without an app mediating. `AppDirectories.migrate(from:to:)` moved the existing store on first launch of the new build and removes the old folder once empty; it never overwrites a file already at the destination, and a store always migrates together with its `-wal`/`-shm` sidecars — a store separated from either is not the database it was.
- **Filenames are timestamps** (`yyyy-MM-dd HH-mm-ss`), so the folder is browsable: they sort chronologically and carry no transcript text. Names are claimed with `O_EXCL` rather than check-then-create, so two recordings in the same second get a Finder-style ` (2)` instead of one overwriting the other. The scheme isn't load-bearing — each entry stores the filename it was actually given, so a rename or a future scheme change orphans nothing.
- **The trade this accepts:** `~/Documents` is more exposed than Application Support. If System Settings ▸ iCloud ▸ "Desktop & Documents Folders" is ever switched on, `~/Documents` is redirected into iCloud Drive and every transcript and recording leaves the Mac — quietly breaking the on-device promise. `AppDirectories.rootIsCloudSynced` detects the redirect and logs it; with audio retention on, that deserves a visible warning in Settings, not just a log line. (Verified off for this user on 2026-07-30.)
- `Recordings/` gets `.metadata_never_index` so Spotlight doesn't index the audio.

---

## 8. Architecture

```
Transcriber/
├── TranscriberApp.swift              // @main, AppDelegate, wiring
├── AppState.swift                    // observable session state machine
├── SoundPlayer.swift
├── MenuBar/StatusItemController.swift    // NSStatusItem, menu, icon states
├── Hotkey/HotkeyManager.swift            // RegisterEventHotKey wrapper
├── Panel/
│   ├── FloatingPanel.swift               // non-activating NSPanel host
│   ├── PanelController.swift
│   └── DictationView.swift               // committed + volatile text, level meter
├── Speech/
│   ├── TranscriptionEngine.swift         // SpeechAnalyzer + SpeechTranscriber session
│   ├── MicrophoneCapture.swift           // AVAudioEngine tap + AVAudioConverter
│   ├── ModelAssetManager.swift           // AssetInventory install/locale checks
│   └── FileTranscriber.swift             // analyzeSequence(from: AVAudioFile)
├── Output/
│   ├── OutputRouter.swift                // NSPasteboard + CGEvent ⌘V, AX trust check
│   └── FrontmostAppTracker.swift         // last non-Transcriber app, for Insert Again
├── Transcript/                           // file-transcription result window
├── History/
│   ├── HistoryEntry.swift                // @Model + TranscriptSegment + HistoryDraft + SchemaV1
│   ├── HistoryStore.swift                // container owner: record/delete/prune/reconcile/export
│   ├── HistoryPruningPolicy.swift        // pure functions: age expiry, size cap
│   ├── HistoryWindowController.swift
│   ├── HistoryListView.swift             // NavigationSplitView, search, grouping
│   ├── HistoryDetailView.swift
│   ├── AudioPlaybackController.swift     // @Observable AVAudioPlayer wrapper
│   └── RetranscribeSheet.swift
├── Recording/
│   ├── SessionAudioRecorder.swift        // serial-queue AVAudioFile writer
│   └── RecordingsDirectory.swift         // paths, permissions, sizing, sweeping
├── Storage/AppDirectories.swift          // ~/Documents/Transcriber, 0700, legacy migration
└── Settings/                             // SettingsView, Preferences, ShortcutRecorderView
```

New Swift files just get created under `Transcriber/` — the target uses folder-synchronized groups, so there are no `pbxproj` edits.

### 8.1 Session state machine

Single source of truth in `AppState`: `idle → recording(live) → finishing → inserting → idle`, plus `transcribingFile(progress)` and `downloadingModel(progress)` as parallel modes. The menu bar icon reflects state.

### 8.2 Streaming pipeline

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

### 8.3 Data model

```swift
@Model final class HistoryEntry {
    #Index<HistoryEntry>([\.createdAt])
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var text: String
    var localeIdentifier: String   // bcp47 actually used
    var duration: TimeInterval
    var isPartial: Bool            // transcriptionIncomplete path
    var isPinned: Bool             // exempt from pruning

    var targetAppBundleID: String?
    var targetAppName: String?
    var deliveryOutcomeRaw: String?   // inserted | copiedToClipboard | none

    var audioFilename: String?        // relative to Recordings/
    var audioByteCount: Int64?
    var audioPrunedAt: Date?

    var segments: [TranscriptSegment]  // Codable value type, may be empty
}

struct TranscriptSegment: Codable, Hashable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}
```

- The schema is registered through a `VersionedSchema` from v1 so future fields have a migration path.
- `segments` come from `result.range` on each **final** result — already available, with no `attributeOptions` change. Per-word ranges (`attributeOptions: [.audioTimeRange]`) would only be needed for word-level highlighting.
- `HistoryDraft` is the `Sendable` value type handed from the session to the store, so nothing on the dictation path touches a `@Model` object.

### 8.4 Audio tee

The tee lives where the converted buffer already arrives, in `TranscriptionEngine`'s `onBuffer` closure:

```swift
onBuffer: { buffer in
    continuation.yield(AnalyzerInput(buffer: buffer))
    recorder?.append(buffer)          // non-blocking hand-off
}
```

`SessionAudioRecorder`:

- `start(format:url:)` builds settings from the analyzer format — `[AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 24_000]` — and opens `AVAudioFile(forWriting:settings:)`.
- `append(_:)` is called on the render thread and does `queue.async { try? file.write(from: buffer) }` on a private `DispatchQueue(qos: .utility)`. This is safe without copying **only because `MicrophoneCapture` allocates a fresh `AVAudioPCMBuffer` per callback** — the code says so, because the day someone "optimises" that allocation into a reused buffer, this breaks silently.
- `finish()` drains the queue and closes the file (finalising the MPEG-4 `moov` atom), returning URL + byte count, or a failure.
- `discard()` closes and deletes.

`SessionAudioRecorder`, `RecordingsDirectory` and `AppDirectories` are explicitly `nonisolated`: the target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise make the recorder main-actor isolated — exactly wrong for a type the audio render thread calls into.

Render-thread purity: `DispatchQueue.async` does allocate and take a lock, which a hard real-time audio engineer would object to. The existing code already yields into an `AsyncStream` from the same callback, so this adds no new class of risk; a lock-free ring buffer is noted in §16 as deliberately out of scope.

### 8.5 Session flow

`TranscriptionEngine.finishSession()` returns a struct rather than a `String`:

```swift
struct SessionResult {
    let text: String
    let segments: [TranscriptSegment]
    let locale: Locale
    let duration: TimeInterval
    let audio: RecordedAudio?     // url + byteCount, nil when retention off/failed
    let isPartial: Bool
}
```

`EngineError.transcriptionIncomplete` carries a `SessionResult` (with `isPartial: true`) rather than a bare partial string, so a truncated session archives its audio and segments instead of dropping them.

In `AppDelegate`: `startDictation()` captures the frontmost app (bundle ID + localized name) and whether secure input is active before starting; `deliver(_:)` records the entry **after** `OutputRouter.deliver` so the stored outcome is the real one, inside a `Task` so F5.4 holds; `cancelDictation()` discards the recording; an empty transcript drops the result and discards audio.

### 8.6 Concurrency

- `HistoryStore` writes through the container's **main context**. The target already defaults to `MainActor` isolation, an entry is a few hundred bytes, and the write happens after delivery while the panel is dismissing — a background context would buy isolation friction and nothing measurable, and one shared context means `@Query` views satisfy F7.9 for free. Pruning and export touch every row and get their own `@ModelActor`.
- Nothing in the history path is `await`ed on the dictation critical path.
- `HistoryStore` takes its `ModelConfiguration` and `Preferences` by injection (defaulting to the real ones), so tests run against an in-memory store and their own `UserDefaults` suite rather than the user's history.

---

## 9. Settings

One page. `UserDefaults`-backed via `Preferences`, mirrored with `@AppStorage` in `SettingsView`.

| Key | Type | Default |
|---|---|---|
| `hotkeyKeyCode` / `hotkeyModifiers` | Int | ⌥Space |
| `localeIdentifier` | String | `""` (follow system) |
| `insertionMode` | String | `paste` |
| `playsSounds` | Bool | `true` |
| `keepsTranscriptHistory` | Bool | `true` |
| `keepsAudioRecordings` | Bool | `false` |
| `historyRetentionDays` | Int | `0` (never) |
| `audioStorageCapBytes` | Int | `1_073_741_824` |
| `historyPaused` | Bool (not persisted across launches) | `false` |

Plus: dictation shortcut recorder, launch-at-login, the Accessibility status row with its deep link, and the History storage readout with Open History… / Reveal Folder / Export… / Delete All….

---

## 10. Permissions (TCC)

| Permission | Needed for | When prompted | Notes |
|---|---|---|---|
| Microphone | live dictation | first mic tap | via `NSMicrophoneUsageDescription` |
| Accessibility | CGEvent paste | manual grant; detected via `AXIsProcessTrusted` | user toggles it in System Settings |
| Input Monitoring | — | never | avoided by the Carbon hotkey |
| Speech Recognition | — | never | `SpeechAnalyzer` needs no `SFSpeechRecognizer` auth |

History and playback add **no** new TCC permissions and no new entitlements.

---

## 11. Privacy & security

1. **Opt-in audio, on-by-default text** (§4.4). The Settings copy states plainly where files go and that they are unencrypted.
2. **Pause History** (F9.9) and the **secure-input skip** (F6.5) are the two escape hatches that matter in practice.
3. `0700` on the data directory. Playback uses no microphone.
4. **Encryption at rest: not implemented.** The honest position is that a non-sandboxed app storing a Keychain-held key gains little against a local attacker who can already read the app's files, and FileVault covers the at-rest case. Revisit if the app ships to other people — call it out in release notes rather than implying encryption.
5. **No indexing / no leakage:** timestamp filenames, `.metadata_never_index`, transcript text never written into a filename and never logged (`os.Logger` calls log counts and byte sizes only).
6. **Deletion is real deletion:** `FileManager.removeItem`, no trash round-trip, no soft-delete tombstones holding text.

---

## 12. Edge cases & failure modes

| Case | Required behaviour |
|---|---|
| Hotkey registration fails | Visible notice; shortcut is reconfigurable in Settings |
| Mic busy / permission denied | Panel error state; session never starts |
| Model not installed | `downloadingModel(progress)` in the panel, then the session proceeds |
| Accessibility not granted | Clipboard-only delivery + notice; onboarding deep-links to System Settings |
| Secure input active | No synthetic paste; clipboard fallback, and **no audio retained** |
| Esc-cancelled dictation | No entry; partial `.m4a` deleted |
| Empty transcript | No entry; audio discarded; "No speech detected" notice |
| Truncated stream (`transcriptionIncomplete`) | Entry written, `isPartial = true`, badge in the UI; audio kept |
| Disk full mid-recording | Recorder marks failure, entry saved with no audio, one-time notice, dictation unaffected |
| App killed / crash mid-session | `.m4a` never finalised → unplayable orphan; swept at next launch (F9.13) |
| SwiftData store corrupt on open | Log, move aside to `History.store.corrupt-<date>`, start fresh, notify once; orphaned audio swept |
| Store sidecar (`-wal`/`-shm`) without its store | Never migrated as a loose file; the owning store decides (a stranded WAL is only reunited with a store it can belong to) |
| Audio file deleted in Finder | F7.12 — reference cleared, transcript retained |
| History window open during a dictation | New entry appears live; no interference with the panel |
| Re-transcribe while busy | Refused with an explanation (F8.4) |
| Deleting an entry that is playing | Playback stops first, then delete |
| History turned off with existing data | Existing entries are **kept**; the toggle governs new sessions. Deleting is an explicit action (F9.7) |
| Audio retention turned off | Existing audio kept; the confirmation offers "Delete existing recordings (N MB)?" |
| Very long dictation (30+ min) | AAC writer streams; memory flat |
| Two Macs, one synced `~/Documents` | Out of scope: history is per-machine, and a synced Documents folder would have two apps writing one SQLite store. `rootIsCloudSynced` is the detection hook |

---

## 13. Performance budgets

- History window cold open with 10,000 entries: **< 300 ms** to first paint (windowed, sorted fetch; row snippets rather than eager full text).
- Search keystroke → filtered list: **< 100 ms** at 10,000 entries.
- Added per-buffer cost on the render thread: one `DispatchQueue.async` enqueue — no audio-data allocation, no file I/O.
- The history write adds **0 ms** to the observable `inserting → idle` transition (detached task).
- Audio: ≈10.8 MB/hour. A 1 GB cap is ≈90+ hours of dictation.
- File transcription streams; a webinar-length file never loads wholesale.

---

## 14. Testing

Unit tests use Swift Testing (`@Test`/`#expect`); UI tests use XCTest.

**Unit**

- Retention policy: age-expiry and size-cap selection over synthetic entry sets (exactly at cap, all pinned, cap smaller than the newest file).
- Reconciliation: temp directory with orphan files (old vs. <60 s), missing-audio entries.
- `HistoryStore` CRUD + search predicates against an **in-memory** `ModelContainer`.
- `SessionAudioRecorder`: feed synthetic PCM buffers, close, reopen with `AVAudioFile(forReading:)`, assert duration within one buffer of expected and non-zero size.
- `RecordingsDirectory`: creation with `0700`, size accounting, safe-delete refuses paths outside the recordings directory.
- `AppDirectories.migrate`: store + sidecars move as one unit; never overwrites; rolls back a partial move.
- Export: round-trip `history.json` → entries.

**Manual** (the running checklist lives in `IMPLEMENTATION_PLAN.md` §7)

- [ ] Menu bar icon present; no Dock icon; Quit works
- [ ] ⌥Space toggles dictation from any app, including full-screen Spaces; panel never steals focus; Esc dismisses
- [ ] Model download UX on fresh install; dictation works offline afterwards
- [ ] Volatile→committed rendering, no jitter
- [ ] Insertion into TextEdit / Notes / Safari / Slack; clipboard restored; clipboard-only fallback when Accessibility denied
- [ ] File drop: short clip + 30 min file; save .txt
- [ ] Launch at login; survives logout/login
- [x] Dictate with history on, audio off → entry appears, no `.m4a` on disk
- [x] Enable audio → entry has playable audio; scrubbing and rate work
- [x] Insert Again lands text in TextEdit; clipboard restored
- [x] Esc-cancel and silent session leave no entry and no file
- [x] Pause History → nothing recorded; unpause → recording resumes; relaunch clears the pause
- [x] Focus a password field, dictate → no audio retained even with retention on
- [x] Re-transcribe a German dictation as German; Replace and Save-As-New both correct
- [x] Set cap to 500 MB with more audio than that → oldest audio deleted, transcripts intact
- [x] Delete a `.m4a` in Finder → entry degrades gracefully
- [x] 30-minute dictation → memory flat, file playable, transcript complete
- [x] Delete All → store and `Recordings/` empty; Export → Markdown + manifest readable

---

## 15. Risks & watch items

1. **API drift** — `SpeechAnalyzer` is new (WWDC25). Confirm signatures against the installed Xcode SDK `swiftinterface`, not blog posts.
2. **`⌥Space` conflicts** — some apps (Alfred defaults) claim it; hence the configurable shortcut and visible registration failure.
3. **`AVAudioConverter` format mismatch** — mic native format vs `bestAvailableAudioFormat` is the classic source of silent failures; both formats are logged at session start.
4. **Render-thread discipline** — the audio tee is the one piece that touches real-time audio. No I/O and no audio-data allocation in `append`; the fresh-buffer dependency is commented; listen for dropouts during manual checks.
5. **SwiftData schema mistakes** are expensive later. `VersionedSchema` from day one, in-memory container in tests, Export so the data is never trapped.
6. **Silent disk growth** — audio off by default, 1 GB default cap when enabled, storage readout in Settings.
7. **Privacy expectations** — history turns a transient tool into a record. §11, plus plain-language Settings copy.
8. **`.m4a` finalisation** — a killed process leaves an unplayable file. Orphan sweep at launch; accept the loss of the interrupted session.
9. **Scope creep toward a "notes app"** — pinning, tagging, folders and AI cleanup are all one step away. Held at the §1 non-goals line.
10. **Sandbox/distribution interaction** — if distribution happens, Hardened Runtime goes back on with `com.apple.security.device.audio-input`; nothing here needs a new entitlement. If the App Sandbox were ever enabled, `~/Documents` becomes a container path and the data needs a second migration — `AppDirectories.migrate(from:to:)` is reusable for it.

---

## 16. Alternatives considered

| Option | Why not |
|---|---|
| `NSEvent.addGlobalMonitorForEvents` for the hotkey | Requires a TCC grant and can't consume the event |
| **File-per-entry JSON** (SuperWhisper-style, Finder-transparent, zero migration risk) | Genuinely close call. Rejected because search/sort/paging over ~18k entries/year would mean hand-rolling an in-memory index, and `@Query` gives it free. Export recovers the transparency, and it's the documented fallback if SwiftData causes trouble |
| Sidecar JSON next to each audio file *and* SwiftData | Dual-write consistency for no user-visible gain |
| Record the **native** mic format (48 kHz stereo) for fidelity | Needs a second `AVAudioConverter` and more render-thread work, produces 4–6× larger files, and loses exact alignment with the analyzer timeline — for fidelity nobody reviewing dictation needs |
| Uncompressed WAV | ~115 MB/hour at 16 kHz Float32; no benefit for speech review |
| `AVAudioRecorder` | Would need its own input device session, conflicting with the `AVAudioEngine` tap |
| Lock-free ring buffer between tap and writer | Strictly more correct on the render thread, but the existing `AsyncStream` yield already sets the bar; revisit only if dropouts appear |
| Keep everything in `~/Library/Application Support/<bundle id>` | Shipped that way first, then moved to `~/Documents/Transcriber`. Hiding a person's own dictation from them to make it feel safer wasn't the right trade; opt-in audio is what actually addresses the SuperWhisper criticism |
| History entries for file transcriptions | The source file is already the user's, in a place they chose; an entry would duplicate a regenerable transcript and add source-file-moved failure modes |
| Global hotkey for "insert last transcript" | Another hotkey to conflict-manage; the menu covers it |
| History inside the floating panel | The panel is non-activating by design and can't take key focus for search or selection |
| A separate Settings tab for History | Three or four rows don't justify a tab and a mode to be in |
| Per-word click-to-seek in playback | No per-run hit testing in SwiftUI `Text`; needs a custom `Layout` or a fake-link trick, and the scrubber already covers navigation |

---

## References

- [Apple Developer Documentation: Speech framework](https://developer.apple.com/documentation/speech/)
- [Apple Developer Documentation: SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [SpeechAnalyzer architectural breakdown](https://blakecrosley.com/blog/speech-framework-vs-sfspeechrecognizer)
- [WWDC25: Bring advanced speech-to-text to your app with SpeechAnalyzer](https://www.youtube.com/watch?v=0m6dimDDj8M&vl=en)
- SDK ground truth: `$(xcrun --show-sdk-path)/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface`
