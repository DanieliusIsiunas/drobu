/**
 * Site-wide configuration values that vary by environment.
 *
 * Override via build-time env vars (Astro reads any `PUBLIC_*` vars at build
 * time): set them in `.env` for local dev or as GitHub Actions secrets / repo
 * variables for the deploy workflow. The defaults below are safe fallbacks
 * so the site builds without any env config (using test/placeholder URLs).
 */

/** Stripe Payment Link URL — used by the in-app ActivationPanel's Buy
 *  button (deep-linked from Drobu when the 14-day trial expires) and
 *  by the Settings → License section. The website itself doesn't
 *  surface this URL as a primary CTA anymore; we lead with the free
 *  trial download. Set PUBLIC_STRIPE_CHECKOUT_URL in .env for local
 *  dev / staging to use the test-mode link. */
export const STRIPE_CHECKOUT_URL =
  import.meta.env.PUBLIC_STRIPE_CHECKOUT_URL ??
  "https://buy.stripe.com/14A7sL2rkeKx6sj3QNdnW01";

/** Direct download URL for the latest signed DMG. Stable across
 *  releases — GitHub redirects `/releases/latest/download/<asset>`
 *  to whatever the newest release advertises, so the website never
 *  needs to be re-deployed when a new Drobu version ships. */
export const DOWNLOAD_URL =
  "https://github.com/DanieliusIsiunas/drobu/releases/latest/download/Drobu.dmg";

