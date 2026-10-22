#!/usr/bin/env bash
# Build a static, signed apt repository from one or more .deb files with apt-ftparchive and gpg.
#
#   bash packaging/debian/build-apt-repo.sh --output DIR --key KEYID --deb FILE [--deb FILE ...]
#        [--url https://mouthtype.app/apt] [--gnupghome DIR] [--passphrase-file FILE]
#
# DIR becomes the web root for https://mouthtype.app/apt/ :
#   dists/stable/{Release,InRelease,Release.gpg}   signed index
#   dists/stable/main/binary-amd64/Packages(.gz,.xz)
#   pool/main/m/mouthtype-linux/*.deb
#   mouthtype-archive-keyring.gpg                  public key, binary (what Signed-By points at)
#   mouthtype-archive-keyring.asc                  public key, armored
#   mouthtype.sources                              deb822 source snippet users install
# Re-running with the same DIR adds the new .deb to the pool and re-signs, so older versions stay available.
# Needs apt-utils (apt-ftparchive), gnupg and gzip/xz. Never put a private key in the repo or in DIR.
set -euo pipefail

output= key= url=https://mouthtype.app/apt gnupghome= passfile=
debs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --output) output=${2:?}; shift 2 ;;
        --key) key=${2:?}; shift 2 ;;
        --deb) debs+=("${2:?}"); shift 2 ;;
        --url) url=${2:?}; shift 2 ;;
        --gnupghome) gnupghome=${2:?}; shift 2 ;;
        --passphrase-file) passfile=${2:?}; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$output" ] && [ -n "$key" ] && [ ${#debs[@]} -gt 0 ] || {
    echo "usage: build-apt-repo.sh --output DIR --key KEYID --deb FILE [--deb FILE ...] [--url URL]" >&2; exit 2; }
command -v apt-ftparchive >/dev/null || { echo "apt-ftparchive missing (install apt-utils)" >&2; exit 2; }
[ -z "$gnupghome" ] || export GNUPGHOME=$gnupghome

suite=stable component=main arch=amd64
gpg_sign=(gpg --batch --yes --local-user "$key")
[ -z "$passfile" ] || gpg_sign+=(--pinentry-mode loopback --passphrase-file "$passfile")

mkdir -p "$output"
output=$(cd "$output" && pwd)
pool="$output/pool/$component/m/mouthtype-linux"
mkdir -p "$pool"
for deb in "${debs[@]}"; do
    dpkg-deb --field "$deb" Package >/dev/null || { echo "not a .deb: $deb" >&2; exit 2; }
    [ "$(dpkg-deb --field "$deb" Package)" = mouthtype-linux ] || { echo "unexpected package in $deb" >&2; exit 2; }
    cp "$deb" "$pool/"
done

index="$output/dists/$suite/$component/binary-$arch"
mkdir -p "$index"
(
    cd "$output"
    apt-ftparchive packages "pool/$component" > "dists/$suite/$component/binary-$arch/Packages"
)
gzip -9nc "$index/Packages" > "$index/Packages.gz"
xz -9ec "$index/Packages" > "$index/Packages.xz"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<CONF
APT::FTPArchive::Release::Origin "Mouthtype";
APT::FTPArchive::Release::Label "Mouthtype";
APT::FTPArchive::Release::Suite "$suite";
APT::FTPArchive::Release::Codename "$suite";
APT::FTPArchive::Release::Architectures "$arch";
APT::FTPArchive::Release::Components "$component";
APT::FTPArchive::Release::Description "Mouthtype Linux client";
CONF
apt-ftparchive -c "$tmp" release "$output/dists/$suite" > "$output/dists/$suite/Release.new"
mv "$output/dists/$suite/Release.new" "$output/dists/$suite/Release"

rm -f "$output/dists/$suite/InRelease" "$output/dists/$suite/Release.gpg"
"${gpg_sign[@]}" --clearsign --output "$output/dists/$suite/InRelease" "$output/dists/$suite/Release"
"${gpg_sign[@]}" --detach-sign --output "$output/dists/$suite/Release.gpg" "$output/dists/$suite/Release"

gpg --batch --yes --export "$key" > "$output/mouthtype-archive-keyring.gpg"
gpg --batch --yes --armor --export "$key" > "$output/mouthtype-archive-keyring.asc"
[ -s "$output/mouthtype-archive-keyring.gpg" ] || { echo "no public key exported for $key" >&2; exit 1; }

cat > "$output/mouthtype.sources" <<SRC
Types: deb
URIs: $url
Suites: $suite
Components: $component
Architectures: $arch
Signed-By: /etc/apt/keyrings/mouthtype-archive-keyring.gpg
SRC

echo "$output"
