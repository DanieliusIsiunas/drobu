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

/** Whether to load privacy-respecting, cookieless analytics (Plausible).
 *  OFF by default so the site ships zero analytics and the privacy copy stays
 *  "no analytics" — the script's presence and the privacy wording are BOTH
 *  gated on this one flag, so they can never drift out of sync. To turn it on:
 *  create the drobu.app site in Plausible, then set the repo Actions variable
 *  PUBLIC_ANALYTICS_ENABLED=true (wired into the deploy workflow) and redeploy.
 *  Read at build time; an unset/empty var is OFF. */
export const ANALYTICS_ENABLED =
  import.meta.env.PUBLIC_ANALYTICS_ENABLED === "true";

