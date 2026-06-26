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

/** Whether to load privacy-respecting, cookieless analytics (Umami Cloud).
 *  Gated on `import.meta.env.PROD`: ON in production builds (the deployed site),
 *  OFF in local `npm run dev` so dev traffic never pollutes the dashboard.
 *  The Umami script AND the privacy page's "No tracking" copy are BOTH gated on
 *  this one flag, so the script's presence and the privacy wording can never
 *  drift out of sync. To disable analytics entirely, change this to `false`
 *  (the privacy copy reverts to "no analytics" in the same build). */
export const ANALYTICS_ENABLED = import.meta.env.PROD;

