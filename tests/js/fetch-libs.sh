#!/bin/sh
# Extract ExtJS, proxmoxlib.js and pvemanagerlib.js from the real Proxmox .debs into ./vendor.
set -eu
cd "$(dirname "$0")"
MIRROR=${PVE_MIRROR:-http://download.proxmox.com/debian/pve}
PKGS=$(curl -fsSL "$MIRROR/dists/trixie/pve-no-subscription/binary-amd64/Packages.gz" | gunzip)
rm -rf vendor && mkdir -p vendor/deb
for p in libjs-extjs proxmox-widget-toolkit pve-manager; do
    f=$(echo "$PKGS" | awk -v p="$p" '/^Package: /{ok=($2==p)} ok&&/^Version: /{v=$2} ok&&/^Filename: /{print v" "$2}' \
        | sort -V | tail -1 | cut -d' ' -f2)
    echo "$p: $f"
    curl -fsSL -o "vendor/deb/$p.deb" "$MIRROR/$f"
    dpkg-deb -x "vendor/deb/$p.deb" vendor/root
done
