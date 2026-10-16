#!/bin/bash
set -euo pipefail
website_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$website_dir/.." && pwd)"
render_dir="$(mktemp -d "${TMPDIR:-/tmp}/mouthtype-assets.XXXXXX")"
trap 'rm -f "$render_dir/render-pills"; rmdir "$render_dir"' EXIT
swiftc -parse-as-library -O \
  "$repo_dir/Sources/MouthtypeMac/Audio/LevelMeter.swift" \
  "$repo_dir/Sources/MouthtypeMac/Typography/Typography.swift" \
  "$repo_dir/Sources/MouthtypeMac/Typography/FontRegistry.swift" \
  "$repo_dir/Sources/MouthtypeMac/Pill/BarModel.swift" \
  "$repo_dir/Sources/MouthtypeMac/Pill/PillMessage.swift" \
  "$repo_dir/Sources/MouthtypeMac/Pill/PillSkin.swift" \
  "$repo_dir/Sources/MouthtypeMac/Pill/ClassicPillLayout.swift" \
  "$repo_dir/Sources/MouthtypeMac/Pill/ClassicPillView.swift" \
  "$repo_dir/Sources/MouthtypeMac/Pill/BitmapFont.swift" \
  "$repo_dir/Sources/MouthtypeMac/Pill/PillLayout.swift" \
  "$repo_dir/Sources/MouthtypeMac/Pill/HiFiPillView.swift" \
  "$repo_dir/Sources/MouthtypeMac/Pill/PillTimeline.swift" \
  "$website_dir/scripts/render-pill-assets.swift" \
  -o "$render_dir/render-pills"
"$render_dir/render-pills" "$repo_dir" "$website_dir/public/assets"
