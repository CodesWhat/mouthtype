import { RootProvider } from "fumadocs-ui/provider/next";
import type { Metadata } from "next";
import type { ReactNode } from "react";
import { BASE_URL, SITE_CONFIG } from "@/lib/site-config";
import "./globals.css";

export const metadata: Metadata = {
  title: {
    default: `${SITE_CONFIG.name} docs`,
    template: `%s | ${SITE_CONFIG.name} docs`,
  },
  description: SITE_CONFIG.description,
  metadataBase: new URL(BASE_URL),
  openGraph: {
    title: `${SITE_CONFIG.name} docs`,
    description: SITE_CONFIG.description,
    siteName: SITE_CONFIG.name,
    type: "website",
  },
  icons: { icon: "/assets/mouthtype-icon.png" },
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body>
        <RootProvider>{children}</RootProvider>
      </body>
    </html>
  );
}
