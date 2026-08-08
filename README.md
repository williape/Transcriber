# Transcriber

A macOS menu bar app for dictation and audio-file transcription. Everything runs
on-device using Apple's `SpeechAnalyzer` framework — after a one-time model
download, no audio or text ever leaves your Mac.

## Requirements

- macOS 26.0 or later
- Apple Silicon recommended

## Install

Download the DMG, drag **Transcriber** to Applications, and launch it. It lives
in the menu bar — there's no Dock icon or window.

On first use it asks for two permissions:

- **Microphone** — for dictation. Prompted automatically.
- **Accessibility** — to type the transcript into whatever app you're using.
  Without it, transcripts go to the clipboard instead and the app says so.

## Use

- **⌥Space** starts and stops dictation. A floating panel shows words as you
  speak; finished text lands at your cursor in whatever app you were in. Press
  Esc to cancel. The shortcut is configurable in Settings.
- **Transcribe a file** by dragging an audio or video file onto the menu bar
  icon, or via *Transcribe File…* in the menu.
- **History** (⌘Y) keeps every dictation — searchable, with copy, re-insert,
  export, and optional audio retention with playback and re-transcription.

Transcripts and any retained audio are stored in `~/Documents/Transcriber`, so
you can browse, back up, or delete them yourself. History can be paused or
turned off, and retention limits are in Settings.

## Build from source

```sh
xcodebuild -project Transcriber.xcodeproj -scheme Transcriber \
  -configuration Debug -derivedDataPath build build
```

To produce a signed, notarized DMG you'll need your own Apple Developer ID —
see `Scripts/release.sh`.

## Notes

Built entirely with Apple frameworks, no third-party dependencies. The App
Sandbox is intentionally off, because typing text into other apps requires it;
that rules out the Mac App Store, which is a deliberate trade.
