---
title: "fix: Blurry menu bar icon on Retina displays"
type: fix
date: 2026-02-25
---

# fix: Blurry menu bar icon on Retina displays

## Overview

The custom calligraphic "C" menu bar icon appears pixelated/blurry compared to other menu bar icons. Two root causes identified.

## Problem Statement

### Root Cause 1: `NSImage(contentsOf:)` ignores @2x variants

The current code loads the icon via `Bundle.main.url(forResource:withExtension:)` + `NSImage(contentsOf:)`. This loads **only** the exact file pointed to (the 22x22 @1x PNG). On Retina displays, macOS upscales this 22x22 image to 44x44 pixels — resulting in blurriness.

**Fix:** Switch to `NSImage(named:)` which automatically performs scale-based lookup (`MenuBarIconTemplate@2x.png` on Retina, `MenuBarIconTemplate.png` on non-Retina).

### Root Cause 2: Icon is 22x22pt instead of standard 16x16pt

Apple's menu bar icon standard is **16x16 points** (32x32px @2x). The current 22x22pt icon fills the entire 22pt status item height with no breathing room, making it look oversized and out of place compared to other icons.

**Fix:** Regenerate PNGs at 16x16 / 32x32 and set `image.size = NSSize(width: 16, height: 16)`.

## Proposed Solution

### Step 1: Regenerate PNGs at correct sizes

Regenerate template images using the existing Swift cleanup script:
- `MenuBarIconTemplate.png` → **16x16 pixels** (was 22x22)
- `MenuBarIconTemplate@2x.png` → **32x32 pixels** (was 44x44)

Same cleanup thresholds as current (removes background noise, pure black + alpha).

### Step 2: Change image loading in AppDelegate

```swift
// Sources/App/AppDelegate.swift — setupStatusItem()

// BEFORE (broken — doesn't select @2x):
if let iconURL = Bundle.main.url(forResource: "MenuBarIconTemplate", withExtension: "png"),
   let image = NSImage(contentsOf: iconURL) {
    image.size = NSSize(width: 22, height: 22)

// AFTER (auto-selects @2x on Retina):
if let image = NSImage(named: "MenuBarIconTemplate") {
    image.size = NSSize(width: 16, height: 16)
```

Keep `image.isTemplate = true` explicitly (the "Template" filename suffix does NOT auto-set this).

### Step 3: Add accessibility label

```swift
button.image = image
button.accessibilityLabel = "Clipboard History"
```

## Acceptance Criteria

- [x] Menu bar icon renders crisp on Retina displays (no visible pixelation)
- [x] Icon is 16x16pt, visually balanced with neighboring system icons
- [x] Icon correctly tints in both light and dark mode
- [x] Fallback to SF Symbol "clipboard" still works if files are missing

## Context

- `NSImage(named:)` searches `Bundle.main.resourcePath` for `{name}.png` and `{name}@2x.png` — confirmed in Apple docs
- `NSStatusItem.squareLength` creates a 22pt-tall button; a 16pt icon centers with ~3pt padding
- Professional apps (Maccy, Bartender) all use 16x16pt template images
- No Package.swift resource changes needed — build.sh copies files to `Contents/Resources/` which is where `NSImage(named:)` looks

## References

- [Apple HIG: Menu Bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)
- [Bjango: Designing Menu Bar Extras](https://bjango.com/articles/designingmenubarextras/)
- Current code: `Sources/App/AppDelegate.swift:124-144`
