---
title: "feat: Build Drobu Landing Page"
type: feat
date: 2026-03-11
---

# Build Drobu Landing Page

## Overview

Create a dark, premium landing page for Drobu — a macOS menu bar clipboard history manager — that showcases actual app functionality through video demos, scroll-driven animations, and interactive elements. The page should feel distinctive and app-authentic, not template-generic.

**Stack:** Astro 5 + React islands + Tailwind CSS v4 + GSAP ScrollTrigger
**Hosting:** GitHub Pages (via GitHub Actions)
**Location:** `/website` directory at repo root

## Problem Statement

Drobu has no web presence. The GitHub repo is named `clipboard-history` (legacy), has no README, and provides no way for potential users to discover, evaluate, or download the app. The existing Drobule mascot and coral brand identity have no public-facing expression.

## Proposed Solution

A single-page dark-themed landing page with six sections: hero, problem/solution, bento feature grid, scroll-driven workflow demo, speed & privacy callout, and download CTA. The page prioritizes showing the real app UI over describing features with text.

---

## Technical Approach

### Architecture

```
clipboard-history/
├── website/                    # Astro project (new)
│   ├── astro.config.mjs
│   ├── tailwind.config.ts      # Tailwind v4 via @tailwindcss/vite
│   ├── tsconfig.json
│   ├── package.json
│   ├── public/
│   │   ├── favicon.svg         # Drobule silhouette
│   │   ├── og-image.png        # 1200x630 social preview
│   │   ├── videos/
│   │   │   ├── hero-demo.webm  # Core workflow loop (<5MB)
│   │   │   └── hero-demo.mp4   # Fallback (<8MB)
│   │   └── fonts/
│   │       └── geist/          # Self-hosted Geist variable font
│   └── src/
│       ├── layouts/
│       │   └── Landing.astro   # Base layout: dark theme, meta, fonts
│       ├── pages/
│       │   └── index.astro     # Composes all sections
│       ├── components/
│       │   ├── Header.astro        # Sticky nav: logo + section links + GitHub
│       │   ├── Hero.astro          # Tagline + video in macOS frame + CTA
│       │   ├── ProblemSolution.astro
│       │   ├── BentoGrid.astro     # 4-6 feature cards
│       │   ├── BentoCard.astro     # Individual card with video/image
│       │   ├── WorkflowDemo.tsx    # React island: GSAP ScrollTrigger pinned section
│       │   ├── SpeedPrivacy.astro
│       │   ├── DownloadCTA.astro   # Platform detection + download links
│       │   ├── Footer.astro        # GitHub link, version, copyright
│       │   └── MacWindow.astro     # Reusable macOS window frame component
│       └── styles/
│           └── global.css          # Tailwind v4 import + custom properties
├── .github/
│   └── workflows/
│       └── deploy-website.yml  # Build Astro → deploy to gh-pages
├── Sources/                    # Existing Swift code (unchanged)
└── ...
```

**Key decisions:**
- Astro static output (no SSR) — required for GitHub Pages
- Only one React island: `WorkflowDemo.tsx` for GSAP ScrollTrigger interactivity
- Everything else is `.astro` (zero JS shipped for those sections)
- Tailwind v4 via `@tailwindcss/vite` plugin (not `@astrojs/tailwind` which is v3)
- Geist font self-hosted with `font-display: swap` and Latin subset only

### Design Tokens

```css
/* website/src/styles/global.css */
:root {
  /* Backgrounds */
  --bg-primary: #0a0a0a;
  --bg-elevated: #141414;
  --bg-card: #1a1a1a;

  /* Text */
  --text-primary: #e5e5e5;
  --text-secondary: #a0a0a0;
  --text-muted: #666666;

  /* Brand — coral/terracotta from Drobule mascot */
  --accent: #D4715E;
  --accent-hover: #E0826F;

  /* Chroma palette from app's ChromaSweepBorder */
  --chroma-pink: #C679C4;
  --chroma-red-orange: #FA3D1D;
  --chroma-amber: #FFB005;
  --chroma-lavender: #E1E1FE;
  --chroma-blue: #0358F7;
}
```

**Contrast notes:**
- `--text-primary` (#e5e5e5) on `--bg-primary` (#0a0a0a) = 16.7:1 (WCAG AAA)
- `--accent` (#D4715E) on `--bg-primary` (#0a0a0a) = ~4.5:1 (WCAG AA for normal text, fails AAA)
- Use `--accent` only for large text (headings), interactive elements, and decorative purposes — never for body text

---

## Implementation Phases

### Phase 1: Foundation (scaffold + deploy pipeline)

Set up the Astro project, dark theme, font loading, GitHub Actions deployment, and verify a blank page deploys to GitHub Pages.

**Tasks:**
- [ ] `website/`: Initialize Astro 5 project with `npm create astro@latest`
- [ ] Install dependencies: `@astrojs/react`, `@tailwindcss/vite`, `gsap`
- [ ] `website/astro.config.mjs`: Configure static output, `site` URL, `base` path (see Open Questions Q1)
- [ ] `website/src/styles/global.css`: Design tokens, Geist font-face declarations, Tailwind v4 import
- [ ] `website/src/layouts/Landing.astro`: HTML boilerplate with dark background, meta tags, OG tags, font preloads
- [ ] `website/public/favicon.svg`: Convert Drobule silhouette to SVG favicon
- [ ] `website/public/og-image.png`: Create 1200x630 social preview (Drobule + tagline on dark background)
- [ ] `.github/workflows/deploy-website.yml`: Astro build → deploy to `gh-pages` branch
- [ ] Verify deployment: blank dark page live at GitHub Pages URL

**Success criteria:**
- `npm run build` succeeds in `/website`
- GitHub Actions workflow deploys on push to `main`
- Page loads with dark background, correct font, valid meta tags
- Lighthouse performance > 95

**Estimated effort:** Small

### Phase 2: Static Sections (hero + content sections without video/animation)

Build all six sections with placeholder content, responsive layout, and proper semantic HTML. No videos or GSAP yet — static images and text only.

**Tasks:**
- [ ] `Header.astro`: Sticky header with backdrop-blur, Drobule logo, section anchor links, GitHub icon link
- [ ] `MacWindow.astro`: Reusable component — macOS-style window chrome (rounded corners, traffic light dots, title bar) that wraps a `<slot>` for content (images, videos, or other components)
- [ ] `Hero.astro`: Headline + subheadline + download CTA button + `MacWindow` with a static screenshot placeholder
  - Headline: "Your clipboard, with a memory."
  - Subheadline: "Drobu keeps everything you copy and lets you find it instantly."
  - Platform detection: show "Download for macOS" on Mac, "Available on macOS" + GitHub link on other platforms
  - Display macOS 14+ requirement in small text
- [ ] `ProblemSolution.astro`: Two-column or stacked layout
  - Left/top: "You copied it. Then you copied something else. Now it's gone."
  - Right/bottom: "Drobu remembers. Search, preview, paste — in one keystroke."
- [ ] `BentoGrid.astro` + `BentoCard.astro`: Asymmetric grid (CSS Grid, not Flexbox)
  - Card 1 (large): Instant search — FTS5 finds anything as you type
  - Card 2 (medium): Global hotkey — Cmd+Shift+V from any app
  - Card 3 (medium): Image & GIF history — not just text
  - Card 4 (small): Multi-select paste — combine multiple items
  - Card 5 (small): Slash commands — /sleep to keep your Mac awake
  - Card 6 (medium): GIF screen capture — record any region as GIF
  - Each card: headline, one-line description, placeholder image area, hover lift effect
  - Responsive: 3-column → 2-column (tablet) → 1-column (mobile)
- [ ] `SpeedPrivacy.astro`: Centered text section with accent highlights
  - "Everything stays on your Mac."
  - "No cloud. No account. No tracking."
  - "SQLite + FTS5 search in milliseconds."
  - "Password managers automatically ignored."
- [ ] `DownloadCTA.astro`: Repeat download button + system requirements + Gatekeeper bypass note
  - "If macOS shows a security warning, right-click the app and choose Open."
  - Link to GitHub releases page
  - Version number (v1.0)
- [ ] `Footer.astro`: GitHub link, "Built with Swift & SwiftUI", copyright, version
- [ ] Responsive breakpoints: mobile (<768px), tablet (768-1024px), desktop (>1024px)
- [ ] `prefers-reduced-motion` media query: disable all transitions/animations
- [ ] Skip navigation link for keyboard users
- [ ] All images have alt text

**Success criteria:**
- Full page renders with all 6 sections + header + footer
- Responsive at all three breakpoints
- No horizontal scroll on any viewport
- Keyboard navigation works (Tab through all interactive elements)
- Lighthouse accessibility > 95

**Estimated effort:** Medium

### Phase 3: Media Assets (record demos, create visuals)

Record actual app demos, compress to WebM/MP4, create bento card visuals.

**Tasks:**
- [ ] Record hero demo video: open panel with hotkey → type search → select result → paste (3-5 seconds, looping)
- [ ] Record bento card clips (3 seconds each):
  - Search: typing in search field with results filtering live
  - Image history: scrolling through image items with preview panel
  - GIF capture: selecting a region and recording a GIF
  - Multi-select: shift-selecting multiple items and pasting
- [ ] Compress all recordings: WebM VP9 (primary, <2MB each) + MP4 H.264 (fallback, <3MB each)
  - Target resolution: 1280x800 (or match actual panel dimensions at 2x)
  - Use `ffmpeg` for encoding
- [ ] Create transparent Drobule PNG/SVG for web (current PNG has white background)
- [ ] Create `og-image.png`: 1200x630, dark background, Drobule + headline + app screenshot
- [ ] Integrate videos into Hero and BentoCards: `<video autoplay muted loop playsinline>` with `<source>` fallbacks
- [ ] Lazy load below-fold videos with `loading="lazy"` or Intersection Observer
- [ ] Test video playback on Safari, Chrome, Firefox

**Success criteria:**
- Hero video loads and loops on all major browsers
- Total page weight < 15MB (all videos included)
- First contentful paint < 1.5s on broadband
- Videos play on Safari (WebM or MP4 fallback)

**Estimated effort:** Medium (mostly recording + compression, not code)

### Phase 4: Scroll-Driven Workflow Demo (GSAP)

Build the pinned scroll section that steps through the copy → search → paste workflow.

**Tasks:**
- [ ] `WorkflowDemo.tsx`: React island component with `client:visible` directive
  - GSAP ScrollTrigger: pin the `MacWindow` frame in viewport center
  - 5 scroll steps, each covering ~100vh of scroll distance:
    1. Copy text from a browser (show browser + copy action)
    2. Copy an image from another app
    3. Press hotkey — Drobu panel appears (inside the MacWindow)
    4. Type search query — results filter
    5. Select and paste — panel closes, text appears in target app
  - Each step: explanatory text fades in on left/right side alongside the pinned visual
  - Transition between steps: crossfade (opacity) the MacWindow content
  - Total pinned scroll height: ~500vh
- [ ] Content for each step: pre-rendered screenshot or short video segment
- [ ] Mobile fallback (<768px): replace pinned section with simple vertical sequence
  - Each step displayed as: image/video + text, stacked vertically
  - No GSAP on mobile — pure CSS
- [ ] `prefers-reduced-motion`: disable pinning, show all steps statically
- [ ] JS-disabled fallback: show all 5 steps as a static image grid (Astro renders the HTML, GSAP just doesn't enhance it)

**Success criteria:**
- Smooth 60fps scroll on desktop Chrome and Safari
- No "stuck" feeling — scroll always progresses even during pinned section
- Mobile shows all 5 steps without GSAP
- Reduced motion users see static content
- No layout shift when GSAP initializes

**Estimated effort:** Large (GSAP pinning is the most complex part of the page)

### Phase 5: Polish & Launch

Final refinements, SEO, analytics decision, and launch.

**Tasks:**
- [ ] SEO: `<title>Drobu — Clipboard History for macOS</title>`, meta description, canonical URL
- [ ] Structured data: JSON-LD `SoftwareApplication` schema (name, OS, price: Free, screenshot)
- [ ] Test OG tags with Facebook Sharing Debugger and Twitter Card Validator
- [ ] Performance audit: Lighthouse all-green, total page weight within budget
- [ ] Cross-browser test: Safari 17+, Chrome, Firefox, Arc
- [ ] Add smooth scroll behavior for header nav links
- [ ] Subtle entry animations for sections (CSS `@keyframes` fade-in on scroll, using `animation-timeline: view()` with fallback)
- [ ] Bento card hover micro-interactions (scale, shadow lift)
- [ ] Review all copy for tone consistency
- [ ] Decision: analytics (Plausible/Umami) or none (see Open Questions Q5)
- [ ] Update GitHub repo description and add homepage URL
- [ ] Create a `README.md` for the repo linking to the landing page

**Success criteria:**
- Lighthouse: Performance > 95, Accessibility > 95, SEO > 95, Best Practices > 95
- OG/Twitter cards render correctly when shared
- Page loads under 3 seconds on 3G throttle (excluding video)
- All interactive elements have visible focus states

**Estimated effort:** Small-Medium

---

## Open Questions (Require Decision Before Implementation)

### Q1. URL and Domain

The repo is `clipboard-history`, so GitHub Pages would serve at `danieliusisiunas.github.io/clipboard-history/`. This doesn't match "Drobu" at all.

**Options:**
- (a) Accept the mismatch for now, set Astro `base: '/clipboard-history/'`
- (b) Register a custom domain (e.g., `drobu.app`, `getdrobu.com`) and point it at GitHub Pages
- (c) Rename the GitHub repo to `drobu`

**Recommendation:** (a) for launch, (b) as a follow-up. Repo rename is disruptive.

### Q2. Distribution Pipeline

The landing page needs something to download. Currently:
- No `.dmg` build step (only `.app` bundle)
- No GitHub Releases
- No Homebrew cask
- No Apple notarization (self-signed `ClipboardHistoryDev` cert)

**Required before launch:**
- [ ] Add `hdiutil create` or `create-dmg` step to `build.sh`
- [ ] Create a GitHub Release with the `.dmg` attached
- [ ] Download CTA links to `https://github.com/DanieliusIsiunas/clipboard-history/releases/latest`

**Deferred (post-launch):**
- Homebrew cask (omit `brew install` from page until this exists)
- Apple notarization ($99/year Developer Program)

### Q3. Non-macOS Visitors

~25-30% of developer traffic is Windows/Linux.

**Recommendation:** Show download button grayed out with "macOS only" label. Below it, show "Star on GitHub" as an alternative action. Do not show a fake `brew install` command.

### Q4. Dark Mode Only vs. System Preference

**Recommendation:** Dark-only. The app is dark, the brand is dark, and respecting `prefers-color-scheme: light` would require designing an entire second theme for minimal gain. Add `<meta name="color-scheme" content="dark">` to tell the browser.

### Q5. Analytics

For a privacy-focused app, tracking visitors is philosophically awkward.

**Options:**
- (a) No analytics (consistent with the privacy message)
- (b) Plausible Analytics (privacy-respecting, no cookies, GDPR-compliant, $9/month)
- (c) GitHub API download count only (free, no tracking)

**Recommendation:** (a) for launch. Add (c) as a badge later if curious about download numbers.

### Q6. Gatekeeper Bypass

Un-notarized apps show "can't be opened because Apple cannot check it for malicious software."

**Recommendation:** Include a small expandable FAQ section near the download CTA:
> **macOS shows a security warning?**
> Right-click the app, choose "Open", then click "Open" in the dialog. This only happens once because Drobu isn't notarized yet.

---

## Alternative Approaches Considered

### Next.js instead of Astro
Rejected. Next.js ships a React runtime (~45KB) even for static pages. Astro ships zero JS for static sections and only hydrates islands. For a marketing page with one interactive section, Astro is strictly better.

### Framer / Webflow (no-code)
Rejected. The user wants authentic, non-generic design. No-code tools produce recognizable template aesthetics and limit control over scroll-driven animations and custom components.

### Separate repository for the website
Rejected. Keeping it in `/website` within the main repo simplifies deployment (single GitHub Actions workflow), keeps assets close to the app code, and avoids repo proliferation.

### Framer Motion instead of GSAP
Rejected for the scroll-driven section. Framer Motion lacks true timeline scrubbing and pinning. GSAP ScrollTrigger is the industry standard for this specific pattern (Apple, Linear, Stripe all use it or similar).

---

## Acceptance Criteria

### Functional Requirements
- [ ] Landing page loads at GitHub Pages URL
- [ ] All six content sections render correctly
- [ ] Download button links to a working GitHub Release (Phase 5 blocker: Q2 must be resolved)
- [ ] Platform detection shows appropriate CTA for macOS vs. other platforms
- [ ] Hero video autoplays and loops on Safari, Chrome, Firefox
- [ ] GSAP scroll-driven workflow demo works on desktop
- [ ] Mobile layout is fully responsive at all breakpoints
- [ ] Keyboard navigation works throughout the page
- [ ] OG/Twitter card metadata renders correct previews when shared

### Non-Functional Requirements
- [ ] Lighthouse Performance > 95
- [ ] Lighthouse Accessibility > 95
- [ ] Lighthouse SEO > 95
- [ ] First Contentful Paint < 1.5s on broadband
- [ ] Total page weight < 15MB (videos included)
- [ ] Zero JS shipped for static sections (only WorkflowDemo.tsx hydrates)

### Quality Gates
- [ ] Cross-browser tested: Safari 17+, Chrome, Firefox, Arc
- [ ] Responsive tested: 375px, 768px, 1024px, 1440px viewports
- [ ] `prefers-reduced-motion` tested: all animations disabled
- [ ] JS-disabled tested: page is usable (static content renders, no broken sections)
- [ ] All images have descriptive alt text
- [ ] Color contrast meets WCAG AA for all text

---

## Dependencies & Prerequisites

| Dependency | Status | Blocks |
|---|---|---|
| Astro 5 + Tailwind v4 + GSAP | Available (npm) | Phase 1 |
| Geist font files | Available (github.com/vercel/geist-font) | Phase 1 |
| Transparent Drobule PNG/SVG | **Needs creation** | Phase 2 (hero) |
| App demo video recordings | **Needs creation** | Phase 3 |
| `.dmg` build pipeline | **Needs creation** | Phase 5 (download CTA) |
| GitHub Release with `.dmg` | **Needs creation** | Phase 5 (download CTA) |
| GitHub Actions setup | No existing workflows | Phase 1 |

---

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| GSAP ScrollTrigger broken on iOS Safari | Medium | High | Mobile fallback: static vertical sequence, no pinning |
| Video files too large, slow page load | Medium | High | Strict budget: <2MB per WebM, lazy load below-fold |
| GitHub Pages `base` path breaks asset URLs | Medium | Medium | Test deployment early in Phase 1 before building content |
| WebM not playing on older Safari | Low | Medium | MP4 fallback via `<source>` element |
| Astro/Tailwind v4 integration issues | Low | Medium | Both are stable; use `@tailwindcss/vite` not `@astrojs/tailwind` |
| No `.dmg` ready at launch | High | High | Link to GitHub repo as interim; resolve Q2 before Phase 5 |

---

## Future Considerations

- **Custom domain:** Register `drobu.app` or similar, point DNS at GitHub Pages
- **Homebrew cask:** Create and publish, then add `brew install` to the download section
- **Apple notarization:** Join Developer Program, notarize builds, remove Gatekeeper FAQ
- **Blog/changelog section:** Add when there are updates to announce
- **Testimonials/social proof:** Add after accumulating real user feedback
- **Localization:** Not needed now, but Astro supports i18n routing natively
- **Dark/light toggle:** Only if user demand justifies the design effort

---

## References & Research

### Internal References
- App icon / brand identity brainstorm: `docs/brainstorms/2026-02-25-app-icon-brainstorm.md`
- Chroma sweep colors: `Sources/Views/ChromaSweepBorder.swift`
- Drobule mascot: `Resources/Drobule.png`
- Menu bar icon: `Resources/MenuBarIconTemplate@2x.png`
- Build script: `build.sh`
- App entry point: `Sources/App/DrobuApp.swift`

### External References
- Astro 5 docs: https://docs.astro.build
- GSAP ScrollTrigger: https://gsap.com/docs/v3/Plugins/ScrollTrigger/
- Tailwind CSS v4: https://tailwindcss.com/blog/tailwindcss-v4
- Geist font: https://vercel.com/font
- GitHub Pages deploy action: https://github.com/withastro/action

### Landing Page References (design inspiration)
- Raycast: raycast.com (WebGL hero, keyboard visualization, dark theme)
- Linear: linear.app (monochrome discipline, real product screenshots)
- CleanShot X: cleanshot.com (feature videos, social proof, alternating sections)
- Paste: pasteapp.io (device frames, scroll parallax, clipboard-specific)
- Maccy: maccy.app (anti-pattern — too minimal, undersells the product)
