# PRD: Transcription History & Audio Retention

Enhancement PRD for **Transcriber**. Companion to `PRD - Native macOS Dictation & Transcription utility.md` and `IMPLEMENTATION_PLAN.md` (phases 1–6 shipped and verified; Phase 7 distribution optional). This document defines a new **Phase 8**.

Status: **approved, in progress** · 2026-07-30 · branch `feature/history-and-audio-retention`

---

## 1. Summary

Today every dictation is fire-and-forget: the transcript goes to the clipboard or is pasted into the active app, `AppState.clearTranscript()` runs, and the words are gone. File transcriptions open a window (`TranscriptWindowController`) which, once closed, is also gone.

This enhancement adds a **persistent history of transcriptions** and an **optional retained audio recording** of each dictation, with a browsable History window, playback, re-transcription, and explicit retention/privacy controls — comparable to what SuperWhisper offers, but with a privacy-first default that SuperWhisper is criticised for lacking.

### Goals

- G1. Never lose a transcript again — a dictation that failed to insert (Accessibility off, secure input, wrong app focused, clipboard clobbered) is recoverable.
- G2. Re-use past transcripts: search, copy, re-insert, export.
- G3. Optionally retain the source audio so a transcript can be **verified** against what was said, and **re-transcribed** (e.g. in a different locale, or after a model update).
- G4. Keep the user in full control of what is kept, for how long, and how much disk it consumes — with a one-click "don't record this one" escape hatch.
- G5. Stay 100% on-device and 100% Apple-framework, consistent with the project's existing rules.

### Non-goals

- Cloud sync or multi-device history.
- LLM post-processing of transcripts ("modes"/prompts, à la SuperWhisper). Separate future PRD.
- Speaker diarization, system-audio/meeting capture, or a waveform editor.
- Encryption at rest in v1 (see §9.4 — FileVault is the answer; a Keychain-keyed store is deferred).
- Full-text search ranking, tags, or folders. v1 is substring search + date grouping.

---

## 2. Where the app is today (grounding)

| Concern | Current behaviour | File |
|---|---|---|
| Session lifecycle | `idle → recording → finishing → inserting → idle`; transcript cleared at the end | `Transcriber/AppState.swift`, `TranscriberApp.swift:251` |
| Live audio | `AVAudioEngine` tap → `AVAudioConverter` → analyzer format; **converted buffer is freshly allocated per tap callback** | `Speech/MicrophoneCapture.swift:50` |
| Live transcript | `SpeechTranscriber` results, committed vs volatile; `finishSession()` returns a `String` | `Speech/TranscriptionEngine.swift:134` |
| Truncated session | `EngineError.transcriptionIncomplete(partial:underlying:)` — partial text is still delivered | `TranscriptionEngine.swift:22` |
| File transcription | `analyzeSequence(from: AVAudioFile)`, result → window, no persistence | `Speech/FileTranscriber.swift` |
| Output | Clipboard always; CGEvent ⌘V when trusted; outcome logged only | `Output/OutputRouter.swift` |
| Preferences | `UserDefaults` via `Preferences` + `@AppStorage` mirrors in `SettingsView` | `Settings/` |
| Persistence | **None.** No store, no data model, no `Application Support` usage | — |

Two facts from the existing code that the design leans on:

1. `MicrophoneCapture` allocates a **new** `AVAudioPCMBuffer` for every converted chunk (`MicrophoneCapture.swift:56`) rather than recycling one, so a second consumer can take a reference without copying.
2. Every `SpeechTranscriber.Result` already carries `range: CMTimeRange` (confirmed in the SDK `swiftinterface`), so per-result timestamps are available for live dictation without changing `attributeOptions`.

---

## 3. Competitive reference: SuperWhisper

What it does, and what we do differently.

| Aspect | SuperWhisper | Transcriber (this PRD) |
|---|---|---|
| History list | Sidebar of previous dictations; right-click ▸ "Process Again" re-runs with the *currently active* mode | Same idea; re-transcribe uses the locale picked in the re-transcribe sheet, not implicitly the current setting |
| Audio retention | Saved to disk **by default, no documented opt-out**; files live in `~/Documents` | **Off by default, explicit opt-in**; files live in `~/Library/Application Support/…` with `0700` perms |
| Retention policy | No documented auto-delete; pruning is manual | Age-based expiry + total-size cap, both enforced automatically |
| Incognito | — | "Pause History" menu toggle; automatic skip while secure input is active |
| Reprocessing | Yes (re-transcribe from stored audio) | Yes, same, but only for entries that still have audio |

The retention-by-default criticism is well documented ([Voibe](https://www.getvoibe.com/resources/is-superwhisper-safe/), [Tota](https://www.heytota.com/is-superwhisper-private)) and is the main thing worth deliberately not copying: a dictation tool bound to a global hotkey will eventually hear a password, a medical detail, or someone else's confidence.

---

## 4. User stories

1. *"I dictated a paragraph into Slack, but the message box wasn't focused and the text vanished."* → Open History, last entry, **Copy** or **Insert Again**.
2. *"Did I actually say 'no' there?"* → Open the entry, press space, hear the audio.
3. *"This came out garbled — the model heard English but I spoke German."* → **Re-transcribe** the retained audio with a different locale.
4. *"What was that phone number I dictated last Tuesday?"* → Search History for "0 4".
5. *"I'm about to dictate my banking details."* → Menu bar ▸ **Pause History** (or just don't enable audio retention).
6. *"How much disk is this eating?"* → Settings ▸ History shows storage used, with Delete All.

Deliberately **not** a story: "I want the transcript of the webinar file I dropped last month." File transcriptions stay window-only (§5.4) — the source file is still on disk, and the user chose where it lives.

---

## 5. Decisions

Stated up front, in the style of `IMPLEMENTATION_PLAN.md` §1. Each is a judgment call with a reason; §16 lists what was rejected.

1. **Transcript history is ON by default; audio retention is OFF by default.** Text is small, low-risk, and delivers G1/G2 on its own. Audio is the sensitive, bulky part and should be a deliberate choice (§3).
2. **Retained audio is exactly the audio the analyzer heard** — the already-converted, analyzer-format buffers are teed into the recorder. No second converter, no extra render-thread work, and the recording's timeline is sample-aligned with the `CMTimeRange`s in the results. Fidelity is speech-grade mono (typically 16 kHz), which is also precisely what a future re-transcription wants.
3. **Container/codec: AAC-LC mono in `.m4a`**, written by `AVAudioFile(forWriting:settings:)` (the SDK header confirms compressed output via the settings dictionary). ≈24 kbit/s → ≈3 KB/s → **≈10.8 MB per hour** of dictation; a 20-second dictation is ~60 KB.
4. **History covers dictation only.** File transcriptions keep today's behaviour — a result window, no persistence. The source audio is already a file the user owns and placed deliberately, so an entry would only duplicate a transcript they can regenerate at will. This drops the `kind` discriminator, the source-file bookmark, and every "did the source file move?" failure mode from the design.
5. **Store: SwiftData** (`SwiftData.framework`, present in the macOS 26 SDK — still 100% Apple). One `@Model` per entry, versioned schema from day one, audio kept as loose files referenced by filename. It gives search/sort/predicate and `@Query`-driven SwiftUI for free.
6. **Audio files are written on a dedicated serial queue, never on the audio render thread.** The tap callback hands off a buffer reference and returns.
7. **A failed recorder never fails a dictation.** Any write/encode/disk error disables retention for that session, logs, and (once per app run) surfaces a notice. Transcription continues untouched.
8. **Cancelled (Esc) and empty ("No speech detected") sessions create no history entry** and delete any partial audio. A *truncated* session (`transcriptionIncomplete`) **does** create an entry, flagged as partial.
9. **History window is a standard `NSWindow`**, like `TranscriptWindowController` — not the non-activating panel. It needs key focus for search and text selection; the panel deliberately cannot have it.

---

## 6. Functional requirements

### F1 — Transcript history store

- F1.1 Every completed dictation writes one entry: text, created-at, duration, locale, source kind, target app, delivery outcome.
- F1.2 File transcriptions write **no** entry (§5.4); `TranscriptWindowController` behaviour is unchanged.
- F1.3 Entries persist across app restarts, rebuilds, and (per the Phase 7 note in §14) reinstalls to the same bundle ID.
- F1.4 Writing an entry must not block the `inserting → idle` transition; the user's next dictation is never gated on the store.
- F1.5 When "Keep transcript history" is off, or history is paused, no entry is written and no audio is retained.

### F2 — Audio retention

- F2.1 When enabled, a dictation's audio is written to `.m4a` alongside the entry (§7).
- F2.2 Recording starts and stops with the microphone tap, so the file covers exactly the transcribed span.
- F2.3 The entry records byte size and duration; the History UI shows both.
- F2.4 Audio can be deleted independently of the transcript (pruning, or per-entry "Delete Audio").
- F2.5 Retention is skipped for a session where `IsSecureEventInputEnabled()` is true at session start (a password field is focused), regardless of the setting.

### F3 — History window

- F3.1 Opened from the menu bar ("History…", ⌘Y) and from Settings.
- F3.2 `NavigationSplitView`: searchable list on the left, detail on the right.
- F3.3 List rows: relative date, target-app icon + name, duration, audio indicator, first ~80 chars of transcript. Grouped by Today / Yesterday / This Week / month.
- F3.4 Search filters on transcript text and app name, case- and diacritic-insensitive, incremental.
- F3.5 Detail pane: full selectable transcript, metadata line, audio player when present, action bar.
- F3.6 Actions: **Copy**, **Insert Again** (routes through `OutputRouter` with the current mode), **Save Transcript…** (.txt), **Save Audio…**, **Re-transcribe…**, **Reveal in Finder**, **Delete** (⌫, with confirmation for multi-select), **Delete Audio Only**.
- F3.7 Multi-select for delete and for "Copy" (concatenated, newline-separated).
- F3.8 Empty states: no history yet; no search matches; history disabled (with a link to Settings).
- F3.9 The list updates live — an entry written while the window is open appears without reopening.

### F4 — Playback

- F4.1 `AVAudioPlayer`-based transport: play/pause (Space), scrubber, elapsed/total, 1×/1.5×/2× rate.
- F4.2 Playback stops when the entry is deselected, deleted, or the window closes.
- F4.3 Missing/unreadable audio file → the player is replaced by "Audio no longer available" and the entry's audio reference is cleared.
- F4.4 *(M4, nice-to-have)* Stored per-result time ranges drive click-to-seek: clicking a sentence in the transcript seeks the player, and the currently playing sentence is highlighted.

### F5 — Re-transcribe

- F5.1 Available for entries with retained audio.
- F5.2 A sheet offers the locale (defaulting to the entry's original) and Replace vs. Save As New Entry.
- F5.3 Runs through the existing `FileTranscriber` against the `.m4a` — no new transcription path.
- F5.4 Reuses the existing busy-gating: refused (with an explanation) while a dictation or file transcription is in flight, matching `TranscriberApp.swift:163`.
- F5.5 Progress is shown in the History window, not the dictation panel; the menu bar icon reflects `.transcribingFile` as it does today.

### F6 — Retention & privacy controls (Settings ▸ History)

- F6.1 Toggle: **Keep transcript history** (default on).
- F6.2 Toggle: **Keep audio recordings** (default **off**), with the per-hour size estimate shown inline.
- F6.3 Picker: **Delete entries older than** — Never (default) / 7 / 30 / 90 / 365 days.
- F6.4 Picker: **Limit audio storage to** — No limit / 500 MB / 1 GB (default when audio is enabled) / 5 GB. Over the cap, oldest audio is deleted first; **transcripts are kept**. Note this cap applies as soon as audio retention is switched on, i.e. it is the one prune that runs without the user having chosen an expiry policy — which is what makes the pin exemption (F6.9) worth having.
- F6.9 **Pin** an entry (M4): exempt from both age expiry and the size cap. Framed strictly as "protect from deletion", not as a favourite — favourites want filters, sections and tags, which §1 rules out.
- F6.5 Storage readout: entry count, total audio size, "Reveal in Finder".
- F6.6 **Delete All History…** — destructive, double-confirmed, removes entries and audio.
- F6.7 **Export All…** — writes a folder of Markdown files plus a `history.json` manifest (makes the SwiftData store non-lock-in).
- F6.8 Menu bar toggle: **Pause History** (checkmark item). While paused, no entries and no audio. Resets to off on relaunch — a pause is for right now, not forever.

### F7 — Quick access

- F7.1 Menu bar submenu **Recent Transcripts** listing the last 5; selecting one inserts it via `OutputRouter`.
- F7.2 Menu bar item **Copy Last Transcript** (⌘⇧C-style behaviour from the menu; no new global hotkey in v1).

### F8 — Pruning & reconciliation

- F8.1 Pruning runs at launch and after each history write, off the main actor.
- F8.2 Age-expiry deletes the entry **and** its audio. Size-cap deletes audio only, marking the entry `audioPrunedAt`.
- F8.3 Launch reconciliation: audio files with no owning entry and an mtime older than 60 s are deleted; entries whose audio file is missing have their reference cleared.
- F8.4 All pruning is logged with counts and bytes reclaimed.

---

## 7. Storage layout

App is **not** sandboxed (`ENABLE_APP_SANDBOX = NO`), so these are real paths, not container paths:

```
~/Library/Application Support/com.pwilliams.Transcriber/     (mode 0700)
├── History.store                 // SwiftData (+ -wal, -shm)
└── Recordings/
    ├── 7C4F…-A19B.m4a            // <entry UUID>.m4a
    └── …
```

- Directory created lazily on first write, with `POSIXPermissions: 0o700`.
- Filenames are entry UUIDs — no timestamp collisions, no transcript text leaking into filenames visible to any process that can list the directory.
- Deliberately **not** `~/Documents` (SuperWhisper's choice): dictation audio is app data, and users shouldn't have to see it unless they ask. "Reveal in Finder" covers the discoverability gap.
- `Recordings/` gets `.metadata_never_index` so Spotlight doesn't index the audio.

---

## 8. Technical design

### 8.1 New files

```
Transcriber/
├── History/
│   ├── HistoryEntry.swift              // @Model + TranscriptSegment + SchemaV1
│   ├── HistoryStore.swift              // ModelContainer owner: add/delete/prune/reconcile/export
│   ├── HistoryWindowController.swift   // standard NSWindow host
│   ├── HistoryListView.swift           // NavigationSplitView, search, grouping
│   ├── HistoryDetailView.swift         // transcript, metadata, actions
│   ├── AudioPlaybackController.swift   // @Observable AVAudioPlayer wrapper
│   └── RetranscribeSheet.swift
├── Recording/
│   ├── SessionAudioRecorder.swift      // serial-queue AVAudioFile writer
│   └── RecordingsDirectory.swift       // paths, permissions, sizing, sweeping
└── Storage/
    └── AppDirectories.swift            // Application Support paths, 0700 creation
```

Folder-synchronized groups mean no `pbxproj` edits (CLAUDE.md rule).

### 8.2 Data model

```swift
@Model final class HistoryEntry {
    #Index<HistoryEntry>([\.createdAt])
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var text: String
    var localeIdentifier: String   // bcp47 actually used
    var duration: TimeInterval
    var isPartial: Bool            // transcriptionIncomplete path
    var isPinned: Bool             // exempt from pruning; UI lands in M4

    // Target app captured at session start (panel is non-activating, so the
    // frontmost app at start is still the insertion target at the end).
    var targetAppBundleID: String?
    var targetAppName: String?
    var deliveryOutcomeRaw: String?   // inserted | copiedToClipboard | none

    // Retained dictation audio
    var audioFilename: String?        // relative to Recordings/
    var audioByteCount: Int64?
    var audioPrunedAt: Date?

    var segments: [TranscriptSegment]  // Codable value type, may be empty
}

struct TranscriptSegment: Codable, Hashable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}
```

- Schema is registered through a `VersionedSchema` from v1 so future fields have a migration path.
- `segments` come from `result.range` on each **final** result — already available, no `attributeOptions` change needed. Per-word ranges (`attributeOptions: [.audioTimeRange]`) are only needed if F4.4 grows into word-level highlighting; not v1.

### 8.3 Audio tee

`MicrophoneCapture.start(...)` is unchanged in shape; the tee lives where the buffer already arrives, in `TranscriptionEngine.startSession`'s `onBuffer` closure (`TranscriptionEngine.swift:121`):

```swift
onBuffer: { buffer in
    continuation.yield(AnalyzerInput(buffer: buffer))
    recorder?.append(buffer)          // non-blocking hand-off
}
```

`SessionAudioRecorder`:

- `start(format: AVAudioFormat, url: URL) throws` — builds settings from the analyzer format:
  `[AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 24_000]`, opens `AVAudioFile(forWriting:settings:)`.
- `append(_ buffer: AVAudioPCMBuffer)` — called on the render thread; `queue.async { try? file.write(from: buffer) }` on a private `DispatchQueue(label:…, qos: .utility)`. Safe without copying because `MicrophoneCapture` allocates a fresh buffer per callback (§2.1). A comment must say so, because the day someone "optimises" that allocation into a reused buffer, this breaks silently.
- `finish() async -> Outcome` — drains the queue, closes the file (finalising the MPEG-4 `moov` atom), returns URL + byte count, or `.failed` if any write errored.
- `discard() async` — closes and deletes.

Render-thread purity: `DispatchQueue.async` does allocate and take a lock, which a hard real-time audio engineer would object to. The existing code already yields into an `AsyncStream` from the same callback, so this adds no new class of risk; the strictly-correct lock-free ring buffer is noted in §16 as deliberately out of scope.

### 8.4 Session flow changes

`TranscriptionEngine.finishSession()` returns a struct instead of `String`:

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

`EngineError.transcriptionIncomplete` carries a `SessionResult` (with `isPartial: true`) rather than a bare `partial: String`, so `AppDelegate.stopDictation`'s truncated-transcript branch (`TranscriberApp.swift:263`) archives audio and segments too instead of dropping them.

`AppDelegate`:

- `startDictation()` captures `NSWorkspace.shared.frontmostApplication` (bundle ID + localized name) and whether secure input is active, before starting the session.
- `deliver(_:)` calls `historyStore.add(…)` **after** `outputRouter.deliver`, so the recorded delivery outcome is the real one — and inside a `Task` so F1.4 holds.
- `cancelDictation()` calls `recorder.discard()` via `engine.cancelSession()`.
- Empty transcript → `SessionResult` is dropped and audio discarded (§5.8).
- `transcribeFile` is untouched — no history entry (§5.4).

### 8.5 Concurrency

- `HistoryStore` is an `actor`-isolated wrapper around its own `ModelContext` (not the main-actor context) for writes, pruning, reconciliation, and export. The History window's `@Query` views use the main-actor context from the shared `ModelContainer`.
- `SessionAudioRecorder` is a `final class` with all mutable state confined to its serial queue; `append` is the only member callable from the render thread.
- Nothing in the history path may be `await`ed on the dictation critical path (F1.4).

---

## 9. Privacy & security

1. **Opt-in audio, on-by-default text** (§5.1). The Settings copy states plainly where files go and that they are unencrypted.
2. **Pause History** (F6.8) and **secure-input skip** (F2.5) are the two escape hatches that matter in practice.
3. **Permissions:** `0700` on the app-support directory; no new TCC permissions, no new entitlements. Playback uses no microphone.
4. **Encryption at rest:** not in v1. The honest position is that a non-sandboxed app storing a Keychain-held key gains little against a local attacker who can already read the app's files, and FileVault covers the at-rest case. Revisit if the app ever ships to other people (Phase 7) — call it out in the release notes rather than implying encryption.
5. **No indexing / no leakage:** UUID filenames, `.metadata_never_index`, transcript text never written into a filename, never logged (`os.Logger` calls log counts and byte sizes only — matching the existing convention of logging `text.count`, not `text`).
6. **Deletion is real deletion:** `FileManager.removeItem`, no trash round-trip, no soft-delete tombstones holding text.

---

## 10. Settings changes

`SettingsView` becomes a `TabView` with two tabs — **General** (everything that exists today) and **History** (F6). New `UserDefaults` keys, registered in `Preferences` alongside the current ones:

| Key | Type | Default |
|---|---|---|
| `keepsTranscriptHistory` | Bool | `true` |
| `keepsAudioRecordings` | Bool | `false` |
| `historyRetentionDays` | Int | `0` (never) |
| `audioStorageCapBytes` | Int64 | `1_073_741_824` |
| `historyPaused` | Bool (not persisted across launches) | `false` |

---

## 11. Edge cases & failure modes

| Case | Required behaviour |
|---|---|
| Esc-cancelled dictation | No entry; partial `.m4a` deleted |
| Empty transcript | No entry; audio discarded; existing "No speech detected" notice unchanged |
| Truncated stream (`transcriptionIncomplete`) | Entry written, `isPartial = true`, badge in the UI; audio kept |
| Disk full mid-recording | Recorder marks failure, entry saved with `audio == nil`, one-time notice, dictation unaffected |
| App killed / crash mid-session | `.m4a` never finalised → unplayable orphan; swept at next launch (F8.3) |
| SwiftData store corrupt on open | Log, move aside to `History.store.corrupt-<date>`, start fresh, notify once; orphaned audio swept |
| Audio file deleted in Finder | F4.3 — reference cleared, transcript retained |
| History window open during a dictation | New entry appears live (F3.9); no interference with the panel |
| Re-transcribe while busy | Refused with an explanation (F5.4) |
| Deleting an entry that is playing | Playback stops first, then delete |
| Retention turned off with existing data | Existing entries are **kept**; the toggle governs new sessions. Deleting is an explicit action (F6.6) |
| Audio retention turned off | Existing audio kept; offer "Delete existing recordings (N MB)?" in the confirmation |
| Very long dictation (30+ min) | AAC writer streams; memory flat. Verify in Phase 8 manual check |
| Two Macs, same Application Support via sync | Out of scope; document that history is per-machine |

---

## 12. Performance budgets

- History window cold open with 10,000 entries: **< 300 ms** to first paint (list fetches a windowed, sorted slice; `text` is not eagerly loaded for rows beyond the snippet).
- Search keystroke → filtered list: **< 100 ms** at 10,000 entries.
- Added per-buffer cost on the render thread: one `DispatchQueue.async` enqueue, no allocation of audio data, no file I/O.
- History write must add **0 ms** to the observable `inserting → idle` transition (it happens in a detached task).
- Audio: ≈10.8 MB/hour (§5.3). 1 GB cap ≈ 90+ hours of dictation.

---

## 13. Testing

The project's unit test target is currently a stub (`TranscriberTests.swift`, 19 lines). History is the first genuinely unit-testable subsystem — Swift Testing (`@Test`/`#expect`) per CLAUDE.md.

**Unit**

- Retention policy: age-expiry and size-cap selection over synthetic entry sets (boundary cases: exactly at cap, all pinned, cap smaller than the newest file).
- Reconciliation: temp directory with orphan files (old vs. <60 s), missing-audio entries.
- `HistoryStore` CRUD + search predicates against an **in-memory** `ModelContainer`.
- `SessionAudioRecorder`: feed synthetic PCM buffers, close, reopen with `AVAudioFile(forReading:)`, assert duration within one buffer of expected and non-zero size.
- `RecordingsDirectory`: creation with `0700`, size accounting, safe-delete refuses paths outside the recordings dir.
- Export: round-trip `history.json` → entries.

**Manual (Phase 8 addition to `IMPLEMENTATION_PLAN.md` §7)**

- [ ] Dictate with history on, audio off → entry appears, no `.m4a` on disk
- [ ] Enable audio → entry has playable audio; scrubbing and rate work
- [ ] Insert Again lands text in TextEdit; clipboard restored (existing Phase 4 behaviour intact)
- [ ] Esc-cancel and silent session leave no entry and no file
- [ ] Pause History → nothing recorded; unpause → recording resumes; relaunch clears the pause
- [ ] Focus a password field, dictate → no audio retained even with retention on
- [ ] Re-transcribe a German dictation as German; Replace and Save-As-New both correct
- [ ] Set cap to 500 MB with more audio than that → oldest audio deleted, transcripts intact
- [ ] Delete a `.m4a` in Finder → entry degrades gracefully
- [ ] 30-minute dictation → memory flat, file playable, transcript complete
- [ ] Delete All History → store and `Recordings/` empty
- [ ] Export All → Markdown + manifest readable

---

## 14. Milestones (Phase 8)

Each milestone ends buildable and manually verifiable, matching the plan's convention (Claude Code verifies compilation; the user does the runtime check).

| # | Scope | Verify |
|---|---|---|
| **M1** | `HistoryEntry` + `HistoryStore` + SwiftData container; dictations write entries; no UI beyond a log line; Settings toggle F6.1. Audio and pin fields exist in the v1 schema but stay unused, so M3/M4 need no migration | Dictate 3×, quit, relaunch, confirm 3 entries in the log |
| **M2** | History window: list, search, grouping, detail, Copy / Insert Again / Save / Delete; menu item + ⌘Y; Recent Transcripts submenu (F7) | Full pass over F3 |
| **M3** | `SessionAudioRecorder`, retention toggle, `.m4a` writing, playback (F4.1–F4.3), Save Audio | Record, play back, verify duration and size |
| **M4** | Retention policy: age expiry, size cap, pruning, reconciliation, storage readout, Delete All, Export; Pause History; secure-input skip; **Pin** UI (F6.9) — deliberately here rather than M2, so the control ships in the same milestone as the pruning it protects against | Cap/expiry manual checks above |
| **M5** | Re-transcribe (F5); segment-driven seek/highlight (F4.4) if it stays cheap | Re-transcribe in a second locale |

Housekeeping in the same phase: add Phase 8 to `IMPLEMENTATION_PLAN.md` (§4 and the §7 checklist), and add to `CLAUDE.md` the new architecture entries plus any gotchas found (expect at least one about AAC writing or SwiftData container setup).

**Phase 7 interaction:** if distribution happens later, Hardened Runtime goes back on with `com.apple.security.device.audio-input`. Nothing here needs a new entitlement. But if the App Sandbox were ever enabled (currently ruled out by decision 3 in the plan), `Application Support` moves into a container and history would need a one-time migration — worth a note in the plan rather than a surprise.

---

## 15. Risks

1. **Render-thread discipline** — the tee is the one piece of this work that touches real-time audio. Mitigation: no I/O and no audio-data allocation in `append`; comment the fresh-buffer dependency (§8.3); listen for dropouts in the M3 manual check.
2. **First use of SwiftData in this project** — schema mistakes are expensive later. Mitigation: `VersionedSchema` from day one, in-memory container in tests, Export (F6.7) so the data is never trapped.
3. **Silent disk growth** — the failure mode users hate. Mitigation: audio off by default, 1 GB default cap when enabled, storage readout in Settings.
4. **Privacy expectations** — history turns a transient tool into a record. Mitigation: §9, plus plain-language Settings copy.
5. **m4a finalisation** — a killed process leaves an unplayable file. Mitigation: orphan sweep; accept the loss of the interrupted session.
6. **Scope creep toward "notes app"** — pinning, tagging, folders, and AI cleanup are all one step away. Held at the §1 non-goals line.

---

## 16. Alternatives considered

| Option | Why not |
|---|---|
| **File-per-entry JSON** (SuperWhisper-style, Finder-transparent, zero migration risk) | Genuinely close call. Rejected because search/sort/paging over ~18k entries/year would mean hand-rolling an in-memory index, and `@Query` gives it free. Export (F6.7) recovers the transparency, and it's the documented fallback if SwiftData causes trouble |
| Sidecar JSON next to each audio file *and* SwiftData | Dual-write consistency for no user-visible gain; Export covers rebuildability |
| Record the **native** mic format (48 kHz stereo) for fidelity | Needs a second `AVAudioConverter` and more render-thread work, produces 4–6× larger files, and loses exact alignment with the analyzer timeline — for fidelity nobody reviewing dictation needs |
| Uncompressed WAV | ~115 MB/hour at 16 kHz Float32; no benefit for speech review |
| `AVAudioRecorder` | Would need its own input device session, conflicting with the `AVAudioEngine` tap |
| Lock-free ring buffer between tap and writer | Strictly more correct on the render thread, but the existing `AsyncStream` yield already sets the bar; revisit only if dropouts appear |
| Store audio in `~/Documents/Transcriber/` | Visible, yes — but it's app data, and default-visible sensitive audio is exactly the SuperWhisper criticism |
| Global hotkey for "insert last transcript" | Another hotkey to conflict-manage; the menu covers it in v1 |
| History inside the floating panel | The panel is non-activating by design and can't take key focus for search or selection (plan decision 4) |

---

## 17. Resolved questions

Settled 2026-07-30; the body of this PRD already reflects all five.

1. **Age-expiry default** — **Never**. Nothing disappears unless the user asks for it (F6.3).
2. **File transcriptions in history** — **No.** Dictation only; see §5.4 for what this removes from the design.
3. **Pinning** — field in the M1 schema, UI in M4 (F6.9), so no control ships before the pruning it exempts from.
4. **Recent Transcripts submenu** — fixed at 5 (F7.1), not configurable.
5. **`.m4a` bitrate** — 24 kbit/s mono, revisit only if M3 playback disappoints. 

