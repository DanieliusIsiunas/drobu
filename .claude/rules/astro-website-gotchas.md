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
