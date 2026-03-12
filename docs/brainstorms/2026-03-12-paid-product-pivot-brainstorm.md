# Brainstorm: Drobu Paid Product Pivot

**Date:** 2026-03-12
**Status:** Ready for planning

## What We're Building

Transform the Drobu landing page from an open-source project site to a paid product site with Stripe-powered subscriptions.

**Pricing model:** 14-day free trial, then $9.99/month via Stripe Checkout.

**Scope:** Website changes only — no app-side licensing enforcement yet.

## Key Decisions

1. **Pricing:** $9.99/month subscription with 14-day free trial
2. **Payment provider:** Stripe Checkout (hosted checkout page — minimal custom UI)
3. **Licensing:** Website-only for now. App-side enforcement deferred to a future phase
4. **GitHub references:** Remove all — no replacements. Keep site minimal with just download/purchase CTA

## What Changes

### Remove (5 files affected)
- **Header.astro:** GitHub icon link (lines 27-37)
- **Hero.astro:** "View on GitHub" button, "Free · macOS 14+ · No account required" text, non-macOS GitHub fallback script
- **DownloadCTA.astro:** "Free, open source, and built for macOS" copy, "View source" button
- **Footer.astro:** GitHub footer link
- **Landing.astro:** Schema.org `"price": "0"` → update to `"9.99"` with `"priceCurrency": "USD"`

### Add
- **Pricing section or pricing info in hero:** Display "$9.99/mo" with "Start 14-day free trial" as primary CTA
- **Stripe Checkout integration:** Primary CTA links to a Stripe Checkout session (can be a simple redirect to a Stripe Payment Link — zero backend needed)
- **Updated copy:** "Free" → "14-day free trial", "open source" → remove entirely

### Stripe Approach: Payment Links (simplest)
Stripe Payment Links are pre-built hosted checkout pages. No backend needed:
1. Create a subscription product ($9.99/mo) in Stripe Dashboard
2. Enable 14-day free trial on the price
3. Generate a Payment Link
4. Replace download CTA `href` with the Payment Link URL
5. After checkout, Stripe redirects to a success page (can be a simple `/thank-you` page on the site with download instructions)

## Open Questions

1. **Download delivery:** After payment, how does the user get the app? Direct download link on the success page? Email with download link?
2. **Trial without payment method:** Should the 14-day trial require a credit card upfront (Stripe default) or be card-free (just download, enforce in app later)?
3. **Existing users:** Any migration plan for current users who downloaded it as free/open-source?
4. **App-side enforcement timeline:** When will the app check subscription status? This determines whether the download flow needs a license key now.

## Next Step

Run `/workflows:plan` to create the implementation plan for the website changes.
