import type { Page } from "fumadocs-core/source";
import { loader } from "fumadocs-core/source";
import { docs } from "../../.source/server";

// The docs are the whole site, so pages live at the root ("/dictating", not "/docs/dictating").
export const source = loader(docs.toFumadocsSource(), {
  baseUrl: "/",
});

/** Frontmatter + body type for a docs page, derived from the generated collection. */
export type DocsPageData = (typeof docs.docs)[number];

/** Typed getPage, avoids `as any` while preserving fumadocs' slug typing. */
export function getDocsPage(slugs?: string[]) {
  return source.getPage(slugs) as Page<string | undefined, DocsPageData> | undefined;
}
