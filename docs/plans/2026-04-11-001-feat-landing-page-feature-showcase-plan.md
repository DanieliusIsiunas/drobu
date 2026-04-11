---
title: "feat: Enhance landing page with full feature showcase and CSS mockups"
type: feat
status: active
date: 2026-04-11
---

# Enhance Landing Page with Full Feature Showcase and CSS Mockups

## Overview

The Drobu landing page has the right structure but underrepresents the app's capabilities. The hero shows a placeholder ("App demo video coming soon"), all 6 bento cards have placeholder content, the #workflow section is empty (but linked in nav), and major features like video capture, Live Text, content filtering, inline editing, and the full slash command system are absent. This plan replaces placeholders with CSS-generated app UI mockups, adds missing features, and removes dead sections.

## Problem Frame

A visitor currently sees a well-designed shell with no substance in the feature cards. Every bento card shows "Preview" or placeholder text instead of demonstrating the feature. The hero's app preview is a mascot image with "App demo video coming soon." For a $9.99/mo product, this undermines trust and conversion — users can't see what they're paying for.

Additionally, several differentiating features are completely absent from the page:
- **Video capture** (5-minute screen recording with region select + trim)
- **Live Text** (VisionKit text selection in image previews)
- **Content type filtering** (All/Text/Image/GIF/Video/File tabs)
- **Inline text editing** (edit clips directly in preview)
- **Source app tracking** (shows which app each clip came from)
- **Keyboard-first design** (Cmd+1-9, arrow nav, Shift multi-select)
- **Closed Lid mode** (keep Mac running with lid closed — requires admin)

## Requirements Trace

- R1. Replace hero placeholder with a CSS mockup of the actual app UI
- R2. Replace all bento card placeholders with CSS-rendered feature demonstrations
- R3. Add missing features to the bento grid (video capture, Live Text, content filtering, keyboard shortcuts)
- R4. Remove the empty #workflow section and its nav link
- R5. Update copy across all sections to accurately represent the full feature set
- R6. Maintain existing dark theme, coral accent, Geist font, and responsive behavior
- R7. No external assets required — all visuals are CSS/HTML generated

## Scope Boundaries

- No real screenshots or video assets — everything is CSS mockups
- No JavaScript animations or interactivity (keep zero-JS Astro philosophy)
- No pricing model changes
- No new pages (terms, privacy, thank-you already exist)
- No Astro/Tailwind version changes

### Deferred to Separate Tasks

- Real app screenshots/video: requires screen recording workflow, separate effort
- Testimonials/social proof: no testimonials exist yet
- Analytics/conversion tracking: separate infrastructure concern
- WorkflowDemo GSAP section: was never built, removing rather than building

## Context & Research

### Relevant Code and Patterns

- `website/src/components/BentoCard.astro` — card component with `size` prop (small/medium/large), slot for visual content
- `website/src/components/BentoGrid.astro` — 3-column grid with 6 cards
- `website/src/components/Hero.astro` — uses `MacWindow.astro` wrapper for app preview
- `website/src/components/MacWindow.astro` — reusable macOS traffic-light frame
- `website/src/styles/global.css` — design tokens: `--color-bg-primary: #0a0a0a`, `--color-accent: #d4715e`, chroma palette
- `website/src/components/SpeedPrivacy.astro` — 2x2 card grid with SVG icons
- Actual app UI: split panel (340px list left, preview right), 780px wide, 11 visible rows at 32px each, search bar at top

### App UI Structure (for CSS mockups)

From `Sources/DrobuCore/Views/PanelView.swift`:
- Panel: 780px wide, search bar + split view (list 340px | preview)
- Rows: source app icon + text preview + shortcut label (Cmd+1 through Cmd+9)
- Content types: text, image, GIF, video, file
- Filter tabs: All | Text | Image | GIF | Video | File
- Preview panel: text with metadata bar, image with dimensions, GIF with frame count

From `Sources/DrobuCore/Views/ClipboardRowView.swift`:
- Row height: 32px
- HStack: app icon (24x24) + content + shortcut kbd

## Key Technical Decisions

- **CSS mockups over screenshots**: Mockups scale perfectly, match the dark theme, and load instantly. Real screenshots would require asset pipeline and may look blurry at different DPIs.
- **Expand bento grid from 6 to 8 cards**: Adding video capture and keyboard shortcuts as dedicated cards. Restructure grid layout to accommodate.
- **Remove #workflow section entirely**: It was never built (empty div with a comment). Remove the nav link too. Better to have a tight page than a dead link.
- **Hero mockup shows the actual panel layout**: A CSS recreation of the split-panel UI with search bar, clipboard rows, and preview — gives visitors an immediate "this is the app" moment.
- **Keep BentoCard component interface**: Extend the slot content with richer HTML instead of changing the component contract. Add a new `xlarge` size for full-width cards.

## Open Questions

### Resolved During Planning

- **Should we add a keyboard shortcuts section separate from bento?** No — a bento card with a keyboard grid mockup is sufficient. A separate section would lengthen the page unnecessarily.
- **Should slash commands get their own card or stay combined?** Keep one card but update copy to mention both Keep Awake and Closed Lid modes specifically.

### Deferred to Implementation

- Exact row content for the hero mockup (which fake clipboard entries to show) — implementer should pick representative examples (code snippet, image thumbnail, URL, etc.)
- Whether the filter tabs mockup needs all 6 tabs or just a representative subset

## Implementation Units

- [ ] **Unit 1: Remove dead #workflow section and nav link**

**Goal:** Clean up the empty workflow section and its navigation reference

**Requirements:** R4

**Dependencies:** None

**Files:**
- Modify: `website/src/pages/index.astro`
- Modify: `website/src/components/Header.astro`

**Approach:**
- Delete the `<div id="workflow">` from index.astro
- Remove the "How it works" nav link from Header.astro (it pointed to #workflow)

**Patterns to follow:**
- Existing nav link array pattern in Header.astro

**Test expectation:** none — pure markup removal

**Verification:**
- Nav has 3 links (Features, Privacy, Download)
- No #workflow anchor on the page
- `npm run build` succeeds in `website/`

---

- [ ] **Unit 2: Build CSS app mockup for Hero section**

**Goal:** Replace the placeholder hero preview with a CSS-rendered mockup of Drobu's actual panel UI

**Requirements:** R1, R6, R7

**Dependencies:** None

**Files:**
- Modify: `website/src/components/Hero.astro`

**Approach:**
- Inside the existing `MacWindow` wrapper, replace the placeholder div with a CSS mockup that recreates the app's split-panel layout:
  - Search bar at top with magnifying glass icon and "Search clipboard..." placeholder
  - Left panel: 5-6 clipboard rows with source app icons (use emoji or simple SVG circles), text previews, and Cmd+N shortcut badges
  - Right panel: preview of the "selected" item (a code snippet or text block with metadata bar showing source app and timestamp)
  - Filter tabs row below search: All | Text | Image | GIF (All highlighted with accent color)
- Use existing design tokens (bg-elevated, bg-card, text-primary, text-secondary, accent)
- The mockup should include varied content types in the rows: a code snippet, a URL, plain text, an image thumbnail (colored rectangle), a file path

**Patterns to follow:**
- MacWindow.astro wrapper (traffic-light title bar)
- Tailwind utility classes used throughout the site
- Actual app dimensions: search bar, list rows at ~32px height, split layout

**Test expectation:** none — pure visual/HTML

**Verification:**
- Hero shows a realistic app mockup instead of "App demo video coming soon"
- Mockup is responsive (stacks or scales on mobile)
- Dark theme colors match the site

---

- [ ] **Unit 3: Create rich CSS mockup content for existing bento cards**

**Goal:** Replace all 6 existing bento card placeholders with CSS-generated visual demonstrations

**Requirements:** R2, R6, R7

**Dependencies:** None

**Files:**
- Modify: `website/src/components/BentoGrid.astro`
- Modify: `website/src/components/BentoCard.astro`

**Approach:**

For each existing card, replace the `<Fragment slot="placeholder">` with inline HTML/CSS that visually demonstrates the feature:

1. **Instant search** (large): Mockup of search bar with "api" typed, showing 3 filtered results highlighted with matching text. Show the FTS5 speed visually.
2. **Global hotkey** (medium): Keep the kbd elements but add a subtle animated pulse or glow around them. Add a mini app-switch visual context (browser -> Drobu panel appearing).
3. **Images & GIFs** (medium): Show a mini preview panel with an image thumbnail and metadata (dimensions, file size). Include a GIF indicator with frame count.
4. **Multi-select paste** (small): Show 3 rows with 2 highlighted in accent color, with a visual "paste" indicator showing combined output.
5. **Slash commands** (small): Show a mini command palette with `/sleep` typed and "Keep Awake" and "Closed Lid" options visible. Update description to mention both modes.
6. **GIF screen capture** (medium): Show a region-selection overlay mockup with crosshair cursor and recording indicator dot.

Update the BentoCard component:
- Remove the generic "Preview" text from the default placeholder slot
- The aspect-video container should be the full visual area

**Patterns to follow:**
- Existing BentoCard slot pattern
- Design tokens from global.css
- Actual app UI structure from source code

**Test expectation:** none — pure visual/HTML

**Verification:**
- All 6 cards show visual content instead of placeholder text
- Visual mockups are recognizable representations of the features
- Cards maintain hover effects and responsive layout

---

- [ ] **Unit 4: Add new bento cards for missing features**

**Goal:** Add cards for video capture, content type filtering, keyboard navigation, and Live Text/inline editing

**Requirements:** R3, R5, R6, R7

**Dependencies:** Unit 3 (BentoCard component may be modified)

**Files:**
- Modify: `website/src/components/BentoGrid.astro`
- Modify: `website/src/components/BentoCard.astro`

**Approach:**

Add 4 new cards to the bento grid, restructuring the layout to fit 10 cards in a visually balanced 3-column grid:

1. **Video screen capture** (medium): Region selection with recording timer showing "02:34", trim timeline mockup. Description: "Record any region of your screen as MP4. Up to 5 minutes, with a built-in trim editor."
2. **Content filtering** (small): Row of filter tabs (All, Text, Image, GIF, Video, File) with "Image" highlighted, showing filtered results below.
3. **Keyboard-first** (medium): A grid of keyboard shortcuts — Cmd+1-9 for quick paste, arrow keys, Shift+arrows for multi-select, Return to paste, / for commands. Style as a mini cheat-sheet.
4. **Source app tracking + inline editing** (small): Show a clipboard row with an app icon and "from Safari" label, plus an edit indicator showing text being modified in the preview.

Add `xlarge` size class to BentoCard (full 3-column span) if needed for the keyboard shortcuts card.

Restructure the grid layout:
- Row 1: Instant search (large, 2-col) + Global hotkey (medium, 1-col)
- Row 2: Images & GIFs (medium) + Video capture (medium) + GIF capture (medium)
- Row 3: Keyboard-first (large, 2-col) + Slash commands (medium)
- Row 4: Content filtering (medium) + Multi-select (medium) + Source tracking & edit (medium)

**Patterns to follow:**
- Existing BentoCard sizes and grid layout
- Copy tone: concise, feature-focused, no marketing fluff

**Test expectation:** none — pure visual/HTML

**Verification:**
- 10 bento cards visible in a balanced grid
- All major app features are represented
- Grid is responsive (collapses to single column on mobile)

---

- [ ] **Unit 5: Update SpeedPrivacy section and overall copy**

**Goal:** Improve the trust/speed section and update copy across the page to reflect the full feature set

**Requirements:** R5, R6

**Dependencies:** None

**Files:**
- Modify: `website/src/components/SpeedPrivacy.astro`
- Modify: `website/src/components/Hero.astro`
- Modify: `website/src/components/ProblemSolution.astro`
- Modify: `website/src/components/DownloadCTA.astro`

**Approach:**

SpeedPrivacy updates:
- Keep all 4 existing cards (local/private, SQLite+FTS5, password manager ignored, auto-cleanup)
- Update "SQLite + FTS5 in milliseconds" description to mention the instant-as-you-type search experience
- Add a 5th card: **"Keyboard-first design"** — "Navigate, select, and paste without touching the mouse. Cmd+1-9 for quick paste, arrow keys for browsing, Shift for multi-select." (or fold this into the bento card if it's already well-covered there — implementer's call)
- Add a 6th card: **"Deduplication"** — "Copy the same thing twice? Drobu moves it to the top instead of creating a duplicate. SHA-256 content hashing keeps your history clean."

Hero copy update:
- Change subtitle to better reflect breadth: "Drobu keeps everything you copy — text, images, GIFs, videos, files — and lets you find it instantly. Search, preview, paste — in one keystroke."

ProblemSolution: Keep as-is — the copy is punchy and effective.

DownloadCTA: Keep structure, but update subtitle to "14-day free trial. All features included." to emphasize there's no tier gating.

**Patterns to follow:**
- SpeedPrivacy card structure (SVG icon + title + description)
- Existing copy tone — concise, no superlatives

**Test expectation:** none — pure copy and markup

**Verification:**
- SpeedPrivacy has 6 cards in a balanced grid (3x2)
- Hero subtitle mentions the full range of content types
- All copy is accurate to the app's actual capabilities
- `npm run build` succeeds

---

- [ ] **Unit 6: Final build verification and responsive check**

**Goal:** Ensure the full page builds, looks correct at different breakpoints, and has no broken links

**Requirements:** R6

**Dependencies:** Units 1-5

**Files:**
- No new files — verification only

**Approach:**
- Run `npm run build` in `website/` to ensure static build succeeds
- Run `npm run dev` and check the page at desktop (1440px), tablet (768px), and mobile (375px)
- Verify all nav links point to valid anchors
- Verify the CTA buttons still link to the Stripe payment link
- Check that no placeholder text ("Preview", "coming soon", "demo") remains

**Test expectation:** none — manual verification

**Verification:**
- `npm run build` exits 0
- No placeholder text visible on the page
- Responsive layout works at all breakpoints
- All links functional

## System-Wide Impact

- **Interaction graph:** Changes are website-only. No impact on the Swift app, build.sh, or any app functionality.
- **Error propagation:** N/A — static site.
- **State lifecycle risks:** None.
- **API surface parity:** N/A.
- **Integration coverage:** N/A.
- **Unchanged invariants:** Stripe payment link, GitHub Pages deployment, privacy/terms/thank-you pages, meta tags, structured data, favicon, OG image all remain unchanged.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| CSS mockups look generic/AI-sloppy | Base mockups on actual app UI dimensions and structure from source code. Use the real design tokens. |
| 10 bento cards may feel overwhelming | Group visually by row with clear rhythm. If too many, the implementer can merge "Source tracking" and "Content filtering" into one card. |
| Responsive breakpoints may break with more cards | Test at 375px, 768px, 1440px. The grid already collapses to 1-col on mobile. |
| Hero mockup may not look "real" enough | Focus on layout accuracy (split panel, search bar, row structure) rather than pixel-perfect fidelity. The structure communicates "this is a real app." |

## Sources & References

- Prior plan: `docs/plans/2026-03-11-feat-drobu-landing-page-plan.md`
- Prior plan: `docs/plans/2026-03-12-feat-paid-product-landing-page-plan.md`
- App panel UI: `Sources/DrobuCore/Views/PanelView.swift` (layout constants, panel dimensions)
- App row UI: `Sources/DrobuCore/Views/ClipboardRowView.swift` (row structure, 32px height)
- App settings: `Sources/DrobuCore/Views/SettingsView.swift` (configurable hotkeys, retention)
- Slash commands: `Sources/DrobuCore/Services/SleepCommand.swift` (Keep Awake + Closed Lid)
- Screen capture: `Sources/DrobuCore/Services/ScreenCaptureService.swift` (GIF, 15s max)
- Video capture: `Sources/DrobuCore/Services/VideoCaptureService.swift` (MP4, 5min max)
- Content types: `Sources/DrobuCore/Models/ClipboardRecord.swift` (text/image/gif/video/file)
