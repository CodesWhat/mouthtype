import type { MetadataRoute } from "next";
import { BASE_URL } from "@/lib/site-config";
import { source } from "@/lib/source";

export default function sitemap(): MetadataRoute.Sitemap {
  const generatedAt = new Date();
  return source.getPages().map((page) => ({
    url: `${BASE_URL}${page.url === "/" ? "" : page.url}`,
    lastModified: generatedAt,
    changeFrequency: "weekly" as const,
    priority: page.url === "/" ? 1 : 0.7,
  }));
}
