# App Icon Redesign Brainstorm

**Date:** 2026-02-25
**Status:** In Progress — awaiting generated artwork

## What We're Building

A custom app icon for ClipboardHistory that replaces the current default macOS generic icon. The icon should reflect the app's identity as a personal power tool for a creative product manager.

## Design Direction

- **Visual metaphor:** Abstract mark (65%) with subtle flow/continuity influence (35%)
- **Color:** Soft coral / terracotta (~#D4715E) — single accent on white/light background
- **Shape language:** Organic, calligraphic — flowing, handcrafted feel
- **Personality:** Elegant, clean, humble, creative, distinctly personal

### What it is NOT
- Not a literal clipboard icon
- Not flashy, loud, or gradient-heavy
- Not generic tech blue/purple

### Reference points
- Restraint of iA Writer
- Distinctiveness of Linear's mark
- Warmth of a handcrafted stamp or seal

## Key Decisions

1. **No literal clipboard metaphor** — abstract mark that becomes a personal identity
2. **Coral/terracotta color** — rare in productivity tools, distinctly human and creative
3. **Organic shapes over geometric** — calligraphic, flowing, feels handmade
4. **AI-generated artwork** — using Gemini (Nano Banana Pro) for the mark, then code-wired into build

## Implementation Plan

1. Generate mark via Gemini with provided prompt
2. Export as 1024x1024 PNG
3. Convert PNG to .icns (multiple sizes: 16, 32, 128, 256, 512, 1024)
4. Add to project at `Resources/AppIcon.icns`
5. Update `build.sh` to copy icon into app bundle `Contents/Resources/`
6. Add `CFBundleIconFile` key to `Info.plist`

## Open Questions

- Final exact coral shade (iterate with generated results)
- Whether the mark should hint at a letter form (D? C?) or be fully abstract
- Light vs white background behind the mark
