/**
 * Site-wide configuration values that vary by environment.
 *
 * Override via build-time env vars (Astro reads any `PUBLIC_*` vars at build
 * time): set them in `.env` for local dev or as GitHub Actions secrets / repo
 * variables for the deploy workflow. The defaults below are safe fallbacks
 * so the site builds without any env config (using test/placeholder URLs).
 */

/** Stripe Payment Link URL used by all "Start free trial" CTAs.
 *  Defaults to the production link; set PUBLIC_STRIPE_CHECKOUT_URL in
 *  .env for local dev / staging to point at the test-mode link instead. */
export const STRIPE_CHECKOUT_URL =
  import.meta.env.PUBLIC_STRIPE_CHECKOUT_URL ??
  "https://buy.stripe.com/14A7sL2rkeKx6sj3QNdnW01";

