#!/bin/sh
# Installs from the flat apt repository in a clean Debian 13 container (run as root), with
# signature checking on (no trusted=yes).
#   apt-repo.sh local REPO_DIR       serve REPO_DIR over HTTP; also check that apt rejects a
#                                    tampered Packages and a tampered InRelease
#   apt-repo.sh remote URL [VERSION] the published repository, key fetched from it
set -eu
MODE=$1 KEYRING=/usr/share/keyrings/pve-cloudinit-extras.gpg
fail() { echo "FAIL: $*"; exit 1; }

apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl gpg python3 >/dev/null
# pve-manager, our dependency, comes from here.
curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg -o /usr/share/keyrings/proxmox-archive-keyring.gpg
cat > /etc/apt/sources.list.d/pve.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

case $MODE in
  local)
    cp -r "$2" /srv/repo
    URL=http://127.0.0.1:8000/
    python3 -m http.server -d /srv/repo -b 127.0.0.1 8000 >/tmp/http.log 2>&1 &
    for _ in 1 2 3 4 5 6 7 8 9 10; do curl -fs "$URL" >/dev/null && break; sleep 1; done
    cp /srv/repo/pve-cloudinit-extras.gpg "$KEYRING"
    VERSION=$(dpkg-deb -f /srv/repo/*.deb Version)
    ;;
  remote)
    URL=$2 VERSION=${3:-}
    curl -fsSL "${URL}pve-cloudinit-extras.gpg" -o "$KEYRING"
    ;;
  *) fail "mode $MODE" ;;
esac
echo "signing key: $(gpg --show-keys --with-colons "$KEYRING" | awk -F: '/^fpr/{print $10; exit}')"
# Local runs may use a throwaway key; the apt-repo CI job checks the real one.
if [ "$MODE" = remote ]; then
  [ "$(gpg --show-keys --with-colons "$KEYRING" | awk -F: '/^fpr/{print $10; exit}')" = \
    "$(gpg --show-keys --with-colons keys/pve-cloudinit-extras.asc | awk -F: '/^fpr/{print $10; exit}')" ] \
    || fail "published key is not keys/pve-cloudinit-extras.asc"
fi

cat > /etc/apt/sources.list.d/pve-cloudinit-extras.sources <<EOF
Types: deb
URIs: $URL
Suites: ./
Signed-By: $KEYRING
EOF

# Remote: "latest" can lag a freshly created release for a moment.
for try in 1 2 3 4 5 6; do
  apt-get update --error-on=any
  CAND=$(apt-cache policy pve-cloudinit-extras | awk '/Candidate:/{print $2}')
  [ -z "$VERSION" ] || [ "$CAND" = "$VERSION" ] && break
  [ "$MODE" = remote ] && [ "$try" -lt 6 ] || fail "candidate $CAND, expected $VERSION"
  sleep 30
done
[ -n "$CAND" ] && [ "$CAND" != "(none)" ] || fail "pve-cloudinit-extras not found"
apt-cache policy pve-cloudinit-extras
apt-get install -y -qq --download-only --no-install-recommends "pve-cloudinit-extras=$CAND"
DEB=/var/cache/apt/archives/pve-cloudinit-extras_${CAND}_all.deb
[ -f "$DEB" ] || fail "$DEB not downloaded"
[ "$MODE" = local ] && { cmp "$DEB" /srv/repo/"$(basename "$DEB")" || fail "downloaded .deb differs"; }
echo "OK: pve-cloudinit-extras $CAND from $URL"
[ "$MODE" = local ] || exit 0

# apt must refuse a repository that does not match its signature.
rejects() {  # rejects WHAT PATTERN
  rm -rf /var/lib/apt/lists/127.0.0.1* /var/lib/apt/lists/partial/127.0.0.1*
  if apt-get update --error-on=any >/tmp/apt.log 2>&1; then cat /tmp/apt.log; fail "apt accepted $1"; fi
  grep -Em1 "$2" /tmp/apt.log || { cat /tmp/apt.log; fail "$1: expected /$2/"; }
  if apt-cache policy pve-cloudinit-extras | grep -q 127.0.0.1; then fail "$1: index was used"; fi
  echo "OK: apt rejects $1"
}
cp -r /srv/repo /srv/orig
# Same length, so the size check cannot catch it first. Without Packages.gz, apt falls back to Packages.
sed -i 's/^Maintainer: ./Maintainer: X/' /srv/repo/Packages
rm /srv/repo/Packages.gz
cmp -s /srv/repo/Packages /srv/orig/Packages && fail "tampering did nothing"
rejects "tampered Packages" 'Hash Sum mismatch'

rm -rf /srv/repo && cp -r /srv/orig /srv/repo && rm /srv/repo/Release.gpg
sed -i 's/^Origin: p/Origin: X/' /srv/repo/InRelease
rejects "tampered InRelease" 'The following signatures were invalid|BADSIG|is not signed'
