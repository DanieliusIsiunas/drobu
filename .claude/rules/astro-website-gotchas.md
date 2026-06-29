# Astro Website Gotchas

Learned wiring Umami analytics into the Astro site (`website/`, GitHub Pages).

## `<script is:inline>` emits its body VERBATIM — a `{`…`}` child does NOT get evaluated

A `<script is:inline>` whose child is a template-literal expression ships the
braces and backticks **literally** into the HTML:

```astro
<!-- WRONG: renders <script>{`document.addEventListener(...)`}</script> -->
<script is:inline>
  {`document.addEventListener("DOMContentLoaded", function () { ... });`}
</script>
```

The browser then runs a **bare block** `{ "…a discarded template string…" }` — the
template literal is evaluated as a useless expression statement and thrown away,
so the code inside the string **never executes**. There is no error; it silently
does nothing. (`is:inline` deliberately disables Astro's normal processing, so it
does NOT evaluate the `{…}` expression the way a processed script or a plain
template position would.)

This is doubly confusing because **`curl`-grepping the deployed HTML "finds" your
code** — the source text is right there in the `<script>` — yet it's inert. The
only reliable check is runtime: load the page and inspect the side effect (here:
`document.querySelector('.js-app-download').getAttribute('data-umami-event')` was
`null` even though `window.umami` was loaded and pageviews were POSTing).

**Fix — inject the body with `set:html`** (evaluates the expression, writes it as
the raw script body):

```astro
<script
  is:inline
  set:html={`document.addEventListener("DOMContentLoaded", function () {
  document.querySelectorAll(".js-app-download").forEach(function (el) {
    el.setAttribute("data-umami-event", "Download");
  });
});`}
/>
```

Verify in `dist/`: the rendered tag must be `<script>document.addEventListener…`
with **no** leading `{` or backtick. A leftover `` {` `` means it's still broken.

(A plain *processed* `<script>` — no `is:inline` — would also run the JS, but
Astro bundles it as a module and you lose the build-time gate / inline guarantee.
For a gated inline snippet, `is:inline set:html` is the right tool.)

## Verifying client-side analytics: use a real browser, not curl

`curl | grep` only proves the bytes shipped, never that the JS ran or the beacon
fired (see above). Use the Playwright MCP against the LIVE site:

1. `browser_navigate` to `https://drobu.app/?cb=N` (cache-bust GitHub Pages CDN).
2. `browser_evaluate` to assert the DOM side effect (attribute set, `window.umami`
   is an object).
3. Wrap `window.fetch` to capture the `/api/send` POST body, synthesize a
   `.click()`, and read back `{type:"event", name:"Download", …}` — definitive
   proof the event fires with the right name. A synthetic `el.click()` DOES
   trigger Umami's document-level **capture-phase** click listener.

Umami's native link tracking (`data-umami-event` on an `<a>`): its document click
listener does `e.target.closest("[data-umami-event]")`, reads the attribute **at
click time** (so setting it later via JS is fine), then for an `<a>`:
`e.preventDefault()` → `track()` → navigate in `.finally()`. A hand-rolled
`umami.track()` on the same click is unreliable because the link navigates before
the beacon settles — always prefer the `data-umami-event` attribute for
download/outbound links.

## Product-demo media: use video, not GIF — and the full web-media checklist

Learned converting homepage demos from CSS mockups → real captures (PR #87). A
GIF demo drew **eleven** Codex review rounds, almost all rooted in the format;
converting to MP4 collapsed the class. For any UI/product demo on the site:

- **Use MP4 (H.264), never an animated GIF.** A GIF is an animated `<img>` with no
  playback API, so you cannot pause/stop it, can't enforce reduced-motion at
  markup time, and it's ~3x larger. (`image-crop.gif` 973KB → `image-crop.mp4`
  324KB.) Convert with `tools/web-media.sh` (needs `ffmpeg`).
- **Frame the capture chrome-free.** Drobu's surface is a floating panel, NOT a
  Mac window — do not wrap real captures in MacWindow traffic-light chrome. The
  `Showcase` component is the one frame (rounded + hairline border + shadow).
- **Motion accessibility (WCAG 2.2.2) — all of these, or Codex will find each
  one separately:**
  - NO `autoplay` attribute. Start playback in JS only when motion is welcome, so
    reduced-motion AND no-JS visitors rest on the `poster` (enforced at markup).
  - Always-visible pause/play toggle (`<button>`, `aria-label`/`aria-pressed`),
    because an autoplaying loop >5s needs a stop path for everyone, not just
    reduced-motion users.
- **Perf — also flagged one at a time:**
  - `IntersectionObserver` gates *playback*: only on-screen showcases play; pause
    on scroll-away; honor the manual-pause intent flag.
  - `preload="none"` gates the *download* — otherwise the browser fetches every
    below-the-fold video on load even with playback gated. The observer's `play()`
    triggers the fetch when near-viewport.
  - **Faststart (`moov` atom before `mdat`).** `ffmpeg -c copy -movflags
    +faststart` (lossless remux, no re-encode). Check order with
    `ffprobe -v trace f.mp4 2>&1 | grep -oE "type:'(moov|mdat)'" | head -2`.
    Externally-supplied MP4s often are NOT faststart — re-remux them; only assets
    you ran through the convert script are guaranteed.
- **Poster = a representative MID-clip frame showing the product, NOT frame 0.**
  Frame 0 of a workflow capture is usually the "before" desktop with no app UI —
  shipping that as the reduced-motion/no-JS still drew its own P2. Pick a frame
  where the app UI is on screen (`ffmpeg -ss <t> -i in -frames:v 1 poster.jpg`);
  `web-media.sh` now defaults to the midpoint.
