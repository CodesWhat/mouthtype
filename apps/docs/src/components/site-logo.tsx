import { BASE_PATH, SITE_CONFIG } from "@/lib/site-config";

export function SiteLogo() {
  return (
    <span className="mt-brand">
      {/* biome-ignore lint/performance/noImgElement: static pixel-art icon, no optimization wanted */}
      <img
        src={`${BASE_PATH}/assets/mouthtype-icon.png`}
        alt=""
        width={24}
        height={24}
        className="mt-brand-icon"
      />
      <span className="mt-brand-name">{SITE_CONFIG.name}</span>
    </span>
  );
}
