import { defineConfig } from "vite";
import deployment from "./vercel.json" with { type: "json" };

export default defineConfig({
  preview: {
    headers: Object.fromEntries(
      deployment.headers[0].headers.map(({ key, value }) => [key, value]),
    ),
  },
});
