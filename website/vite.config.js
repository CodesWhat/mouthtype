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
    headers: Object.fromEntries(
      deployment.headers[0].headers.map(({ key, value }) => [key, value]),
    ),
  },
});
