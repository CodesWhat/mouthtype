#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(uname -s)" != Linux ]]; then
  echo 'This entry point requires Linux. Host orchestration tests use unittest separately.' >&2
  exit 2
fi
exec "${MOUTHTYPE_PROOF_PYTHON:-python3}" "$script_dir/proof.py" "$@"
