#!/bin/sh
# Sanity checks on the built .deb: exact file list, modes, substituted version, maintainer scripts.
set -eu
DEB=$1
V=$(dpkg-deb -f "$DEB" Version)
fail() { echo "FAIL: $*"; exit 1; }

dpkg-deb --contents "$DEB" | awk '{print $1, $6}' | grep -v '/$' | sort > /tmp/contents
cat > /tmp/expected <<EXP
-rw-r--r-- ./usr/share/doc/pve-cloudinit-extras/changelog.gz
-rw-r--r-- ./usr/share/doc/pve-cloudinit-extras/copyright
-rw-r--r-- ./usr/share/man/man8/pve-cloudinit-extras-patch.8.gz
-rw-r--r-- ./usr/share/perl5/PVE/API2/CloudinitExtras.pm
-rw-r--r-- ./usr/share/perl5/PVE/CloudinitExtras/Vendor.pm
-rw-r--r-- ./usr/share/pve-cloudinit-extras/supported
-rw-r--r-- ./usr/share/pve-manager/js/pve-cloudinit-extras.js
-rwxr-xr-x ./usr/sbin/pve-cloudinit-extras-patch
EXP
sort -o /tmp/expected /tmp/expected
diff -u /tmp/expected /tmp/contents || fail "file list differs"
dpkg-deb --contents "$DEB" | awk '$2 != "root/root" {exit 1}' || fail "files not owned by root"

rm -rf /tmp/x && dpkg-deb -R "$DEB" /tmp/x
grep -rl '@VERSION@' /tmp/x && fail "@VERSION@ not substituted"
grep -q "my \$VERSION = '$V';" /tmp/x/usr/sbin/pve-cloudinit-extras-patch || fail "version not in patch tool"
grep -q "our \$VERSION = '$V';" /tmp/x/usr/share/perl5/PVE/API2/CloudinitExtras.pm || fail "version not in API"
for s in postinst prerm postrm triggers; do test -f /tmp/x/DEBIAN/$s || fail "missing DEBIAN/$s"; done
grep -qx 'interest-noawait /usr/share/pve-manager/index.html.tpl' /tmp/x/DEBIAN/triggers || fail "template trigger"
grep -qx 'interest-noawait /usr/share/perl5/PVE/API2/Nodes.pm' /tmp/x/DEBIAN/triggers || fail "Nodes.pm trigger"
dpkg-deb -f "$DEB" Architecture | grep -qx all || fail "arch"
perl -c /tmp/x/usr/sbin/pve-cloudinit-extras-patch
grep -rlI "$(printf '\015')" /tmp/x/DEBIAN /tmp/x/usr/sbin /tmp/x/usr/share/perl5 && fail "CRLF line endings"
echo "deb contents OK ($V)"
