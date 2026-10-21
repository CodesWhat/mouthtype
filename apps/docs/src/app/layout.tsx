import { RootProvider } from "fumadocs-ui/provider/next";
import type { Metadata } from "next";
import localFont from "next/font/local";
import type { ReactNode } from "react";
import { BASE_PATH, BASE_URL, SITE_CONFIG } from "@/lib/site-config";
import "./globals.css";

// Same files as the product site (website/public/fonts). next/font emits the URLs itself,
// so they pick up DOCS_BASE_PATH without extra work.
const instrumentSans = localFont({
  src: "../../public/fonts/instrument-sans-latin-wght-normal.woff2",
  weight: "400 700",
  variable: "--font-instrument-sans",
});
const instrumentSerif = localFont({
  src: [
    { path: "../../public/fonts/instrument-serif-latin-400-normal.woff2", style: "normal" },
    { path: "../../public/fonts/instrument-serif-latin-400-italic.woff2", style: "italic" },
  ],
  weight: "400",
  variable: "--font-instrument-serif",
});
const jetbrainsMono = localFont({
  src: "../../public/fonts/jetbrains-mono-latin-wght-normal.woff2",
  weight: "100 800",
  variable: "--font-jetbrains-mono",
});

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
  icons: {
    icon: [
      { url: `${BASE_PATH}/assets/favicon.ico`, sizes: "any" },
      { url: `${BASE_PATH}/assets/favicon-32.png`, type: "image/png", sizes: "32x32" },
      { url: `${BASE_PATH}/assets/favicon-16.png`, type: "image/png", sizes: "16x16" },
    ],
    apple: `${BASE_PATH}/assets/apple-touch-icon.png`,
  },
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html
      lang="en"
      className={`${instrumentSans.variable} ${instrumentSerif.variable} ${jetbrainsMono.variable}`}
      suppressHydrationWarning
    >
      <body>
        <RootProvider search={{ options: { type: "static", api: `${BASE_PATH}/api/search` } }}>
          {children}
        </RootProvider>
      </body>
    </html>
  );
}
