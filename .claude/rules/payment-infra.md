# Payment Infrastructure Gotchas

Learned standing up drobu.app + the purchase-path monitoring (2026-06-10).

## A URL baked into a shipped binary is a permanent contract — payments edition

The Stripe Payment Link shipped inside v1.2–v1.5.2 binaries is the commerce
equivalent of `SUFeedURL` (see sparkle-macos-gotchas.md): never deactivate
it, never "rotate" by creating a new link — installed apps point at it
forever and Sparkle updates are optional. **Price changes edit the existing
link in place** (CLAUDE.md has the full price-change checklist). New builds
go through `https://drobu.app/buy` (Cloudflare edge 302) precisely so the
checkout target stays mutable — that redirect URL is itself the next
permanent contract. Both are watched by `payment-links-monitor.yml` (daily)
and the `release.sh` preflight, which pin the redirect's **exact** target
URL — a prefix match (`buy.stripe.com/*`) would stay green on a hijacked
or retargeted redirect.

## .app TLD is HSTS-preloaded — redirects must serve valid TLS

The entire `.app` TLD is on the browser HSTS preload list: there is no
HTTP fallback, so any redirect host must present a valid cert for the
domain. Registrar-level "URL forwarding" (plain HTTP 301) silently fails
for `.app` domains — users see a hard TLS error. Cloudflare proxied DNS +
Universal SSL is the free path (dummy A record `192.0.2.1`, proxied, with
edge Redirect Rules).

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
