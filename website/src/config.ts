/**
 * Site-wide configuration values that vary by environment.
 *
 * Override via build-time env vars (Astro reads any `PUBLIC_*` vars at build
 * time): set them in `.env` for local dev or as GitHub Actions secrets / repo
 * variables for the deploy workflow. The defaults below are safe fallbacks
 * so the site builds without any env config (using test/placeholder URLs).
 */

/** Direct download URL for the latest signed DMG. Stable across
 *  releases — GitHub redirects `/releases/latest/download/<asset>`
 *  to whatever the newest release advertises, so the website never
 *  needs to be re-deployed when a new Drobu version ships. */
export const DOWNLOAD_URL =
  "https://github.com/DanieliusIsiunas/drobu/releases/latest/download/Drobu.dmg";

