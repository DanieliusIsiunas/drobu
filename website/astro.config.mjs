// @ts-check
import { defineConfig } from "astro/config";
import tailwindcss from "@tailwindcss/vite";
import sitemap from "@astrojs/sitemap";

// Stamp every sitemap entry with the build time. This is a static site that is
// rebuilt and redeployed whenever content changes, so the deploy time is a
// truthful "last modified" hint that tells search engines to re-crawl after a
// change (e.g. the positioning/copy reframe) instead of waiting out their
// default schedule.
const lastmod = new Date().toISOString();

export default defineConfig({
  // Custom domain (GitHub Pages serves the site at the apex; the old
  // danieliusisiunas.github.io/drobu/* URLs 301-redirect here, which is
  // what keeps the SUFeedURL baked into shipped binaries working).
  site: "https://drobu.app",
  integrations: [
    sitemap({
      // Keep the noindex pages out of the sitemap so we never advertise a
      // URL we're asking search engines not to index.
      filter: (page) =>
        !page.includes("/buy") && !page.includes("/thank-you"),
      serialize: (item) => ({ ...item, lastmod }),
    }),
  ],
  devToolbar: { enabled: false },
  vite: {
    plugins: [tailwindcss()],
  },
});
