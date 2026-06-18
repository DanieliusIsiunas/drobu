// @ts-check
import { defineConfig } from "astro/config";
import tailwindcss from "@tailwindcss/vite";
import sitemap from "@astrojs/sitemap";

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
    }),
  ],
  devToolbar: { enabled: false },
  vite: {
    plugins: [tailwindcss()],
  },
});
