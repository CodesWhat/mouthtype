import type { MetadataRoute } from "next";
import { absoluteUrl } from "@/lib/site-config";
import { source } from "@/lib/source";

export const dynamic = "force-static";

export default function sitemap(): MetadataRoute.Sitemap {
  return source.getPages().map((page) => ({
    url: absoluteUrl(page.url),
    changeFrequency: "weekly" as const,
    priority: page.url === "/" ? 1 : 0.7,
  }));
}
