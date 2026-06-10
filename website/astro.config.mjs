// @ts-check
import { defineConfig } from "astro/config";
import tailwindcss from "@tailwindcss/vite";
import react from "@astrojs/react";

export default defineConfig({
  // Custom domain (GitHub Pages serves the site at the apex; the old
  // danieliusisiunas.github.io/drobu/* URLs 301-redirect here, which is
  // what keeps the SUFeedURL baked into shipped binaries working).
  site: "https://drobu.app",
  integrations: [react()],
  devToolbar: { enabled: false },
  vite: {
    plugins: [tailwindcss()],
  },
});
