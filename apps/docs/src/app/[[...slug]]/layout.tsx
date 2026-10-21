import { DocsLayout } from "fumadocs-ui/layouts/docs";
import type { ReactNode } from "react";
import { SiteLogo } from "@/components/site-logo";
import { source } from "@/lib/source";

export default function Layout({ children }: { children: ReactNode }) {
  return (
    <DocsLayout
      tree={source.getPageTree()}
      nav={{ title: <SiteLogo />, url: "/" }}
      links={[{ text: "Download", url: "https://mouthtype.app/download", external: true }]}
      githubUrl={undefined}
    >
      {children}
    </DocsLayout>
  );
}
