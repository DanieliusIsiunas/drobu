---
title: "feat: Transform landing page to paid product with Stripe"
type: feat
date: 2026-03-12
---

# Transform Landing Page to Paid Product with Stripe

## Overview

Convert the Drobu landing page from open-source/free messaging to a paid product site. $9.99/month subscription with 14-day free trial, powered by Stripe Payment Links (no backend needed). Website-only scope — app-side license enforcement is deferred.

**Brainstorm:** `docs/brainstorms/2026-03-12-paid-product-pivot-brainstorm.md`

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Pricing | $9.99/mo, 14-day trial | User decision |
| Payment provider | Stripe Payment Links | No backend needed, stays on GitHub Pages |
| GitHub refs | Remove all, no replacements | Keep site minimal |
| /thank-you security | Publicly accessible | App enforcement deferred; binary is also public |
| Non-macOS visitors | "macOS only" dead-end CTA | Simplest approach, no email backend needed |
| Delivery | Receipt email + success page download link | Stripe sends receipt; /thank-you has download |

## Architecture Note: Static Site Constraints

The site deploys to GitHub Pages (static). This means:
- **No webhooks** — cannot verify checkout completion server-side
- **No session validation** — /thank-you page cannot verify `session_id` against Stripe API
- **/thank-you is publicly accessible** — anyone who finds the URL can see the download link

This is acceptable because:
1. The app binary on GitHub Releases is already public
2. App-side enforcement will gate functionality in a future phase
3. Stripe Payment Links handle the entire checkout flow hosted on Stripe's domain

## Implementation Plan

### Phase 1: Stripe Setup (Manual — Stripe Dashboard)

Before any code changes:

1. Create a Product in Stripe Dashboard: "Drobu — Clipboard Manager for macOS"
2. Create a Price: $9.99/mo recurring
3. Enable 14-day free trial on the price
4. Generate a Payment Link from this price
5. Configure the Payment Link:
   - **After payment redirect:** `https://danieliusisiunas.github.io/clipboard-history/thank-you`
   - **Confirmation page:** Custom redirect (not Stripe's hosted page)
   - Enable receipt emails
6. Note the Payment Link URL (e.g., `https://buy.stripe.com/xxxxx`) — this becomes the CTA href

### Phase 2: Remove Open-Source / GitHub References (5 files)

#### `website/src/components/Header.astro`

- **Line 28-38:** Delete the entire GitHub icon `<a>` tag (SVG icon + link)

#### `website/src/components/Hero.astro`

- **Line 17-26:** Change primary CTA:
  - `href` → Stripe Payment Link URL
  - Button text: "Download for macOS" → **"Start free trial"**
  - Remove download icon SVG, replace with a play/arrow icon or no icon
- **Line 33:** Change `download-label` span text
- **Line 35-42:** Delete "View on GitHub" secondary button entirely
- **Line 46:** Change `"Free &middot; macOS 14+ &middot; No account required"` → **`"$9.99/mo after 14-day free trial &middot; macOS 14+ &middot; Cancel anytime"`**
- **Lines 63-76:** Update platform detection script:
  - Non-macOS: change label to `"macOS only"` and set `href="#"` with `pointer-events: none` / muted styling
  - Remove GitHub fallback URL

#### `website/src/components/DownloadCTA.astro`

- **Line 10:** Change `"Free, open source, and built for macOS."` → **`"Start your 14-day free trial today."`**
- **Line 15:** Change `href` to Stripe Payment Link URL
- **Line 16-24:** Change button text to **"Start free trial"**
- **Lines 25-32:** Delete "View source" secondary button entirely

#### `website/src/components/Footer.astro`

- **Lines 9-15:** Delete GitHub link
- Add links: **Terms** (`/clipboard-history/terms`) and **Privacy** (`/clipboard-history/privacy`)
- Keep "Built with Swift & SwiftUI" — it's a tech credibility signal, not an open-source signal
- Keep version display

#### `website/src/layouts/Landing.astro`

- **Line 56:** Change `"price": "0"` → `"price": "9.99"`
- Add `"priceSpecification"` with billing period info:
  ```json
  "offers": {
    "@type": "Offer",
    "price": "9.99",
    "priceCurrency": "USD",
    "priceSpecification": {
      "@type": "UnitPriceSpecification",
      "price": "9.99",
      "priceCurrency": "USD",
      "billingDuration": "P1M"
    }
  }
  ```
- Update `<meta name="description">` to mention pricing

### Phase 3: Create /thank-you Page (New file)

**File:** `website/src/pages/thank-you.astro`

**Content:**
- Headline: "You're in! Welcome to Drobu."
- Download button linking to the latest release `.dmg`/`.zip` (GitHub Releases URL stays as the artifact host — it's public anyway)
- Brief setup instructions:
  1. Open the .dmg
  2. Drag to Applications
  3. Grant Accessibility permission when prompted
  4. Gatekeeper bypass note ("macOS shows a security warning?")
- "Manage your subscription" link → Stripe Customer Portal URL
- Note: "A receipt has been sent to your email."
- Non-macOS messaging: "On a different device? Open this page on your Mac to download."

**Layout:** Uses the existing `Landing.astro` layout but with a simpler structure (no nav sections needed).

### Phase 4: Create Terms & Privacy Pages (New files)

Required by Stripe for checkout. Minimal but legally necessary.

**File:** `website/src/pages/terms.astro`

Cover:
- Subscription terms ($9.99/mo, auto-renews)
- 14-day free trial with auto-conversion disclosure
- Cancellation policy (cancel anytime, access continues through billing period)
- Refund policy
- "As-is" warranty disclaimer

**File:** `website/src/pages/privacy.astro`

Cover:
- Local-first: clipboard data never leaves the device
- Stripe collects: email, payment info (link to Stripe's privacy policy)
- No analytics / tracking on the landing page (or disclose if added)
- No account system — no user data stored on servers
- Contact info for privacy questions

### Phase 5: Update Stripe Payment Link Configuration

After /thank-you and /terms and /privacy pages are deployed:

1. Update Payment Link success redirect to the deployed /thank-you URL
2. Add Terms of Service URL to Stripe Checkout
3. Add Privacy Policy URL to Stripe Checkout
4. Test the full flow end-to-end

## Files Summary

| File | Action | Key Change |
|------|--------|------------|
| `website/src/components/Header.astro` | Edit | Remove GitHub icon link |
| `website/src/components/Hero.astro` | Edit | CTA → Stripe link, remove GitHub button, update copy |
| `website/src/components/DownloadCTA.astro` | Edit | CTA → Stripe link, remove "View source", update copy |
| `website/src/components/Footer.astro` | Edit | Remove GitHub link, add Terms/Privacy links |
| `website/src/layouts/Landing.astro` | Edit | Update structured data pricing + meta description |
| `website/src/pages/thank-you.astro` | **Create** | Post-checkout success page with download link |
| `website/src/pages/terms.astro` | **Create** | Terms of Service |
| `website/src/pages/privacy.astro` | **Create** | Privacy Policy |

## Acceptance Criteria

- [x] No GitHub URLs, "open source", or "free" text anywhere on the site
- [x] Primary CTA in Hero links to Stripe Payment Link
- [x] Primary CTA in DownloadCTA links to Stripe Payment Link
- [x] Pricing copy shows "$9.99/mo after 14-day free trial"
- [x] "Cancel anytime" messaging visible near price
- [x] Non-macOS visitors see disabled "macOS only" CTA (no dead GitHub link)
- [x] /thank-you page exists with download link and setup instructions
- [x] /terms page exists with subscription terms and auto-renewal disclosure
- [x] /privacy page exists with local-first data practices and Stripe data collection
- [x] Footer links to Terms and Privacy pages
- [x] Schema.org structured data shows price "9.99" USD
- [x] `npm run build` succeeds with no errors
- [ ] Full Stripe Payment Link → /thank-you flow works end-to-end

## Open Items (Deferred)

These are out of scope for this plan but should be addressed before or shortly after launch:

1. **App-side license enforcement** — the app currently works for everyone regardless of payment
2. **Apple Developer ID / notarization** — Gatekeeper warning is acceptable for now but hurts trust for a paid product
3. **Existing user migration** — current free users need communication about the change
4. **Analytics / conversion tracking** — no funnel visibility currently
5. **Annual pricing option** — monthly only for launch
6. **Custom domain** — still on `danieliusisiunas.github.io/clipboard-history/`; a `drobu.app` domain would look more professional for a paid product
7. **Email capture for non-macOS visitors** — requires email service (Mailchimp/ConvertKit)

## Placeholder Note

The Stripe Payment Link URL is not yet created. Use `#STRIPE_PAYMENT_LINK` as a placeholder in the code. Replace with the real URL after creating the product in Stripe Dashboard.
