#!/bin/sh
# Builds the signed flat apt repository that is attached to each release.
# Usage: build-apt-repo.sh OUTDIR FINGERPRINT DEB  (the secret key must be in the gpg keyring)
# Filename: must be a bare name: nodes fetch releases/latest/download/<Filename>.
set -eu
OUT=$1 FPR=$2 DEB=$3
mkdir "$OUT"
cp "$DEB" "$OUT/"
cd "$OUT"

apt-ftparchive packages . | sed 's|^Filename: \./|Filename: |' > Packages
gzip -9nk Packages
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin=pve-cloudinit-extras \
  -o APT::FTPArchive::Release::Label=pve-cloudinit-extras \
  release . > ../Release.tmp
mv ../Release.tmp Release

sign() { gpg --batch --yes --pinentry-mode loopback --passphrase '' --local-user "$FPR!" --digest-algo SHA512 "$@"; }
sign --clearsign -o InRelease Release
sign --armor --detach-sign -o Release.gpg Release
gpg --export "$FPR" > pve-cloudinit-extras.gpg
gpg --armor --export "$FPR" > pve-cloudinit-extras.asc

gpgv --keyring ./pve-cloudinit-extras.gpg InRelease
gpgv --keyring ./pve-cloudinit-extras.gpg Release.gpg Release
grep -q '^Filename: pve-cloudinit-extras_[^/]*_all\.deb$' Packages
ls -l
