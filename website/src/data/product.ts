/**
 * Canonical one-sentence product definition.
 *
 * Single source of truth so the JSON-LD description (Landing.astro) and the FAQ
 * lead (faq.astro) stay in lockstep and answer engines bind the right "Drobu"
 * entity (not Drobo the NAS, not Drobu Media the insurer). public/llms.txt is a
 * static file and cannot import this, so it keeps a verbatim copy that must be
 * edited together with this constant.
 */
export const PRODUCT_DESCRIPTION =
  "Drobu is a macOS clipboard manager that also records your screen as GIF or video, edits media inline, and pastes anything with one keystroke. Your clipboard stays on your Mac with no account to create, it is a one-time $14.99 purchase, and it works on macOS 14 or later.";
