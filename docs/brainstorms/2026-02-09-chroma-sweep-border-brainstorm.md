# Chroma Sweep Border Animation — Brainstorm

**Date:** 2026-02-09
**Status:** Ready for implementation

## What We're Building

A rainbow gradient "chroma sweep" border animation that plays when the preview panel enters edit mode. Inspired by the diabrowser.com landing page effect. The rainbow band sweeps across the border (~0.9s) then settles into a solid accentColor border. On exit, the border instantly resets (no animation out).

**Building both variants to compare:**
- **Conic sweep** — rainbow rotates around the border like a clock hand
- **Linear sweep** — rainbow band wipes diagonally corner-to-corner

## Why This Approach

The current edit mode transition is an instant swap with a static 1px blue border. Adding a one-shot chroma sweep provides a clear, delightful visual signal that the panel has entered an interactive editing state — without being distracting on repeated use since it's a short one-shot animation.

## Key Decisions

1. **SwiftUI-native implementation** — AngularGradient (conic) and LinearGradient (linear), no WebView or CSS
2. **Both variants built** — conic (rotational) and linear (diagonal) for side-by-side comparison
3. **Exit behavior: instant reset** — no reverse animation, border disappears immediately
4. **Resting state: system accentColor** — after sweep completes, settles to solid blue border matching current UI
5. **Border width: 2px**, corner radius matching element (currently 4pt)
6. **Soft glow: blur 1px → 0px** during sweep for subtle glow effect
7. **Timing: ~0.9s ease-in-out** one-shot animation

## Implementation Notes (SwiftUI Translation)

### Shared Technique
- Overlay or background `RoundedRectangle` with gradient fill, masked to show only the 2px border ring
- Content background must be opaque and on top (naturally the case with `.overlay()`)
- Animation triggered by `isEditing` state change

### Conic Variant
- `AngularGradient` with color stops: accentColor zone, rainbow band (pink → red-orange → amber → lavender → blue), transparent zone
- Animate gradient rotation angle from 0° → 360° to sweep the rainbow band around all edges
- Each edge lights up sequentially — more dramatic

### Linear Variant
- `LinearGradient` with same color palette positioned in a narrow band
- Animate `startPoint`/`endPoint` or use `GeometryEffect` to shift gradient position diagonally
- All edges animate simultaneously — smoother, subtler

### Rainbow Palette (from CSS spec)
- Pink: `rgb(198, 121, 196)`
- Red-orange: `rgb(250, 61, 29)`
- Amber: `rgb(255, 176, 5)`
- Lavender: `rgb(225, 225, 254)`
- Blue: `rgb(3, 88, 247)`

## Current State (for reference)

- **File:** `PreviewPanel.swift:49` — `.overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1))`
- **Trigger:** `isEditing` boolean in `ClipboardPanelView.swift`
- **No current animation** — instant conditional swap between preview and edit views

## Open Questions

- Which variant feels better in practice? (Build both, decide after seeing them)
- Should the sweep play every time you re-enter edit mode, or only the first time per session?
