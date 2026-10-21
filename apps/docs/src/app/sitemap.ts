import type { MetadataRoute } from "next";
import { absoluteUrl } from "@/lib/site-config";
import { source } from "@/lib/source";

export const dynamic = "force-static";

export default function sitemap(): MetadataRoute.Sitemap {
  const generatedAt = new Date();
  return source.getPages().map((page) => ({
    url: absoluteUrl(page.url),
    lastModified: generatedAt,
    changeFrequency: "weekly" as const,
    priority: page.url === "/" ? 1 : 0.7,
  }));
}
