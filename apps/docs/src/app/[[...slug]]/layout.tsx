import { DocsLayout } from "fumadocs-ui/layouts/docs";
import { SearchTrigger } from "fumadocs-ui/layouts/shared/slots/search-trigger";
import type { ReactNode } from "react";
import { SearchButton } from "@/components/search-button";
import { SiteLogo } from "@/components/site-logo";
import { ThemeToggle } from "@/components/theme-toggle";
import { source } from "@/lib/source";

export default function Layout({ children }: { children: ReactNode }) {
  return (
    <DocsLayout
      tree={source.getPageTree()}
      nav={{ title: <SiteLogo />, url: "/" }}
      links={[{ text: "Download", url: "https://mouthtype.app/download", external: true }]}
      githubUrl={undefined}
      // One search (the sidebar trigger) and one compact theme button. The stock theme switch
      // sits in a bordered, search-looking box that reads as a second search field.
      slots={{ themeSwitch: false, searchTrigger: { full: SearchButton, sm: SearchTrigger } }}
      sidebar={{ footer: <ThemeToggle /> }}
    >
      {children}
    </DocsLayout>
  );
}
