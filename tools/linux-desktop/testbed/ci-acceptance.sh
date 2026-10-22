#!/usr/bin/env bash
# Build the T1/T3-based acceptance images and run the gnome-portal and kde-portal components, collecting evidence.
# Usage: ci-acceptance.sh <evidence-dir> [gnome|kde ...]   (default: both)
# DOCKER overrides the docker command, e.g. DOCKER="bash ~/scripts/nas-docker.sh" to run on the NAS testbed.
set -uo pipefail

evidence=${1:?Provide the evidence directory}
shift
components=("$@")
[[ ${#components[@]} -gt 0 ]] || components=(gnome kde)
read -r -a docker <<< "${DOCKER:-docker}"
tag=${MOUTHTYPE_ACCEPTANCE_TAG:-ld-a3}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
desktop=$(dirname "$here")
tools=$(dirname "$desktop")
mkdir -p "$evidence"
limit=(env); command -v timeout >/dev/null && limit=(timeout --kill-after=10s 300s)
status=0
containers=()
cleanup() {
  for name in "${containers[@]:-}"; do "${docker[@]}" rm -f "$name" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

run_component() { # name, base dockerfile, base context, acceptance dockerfile, acceptance context, evidence path in container
  local name=$1 out=$evidence/$1
  mkdir -p "$out"
  {
    "${docker[@]}" build -f "$2" -t "$tag-$name-base:test" "$3" &&
    "${docker[@]}" build -f "$4" --build-arg "BASE=$tag-$name-base:test" -t "$tag-$name:test" "$5"
  } > "$out/build.log" 2>&1 || { echo "$name image build failed; see build.log" >&2; status=1; return; }
  containers+=("$tag-$name-run")
  "${docker[@]}" rm -f "$tag-$name-run" >/dev/null 2>&1 || true
  "${limit[@]}" "${docker[@]}" run --name "$tag-$name-run" "$tag-$name:test" > "$out/run.log" 2>&1 || status=1
  "${docker[@]}" cp "$tag-$name-run:$6/." "$out/" > /dev/null 2>&1 || { echo "$name evidence copy failed" >&2; status=1; }
  [[ -s $out/$name-portal.json ]] || status=1
}

for component in "${components[@]}"; do
  case $component in
    gnome) run_component gnome "$here/gnome/Dockerfile" "$here/gnome" "$here/gnome/acceptance.Dockerfile" "$desktop" /home/tester/evidence ;;
    kde) run_component kde "$here/kde/Dockerfile" "$here/kde" "$here/kde/acceptance.Dockerfile" "$tools" /var/lib/testbed ;;
    *) echo "unknown component $component" >&2; status=1 ;;
  esac
done
exit "$status"
