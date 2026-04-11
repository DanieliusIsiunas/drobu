---
title: Landing page content journey reframe
date: 2026-04-11
status: approved
---

# Landing Page Content Journey Reframe

## Problem

The current landing page positions Drobu as "clipboard history that remembers." This undersells the product. Drobu's real differentiator is the end-to-end content journey — capture, edit, paste — not just remembering what was copied. Competitors like Maccy and CopyClip handle clipboard history. None of them handle screen capture → trim → paste as one flow.

The page lists features but doesn't communicate the vision. A visitor sees a feature comparison matrix, not a story about effortless content workflows.

## Goal

Rewrite copy across existing sections to tell content journey stories instead of feature descriptions. Minimal structural changes — the page layout stays, but the narrative shifts from "clipboard that remembers" to "content moves from A to B without friction."

## Approach: Feature-journey reframe

Keep the existing page structure (Hero, ProblemSolution, BentoGrid, SpeedPrivacy, DownloadCTA). Rewrite copy to emphasize the capture → edit → paste journey for each content type. No new sections, no structural reorganization.

## Requirements

### R1. Hero copy reframe

Replace "Your clipboard, with a memory" with a headline that communicates content workflow, not just memory. The subtitle should frame Drobu as reducing cognitive load — capturing, editing, and pasting content without switching apps or thinking about file management.

Current: "Your clipboard, with a memory."
Direction: Something that positions Drobu as where content flows through, not where it gets stored.

### R2. ProblemSolution reframe

Current: "You copied it. Then you copied something else. Now it's gone." → "Drobu remembers."

This frames the problem as lost clipboard items. The real problem is friction — switching between apps to capture, edit, export, paste. Rewrite to frame the problem as "too many steps between having content and using it" and the solution as "Drobu handles the journey."

### R3. Bento card descriptions as journeys

Update bento card titles and descriptions to emphasize what the user accomplishes, not what the feature does technically. Each card should answer "what workflow does this eliminate?" not "what technology powers this?"

Examples:
- "GIF screen capture" → something about capturing a moment and sharing it in seconds
- "Video screen capture" → something about recording → trimming → pasting without leaving Drobu
- "Instant search" → something about finding anything you've ever copied without remembering when
- "Multi-select paste" → something about combining clips without a text editor

### R4. Competitor differentiation through copy

Without naming competitors, the copy should make it clear that Drobu does things other clipboard managers don't: screen capture (GIF + video), inline editing, built-in trim editors, content type filtering, slash commands for system control. These should feel like natural parts of the content journey narrative, not bolted-on features.

### R5. Maintain accuracy

All copy must be accurate to the app's current capabilities. Don't promise features that don't exist. The reframe is about telling the story of existing features differently, not adding fictional ones.

## Success criteria

- A developer visiting the page understands within 10 seconds that Drobu is more than clipboard history
- The capture → edit → paste narrative is visible without scrolling past the fold
- Feature cards read as "what you can accomplish" not "what technology we built"
- No new HTML sections or structural changes — copy and descriptions only
- `npm run build` passes

## Scope

- **In scope:** Hero headline/subtitle, ProblemSolution copy, BentoGrid card titles/descriptions, DownloadCTA subtitle
- **Out of scope:** New page sections, CSS/layout changes, bento card visual mockups, SpeedPrivacy section (trust messaging stays as-is), new pages

## Non-goals

- Don't add JavaScript or animations
- Don't change the bento card CSS mockup visuals (only titles and descriptions)
- Don't add a competitor comparison table
- Don't change pricing or CTA copy
