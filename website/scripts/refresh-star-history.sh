#!/usr/bin/env bash
# Refresh the self-hosted Star History charts shown on the homepage.
# Run by hand when you want fresh numbers. The site itself never calls
# star-history.com (CSP img-src 'self'). Usage: bash website/scripts/refresh-star-history.sh
set -euo pipefail

out="$(cd "$(dirname "${BASH_SOURCE[0]}")/../public/assets" && pwd)"
base='https://api.star-history.com/chart?repos=codeswhat/mouthtype&type=date&legend=top-left'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fetch() { # url dest
  curl -fsSL --retry 2 -A 'Mozilla/5.0' -D "$tmp/h" -o "$tmp/body" "$1"
  if ! grep -qi '^content-type: image/svg+xml' "$tmp/h" \
    || [ "$(wc -c <"$tmp/body")" -lt 20000 ] \
    || ! grep -q 'codeswhat/mouthtype' "$tmp/body" \
    || ! grep -q 'GitHub Stars' "$tmp/body"; then
    echo "refusing to overwrite $2: response is not a real chart" >&2
    exit 1
  fi
  mv "$tmp/body" "$2"
}

fetch "$base" "$out/star-history.svg"
fetch "$base&theme=dark" "$out/star-history-dark.svg"
echo "Updated star-history.svg and star-history-dark.svg in $out"
