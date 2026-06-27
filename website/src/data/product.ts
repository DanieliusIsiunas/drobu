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
  "Drobu is a macOS clipboard manager that captures text, images, GIFs, files, and screen recordings, lets you crop, trim, and search them in one panel, and pastes one item or many back with a single keystroke. Everything stays on your Mac with no account to create, it is a one-time $14.99 purchase, and it works on macOS 14 or later.";
