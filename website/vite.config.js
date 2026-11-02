import { defineConfig } from "vite";
import deployment from "./vercel.json" with { type: "json" };
import { fileURLToPath } from "node:url";

// vite preview ignores vercel.json routes, so mirror the ones that set a Content-Type for the page tests.
const contentTypes = {
  name: "vercel-content-types",
  configurePreviewServer(server) {
    server.middlewares.use((request, response, next) => {
      const path = (request.url ?? "").split("?")[0];
      const route = deployment.routes.find(
        (entry) => entry.headers?.["Content-Type"] && new RegExp(`^${entry.src}$`).test(path),
      );
      if (route) response.setHeader("Content-Type", route.headers["Content-Type"]);
      next();
    });
  },
};

export default defineConfig({
  plugins: [contentTypes],
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
