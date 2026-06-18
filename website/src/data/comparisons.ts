/**
 * Comparison data for the /compare pages.
 *
 * Facts verified via web research (June 2026) and stated as defensible
 * positions: where a rival genuinely beats Drobu, we say so (honest
 * comparisons rank better and read as credible). Competitor prices can drift —
 * re-verify before a major price-sensitive campaign. Sources are in the PR.
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
  /** rival's site, for an honest outbound reference link */
  rivalUrl: string;
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
  rivalUrl: "https://maccy.app",
  headTerm: "Maccy alternative",
  title: "Drobu vs Maccy: Mac Clipboard Manager Compared",
  description:
    "Drobu vs Maccy: how a $14.99 clipboard manager with built-in screen-to-GIF capture and full-text search compares to free, open-source Maccy on macOS.",
  h1: "Drobu vs Maccy",
  subhead:
    "Maccy is a free, open-source clipboard manager and it's excellent at exactly that. Drobu costs $14.99 once and adds screen capture, media editing, and full-text search in the same tool. Here's the honest breakdown.",
  priceLine:
    "Drobu is $14.99 one-time. Maccy is free via direct download or Homebrew (or $9.99 on the App Store) — so this isn't a price contest; it's about what you get for paying.",
  rows: [
    { dimension: "Price", drobu: "$14.99 one-time", rival: "Free (or $9.99 on the App Store)", advantage: "rival" },
    { dimension: "Clipboard history", drobu: "Full history, retention up to 365 days", rival: "Yes — configurable, with pinning", advantage: "even" },
    { dimension: "Search", drobu: "FTS5 full-text indexed", rival: "Exact → fuzzy → regex matching", advantage: "drobu" },
    { dimension: "Screen capture (GIF/video)", drobu: "Yes — record a region to GIF or video", rival: "None", advantage: "drobu" },
    { dimension: "Inline media editing", drobu: "Crop & trim images, GIFs, video", rival: "None", advantage: "drobu" },
    { dimension: "Source app shown per clip", drobu: "Yes — name on every item", rival: "Optional source-app icons (Maccy 2.2+)", advantage: "even" },
    { dimension: "Multi-select paste", drobu: "Yes", rival: "No", advantage: "drobu" },
    { dimension: "System slash commands", drobu: "/sleep, keep-awake, closed-lid", rival: "None", advantage: "drobu" },
    { dimension: "Open source", drobu: "No", rival: "Yes — MIT licensed", advantage: "rival" },
    { dimension: "Storage", drobu: "Fully local, no account", rival: "Fully local, no account", advantage: "even" },
    { dimension: "Platform", drobu: "macOS 14+", rival: "macOS 14+", advantage: "even" },
  ],
  drobuWins: [
    "Built-in screen capture — GIF and video recording Maccy doesn't have",
    "Inline crop & trim of images, GIFs, and video",
    "FTS5 full-text search across your history",
    "Configurable date-based retention (up to a year), not just an item cap",
    "Multi-select paste and system slash commands",
  ],
  rivalWins: [
    "Genuinely free — full functionality at zero cost",
    "Open source (MIT) — auditable, and can never be paywalled or sunset",
    "Tiny footprint — a ~1.7 MB app, light on memory",
    "Nuanced password-manager handling (honors concealed pasteboard flags)",
    "Homebrew-installable, fits dotfile/automation setups",
    "Regex search for power users",
  ],
  verdict:
    "Pick Drobu if you want screen capture, media editing, full-text search, and source-app visibility in one tool. Stick with Maccy if cost is the deciding factor, you want an open-source codebase you can audit, or you prefer the absolute minimum footprint.",
};

const paste: Comparison = {
  slug: "drobu-vs-paste",
  rival: "Paste",
  rivalUrl: "https://pasteapp.io",
  headTerm: "Paste app alternative",
  title: "Drobu vs Paste: A Clipboard Manager, Bought Once",
  description:
    "Drobu vs Paste: a one-time $14.99 Mac clipboard manager with screen capture vs Paste's subscription and iCloud sync. Which one fits your workflow?",
  h1: "Drobu vs Paste",
  subhead:
    "Paste is a polished, cross-device clipboard manager — on a subscription. Drobu is a one-time $14.99 purchase that adds screen capture and keeps everything local. The trade-off is sync: here's how it shakes out.",
  priceLine:
    "Drobu is $14.99 one-time. Paste is $29.99/year or a $89.99 one-time license — either way, several times Drobu's price.",
  rows: [
    { dimension: "Price", drobu: "$14.99 one-time", rival: "$29.99/year (or $89.99 lifetime)", advantage: "drobu" },
    { dimension: "Clipboard history", drobu: "Full history, retention up to 365 days", rival: "Unlimited history, pinboards", advantage: "even" },
    { dimension: "Search", drobu: "FTS5 full-text indexed", rival: "Full-text + OCR inside screenshots", advantage: "rival" },
    { dimension: "Screen capture (GIF/video)", drobu: "Yes — record a region to GIF or video", rival: "None", advantage: "drobu" },
    { dimension: "Inline media editing", drobu: "Crop & trim images, GIFs, video", rival: "None", advantage: "drobu" },
    { dimension: "Cross-device sync", drobu: "No — Mac only", rival: "iCloud across Mac, iPhone, iPad", advantage: "rival" },
    { dimension: "iPhone / iPad app", drobu: "No", rival: "Yes, with a keyboard extension", advantage: "rival" },
    { dimension: "Shared pinboards", drobu: "No", rival: "Yes — saved, shareable collections", advantage: "rival" },
    { dimension: "Local-first storage", drobu: "Fully local — no cloud component", rival: "Local-first; optional iCloud sync", advantage: "even" },
    { dimension: "System slash commands", drobu: "/sleep, keep-awake, closed-lid", rival: "None", advantage: "drobu" },
    { dimension: "Platform", drobu: "macOS 14+", rival: "macOS, iOS, iPadOS, visionOS", advantage: "rival" },
  ],
  drobuWins: [
    "Built-in screen capture — GIF and video recording Paste doesn't offer",
    "Region recording plus inline crop & trim of captured media",
    "Much lower one-time price — $14.99 vs Paste's $29.99/year or $89.99 lifetime",
    "System slash commands (/sleep, keep-awake, closed-lid)",
  ],
  rivalWins: [
    "iPhone and iPad apps with iCloud sync — your history everywhere",
    "Pinboards: saved, organized clip collections you can share with a team",
    "Paste Stack for sequential form-filling",
    "OCR search inside stored screenshots",
    "A decade-old, very polished product with a large user base",
    "Apple Intelligence rewrite and a Paste MCP server for AI tools",
  ],
  verdict:
    "Pick Drobu if you want screen capture bundled with clipboard history, a one-time price, and fully local storage. Pick Paste if you need your clipboard on iPhone and iPad with iCloud sync, or if shared pinboards are central to how you work.",
};

const cleanshot: Comparison = {
  slug: "drobu-vs-cleanshot-x",
  rival: "CleanShot X",
  rivalUrl: "https://cleanshot.com",
  headTerm: "CleanShot X alternative",
  title: "Drobu vs CleanShot X: Clipboard Meets Capture",
  description:
    "Drobu vs CleanShot X: a searchable clipboard history with screen-to-GIF capture vs a screen-capture and annotation suite. How they differ on macOS.",
  h1: "Drobu vs CleanShot X",
  subhead:
    "These solve different problems. CleanShot X is a mature screen-capture and annotation suite; Drobu is a clipboard manager that happens to record your screen. If you mostly need to find and reuse what you copied, here's the comparison.",
  priceLine:
    "Drobu is $14.99 one-time with no renewal. CleanShot X is $29 one-time including a year of updates, then an optional $19/year to keep getting the latest version.",
  rows: [
    { dimension: "Core focus", drobu: "Clipboard manager + light capture", rival: "Screen-capture & annotation suite", advantage: "even" },
    { dimension: "Clipboard history", drobu: "Yes — system-wide, searchable", rival: "No — capture history only", advantage: "drobu" },
    { dimension: "Full-text search of clips", drobu: "FTS5 indexed", rival: "None (OCR pulls text from images)", advantage: "drobu" },
    { dimension: "Source app per clip", drobu: "Yes", rival: "N/A", advantage: "drobu" },
    { dimension: "Multi-select paste", drobu: "Yes", rival: "N/A", advantage: "drobu" },
    { dimension: "Screen capture", drobu: "GIF + video, region select", rival: "Screenshot, window, scrolling, 4K video, GIF", advantage: "rival" },
    { dimension: "Annotation / markup", drobu: "None", rival: "Rich — arrows, blur, text, shapes", advantage: "rival" },
    { dimension: "OCR", drobu: "No", rival: "Yes — 20+ languages", advantage: "rival" },
    { dimension: "Cloud share links", drobu: "No", rival: "Yes — Cloud links (Pro tier for password/self-destruct)", advantage: "rival" },
    { dimension: "Price", drobu: "$14.99 once, no renewal", rival: "$29 once (+$19/yr to stay current)", advantage: "drobu" },
  ],
  drobuWins: [
    "A real system-wide clipboard history — CleanShot only tracks its own captures",
    "FTS5 full-text search across everything you copied",
    "Source-app tracking and multi-select paste",
    "Configurable clipboard retention up to a year",
    "System slash commands (/sleep, keep-awake, closed-lid)",
    "One-time price with no annual renewal to stay current",
  ],
  rivalWins: [
    "A rich annotation toolset — arrows, blur, highlight, text, shapes",
    "Scrolling capture that auto-stitches long pages",
    "On-device OCR from any screenshot (20+ languages)",
    "CleanShot Cloud share links (password protection & self-destruct on the Cloud Pro tier)",
    "4K video recording with system-audio capture",
    "The de-facto standard Mac capture suite — broad and mature",
  ],
  verdict:
    "Pick Drobu if your real need is managing and recalling what you copy, with lightweight GIF/video capture along for the ride. Choose CleanShot X if your work centers on capturing, annotating, and sharing screenshots. They overlap little — plenty of people run both.",
};

export const comparisons: Comparison[] = [maccy, paste, cleanshot];

/** Condensed 4-product matrix for the /compare hub "at a glance" table. */
export interface MasterRow {
  dimension: string;
  drobu: string;
  maccy: string;
  paste: string;
  cleanshot: string;
}

export const masterMatrix: MasterRow[] = [
  { dimension: "Price", drobu: "$14.99 once", maccy: "Free (or $9.99)", paste: "$29.99/yr", cleanshot: "$29 once" },
  { dimension: "Clipboard history", drobu: "Yes — searchable", maccy: "Yes", paste: "Yes (+ pinboards)", cleanshot: "No" },
  { dimension: "Full-text search", drobu: "FTS5 indexed", maccy: "Fuzzy / regex", paste: "Full-text + OCR", cleanshot: "—" },
  { dimension: "Screen capture (GIF/video)", drobu: "Yes", maccy: "No", paste: "No", cleanshot: "Yes — advanced" },
  { dimension: "Inline media editing", drobu: "Crop & trim", maccy: "No", paste: "No", cleanshot: "Annotation" },
  { dimension: "Cross-device sync", drobu: "No", maccy: "No", paste: "iCloud (Mac + iOS)", cleanshot: "No" },
  { dimension: "Storage / account", drobu: "Local, no account", maccy: "Local, no account", paste: "Local-first, opt. sync", cleanshot: "Local core" },
  { dimension: "Open source", drobu: "No", maccy: "Yes (MIT)", paste: "No", cleanshot: "No" },
  { dimension: "Platform", drobu: "macOS 14+", maccy: "macOS 14+", paste: "macOS + iOS", cleanshot: "macOS 10.15+" },
];

export function getComparison(slug: string): Comparison | undefined {
  return comparisons.find((c) => c.slug === slug);
}
