import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { type InferPageType, llms } from "fumadocs-core/source";
import { absoluteUrl, BASE_URL } from "@/lib/site-config";
import { source } from "@/lib/source";

function stripFrontmatter(text: string) {
  return text.replace(/^---\n[\s\S]*?\n---\n+/, "");
}

/** Raw Markdown of a page, read from the synced content, with a title heading. */
async function renderPage(page: InferPageType<typeof source>) {
  const raw = await readFile(join(process.cwd(), "content", "docs", page.path), "utf8");
  const url = absoluteUrl(page.url);
  return `# ${page.data.title}\n\nURL: ${url}\n\n${stripFrontmatter(raw).trim()}\n`;
}

export const llmsOutput = llms(source, { renderPage });

/** llms.txt with absolute links, so it still makes sense when read outside the site. */
export function llmsIndex() {
  return llmsOutput.index().replaceAll("](/", `](${BASE_URL}/`);
}
