import { defineConfig } from "vite";
import deployment from "./vercel.json" with { type: "json" };
import { fileURLToPath } from "node:url";

export default defineConfig({
  build: {
    rolldownOptions: {
      input: Object.fromEntries(
        [
          "index",
          "start/index",
          "download/index",
          "linux/index",
          "docs/index",
          "why-mouthtype/index",
          "compare/index",
          "compare/apple-dictation/index",
          "compare/wispr-flow/index",
        ].map((page) => [
          page,
          fileURLToPath(new URL(`./${page}.html`, import.meta.url)),
        ]),
      ),
    },
  },
  preview: {
    headers: deployment.routes[0].headers,
  },
});
