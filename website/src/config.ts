/**
 * Site-wide configuration values that vary by environment.
 *
 * Override via build-time env vars (Astro reads any `PUBLIC_*` vars at build
 * time): set them in `.env` for local dev or as GitHub Actions secrets / repo
 * variables for the deploy workflow. The defaults below are safe fallbacks
 * so the site builds without any env config (using test/placeholder URLs).
 */

/** Stripe Checkout / Payment Link URL used by all "Start free trial" CTAs. */
export const STRIPE_CHECKOUT_URL =
  import.meta.env.PUBLIC_STRIPE_CHECKOUT_URL ??
  "https://buy.stripe.com/test_3cI3cu1YJ8tDeRMbOCcwg00";

/** GitHub Releases "latest" download URL — kept stable so the website never
 *  needs to be re-deployed when a new release is cut. */
export const DOWNLOAD_URL =
  "https://github.com/DanieliusIsiunas/drobu/releases/latest/download/Drobu.zip";
