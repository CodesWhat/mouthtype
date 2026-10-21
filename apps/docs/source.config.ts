import { remarkSteps } from "fumadocs-core/mdx-plugins/remark-steps";
import { defineConfig, defineDocs } from "fumadocs-mdx/config";
import remarkCustomHeadingId from "remark-custom-heading-id";

import remarkDocsBlocks from "./src/lib/remark-docs-blocks.mjs";
import remarkLiteralIdentifierExpressions from "./src/lib/remark-literal-identifier-expressions.mjs";

export const docs = defineDocs({
  dir: "content/docs",
});

export default defineConfig({
  mdxOptions: {
    remarkPlugins: [
      remarkCustomHeadingId,
      remarkLiteralIdentifierExpressions,
      remarkDocsBlocks,
      remarkSteps,
    ],
  },
});
