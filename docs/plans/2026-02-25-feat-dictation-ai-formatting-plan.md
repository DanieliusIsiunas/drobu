---
title: "feat: Add dictation with AI formatting"
type: feat
date: 2026-02-25
brainstorm: docs/brainstorms/2026-02-24-dictation-ai-formatting-brainstorm.md
---

# feat: Add Dictation with AI Formatting

## Overview

Add a toggle-hotkey-triggered dictation feature that uses native macOS `SFSpeechRecognizer` for speech-to-text and a local Ollama LLM for restructuring/formatting, then auto-pastes the result into the active app. Follows the existing GIF capture service pattern exactly.

## Problem Statement / Motivation

The user (a builder/PM/vibe coder) dictates instructions to AI agents and colleagues constantly. Current workflow requires a separate app (Wispr Flow) for dictation + formatting. Integrating this into ClipboardHistory creates a unified clipboard + dictation experience: speak → formatted text lands in clipboard history and auto-pastes, all from one app.

## Proposed Solution

A lean `DictationService` that mirrors the `ScreenCaptureService` architecture:

```
Press hotkey → recording starts (indicator appears)
→ speak naturally (up to 60s)
→ press hotkey again → recording stops
→ SFSpeechRecognizer transcribes (on-device)
→ Ollama reformats via HTTP (localhost:11434)
→ formatted text → clipboard + auto-paste (Cmd+V)
→ saved to DB as kindText, sourceApp = "Dictation"
```

## Technical Approach

### State Machine

```
DictationService.State:
  .idle        → hotkey press    → .recording
  .recording   → hotkey press    → .processing  (stops audio, transcribes + formats)
  .recording   → Escape / cancel → .idle        (discard, no output)
  .recording   → 60s auto-stop   → .processing  (process what was captured)
  .processing  → completion      → .idle        (pastes result)
  .processing  → hotkey press    → ignored (no-op, let it finish)
```

The `.processing` state covers both transcription and Ollama formatting — the user doesn't need to distinguish them. The `cancel()` method is both user-facing (discard current dictation) and used for app termination cleanup.

### Mutual Exclusion

Three early-return guards in AppDelegate — one per handler:

```swift
// In togglePanel():
if dictationService?.state == .recording { return }

// In handleCaptureHotkey():
if dictationService?.state != .idle { return }

// In handleDictationHotkey():
if captureService?.state != .idle { return }
if panel?.isVisible == true { togglePanel() }  // close panel, then start
```

Screen capture is blocked during both `.recording` and `.processing` (pasting while capture runs would be confusing). Panel can open during `.processing` since dictation will paste independently.

### Architecture

```
New files:
  Sources/Services/DictationService.swift       - Speech recognition + Ollama client
  Sources/Models/DictationHotkeyDefaults.swift  - UserDefaults + notification pattern

Modified files:
  Sources/App/AppDelegate.swift                 - Hotkey registration, callbacks, mutual exclusion
  Sources/Views/SettingsView.swift              - Dictation hotkey row in General section
  Sources/Views/RecordingIndicatorWindow.swift  - New show(centeredOn:) method
  Sources/Views/FloatingPanel.swift             - Extract firePaste() + showCopiedNotification() as static/free functions
  Sources/Info.plist                            - Permission descriptions
```

### DictationService.swift

```swift
import Speech
import AVFoundation

@MainActor
final class DictationService {
    // MARK: - The formatting prompt (the soul of this feature — edit here to tune)
    static let systemPrompt = """
    You are a thought organizer. You receive raw speech transcriptions from a product manager \
    and builder. Your job is to restructure their stream-of-consciousness into clear, actionable \
    text. Rules:
    - Preserve the speaker's voice and intent
    - Fix grammar, remove filler words, add punctuation
    - Restructure for logical flow and clarity
    - Keep it concise — remove repetition
    - Output ONLY the restructured text, no explanations or meta-commentary
    - If the input is a set of instructions, format as clear directives
    - If the input is conversational, keep it natural but polished
    """

    private static let ollamaURL = URL(string: "http://localhost:11434/api/chat")!
    private static let ollamaModel = "llama3.2:3b"

    enum State: Sendable { case idle, recording, processing }
    private(set) var state: State = .idle

    var onComplete: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onStateChange: ((State) -> Void)?

    private let speechRecognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var transcriptionBuffer: String = ""
    private var indicatorWindow: RecordingIndicatorWindow?
    private var autoStopTimer: Timer?

    func startRecording() { ... }
    func stopRecording() { ... }
    func cancel() { ... }
}
```

### Critical Implementation Details

**1. Preconditions in `startRecording()`:**
```swift
func startRecording() {
    guard state == .idle else { return }
    guard let speechRecognizer, speechRecognizer.isAvailable else {
        onError?("Speech recognition is not available.")
        return
    }
    // Request permissions if not yet granted (first-use flow)
    // Set up audio engine + recognition request
    // Start recording
}
```

**2. Audio engine teardown sequence (critical for avoiding lost transcriptions):**
```swift
func stopRecording() {
    guard state == .recording else { return }
    setState(.processing)
    autoStopTimer?.invalidate()

    // 1. Stop audio input
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()

    // 2. Signal end of audio to speech recognizer
    recognitionRequest?.endAudio()

    // 3. Wait for final transcription result via the recognition task's
    //    result handler (already set up in startRecording).
    //    The handler checks result.isFinal == true, then calls formatAndPaste().
}
```

**3. Recognition callback → MainActor dispatch (avoids data race):**
```swift
recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
    Task { @MainActor in
        guard let self else { return }
        if let result {
            self.transcriptionBuffer = result.bestTranscription.formattedString
        }
        if result?.isFinal == true || error != nil {
            self.formatAndPaste()
        }
    }
}
```

**4. `requiresOnDeviceRecognition = true`** — explicitly force on-device processing. No audio sent to Apple servers.

**5. 60-second auto-stop:** Timer set in `startRecording()`, fires `stopRecording()`. No warning colors — the elapsed timer is visible and auto-stop is seamless.

### Ollama Integration

**Request:** `POST http://localhost:11434/api/chat`
```json
{
  "model": "llama3.2:3b",
  "messages": [
    {"role": "system", "content": "<DictationService.systemPrompt>"},
    {"role": "user", "content": "<transcription>"}
  ],
  "stream": false
}
```

Uses `/api/chat` (not `/api/generate`) for proper system/user role separation — the model gets clear signal about what is instruction vs. input.

**Response parsing:** `json["message"]["content"]` as `String`.

**Timeouts:**
```swift
var config = URLSessionConfiguration.default
config.timeoutIntervalForRequest = 15   // server must start responding within 15s
config.timeoutIntervalForResource = 30  // entire request must complete within 30s
```

Both timeouts are needed because with `stream: false`, the entire response must arrive before any data is available. `timeoutIntervalForRequest` alone won't catch a server that accepts the connection but takes 60s to generate.

**Fallback triggers** (paste raw transcription instead):
- Connection refused (Ollama not running)
- Any timeout exceeded
- Non-200 HTTP response
- JSON parse failure or empty `message.content`
- Model not found (Ollama returns error JSON)

No special notification on fallback — the text pastes either way. Raw transcription is still useful.

### RecordingIndicatorWindow Changes

Add one method — `show(centeredOn:)` — for dictation positioning (no capture region):

```swift
func show(centeredOn screen: NSScreen) {
    let screenFrame = screen.visibleFrame
    let x = screenFrame.midX - frame.width / 2
    let y = screenFrame.maxY - frame.height - 8
    setFrameOrigin(NSPoint(x: x, y: y))
    // ... same setup as existing show() method
}
```

Indicator dismisses when recording stops (before Ollama processing). The auto-paste arriving is the user's confirmation that formatting completed. No amber dot, no "Formatting..." label — keep it simple.

### Paste Mechanics

Extract `firePaste()` and `showCopiedNotification()` from `FloatingPanel` to free functions or static methods accessible by both `FloatingPanel` and `AppDelegate`.

In `AppDelegate.handleDictationComplete(_ text: String)`:

```swift
// 1. Suppress monitor
monitor?.suppressNextChange()

// 2. Write to pasteboard
let pasteboard = NSPasteboard.general
pasteboard.clearContents()
pasteboard.setString(text, forType: .string)

// 3. Save to DB
let hash = text.data(using: .utf8)!.sha256String
let record = ClipboardRecord(
    kind: ClipboardRecord.kindText,
    plainText: text,
    imageData: nil,
    sourceApp: "Dictation",
    sourceBundleId: nil,
    contentHash: hash,
    createdAt: Date()
)
Task.detached { [database] in
    try? await database!.pool.write { db in
        try ClipboardRecord.upsert(record, in: db)
    }
}

// 4. Auto-paste if Accessibility granted
if AXIsProcessTrusted() {
    firePaste()
} else {
    showCopiedNotification()
}
```

### Permissions

**Info.plist additions:**
```xml
<key>NSMicrophoneUsageDescription</key>
<string>ClipboardHistory needs microphone access for voice dictation.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>ClipboardHistory uses speech recognition to transcribe your dictation.</string>
```

**Permission flow:** Request on first hotkey press (not on launch). If denied, show an alert with a button to open System Settings → Privacy & Security. Cache `SFSpeechRecognizer.authorizationStatus()` — don't re-request on every press. If permission is revoked mid-session, the next `startRecording()` precondition check catches it.

### Settings UI

Add dictation hotkey row to existing `Section("General")` in `SettingsView.swift`:

```swift
HStack {
    Text("Dictation Hotkey")
    Spacer()
    HotkeyRecorderView(keyCombo: $dictationHotkeyCombo, saveAction: DictationHotkeyDefaults.save)
        .frame(width: 160, height: 24)
}
```

No new section. No Ollama model field. The model is hardcoded as `llama3.2:3b` in `DictationService` — a one-line change if needed.

### Default Hotkey

`Cmd+Shift+D` — mnemonic for "Dictation", doesn't conflict with existing hotkeys (`Cmd+Shift+V`, `Ctrl+Shift+G`).

### Edge Cases

| Edge Case | Behavior |
|---|---|
| Empty transcription (user says nothing) | Silent no-op. Indicator dismisses, nothing pasted. |
| Ollama returns empty string | Paste raw transcription. |
| Ollama model not pulled | Paste raw transcription (Ollama returns error JSON). |
| 60-second SFSpeechRecognizer limit | Auto-stop at 60s, process what was captured. |
| Cancel during recording (Escape) | Discard. Audio stops, indicator dismisses, nothing pasted. |
| Hotkey press during .processing | Ignored (no-op). Let it finish. |
| Audio interruption mid-recording | Stop recording, process whatever was captured. |
| Audio engine fails to start | `onError` callback fires. Alert shown. |
| App quit during recording | `applicationWillTerminate` calls `dictationService?.cancel()`. |
| Accessibility not granted | Text goes to clipboard only. "Copied!" HUD shown. |
| Duplicate content hash | Standard upsert behavior — moves to top of list. |
| SFSpeechRecognizer not available | Alert: "On-device speech recognition is not available for your language." |
| `speechRecognizer.isAvailable` false | Alert shown. Dictation not started. |
| Permission revoked after previously granted | Caught by precondition check on next `startRecording()`. |

## Acceptance Criteria

### Functional Requirements

- [ ] Toggle hotkey (`Cmd+Shift+D` default) starts/stops dictation
- [ ] Cancel with Escape during recording discards without output
- [ ] Recording indicator appears during dictation with elapsed timer
- [ ] Native `SFSpeechRecognizer` transcribes speech on-device (`requiresOnDeviceRecognition = true`)
- [ ] Ollama `/api/chat` formats transcription with `stream: false`
- [ ] Formatted text auto-pastes into active app via Cmd+V simulation
- [ ] Formatted text saved to DB as `kindText` with `sourceApp = "Dictation"`
- [ ] Dictated items appear in clipboard panel via existing GRDB observation
- [ ] Graceful degradation: raw transcription pastes if Ollama unavailable
- [ ] 60-second auto-stop processes what was captured
- [ ] Mutual exclusion: dictation blocks screen capture and vice versa
- [ ] Clipboard panel dismissed when dictation starts
- [ ] Empty transcription produces no output (silent no-op)

### Permissions

- [ ] `NSMicrophoneUsageDescription` in Info.plist
- [ ] `NSSpeechRecognitionUsageDescription` in Info.plist
- [ ] Permissions requested on first use, not on launch
- [ ] Permission denial shows alert with System Settings link
- [ ] Precondition checks in `startRecording()` for recognizer availability + audio engine

### Settings

- [ ] Dictation hotkey configurable in Settings (General section)
- [ ] Hotkey changes take effect immediately via notification pattern

### Quality

- [ ] Swift 6 strict concurrency compliance (`@MainActor`, `Sendable`)
- [ ] Recognition callbacks dispatched to `@MainActor` via `Task { @MainActor in }`
- [ ] Audio teardown sequence: removeTap → stop engine → endAudio() → wait for isFinal
- [ ] Monitor suppression prevents self-capture of pasted text
- [ ] Clean shutdown: audio engine stopped on app terminate
- [ ] Ollama timeouts: 15s request + 30s resource

## Implementation Phases

### Phase 1: Service + Models

Create the core service and wire the indicator.

**Files to create:**
- `Sources/Models/DictationHotkeyDefaults.swift` — Clone `CaptureHotkeyDefaults.swift`. Key: `"dictationHotkey"`, notification: `.dictationHotkeyDidChange`, default: `KeyCombo(key: .d, modifiers: [.command, .shift])`
- `Sources/Services/DictationService.swift` — Full service: state machine, `SFSpeechRecognizer`, `AVAudioEngine`, Ollama HTTP client (hardcoded URL + model), `RecordingIndicatorWindow` management, 60s auto-stop timer

**Files to modify:**
- `Sources/Info.plist` — Add `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`
- `Sources/Views/RecordingIndicatorWindow.swift` — Add `show(centeredOn:)` method (~10 lines)
- `Sources/Views/FloatingPanel.swift` — Extract `firePaste()` and `showCopiedNotification()` so AppDelegate can call them

### Phase 2: AppDelegate Wiring + Settings

**Files to modify:**
- `Sources/App/AppDelegate.swift`:
  - Add `dictationService`, `dictationHotKey`, `dictationHotkeyObserver` properties
  - Add `registerDictationHotkey()` method
  - Add `handleDictationHotkey()` with state machine dispatch
  - Add `handleDictationComplete(_ text: String)` with paste mechanics
  - Add 3 mutual exclusion guards (one in each handler)
  - Wire into `applicationDidFinishLaunching` and `applicationWillTerminate`
- `Sources/Views/SettingsView.swift`:
  - Add `@State` for `dictationHotkeyCombo`
  - Add dictation hotkey row in General section

### Phase 3: End-to-End Testing

- Full flow: hotkey → dictate → stop → format → paste
- Permission flows: first-use grant, denial, revocation
- Ollama unavailable: connection refused, timeout, model not found
- Mutual exclusion between all three features
- 60-second auto-stop
- Cancel during recording
- System prompt tuning with real dictation samples

## Dependencies & Risks

**Dependencies:**
- Ollama installed and running with a pulled model (`ollama pull llama3.2:3b`)
- macOS 14+ for `SFSpeechRecognizer` on-device recognition
- Accessibility permission for auto-paste (graceful fallback exists)

**Risks:**
- **SFSpeechRecognizer accuracy:** May vary by accent/context. If insufficient, swap the internals of `DictationService` to use Whisper — the public API (`startRecording/stopRecording/onComplete`) stays the same.
- **Ollama cold start:** First inference after model load can take 5-15 seconds. The text still pastes — just with a delay. No UI feedback during this wait (indicator already dismissed). If this proves annoying in practice, add a small processing HUD later.
- **System prompt quality:** This is the soul of the feature. The `static let systemPrompt` at the top of `DictationService` is intentionally prominent and easy to iterate on.

## References

### Internal
- Brainstorm: `docs/brainstorms/2026-02-24-dictation-ai-formatting-brainstorm.md`
- GIF capture pattern: `Sources/Services/ScreenCaptureService.swift`
- Hotkey defaults pattern: `Sources/Models/CaptureHotkeyDefaults.swift`
- Recording indicator: `Sources/Views/RecordingIndicatorWindow.swift`
- Paste mechanics: `Sources/Views/FloatingPanel.swift:109-146` (`pasteItem`)
- CGEvent paste: `Sources/Views/FloatingPanel.swift:249-263` (`firePaste`)
- Settings layout: `Sources/Views/SettingsView.swift:15-27`
- AppDelegate hotkey wiring: `Sources/App/AppDelegate.swift:49-72`

### External
- [SFSpeechRecognizer docs](https://developer.apple.com/documentation/speech/sfspeechrecognizer)
- [Ollama API docs — /api/chat](https://github.com/ollama/ollama/blob/main/docs/api.md#generate-a-chat-completion)
