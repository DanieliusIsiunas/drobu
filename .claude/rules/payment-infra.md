# Payment Infrastructure Gotchas

Learned standing up drobu.app + the purchase-path monitoring (2026-06-10).

## A URL baked into a shipped binary is a permanent contract — payments edition

The Stripe Payment Link shipped inside v1.2–v1.5.2 binaries is the commerce
equivalent of `SUFeedURL` (see sparkle-macos-gotchas.md): never deactivate
it, never "rotate" by creating a new link — installed apps point at it
forever and Sparkle updates are optional. **Price changes edit the existing
link in place** (CLAUDE.md has the full price-change checklist). New builds
go through `https://drobu.app/buy` precisely so the checkout target stays
mutable — that URL is itself the next permanent contract. Both are watched
by `payment-links-monitor.yml` (daily) and the `release.sh` preflight,
which pin the **exact** Stripe URL (in the `/buy` page body) — a prefix
match (`buy.stripe.com/*`) would stay green on a hijacked or retargeted
redirect.

## `/buy` is a static page on GitHub Pages, not an edge redirect

We did NOT need Cloudflare. The site lives on GitHub Pages at the `drobu.app`
custom domain (DNS stayed at Hostinger — 4 apex A records to GitHub's
`185.199.108-111.153`, www CNAME, email MX/SPF/DKIM untouched). `/buy` is a
static Astro page (`website/src/pages/buy.astro`) that meta-refresh + JS
redirects to the Stripe link. GitHub Pages can't issue a server 302, but a
static page is fine — and arguably better: the redirect target is
version-controlled in the repo (not a dashboard rule), with a visible
fallback link. The monitor checks it as a 200 page containing the exact
target, not a 302.

## .app TLD is HSTS-preloaded — the redirect host must serve valid TLS

The entire `.app` TLD is on the browser HSTS preload list: no HTTP fallback,
so whatever serves `drobu.app/buy` must present a valid cert. Registrar
"URL forwarding" (plain HTTP 301, no cert) silently fails — users see a hard
TLS error. GitHub Pages provisions a free Let's Encrypt cert for the custom
domain automatically (covers apex + `www`), which satisfies this. Attaching
the custom domain also makes GitHub 301 the old `<user>.github.io/<repo>/*`
paths to the domain — that is what keeps a baked-in `SUFeedURL` alive across
the flip (a rename, by contrast, 404s — see sparkle-macos-gotchas.md).

## Stripe Checkout pages render client-side — no product-name assertions

A Payment Link's static HTML is a ~500KB app shell titled "Stripe
Checkout" with a `livemode` marker; the product name and price are NOT in
the HTML (client-side render). Monitoring can assert status 200 + shell
size + `livemode`, nothing stronger. Two traps: a *deactivated* link may
still serve HTTP 200 (assert on body shape, never status alone — and
empirically capture a deactivated test link's response before trusting
any discriminator), and `livemode` matches test-mode shells too
(`"livemode":false`), so it proves shell shape, not live-mode.

## `VAR=$(cmd || echo 0)` concatenates on failure — use assignment fallback

If `cmd` prints partial output (e.g. curl's `-w '%{size_download}'` after
a failed transfer, no trailing newline) and exits non-zero, the fallback
`echo 0` APPENDS: `"15360"` + `"0"` → `"153600"`, which can flip a
size-threshold check from fail to pass. Use `VAR=$(cmd) || VAR=0` so the
fallback replaces instead of appending.
