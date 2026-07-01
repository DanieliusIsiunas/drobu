---
title: "feat: Make the ⌘→ edit/crop/trim affordance discoverable"
date: 2026-07-01
type: feat
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
plan_depth: standard
---

# feat: Make the ⌘→ edit/crop/trim affordance discoverable

## Summary

`⌘→` (Cmd+Right) is the panel's universal "edit this entry" key — text opens text editing, image/GIF open crop, video opens trim — but it is almost invisible. The **only** on-screen hint is `⌘→ to crop`, shown for **images only**. Text (the reported complaint), GIF, and video give no signal at all, and the footer hint bar (`filter / navigate / paste / preview`) never mentions editing.

This plan makes the affordance discoverable by (1) extracting a single pure source of truth for "is this item editable via `⌘→`, and what verb," (2) surfacing a context-sensitive `⌘→ <verb>` hint in the footer bar **and** at parity across kinds in the preview pane, (3) documenting the shortcut in Settings → Shortcuts, and (4) reaching VoiceOver via a row hint. Ships as a hotfix patch (1.9.8).

**Product Contract preservation:** N/A — solo plan, no upstream brainstorm (`product_contract_source: ce-plan-bootstrap`).

---

## Problem Frame

`PanelView.handleClipboardKeyPress` (~614-640) makes `⌘→` enter edit mode, gated on kind **and** data availability: text needs `plainText != nil`; image needs `ImageCrop.isBitmapData(data)`; GIF needs `imageData != nil`; video needs the file to exist at `ClipboardRecord.videoPath(for:)`. File entries do nothing.

Discoverability is almost entirely absent:
- **`PreviewPanel.metadataBar(for:)`** renders a per-kind metadata line. Only the **image** branch (~234) shows `⌘→ to crop` (gated on `!isEditing && ImageCrop.isBitmapData`). Text (~191, only "N words; M chars"), GIF (~198), and video (~210) show **nothing**.
- **The footer hint bar** (`PanelView.swift:382`) is a static `←→ filter  ↑↓ navigate  ↵ paste  ⇧ preview`, kind-independent, `.accessibilityHidden(true)`. No edit hint.
- **Settings → Shortcuts** (`SettingsView.swift` ~334-352) lists the 3 configurable global hotkeys; the in-panel `⌘→` key is not represented.

There is also a **drift hazard**: the "editable + verb" predicate is duplicated across the entry gate (~614-640), the image-only hint (~234), and referenced by the `saveEdit` invariant (~957, with a "keep in sync with the Cmd+Right entry gate" comment). Adding more hint sites without consolidating triples the risk that one copy silently diverges and advertises a no-op (or misses a real one).

---

## Requirements

- **R1** — A `⌘→` hint is shown for every editable kind: text ("edit"), image ("crop"), GIF ("crop"), video ("trim"). File entries show no hint.
- **R2** — The hint is gated on the **same predicate** as the `⌘→` entry gate, so it never advertises an action that would do nothing (e.g. a non-bitmap image, a video whose file is missing).
- **R3** — A context-sensitive `⌘→ <verb>` hint appears in the footer hint bar, next to the existing hints, for the currently-selected item when editable.
- **R4** — The per-kind preview-pane hint reaches parity: text/GIF/video get their verb, matching the existing image hint.
- **R5** — The editable/verb decision has a single source of truth: one pure, unit-tested function used by the entry gate, the footer hint, and the preview hint.
- **R6** — The edit affordance reaches VoiceOver users (not via the decorative visual hints, which stay hidden).
- **R7** — Settings → Shortcuts documents the in-panel `⌘→` edit shortcut.
- **R8** — Hotfix version bump across all version surfaces.

---

## Key Technical Decisions

- **KTD1 — One pure source of truth, two layers.** In one file, mirroring the repo's pure-helper pattern (`screenRecordingGrantedFromWindows` in `PermissionsService.swift`; `shiftTapDecision` in `ShiftTapDetector.swift`): (a) a pure kind→verb map `editVerb(forKind:) -> String?` (text→"edit", image/gif→"crop", video→"trim", file/other→nil), and (b) the data-gated `editActionVerb(for:isBitmapImage:videoFileExists:) -> String?` that wraps it and returns nil when the required data is unavailable. The two impure facts (bitmap-ness of image data, video-file existence) are passed **in** as booleans, keeping both functions pure and unit-testable; the `ImageCrop.isBitmapData` / `FileManager` checks stay at the call sites. `plainText`/`imageData` are record properties, read directly. The `⌘→` entry gate and both **visual** hints call the gated `editActionVerb` (precise — a nil return means "no hint and `⌘→` is a no-op," structurally enforcing R2); the per-row VoiceOver hint calls the cheap kind-only `editVerb(forKind:)` — see KTD5.
- **KTD2 — Both surfaces, not one.** Footer gets a context-sensitive segment (the user's "next to other ones"; always visible), and the preview pane reaches per-kind parity (images already have it — extending to text/GIF/video removes the "why is image special" inconsistency). The mild redundancy for images is acceptable and gives two discovery chances. *Alternative considered:* footer-only, deleting the image preview hint — rejected because it removes a hint image-croppers already rely on and where they expect it.
- **KTD3 — Context-sensitive verb, not a generic "edit."** The footer shows the exact verb for the selected kind (`⌘→ edit` / `⌘→ crop` / `⌘→ trim`), matching the preview pane's specific verbs and telling the user precisely what the key does. The footer segment simply changes as the selection moves between kinds. *Alternative:* a single umbrella `⌘→ edit` — rejected as less precise and inconsistent with the preview verbs.
- **KTD4 — Settings documents, does not rebind.** Add a static, non-editable reference row in Settings → Shortcuts for `⌘→` (edit/crop/trim). *Alternative:* make `⌘→` rebindable via `HotkeyRecorderView` — rejected: it is an arrow-based, context-dependent, in-panel key, and the recorder is built for global modifier+letter combos; rebinding is heavy and low-value versus documenting.
- **KTD5 — A11y via a row hint, computed cheaply.** The footer/preview visual hints stay `.accessibilityHidden(true)` (matching the existing crop hint). The affordance reaches VoiceOver through an `.accessibilityHint` on rows, **appended to** (not replacing) the existing "Press Return to paste" hint. The row hint uses the cheap kind-only `editVerb(forKind:)` — **not** the data-gated `editActionVerb` — because gating every visible row on `ImageCrop.isBitmapData` (a CGImageSource build over the full image `Data`) + `FileManager` per render is a hot-path cost (`isBitmapData` is documented as per-keypress, not per-render). Accepted tradeoff: a rare non-bitmap image / missing-file video row announces its verb in VoiceOver even though `⌘→` would no-op there — a minor over-promise in a spoken hint, far cheaper than per-row ImageIO/fs. The precise data-gate still governs the visual hints and the actual `⌘→` action. Per `.claude/rules/accessibility.md` (hint not label; spoken after a pause).

---

## Implementation Units

### U1. Extract the pure `editActionVerb` source of truth + tests

**Goal:** One tested function deciding editability and verb, replacing the scattered predicate.

**Requirements:** R1, R2, R5.

**Dependencies:** none.

**Files:**
- `Sources/DrobuCore/Views/EditAction.swift` (create — pure function + doc comment)
- `Tests/DrobuTests/EditActionTests.swift` (create)

**Approach:** Add two top-level `internal` free functions in one file (reachable from tests via `@testable import DrobuCore`). Directional shape:

```
// Pure kind→verb map. Used by the per-row VoiceOver hint (cheap, per-row-safe).
func editVerb(forKind kind: String) -> String?    // text→"edit", image/gif→"crop", video→"trim", else nil

// Data-gated. Used by the ⌘→ entry gate and the visual footer/preview hints.
func editActionVerb(for item: ClipboardRecord,
                    isBitmapImage: Bool,      // caller: item.imageData.map(ImageCrop.isBitmapData) ?? false
                    videoFileExists: Bool)    // caller: FileManager check on ClipboardRecord.videoPath
    -> String?
```

`editActionVerb` returns `editVerb(forKind:)` gated by availability, matching the entry gate exactly: text → requires `plainText != nil`; image → requires `isBitmapImage`; gif → requires `imageData != nil`; video → requires `videoFileExists`; file/other → nil. No filesystem or ImageIO inside either function — the two impure facts are parameters.

**Patterns to follow:** `screenRecordingGrantedFromWindows` (`PermissionsService.swift:66`) and `shiftTapDecision` (`ShiftTapDetector.swift`) — top-level pure func + doc comment; tests in `Tests/DrobuTests/` using Swift Testing (`@Suite`/`@Test`/`#expect`), mirroring `ShiftTapDetectorTests.swift`.

**Test scenarios:**
- `editVerb(forKind:)` alone (kind-only, no availability gate): text→"edit", image→"crop", gif→"crop", video→"trim", file→nil, unknown string→nil.
- `editActionVerb`: text with `plainText` present → `"edit"`; text with `plainText == nil` → `nil`.
- Image with `isBitmapImage: true` → `"crop"`; image with `isBitmapImage: false` (e.g. non-bitmap/PDF-style) → `nil`.
- GIF with `imageData` present → `"crop"`; GIF with `imageData == nil` → `nil`.
- Video with `videoFileExists: true` → `"trim"`; video with `videoFileExists: false` → `nil`.
- File kind → `nil` regardless of the boolean facts.
- Use `makeRecord(...)` factory for records (see `TestSupport.swift` / `ClipboardRecordTests`).

**Verification:** `swift test` — new suite green; every kind × available/unavailable pair asserted.

---

### U2. Route the ⌘→ entry gate through `editActionVerb` (behavior-preserving)

**Goal:** Remove the duplicated predicate at the entry gate; make the helper the gate.

**Requirements:** R2, R5.

**Dependencies:** U1.

**Files:**
- `Sources/DrobuCore/Views/PanelView.swift` (modify — `handleClipboardKeyPress` `⌘→` branch ~614-640; the `saveEdit` invariant comment ~957)

**Approach:** Replace the four inline `if item.kind == … { enterEditMode(); return .handled }` checks with a single call: compute `isBitmapImage: item.imageData.map(ImageCrop.isBitmapData) ?? false` and `videoFileExists` (`FileManager` on `ClipboardRecord.videoPath(for:)`) at the call site, then `if editActionVerb(for: item, …) != nil { enterEditMode(); return .handled }` else `return .ignored`. Preserve the existing guards (`!items.isEmpty`, `!hasMultiSelection`). This is behavior-preserving — the U1 mapping is copied from this gate. Update the `saveEdit` invariant comment (~957) to point at `editActionVerb` as the shared **entry** gate, while **preserving** its existing note that `kindVideo` is deliberately absent from `saveEdit`'s media-kind list because `VideoTrimView` fires `onVideoSave` directly — the entry gate and the save routing are different concerns, so don't imply video routes through `saveEdit` just because `editActionVerb` returns a verb for it.

**Patterns to follow:** the existing `SystemPermissionProbe` ↔ `screenRecordingGrantedFromWindows` split — impure facts at the call site, decision in the pure function.

**Test scenarios:** `Test expectation: none` — SwiftUI/AppKit key-handling wiring is not unit-tested per CLAUDE.md; the decision logic is covered by U1. Behavior preservation is covered by U6 manual verification (each kind still enters edit on `⌘→`; file still does nothing).

**Verification:** build succeeds; `⌘→` still enters edit/crop/trim for text/image/gif/video and is a no-op for file and for a non-bitmap image / missing video file.

---

### U3. Footer hint: context-sensitive `⌘→ <verb>` + VoiceOver row hint

**Goal:** Surface the affordance in the footer bar and to VoiceOver.

**Requirements:** R3, R6.

**Dependencies:** U1.

**Files:**
- `Sources/DrobuCore/Views/PanelView.swift` (modify — footer hint `Text` at ~382; compute the kind-only verb and pass it into the row view)
- `Sources/DrobuCore/Views/ClipboardRowView.swift` (modify — accept a new `editVerb: String?` init param and append the VoiceOver `.accessibilityHint`)

**Approach:**
- *Footer (visual):* for the selected item (guard `!items.isEmpty`, `cursor` in bounds, `!isEditing`), compute the verb via the data-gated `editActionVerb` — computed once for the single selected item, so it's cheap. When non-nil, append a `  ⌘→ <verb>` segment to the footer string (keep font size 11, `.tertiary`, `.accessibilityHidden(true)` — stays decorative). When nil (file kind, or unavailable data), append nothing. Only the `.clipboard`-mode footer (~382) changes; commands-mode (~500) is untouched.
- *Row VoiceOver hint (R6):* pass `editVerb(forKind: item.kind)` (the cheap kind-only map — KTD5) from `PanelView` into `ClipboardRowView` as a new `editVerb: String?` param; the row **appends** it to its existing hint (today `.accessibilityHint("Press Return to paste")` — combine into e.g. "Press Return to paste. Press Command Right to \(verb).", do not overwrite). Keep the row's existing `.accessibilityElement(children: .ignore)` + label intact. Do **not** compute `isBitmapData`/`FileManager` per row, and do **not** unhide the footer text. Follow `.claude/rules/accessibility.md` (hint not label).

**Patterns to follow:** the existing footer `Text` (~382) for styling; `ClipboardRecord.accessibilityDescription` and the row a11y conventions in `.claude/rules/accessibility.md`.

**Test scenarios:** `Test expectation: none` — SwiftUI view rendering / a11y modifiers are not unit-tested per CLAUDE.md (the verb logic is covered by U1). Covered by U6 manual + VoiceOver verification.

**Verification:** footer shows `⌘→ edit` on a text row, `⌘→ crop` on image/GIF, `⌘→ trim` on video, nothing on a file row; the segment updates as the selection moves. VoiceOver announces the edit hint on an editable row.

---

### U4. Preview-pane hint parity across kinds

**Goal:** Bring text/GIF/video preview hints to parity with the existing image `⌘→ to crop`, all via the helper.

**Requirements:** R1, R4, R2.

**Dependencies:** U1.

**Files:**
- `Sources/DrobuCore/Views/PreviewPanel.swift` (modify — `metadataBar(for:)` ~189-254: text ~191, gif ~198, video ~210, image ~234)

**Approach:** In each kind branch of `metadataBar`, after the existing metadata line, render `Text("⌘→ to \(verb)")` when `!isEditing` and `editActionVerb(for:…) != nil` — same font (`.caption2`), `.tertiary`, `.accessibilityHidden(true)` as the current image hint. Replace the image branch's inline `ImageCrop.isBitmapData` gate with the shared helper so all four kinds go through one path. The invariant comment at ~232-233 stays true and now points at `editActionVerb`.

**Patterns to follow:** the existing image hint (`PreviewPanel.swift:234-238`) — copy its styling and `.accessibilityHidden(true)`.

**Test scenarios:** `Test expectation: none` — preview-pane SwiftUI rendering is not unit-tested per CLAUDE.md; verb/editability logic covered by U1. Covered by U6 manual verification.

**Verification:** selecting a text entry shows `⌘→ to edit` under "N words; M chars"; GIF shows `⌘→ to crop`; video shows `⌘→ to trim`; image still shows `⌘→ to crop`; a non-bitmap image / missing-file video shows no hint.

---

### U5. Settings → Shortcuts reference row for ⌘→

**Goal:** Document the in-panel edit shortcut next to the configurable global hotkeys.

**Requirements:** R7.

**Dependencies:** none.

**Files:**
- `Sources/DrobuCore/Views/SettingsView.swift` (modify — Shortcuts pane ~334-352)

**Approach:** Add a static, non-editable reference row below the three `shortcutRow` entries (append a `Divider()` + one `settingsRow`): a label like "Edit / crop / trim selected" with the trailing `⌘→` shown as static `Text` (not a `HotkeyRecorderView`). Use `settingsRow` with its default `.firstTextBaseline` alignment (static `Text` trailing, not a bordered control), and pass **no** `description:` — a `settingsRow` description is spoken by VoiceOver, and the label + `⌘→` text reads fine alone. It is informational, so deliberately not a `shortcutRow` (which is for editable bindings). Follow the Settings row grammar in `.claude/rules/swiftui-macos-gotchas.md`.

**Patterns to follow:** `settingsRow(_:description:trailing:)` and the Shortcuts pane structure in `SettingsView.swift`; the row-grammar rules in `.claude/rules/swiftui-macos-gotchas.md`.

**Test scenarios:** `Test expectation: none` — static SwiftUI Settings row, no logic.

**Verification:** Settings → Shortcuts shows an "Edit / crop / trim selected  ⌘→" reference row beneath the three configurable hotkeys; it is not editable.

---

### U6. Hotfix version bump

**Goal:** Ship as a patch release.

**Requirements:** R8.

**Dependencies:** U1, U2, U3, U4, U5.

**Files:**
- `Sources/DrobuCore/Info.plist` (modify — `CFBundleShortVersionString` `1.9.7` → `1.9.8`; `CFBundleVersion` `21` → `22`)
- `website/src/components/Footer.astro` (modify — `v1.9.7` → `v1.9.8`)

**Approach:** Patch tier per CLAUDE.md versioning (refines an existing feature's discoverability — no new capability). `CFBundleVersion` increments by exactly one. Settings "About" reads `CFBundleShortVersionString` at runtime — no edit there.

**Test scenarios:** `Test expectation: none` — version strings, no logic.

**Verification:** `plutil -extract CFBundleShortVersionString raw Sources/DrobuCore/Info.plist` → `1.9.8`; footer renders `v1.9.8`.

---

## Risks & Dependencies

- **Footer noise / reflow.** Adding a segment that changes per selection could feel busy or shift layout. Mitigation: it's one short `.tertiary` segment appended to an existing hint line; verify it doesn't wrap at the panel's min width during U6 manual check.
- **Verb-mapping drift is the thing being fixed** — U2 must copy the mapping from the current entry gate verbatim into U1 so the refactor is behavior-preserving. The U1 tests lock it; U6 manual check confirms each kind still enters edit.
- **`imageData` availability.** The helper reads `item.imageData` for the GIF branch; the entry gate already does this (~623), so it's loaded on panel records. If a record ever lazy-loads media, the caller's `isBitmapImage`/data facts must reflect the loaded state (same constraint the entry gate has today).
- **Sequencing:** U2/U3/U4 depend on U1 (the helper). U5 is independent. U6 ships last.

---

## System-Wide Impact

- **All users** gain discoverability of an existing, previously-hidden feature — no behavior change to the `⌘→` action itself (U2 is behavior-preserving).
- VoiceOver users gain the affordance for the first time (today neither the crop hint nor the edit path is announced).
- `LargePreviewPanel` is intentionally **not** touched — it renders content only (no metadata bar, no existing `⌘→` hint), so there is no image-vs-other inconsistency there to fix; adding a hint would be a new surface, not parity.
- No DB, schema, daemon, licensing, or global-hotkey change. Pure UI/discoverability + one pure helper. Normal patch release.

---

## Definition of Done

- `editActionVerb` exists as a pure function with the full kind × availability test matrix green under `swift test`; existing suite still passes (R1, R2, R5).
- The `⌘→` entry gate, footer hint, and preview hints all call `editActionVerb` — no remaining copy of the predicate; `saveEdit` invariant comment updated to reference it (R5).
- Footer shows the context-sensitive `⌘→ <verb>` for the selected editable item and nothing for file/unavailable (R3); preview pane shows the verb hint for text/GIF/video/image at parity (R1, R4).
- Editable rows carry a VoiceOver `.accessibilityHint`; decorative visual hints stay `.accessibilityHidden(true)` (R6).
- Settings → Shortcuts shows the static `⌘→` reference row (R7).
- Version reads `1.9.8` / build `22` and footer `v1.9.8` (R8).
- Manual check on an installed build: each kind's hint appears/updates correctly and `⌘→` still performs edit/crop/trim.

---

## Sources & Research

- Code mechanism verified live this session: `PanelView.swift` `handleClipboardKeyPress` ~614-640 (`⌘→` entry gate) and footer ~382; `PreviewPanel.swift` `metadataBar(for:)` ~189-254 (image-only `⌘→ to crop` at ~234); `SettingsView.swift` Shortcuts pane ~334-352; `saveEdit` invariant `PanelView.swift` ~957.
- Pure-helper + test pattern: `PermissionsService.swift:66` / `ShiftTapDetector.swift` + `ShiftTapDetectorTests.swift`.
- Conventions: `CLAUDE.md` (Testing, Versioning), `.claude/rules/accessibility.md` (hint vs label; decorative `.accessibilityHidden`), `.claude/rules/swiftui-macos-gotchas.md` (Settings row grammar).
