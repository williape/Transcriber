# Plan: Include system audio in dictation (e.g. a Zoom call on headphones)

## Context

Today Transcriber only hears the microphone. On a Zoom call with headphones, the other people's voices go straight to the headphones and never reach the mic, so only your half of the conversation is transcribed. The goal is an option to capture **everything the Mac plays, mixed with your mic, in one transcript**. The transcript is **pasted like a normal dictation** when you stop, and history and audio retention keep working as they do now.

Decisions made with the user:
- **Capture:** mic and system audio mixed into one stream. No "Me / Them" labels.
- **Output:** the same as dictation. Stop, then paste into the active app.
- **Source:** all system audio except Transcriber's own sounds, not a chosen app.

This is a scope change. The PRD §1 non-goals list says "Speaker diarization, system-audio/meeting capture". This plan removes system-audio capture from that list. Diarization stays a non-goal.

## Mechanism

macOS has **CoreAudio process taps** (`AudioHardwareCreateProcessTap` + `CATapDescription`, macOS 14.2+, in `CoreAudio/AudioHardwareTapping.h`). A tap captures the audio that processes *play*, before it reaches the output device. So it works with headphones, AirPods or speakers, and doesn't need Screen Recording or ScreenCaptureKit.

Design: **one private aggregate device per session** that combines:
- the chosen mic (from `AudioInputDevices.captureCandidates()`), as the clock master (`kAudioAggregateDeviceMainSubDeviceKey`), and
- a mono global tap, `CATapDescription(monoGlobalTapButExcludeProcesses: [ownProcessObjectID])`, with `kAudioSubTapDriftCompensationKey = true`.

The existing `MicrophoneCapture.attach(to:)` path binds `AVAudioEngine` to the **aggregate's** device ID instead of the mic's. The aggregate keeps the mic and the tap in sync on one clock and corrects the drift between them. So the input node delivers mic and system-audio channels together, and the tap block only has to sum them to mono before the existing `AVAudioConverter`. Everything downstream stays the same: SpeechAnalyzer, `SessionAudioRecorder`, history, `OutputRouter` paste.

A global tap covers every app, so it doesn't matter when the call's output device changes. `muteBehavior` stays at its default (unmuted), so you still hear the call. `privateTap = true` and `kAudioAggregateDeviceIsPrivateKey = true` make both invisible to other apps, and macOS removes them automatically if Transcriber crashes.

## Changes

### New: `Transcriber/Speech/SystemAudioTap.swift`
A small CoreAudio wrapper that covers one session, following the CLAUDE.md rule "never hold audio resources beyond one session":
- `static func ownProcessObjectID() -> AudioObjectID`, via `kAudioHardwarePropertyTranslatePIDToProcessObject` with `getpid()`. Used to exclude Transcriber's own start and stop sounds (`SoundPlayer`).
- `init(micUID: String) throws`. Creates the tap, reads `kAudioTapPropertyFormat` for logging, then builds the aggregate with `AudioHardwareCreateAggregateDevice`: sub-device list = [mic UID], main = mic UID, tap list = [{uid: tap UUID, drift: true}], private, a fixed name ("Transcriber System Audio") and a per-session UID.
- `var aggregateDeviceID: AudioDeviceID`
- `func destroy()`. Calls `AudioHardwareDestroyAggregateDevice`, then `AudioHardwareDestroyProcessTap`. It's idempotent.
- Named errors (`tapCreationFailed(OSStatus)`, `aggregateCreationFailed(OSStatus)`) so failures are as clear as the `AttachFailure` messages.

### `Transcriber/Speech/MicrophoneCapture.swift`
- Add `includeSystemAudio: Bool` to `Request` and `start(...)`.
- `attach(to:request:)`: when the flag is on, create `SystemAudioTap(micUID: device.uid)` and call `setDeviceID(tap.aggregateDeviceID)`. Store the tap next to `engine`. If the tap fails to build, **fall back to mic-only** for that session, log it and set a flag so the caller can show a one-line notice. The session still runs.
- The tap block: if `nativeFormat.channelCount > 1`, sum the channels into a mono buffer with `vDSP_vadd`, clip to ±1 with `vDSP_vclip`, then convert as now. Put this in a small static helper, `downmixToMono(_:)`, so it can be unit tested. The level meter reads the mixed signal.
- `teardownEngine()`: release the engine **first**, then `systemAudioTap?.destroy()`.
- Configuration-change handling needs no new logic. `boundDeviceID` becomes the aggregate's ID, so the "device and format unchanged → ignore" check still holds. A rebuild creates a fresh aggregate.

### `Transcriber/Speech/AudioInputDevices.swift`
- Leave aggregate devices out of `captureCandidates()` and `summary()`. Check `kAudioDevicePropertyTransportType == kAudioDeviceTransportTypeAggregate`, and add `transportType` to `Device`. Today's logs already show `CADefaultDeviceAggregate-<pid>` among the candidates, and our own private aggregate would show up too. Neither should ever be chosen as "the mic".
- Add `static func describeOutputTransport()` (built-in speakers vs anything else) for the speaker warning below.

### `Transcriber/Speech/TranscriptionEngine.swift`
- `startSession(locale:retainAudio:includeSystemAudio:modelDownloadProgress:)` passes the flag to `microphone.start`. Nothing else changes, since the analyzer format, recorder and segments are unaffected.

### `AppState.swift` / the session start site
- Read `Preferences.shared.includesSystemAudio` and pass it through.
- When it's on and the default output is the built-in speakers, show a short `showNotice` such as "Using speakers — call audio may be transcribed twice". With speakers, the mic also picks up the far side, so words get duplicated.

### `Transcriber/Settings/Preferences.swift` + `SettingsView.swift`
- New `includesSystemAudio: Bool`, default `false`, with a UserDefaults key next to the others.
- One toggle under "Insert text by": **"Also transcribe system audio (use headphones)"**. Per the settings preference memory: one page, minimal helper text.
- When it's on, an "Open Privacy Settings…" button below it, like the existing Accessibility row (`x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`).

### Permissions and build config
- Add `INFOPLIST_KEY_NSAudioCaptureUsageDescription = "Transcriber can include audio playing on your Mac, such as the other side of a call, in a dictation.";` to **both** build configurations in `project.pbxproj`, next to `NSMicrophoneUsageDescription`.
- TCC service: **System Audio Recording Only** (Privacy & Security ▸ Screen & System Audio Recording). macOS asks the first time a tap starts. There's no preflight API.
- Entitlements: none expected for a non-sandboxed app with Hardened Runtime. **Check this in the spike against a Release/Developer ID build**, since a missing entitlement could fail silently like the microphone did before.

### History
- No schema change. A mixed session is stored like any other dictation. A "source" field would need a `HistorySchemaV2` migration, which isn't worth it for this.

### Docs
- `PRD … .md` §1: drop "system-audio/meeting capture" from the non-goals and add a short section for this feature.
- `IMPLEMENTATION_PLAN.md`: add **Phase 9 — System audio**, with the status kept current.
- `CLAUDE.md`: add the new TCC reset to the Permissions section. Record whatever the spike finds about taps, aggregates and AVAudioEngine under Hard-won gotchas.

## Order of work

1. **Spike (de-risks everything):** a throwaway branch with `SystemAudioTap` plus a hard-coded flag. Confirm that:
   - `AVAudioEngine` will bind to a private aggregate that contains a tap, and the input node reports mic + tap channels.
   - The permission prompt appears, and you can see how a denial shows up (silence or an error).
   - A Developer ID build with Hardened Runtime still works.

   **Fallback** if AVAudioEngine won't bind to the aggregate: drive the aggregate directly with `AudioDeviceCreateIOProcIDWithBlock` and feed the same downmix → converter → `onBuffer` path. Only the capture front end of `MicrophoneCapture` would change.
2. `AudioInputDevices` aggregate filtering, with tests.
3. `SystemAudioTap` + `MicrophoneCapture` integration + downmix helper, with tests.
4. Preference, settings toggle, speaker notice, plist key.
5. Docs.

Rough size: about half a day for the spike, then 1–2 days for the rest.

## Risks

- **Speakers instead of headphones:** the far side is captured twice (tap + mic echo), which garbles the transcript. Mitigated by the notice and the toggle label. Real echo cancellation is out of scope.
- **Overlapping speakers:** SpeechTranscriber accuracy drops when two people talk at once in a mixed stream. That's inherent to the "mixed" choice.
- **Unrelated sounds:** a global tap also picks up notification sounds or music played during the session. That's accepted with the "all system audio" choice.
- **Bluetooth headsets:** using an AirPods mic already switches them to the lower-quality HFP mode during a call. The aggregate must be destroyed with the engine (same rule as CLAUDE.md "never hold an AVAudioEngine") or A2DP won't come back.
- **Consent:** this records other people on calls. macOS shows its own recording indicator. Consider a one-time note in Settings.

## Verification

- `xcodebuild … build` and the unit tests: `downmixToMono` (stereo → mono sum, clipping), aggregate exclusion in `AudioInputDevices.order`/candidates.
- Manual, launched with `open build/…` (not ⌘R):
  1. `tccutil reset AudioCapture com.pwilliams.Transcriber`, turn on the toggle and dictate. The prompt should appear.
  2. Headphones on, a YouTube video playing, speak over it. Both voices should appear in the pasted text.
  3. A Zoom test call (zoom.us/test) with headphones. Both sides should be transcribed. Then plug in or remove headphones mid-session; capture should continue, with at most one "rebuilding capture" log line.
  4. Stop. Check that Audio MIDI Setup and the `Input devices:` log line show no leftover "Transcriber System Audio" aggregate, and that Bluetooth playback is back to normal quality.
  5. Toggle off: plain dictation behaves exactly as now.
  6. Permission denied: dictation still works mic-only and shows the notice.
- Build a release with `./Scripts/release.sh --no-notarize` and repeat step 2 on the exported app (Hardened Runtime + Developer ID).
- Logs: `/usr/bin/log stream --predicate 'subsystem == "com.pwilliams.Transcriber"' --level debug`.
