# Dictation + AI Formatting

**Date:** 2026-02-24
**Status:** Brainstormed
**Inspired by:** Wispr Flow, Super Whisper

---

## What We're Building

A dictation feature for ClipboardHistory that lets you speak your thoughts, have them structured and formatted by a local AI model, and land directly in your clipboard ready to paste. Toggle on/off with a hotkey - speak naturally, stop, and your formatted text auto-pastes into the active app.

**Target user:** Builder / product manager / vibe coder who dictates instructions to AI agents (Claude Code, etc.) and communicates with colleagues. Speaks in streams of consciousness about technical topics but doesn't dictate actual code.

**Core value:** Transform rambling speech into clear, actionable text that AI agents and colleagues can immediately act on.

## Why This Approach

### Approach chosen: Lean Dictation Service

Single new service following the existing GIF capture pattern. One hotkey, one well-tuned prompt, straight to clipboard + auto-paste. Minimal new UI.

**Rejected alternatives:**
- **Prompt profiles (B):** Adds complexity before we know if the base feature feels right. Can layer on later.
- **Full dictation panel (C):** Contradicts the speed-first philosophy. If you're reviewing text before pasting, you've lost the dictation advantage.

## Key Decisions

1. **Trigger:** Toggle hotkey (press to start, press to stop). Consistent with GIF capture pattern.

2. **Speech-to-text:** Native macOS `SFSpeechRecognizer` - on-device, fast, excellent on Apple Silicon. No external dependencies for the speech part.

3. **AI formatting:** Local LLM via Ollama HTTP API (`localhost:11434`). Start with a 7B model (Mistral, Llama 3, or similar). The service interface is a simple protocol so the backend can be swapped to MLX or llama.cpp later without changing anything else.

4. **Output flow:** Formatted text goes straight to clipboard + auto-pastes (Cmd+V simulation). Maximum speed, matching the existing paste mechanics.

5. **Formatting style:** "Rewrite + restructure" - not just cleanup (removing filler words) but actual restructuring of thoughts into clear prose. The system prompt should preserve the speaker's voice while organizing content for clarity and actionability.

6. **Storage:** Formatted results save as regular `kindText` clipboard items with `sourceApp = "Dictation"`. No schema changes needed - GRDB observation in the panel picks them up automatically.

7. **Visual feedback:** Reuse `RecordingIndicatorWindow` pattern from GIF capture to show dictation is active.

## Architecture Fit

This plugs cleanly into the existing app:

```
New components:
  Services/DictationService.swift    - SFSpeechRecognizer + Ollama integration
  Models/DictationHotkeyDefaults.swift - UserDefaults for dictation hotkey

Modified:
  App/AppDelegate.swift              - New hotkey registration (parallel to capture hotkey)
  Views/SettingsView.swift           - Dictation hotkey row + Ollama model config
  Sources/Info.plist                 - NSMicrophoneUsageDescription, NSSpeechRecognitionUsageDescription
```

**Pattern reuse:**
- Hotkey registration: same as `captureHotKey` in AppDelegate
- Recording indicator: same as GIF capture's `RecordingIndicatorWindow`
- Clipboard write + auto-paste: same as `FloatingPanel.pasteItem()`
- Settings hotkey row: same `HotkeyRecorderView` component
- Suppression: same `monitor.suppressNextChange()` before paste

## Open Questions

1. **Ollama availability:** What happens when Ollama isn't running? Options: (a) paste raw transcription with a notification, (b) show an error, (c) prompt to start Ollama. Leaning toward (a) - graceful degradation.

2. **Model selection:** Which specific 7B model works best for "restructure thoughts" tasks? Needs experimentation. Could expose model name in settings.

3. **Streaming vs batch:** Should we wait for the full transcription before sending to Ollama, or stream partial results? Batch is simpler and the LLM needs full context to restructure well.

4. **Maximum dictation length:** What's the practical limit? SFSpeechRecognizer has a ~1 minute continuous limit per request. For longer sessions, we'd need to chain recognition requests. Start with the natural limit and extend if needed.

5. **Raw text preservation:** Should we save both the raw transcription AND the formatted version? Could be useful for debugging the AI prompt but adds complexity.

6. **System prompt tuning:** The formatting prompt is the soul of this feature. Will need iteration. Consider making it editable in settings (advanced) or at least easy to tweak in code.
