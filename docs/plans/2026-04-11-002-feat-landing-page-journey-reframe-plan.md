---
title: "feat: Reframe landing page copy around content journeys"
type: feat
status: active
date: 2026-04-11
origin: docs/brainstorms/2026-04-11-landing-page-content-journey-reframe-requirements.md
---

# Reframe Landing Page Copy Around Content Journeys

## Overview

Rewrite landing page copy to shift the narrative from "clipboard history that remembers" to "content moves from A to B without friction." No structural/layout changes — this is a pure copy rewrite across Hero, ProblemSolution, BentoGrid descriptions, and DownloadCTA.

## Problem Frame

The current page lists features technically. Visitors see "FTS5 full-text search" and "GIF screen capture" — but they don't see the workflow these features eliminate. The page reads like a spec sheet rather than a story about effortless content workflows. (see origin: `docs/brainstorms/2026-04-11-landing-page-content-journey-reframe-requirements.md`)

## Requirements Trace

- R1. Hero copy reframe — headline + subtitle communicate content workflow
- R2. ProblemSolution reframe — problem is friction, not lost clipboard
- R3. Bento card descriptions as journeys — what you accomplish, not what the tech does
- R4. Competitor differentiation through copy — unique capabilities feel natural
- R5. Maintain accuracy — no fictional features

## Scope Boundaries

- Copy and text content only — no CSS, layout, or structural changes
- Bento card mockup visuals stay as-is — only titles and descriptions change
- SpeedPrivacy section stays as-is — trust messaging is distinct from feature narrative
- No new sections or pages

## Key Technical Decisions

- **Keep the headline short and punchy** — one line, not a paragraph. The subtitle does the explaining.
- **Don't use jargon in card descriptions** — "FTS5" means nothing to a designer. "Find anything instantly" does.
- **Frame each bento card as a eliminated workflow** — "Record → trim → paste. No QuickTime needed." rather than "Record any region of your screen as MP4."

## Implementation Units

- [ ] **Unit 1: Rewrite Hero headline and subtitle**

**Goal:** Replace "Your clipboard, with a memory" with a headline that positions Drobu as a content workflow tool

**Requirements:** R1, R5

**Dependencies:** None

**Files:**
- Modify: `website/src/components/Hero.astro`

**Approach:**
- New headline should communicate "content flows through Drobu" not "Drobu stores your clipboard"
- Subtitle should mention the capture → edit → paste journey and the reduction of cognitive load
- Keep the CTA and pricing line unchanged

**Test expectation:** none — pure copy

**Verification:**
- Headline communicates workflow, not storage
- Subtitle mentions the content journey

---

- [ ] **Unit 2: Rewrite ProblemSolution section**

**Goal:** Reframe the problem from "lost clipboard items" to "too many steps between having content and using it"

**Requirements:** R2, R4, R5

**Dependencies:** None

**Files:**
- Modify: `website/src/components/ProblemSolution.astro`

**Approach:**
- Left side (problem): Frame as friction — switching apps, exporting, managing files, too many steps
- Right side (solution): Frame as Drobu collapsing those steps — capture, edit, paste, done
- Keep the punchy two-column layout

**Test expectation:** none — pure copy

**Verification:**
- Problem side describes workflow friction, not lost clipboard
- Solution side describes collapsed workflow

---

- [ ] **Unit 3: Rewrite all bento card titles and descriptions**

**Goal:** Transform feature descriptions into journey/outcome descriptions

**Requirements:** R3, R4, R5

**Dependencies:** None

**Files:**
- Modify: `website/src/components/BentoGrid.astro`

**Approach:**
Rewrite each card's title and description. Keep titles concise (2-4 words). Descriptions answer "what workflow does this eliminate?"

Current → New direction for each card:
1. **Instant search** — "FTS5 full-text search finds anything as you type" → emphasize finding any past content without remembering when you copied it
2. **Slash commands** — "Type / for built-in commands" → emphasize controlling your Mac without leaving the flow
3. **Images & GIFs** — "Not just text. Drobu captures images and GIFs with full preview" → emphasize visual content captured and ready to reuse
4. **Video screen capture** — "Record any region of your screen as MP4" → emphasize record → trim → paste without QuickTime
5. **GIF screen capture** — "Record any region... as a GIF" → emphasize capture a moment → trim frames → share in seconds
6. **Keyboard-first** — "Navigate, select, and paste without touching the mouse" → emphasize everything stays in flow, no context switching
7. **Content filtering** — "Filter your history by type" → emphasize jump to the exact content type you need
8. **Multi-select paste** — "Select multiple items with Shift, paste them all at once" → emphasize combining content without opening a text editor
9. **Source app tracking** — "Every clip shows which app it came from" → emphasize always knowing where content originated

**Test expectation:** none — pure copy

**Verification:**
- Each card reads as "what you accomplish" not "what the technology does"
- No jargon (FTS5, SHA-256, etc.)
- All descriptions are accurate to current app capabilities

---

- [ ] **Unit 4: Update DownloadCTA subtitle**

**Goal:** Align CTA messaging with the content journey narrative

**Requirements:** R1, R5

**Dependencies:** None

**Files:**
- Modify: `website/src/components/DownloadCTA.astro`

**Approach:**
- Update the subtitle to reinforce the content workflow value prop
- Keep "Try Drobu today" headline and CTA button unchanged

**Test expectation:** none — pure copy

**Verification:**
- CTA subtitle echoes the content journey theme
- Build passes

---

- [ ] **Unit 5: Build verification**

**Goal:** Ensure the build passes and no placeholder text remains

**Requirements:** R5

**Dependencies:** Units 1-4

**Files:**
- None — verification only

**Verification:**
- `npm run build` exits 0
- No stale copy references to "clipboard history that remembers" or similar

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Copy feels too abstract / marketing-speak | Ground every description in a concrete action the user takes. "Record → trim → paste" not "seamless content workflow." |
| Visitors don't understand what the app does | Keep the hero subtitle concrete — mention clipboard, capture, paste. The reframe is about story, not obscuring function. |

## Sources & References

- Origin document: `docs/brainstorms/2026-04-11-landing-page-content-journey-reframe-requirements.md`
- Current landing page: `website/src/components/Hero.astro`, `website/src/components/ProblemSolution.astro`, `website/src/components/BentoGrid.astro`, `website/src/components/DownloadCTA.astro`
- Product vision: Drobu is a content action platform, not just clipboard history (see memory: `project_value_proposition.md`)
