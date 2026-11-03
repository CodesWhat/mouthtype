import { createFromSource } from "fumadocs-core/search/server";
import { source } from "@/lib/source";

// Static export: the search index is built once at build time and served as a file.
// The client (RootProvider search options in layout.tsx) loads it with the static client.
export const revalidate = false;
export const dynamic = "force-static";

type Headings = { id: string; content: string }[];
type Structured = { headings: Headings };

// Index titles, descriptions and headings only. Full body text made the index several MB.
export const { staticGET: GET } = createFromSource(source, {
  buildIndex: async (page) => {
    const data = page.data as {
      structuredData?: Structured | (() => Promise<Structured>);
      load?: () => Promise<{ structuredData: Structured }>;
    };
    const structured =
      typeof data.structuredData === "function"
        ? await data.structuredData()
        : (data.structuredData ?? (await data.load?.())?.structuredData);
    return {
      id: page.url,
      url: page.url,
      title: page.data.title ?? page.url,
      description: page.data.description,
      structuredData: { headings: structured?.headings ?? [], contents: [] },
    };
  },
});
