#!/usr/bin/env bash
# End-to-end signed apt flow in a disposable Debian or Ubuntu container (run as root, repo mounted at /ws or
# passed as $1): throwaway GPG key, build two versions, publish v1, apt update, apt install, publish v2,
# apt upgrade, then confirm a tampered index and an untrusted key are both rejected.
set -euo pipefail

root=$(cd "${1:-/ws}" && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root inside a disposable container" >&2; exit 2; }
export DEBIAN_FRONTEND=noninteractive GNUPGHOME=/tmp/throwaway-gnupg
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
. /etc/os-release; echo "$PRETTY_NAME"

step "tools"
apt-get update -qq
apt-get install -y -qq --no-install-recommends python3 dpkg-dev apt-utils gnupg gzip xz-utils ca-certificates >/dev/null

step "throwaway key (never reused, lives only in this container)"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'Mouthtype Test Throwaway <test@invalid>' ed25519 sign never 2>/dev/null
key=$(gpg --batch --list-secret-keys --with-colons | awk -F: '$1 == "fpr" {print $10; exit}')
echo "key $key"

step "build v1 and v2"
mkdir -p /tmp/debs /tmp/site
# PREBUILT_DEBS=DIR (holding 0.3.0-1 and 0.3.1-1) skips building, for images whose tar cannot run on the host kernel.
if [ -n "${PREBUILT_DEBS:-}" ]; then
    cp "$PREBUILT_DEBS"/mouthtype-linux_0.3.[01]-1_amd64.deb /tmp/debs/
else
    bash "$root/packaging/debian/build-deb.sh" --output /tmp/debs --version 0.3.0-1 >/dev/null
    bash "$root/packaging/debian/build-deb.sh" --output /tmp/debs --version 0.3.1-1 >/dev/null
fi
ls /tmp/debs

step "publish v1"
bash "$root/packaging/debian/build-apt-repo.sh" --output /tmp/site --key "$key" --url http://127.0.0.1:8000 --deb /tmp/debs/mouthtype-linux_0.3.0-1_amd64.deb >/dev/null
(cd /tmp/site && python3 -m http.server 8000 --bind 127.0.0.1 >/tmp/http.log 2>&1 &)
sleep 1
find /tmp/site -type f | sort
gpg --batch --verify /tmp/site/dists/stable/Release.gpg /tmp/site/dists/stable/Release 2>&1 | tail -2
gpg --batch --verify /tmp/site/dists/stable/InRelease 2>&1 | tail -2

step "client: add source (one-time), apt update, apt install"
install -d -m 755 /etc/apt/keyrings
install -m 644 /tmp/site/mouthtype-archive-keyring.gpg /etc/apt/keyrings/mouthtype-archive-keyring.gpg
install -m 644 /tmp/site/mouthtype.sources /etc/apt/sources.list.d/mouthtype.sources
cat /etc/apt/sources.list.d/mouthtype.sources
apt-get update 2>&1 | tee /tmp/update.log
grep -q "127.0.0.1:8000 stable InRelease" /tmp/update.log || fail "apt update did not fetch the signed repo"
grep -qE "^(W|E):" /tmp/update.log && fail "apt update warned" || true
apt-cache policy mouthtype-linux | sed -n 1,5p
apt-get install -y mouthtype-linux >/dev/null
[ "$(dpkg-query -W -f='${Version}' mouthtype-linux)" = 0.3.0-1 ] || fail "wrong installed version"
mouthtype-linux capabilities >/dev/null

step "publish v2, apt update, apt upgrade"
bash "$root/packaging/debian/build-apt-repo.sh" --output /tmp/site --key "$key" --url http://127.0.0.1:8000 --deb /tmp/debs/mouthtype-linux_0.3.1-1_amd64.deb >/dev/null
apt-get update -qq
apt list --upgradable 2>/dev/null | grep mouthtype
apt-get upgrade -y 2>&1 | grep -E "mouthtype|upgraded" 
[ "$(dpkg-query -W -f='${Version}' mouthtype-linux)" = 0.3.1-1 ] || fail "upgrade did not land"
mouthtype-linux capabilities >/dev/null

step "negative: tampered Release is rejected"
cp /tmp/site/dists/stable/InRelease /tmp/InRelease.good
cp /tmp/site/dists/stable/Release /tmp/Release.good
cp /tmp/site/dists/stable/Release.gpg /tmp/Release.gpg.good
sed -i 's/^Label: Mouthtype/Label: Tampered/' /tmp/site/dists/stable/Release /tmp/site/dists/stable/InRelease
apt-get update >/tmp/tamper.log 2>&1 || true
if grep -qiE "not signed|BADSIG|signature|failed" /tmp/tamper.log; then echo "rejected: ok"; else cat /tmp/tamper.log; fail "tampered index was accepted"; fi
cp /tmp/InRelease.good /tmp/site/dists/stable/InRelease
cp /tmp/Release.good /tmp/site/dists/stable/Release
cp /tmp/Release.gpg.good /tmp/site/dists/stable/Release.gpg

step "negative: repo re-signed by a different key is rejected"
export GNUPGHOME=/tmp/other-gnupg
mkdir -m 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'Other <other@invalid>' ed25519 sign never 2>/dev/null
other=$(gpg --batch --list-secret-keys --with-colons | awk -F: '$1 == "fpr" {print $10; exit}')
bash "$root/packaging/debian/build-apt-repo.sh" --output /tmp/site --key "$other" --url http://127.0.0.1:8000 --deb /tmp/debs/mouthtype-linux_0.3.1-1_amd64.deb >/dev/null
apt-get update >/tmp/other.log 2>&1 || true
if grep -qiE "NO_PUBKEY|not signed|signature" /tmp/other.log; then echo "rejected: ok"; else cat /tmp/other.log; fail "untrusted key was accepted"; fi

apt-get purge -y mouthtype-linux >/dev/null
echo; echo "PASS apt flow on $PRETTY_NAME"
