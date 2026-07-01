/**
 * Comparison data for the /compare pages.
 *
 * Facts verified via web research (June 2026) and stated as defensible
 * positions: where a rival genuinely beats Drobu, we say so (honest
 * comparisons rank better and read as credible). Competitor prices can drift;
 * re-verify before a major price-sensitive campaign. Sources are in the PR.
 *
 * Copy style: crisp, simple phrases. No em dashes. No premature tails
 * ("Requires macOS 26" is enough; don't add "not on macOS 14 or 15").
 */

/** Which product an attribute favors — drives the cell styling. */
export type Advantage = "drobu" | "rival" | "even";

export interface CompareRow {
  dimension: string;
  drobu: string;
  rival: string;
  advantage: Advantage;
}

export interface Comparison {
  /** URL slug under /compare/ */
  slug: string;
  /** Rival display name */
  rival: string;
  /** primary search phrase this page targets */
  headTerm: string;
  /** <title> (<60 chars) */
  title: string;
  /** meta description (~150 chars) */
  description: string;
  /** visible H1 */
  h1: string;
  /** hero subhead */
  subhead: string;
  /** one accurate price-comparison line */
  priceLine: string;
  /** feature table rows */
  rows: CompareRow[];
  /** where Drobu wins */
  drobuWins: string[];
  /** where the rival wins — honest */
  rivalWins: string[];
  /** balanced closing verdict */
  verdict: string;
}

const maccy: Comparison = {
  slug: "drobu-vs-maccy",
  rival: "Maccy",
  headTerm: "Maccy alternative",
  title: "Drobu vs Maccy: Mac Clipboard Manager Compared",
  description:
    "Drobu vs Maccy: how a $14.99 clipboard manager you can edit (crop, trim, clean) with full-text search and screen capture compares to free, open-source Maccy on macOS.",
  h1: "Drobu vs Maccy",
  subhead:
    "Maccy is a free, open-source clipboard manager, and it's excellent at exactly that. Drobu costs $14.99 once and is the clipboard you can edit: crop an image, trim a GIF or recording, clean up text, then paste it back, all in one tool. It also captures your screen and full-text-searches your whole history.",
  priceLine:
    "Drobu is $14.99 one-time. Maccy is free, or $9.99 on the App Store. This isn't a price contest; it's about what you get for paying.",
  rows: [
    { dimension: "Price", drobu: "$14.99 one-time", rival: "Free, or $9.99 on the App Store", advantage: "rival" },
    { dimension: "Clipboard history", drobu: "Full history, up to 365 days", rival: "Configurable, with pinning", advantage: "even" },
    { dimension: "Search", drobu: "Full-text search (FTS5)", rival: "Fuzzy and regex matching", advantage: "drobu" },
    { dimension: "Screen capture (GIF/video)", drobu: "Record a region to GIF or video", rival: "None", advantage: "drobu" },
    { dimension: "Inline editing", drobu: "Edit and clean text; crop and trim images, GIFs, video", rival: "None", advantage: "drobu" },
    { dimension: "Source app per clip", drobu: "Name on every item", rival: "Optional icons (Maccy 2.2+)", advantage: "even" },
    { dimension: "Multi-select paste", drobu: "Yes", rival: "No", advantage: "drobu" },
    { dimension: "System slash commands", drobu: "/sleep, keep-awake, closed-lid", rival: "None", advantage: "drobu" },
    { dimension: "Open source", drobu: "No", rival: "Yes (MIT)", advantage: "rival" },
    { dimension: "Storage", drobu: "Local storage, no account", rival: "Fully local, no account", advantage: "even" },
    { dimension: "Platform", drobu: "macOS 14+", rival: "macOS 14+", advantage: "even" },
  ],
  drobuWins: [
    "Edit clips in place: clean text, crop and trim images, GIFs, and video",
    "Built-in GIF and video screen recording",
    "Full-text search across your whole history",
    "Configurable retention up to a year",
    "Multi-select paste and system slash commands",
  ],
  rivalWins: [
    "Genuinely free, with full functionality",
    "Open source (MIT) and fully auditable",
    "Tiny, lightweight footprint",
    "Installable via Homebrew",
  ],
  verdict:
    "Pick Drobu if you want screen capture, media editing, and full-text search in one tool. Stick with Maccy if it needs to be free, you want open source you can audit, or you prefer the lightest possible app.",
};

const paste: Comparison = {
  slug: "drobu-vs-paste",
  rival: "Paste",
  headTerm: "Paste app alternative",
  title: "Drobu vs Paste: A Clipboard Manager, Bought Once",
  description:
    "Drobu vs Paste: a one-time $14.99 Mac clipboard manager you can edit, with screen capture, vs Paste's subscription and iCloud sync. Which one fits your workflow?",
  h1: "Drobu vs Paste",
  subhead:
    "Paste is a polished, cross-device clipboard manager, billed by subscription or a pricier one-time license. Drobu is a one-time $14.99 purchase that lets you edit clips in place (crop, trim, clean) and capture your screen, all kept local. The trade-off is sync.",
  priceLine:
    "Drobu is $14.99 one-time. Paste is $29.99/year, or a $89.99 one-time license. Either way, several times Drobu's price.",
  rows: [
    { dimension: "Price", drobu: "$14.99 one-time", rival: "$29.99/year (or $89.99 lifetime)", advantage: "drobu" },
    { dimension: "Clipboard history", drobu: "Full history, up to 365 days", rival: "Unlimited history, pinboards", advantage: "even" },
    { dimension: "Search", drobu: "Full-text search (FTS5)", rival: "Full-text, plus OCR in screenshots", advantage: "rival" },
    { dimension: "Screen capture (GIF/video)", drobu: "Record a region to GIF or video", rival: "None", advantage: "drobu" },
    { dimension: "Inline editing", drobu: "Edit and clean text; crop and trim images, GIFs, video", rival: "None", advantage: "drobu" },
    { dimension: "Cross-device sync", drobu: "No, Mac only", rival: "iCloud across Mac, iPhone, iPad", advantage: "rival" },
    { dimension: "iPhone / iPad app", drobu: "No", rival: "Yes, with a keyboard extension", advantage: "rival" },
    { dimension: "Shared pinboards", drobu: "No", rival: "Yes, shareable collections", advantage: "rival" },
    { dimension: "Local-first storage", drobu: "Fully local storage", rival: "Local-first, optional iCloud sync", advantage: "even" },
    { dimension: "System slash commands", drobu: "/sleep, keep-awake, closed-lid", rival: "None", advantage: "drobu" },
    { dimension: "Platform", drobu: "macOS 14+", rival: "macOS, iOS, iPadOS, visionOS", advantage: "rival" },
  ],
  drobuWins: [
    "Built-in GIF and video screen recording",
    "Region recording with inline crop and trim",
    "Lower price: $14.99 once vs Paste's $29.99/year or $89.99 lifetime",
    "System slash commands (/sleep, keep-awake, closed-lid)",
  ],
  rivalWins: [
    "iPhone and iPad apps with iCloud sync",
    "Shareable pinboards for team collections",
    "Paste Stack for sequential form-filling",
    "OCR search inside stored screenshots",
    "A mature, polished product",
    "Apple Intelligence rewrite and a Paste MCP server",
  ],
  verdict:
    "Pick Drobu if you want screen capture bundled with clipboard history, a one-time price, and fully local storage. Pick Paste if you need your clipboard on iPhone and iPad with iCloud sync, or if shared pinboards are central to how you work.",
};

const cleanshot: Comparison = {
  slug: "drobu-vs-cleanshot-x",
  rival: "CleanShot X",
  headTerm: "CleanShot X alternative",
  title: "Drobu vs CleanShot X: Clipboard Meets Capture",
  description:
    "Drobu vs CleanShot X: a searchable clipboard history you can edit (crop, trim) with screen capture vs a screen-capture and annotation suite. How they differ on macOS.",
  h1: "Drobu vs CleanShot X",
  subhead:
    "These solve different problems. CleanShot X is a mature screen-capture and annotation suite. Drobu is the clipboard you can edit: it captures text, images, GIFs, and screen recordings, lets you crop and trim them in place, and pastes them back. If you mostly need to find, edit, and reuse what you copied, here's the comparison.",
  priceLine:
    "Drobu is $14.99 once, no renewal. CleanShot X is $29 once with a year of updates, then an optional $19/year to stay current.",
  rows: [
    { dimension: "Core focus", drobu: "Clipboard you can edit: capture, crop/trim, paste back", rival: "Screen-capture and annotation suite", advantage: "even" },
    { dimension: "Clipboard history", drobu: "System-wide and searchable", rival: "No, capture history only", advantage: "drobu" },
    { dimension: "Search of clips", drobu: "Full-text (FTS5)", rival: "None", advantage: "drobu" },
    { dimension: "Source app per clip", drobu: "Yes", rival: "N/A", advantage: "drobu" },
    { dimension: "Multi-select paste", drobu: "Yes", rival: "N/A", advantage: "drobu" },
    { dimension: "Screen capture", drobu: "GIF and video, region select", rival: "Screenshot, window, scrolling, 4K video, GIF", advantage: "rival" },
    { dimension: "Annotation / markup", drobu: "None", rival: "Arrows, blur, text, shapes", advantage: "rival" },
    { dimension: "OCR", drobu: "No", rival: "Yes, 20+ languages", advantage: "rival" },
    { dimension: "Cloud share links", drobu: "No", rival: "Cloud links (Pro tier for password/self-destruct)", advantage: "rival" },
    { dimension: "Price", drobu: "$14.99 once, no renewal", rival: "$29 once, +$19/yr to stay current", advantage: "drobu" },
  ],
  drobuWins: [
    "A real system-wide clipboard history",
    "Full-text search across everything you copied",
    "Source-app tracking and multi-select paste",
    "Configurable clipboard retention up to a year",
    "System slash commands (/sleep, keep-awake, closed-lid)",
    "One-time price, no annual renewal",
  ],
  rivalWins: [
    "Rich annotation: arrows, blur, highlight, text",
    "Scrolling capture that stitches long pages",
    "On-device OCR from any screenshot (20+ languages)",
    "Cloud share links (password and self-destruct on the Pro tier)",
    "4K video recording with system-audio capture",
    "The de-facto standard Mac capture suite",
  ],
  verdict:
    "Pick Drobu if your real need is managing, editing, and recalling what you copy, where cropping an image, trimming a clip, and pasting it back live on the same surface. Choose CleanShot X if your work centers on capturing, annotating, and sharing screenshots. They overlap little, so plenty of people run both.",
};

const spotlight: Comparison = {
  slug: "drobu-vs-spotlight",
  rival: "Spotlight",
  headTerm: "macOS Spotlight clipboard alternative",
  title: "Drobu vs the macOS Spotlight Clipboard",
  description:
    "Drobu vs the macOS 26 Spotlight clipboard: keep clips for up to a year with search, source tracking, and screen capture, on macOS 14 too. $14.99 once.",
  h1: "Drobu vs Spotlight Clipboard",
  subhead:
    "macOS 26 added a built-in clipboard to Spotlight. It's free and handy, but it forgets your clips within days, can't edit them, and only runs on macOS 26. Drobu keeps far more, for longer, lets you crop and trim what you copied, and runs on macOS 14 too.",
  priceLine:
    "Drobu is $14.99 one-time. Spotlight's clipboard is free, but it's built into macOS 26 only and clears your clips within days.",
  rows: [
    { dimension: "Price", drobu: "$14.99 one-time", rival: "Free, built into macOS 26", advantage: "rival" },
    { dimension: "Retention", drobu: "Up to a year, configurable", rival: "7 days at most", advantage: "drobu" },
    { dimension: "Formatting", drobu: "Preserved", rival: "Stripped from text", advantage: "drobu" },
    { dimension: "Long clips", drobu: "Stored in full", rival: "Capped at ~16,000 characters", advantage: "drobu" },
    { dimension: "Source app per clip", drobu: "Shown on every item", rival: "Not tracked", advantage: "drobu" },
    { dimension: "Screen capture (GIF/video)", drobu: "Yes", rival: "None", advantage: "drobu" },
    { dimension: "Inline editing", drobu: "Edit text; crop and trim media", rival: "None", advantage: "drobu" },
    { dimension: "Platform", drobu: "macOS 14+", rival: "macOS 26 only", advantage: "drobu" },
  ],
  drobuWins: [
    "Keeps clips for up to a year",
    "Records your screen to GIF and video, with crop and trim",
    "Full-text search across your whole history",
    "Shows the source app on every clip",
    "Keeps formatting and long clips in full",
    "Works on macOS 14 and later",
  ],
  rivalWins: [
    "Free and built into macOS 26",
    "Nothing to download or install",
    "Always a keystroke away inside Spotlight",
  ],
  verdict:
    "Pick Drobu if you want clips that stick around, keep their formatting and media, and work on macOS 14 and later. Spotlight's clipboard is a fine free buffer for the last few days if you're on macOS 26 and don't need more.",
};

const raycast: Comparison = {
  slug: "drobu-vs-raycast",
  rival: "Raycast",
  headTerm: "Raycast clipboard alternative",
  title: "Drobu vs Raycast Clipboard for Mac",
  description:
    "Drobu vs Raycast clipboard history: a dedicated Mac clipboard you can edit versus the free clipboard built into the Raycast launcher. Honest side-by-side, including where Raycast wins.",
  h1: "Drobu vs Raycast Clipboard",
  subhead:
    "Raycast is a launcher with a genuinely good, free clipboard history. Drobu is a dedicated clipboard manager you can edit. They overlap, but they solve different problems. Here is the honest comparison, including where Raycast wins.",
  priceLine:
    "Drobu is $14.99 one-time. Raycast's clipboard history is free (up to 3 months of history); unlimited history and cloud sync need Raycast Pro at $8/month billed annually. Prices as of mid-2026.",
  rows: [
    { dimension: "Primary purpose", drobu: "Dedicated clipboard manager (capture, edit, paste)", rival: "Launcher and command bar; clipboard is one built-in feature", advantage: "even" },
    { dimension: "Free version", drobu: "14-day full trial, then paid", rival: "Free tier with up to 3 months of clipboard history", advantage: "rival" },
    { dimension: "Price to own", drobu: "$14.99 one-time", rival: "Free tier; Pro is $8/month billed annually ($96/year) for unlimited history and sync", advantage: "drobu" },
    { dimension: "Unlimited clipboard history", drobu: "Included, configurable by you", rival: "Pro only (free caps at 3 months)", advantage: "drobu" },
    { dimension: "In-place media editing", drobu: "Crop images, trim GIFs and screen recordings, clean text", rival: "Text, link, and color editing only; no image, GIF, or video editing", advantage: "drobu" },
    { dimension: "Screen capture into history", drobu: "Yes, capture a screen region as a GIF or recording", rival: "No", advantage: "drobu" },
    { dimension: "Search", drobu: "Full-text search, type filters", rival: "Full-text search, type filters", advantage: "even" },
    { dimension: "Snippets and text expansion", drobu: "No", rival: "Yes, built in and free", advantage: "rival" },
    { dimension: "Extensions and integrations", drobu: "No, a focused tool", rival: "Thousands of community extensions", advantage: "rival" },
    { dimension: "Built-in AI", drobu: "No", rival: "Yes, limited on free, more on Pro", advantage: "rival" },
    { dimension: "Cross-device sync and iOS", drobu: "No, local only by design", rival: "Cloud sync and iOS clipboard on Pro", advantage: "rival" },
    { dimension: "Fully local, no account", drobu: "Yes, no login ever", rival: "Local for free clipboard use; account needed for sync and extensions", advantage: "drobu" },
    { dimension: "Platform", drobu: "macOS 14+", rival: "macOS, Windows beta, iOS companion", advantage: "rival" },
  ],
  drobuWins: [
    "Edit what you copy: crop images, trim GIFs and screen recordings, clean text, none of which Raycast does",
    "Capture a screen region straight into your clipboard history",
    "Own it once for $14.99, with no subscription and no Pro upsell for unlimited history",
    "Unlimited, configurable retention included, not gated behind a monthly plan",
    "Fully local with no account, ever; privacy is structural, not a setting",
    "Built solely around the capture, edit, and paste loop",
  ],
  rivalWins: [
    "A genuinely capable free tier (clipboard history, snippets, window management)",
    "It is a full launcher and Spotlight replacement, not just a clipboard",
    "A large extensions ecosystem (GitHub, Notion, Figma, and more)",
    "Built-in snippets, quicklinks, and window management",
    "Built-in AI commands from any context",
    "Cross-device cloud sync, an iOS companion, and a Windows beta",
  ],
  verdict:
    "If you already want a launcher, Raycast's free clipboard history is a great bonus and may be all you need. Choose Drobu if you specifically want to edit what you copy (crop, trim, clean), capture your screen into history, keep everything unlimited and fully local for a one-time price, and use a tool built only for the capture, edit, and paste loop. Plenty of people run both: Raycast as the launcher, Drobu as the clipboard you work in.",
};

export const comparisons: Comparison[] = [maccy, paste, cleanshot, spotlight, raycast];

/** Condensed matrix for the /compare hub "at a glance" table. */
export interface MasterRow {
  dimension: string;
  drobu: string;
  maccy: string;
  paste: string;
  cleanshot: string;
  spotlight: string;
  raycast: string;
}

export const masterMatrix: MasterRow[] = [
  { dimension: "Price", drobu: "$14.99 once", maccy: "Free (or $9.99)", paste: "$29.99/yr or $89.99 once", cleanshot: "$29 once", spotlight: "Free (macOS 26)", raycast: "Free; Pro $8/mo" },
  { dimension: "Clipboard history", drobu: "Yes, searchable", maccy: "Yes", paste: "Yes (+ pinboards)", cleanshot: "No", spotlight: "Yes, 7-day", raycast: "Yes (3-mo free)" },
  { dimension: "Search", drobu: "Full-text (FTS5)", maccy: "Fuzzy / regex", paste: "Full-text + OCR", cleanshot: "None", spotlight: "Recent clips", raycast: "Full-text + filter" },
  { dimension: "Screen capture (GIF/video)", drobu: "Yes", maccy: "No", paste: "No", cleanshot: "Yes, advanced", spotlight: "No", raycast: "No" },
  { dimension: "Inline editing", drobu: "Crop, trim, clean", maccy: "No", paste: "No", cleanshot: "Annotation", spotlight: "No", raycast: "Text only, no media" },
  { dimension: "Cross-device sync", drobu: "No", maccy: "No", paste: "iCloud (Mac + iOS)", cleanshot: "No", spotlight: "No", raycast: "Pro (Cloud Sync)" },
  { dimension: "Storage / account", drobu: "Local, no account", maccy: "Local, no account", paste: "Local-first, opt. sync", cleanshot: "Local core", spotlight: "Local, on device", raycast: "Local; account for sync" },
  { dimension: "Open source", drobu: "No", maccy: "Yes (MIT)", paste: "No", cleanshot: "No", spotlight: "No (built in)", raycast: "No" },
  { dimension: "Platform", drobu: "macOS 14+", maccy: "macOS 14+", paste: "macOS + iOS", cleanshot: "macOS 10.15+", spotlight: "macOS 26 only", raycast: "macOS + Win beta + iOS" },
];

export function getComparison(slug: string): Comparison | undefined {
  return comparisons.find((c) => c.slug === slug);
}
