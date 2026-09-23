#!/bin/bash
# Package lifecycle against real pve-manager .debs, in a throwaway Debian 13 container (as root).
# Usage: tests/lifecycle.sh path/to/pve-cloudinit-extras_*.deb
#
# pve-manager is installed from the real .deb, repacked only to drop its dependencies and
# maintainer scripts (the full PVE stack does not run in a container). Its files and md5sums
# are untouched, so dpkg, the file triggers and the md5 checks see exactly what a node sees.
# The Nodes.pm load test needs the full stack, so it is skipped here (SKIP_LOAD_TEST=1) and
# covered by the end-to-end test.
set -uo pipefail

OURDEB=$(realpath "$1")
W=/tmp/lifecycle
REPO=$W/repo
MIRROR=${PVE_MIRROR:-http://download.proxmox.com/debian/pve}
TPL=/usr/share/pve-manager/index.html.tpl
NODES=/usr/share/perl5/PVE/API2/Nodes.pm
JS=/usr/share/pve-manager/js/pve-cloudinit-extras.js
ANCHOR='<script type="text/javascript" src="/pve2/js/pvemanagerlib.js?ver=[% version %]"></script>'

rm -rf "$W" && mkdir -p "$REPO" "$W/tmp"
N=0 FAILED=0
ok() { N=$((N + 1)); echo "ok $N - $1"; }
nok() { N=$((N + 1)); FAILED=$((FAILED + 1)); echo "not ok $N - $1"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }

# Run dpkg; it must exit 0 and never print an error.
dpkg_ok() {
    local d=$1; shift
    local out rc
    out=$("$@" 2>&1); rc=$?
    echo "$out" > "$W/last.log"
    echo "$out" | sed 's/^/    # /'
    if [ $rc -eq 0 ] && ! grep -qiE '^dpkg: (error|warning: .*(failed|error))|subprocess .* returned error|compilation errors|^pve-cloudinit-extras: .*: error:' <<<"$out"; then
        ok "$d (dpkg exit 0, no errors)"
    else
        nok "$d (dpkg exit $rc)"
    fi
}

stock_md5() { dpkg-query --control-show pve-manager md5sums | awk -v f="${1#/}" '$2 == f { print $1 }'; }
is_stock() { [ "$(md5sum < "$1" | cut -d' ' -f1)" = "$(stock_md5 "$1")" ]; }
count() { grep -c -- "$1" "$2"; }
gui_marks() { count 'data-pve-cloudinit-extras' "$TPL"; }
api_marks() { count '# pve-cloudinit-extras$' "$NODES"; }
pm_version() { dpkg-query -W -f='${Version}' pve-manager; }
trigger_ran() { grep -q 'Processing triggers for pve-cloudinit-extras' "$W/last.log"; }

gui_patched() {
    [ "$(gui_marks)" = 1 ] || return 1
    # the marker line directly follows the anchor
    grep -A1 -F -- "$ANCHOR" "$TPL" | tail -1 | grep -q 'src="/pve2/js/pve-cloudinit-extras.js?ver=.*" data-pve-cloudinit-extras></script>'
}
api_patched() {
    [ "$(api_marks)" = 2 ] || return 1
    grep -A1 -Fx 'use PVE::API2::VZDump;' "$NODES" | tail -1 | grep -qx 'use PVE::API2::CloudinitExtras; # pve-cloudinit-extras' || return 1
    grep -A2 -F "'PVE::API2::CloudinitExtras', path => 'cloudinit-extras'" "$NODES" | grep -q 'subclass => "PVE::API2::Qemu"'
}
both_stock() { is_stock "$TPL" && is_stock "$NODES" && [ -z "$(dpkg --verify pve-manager)" ]; }
patched_ok() {
    check "$1: GUI line present exactly once, after the anchor" gui_patched
    check "$1: API lines present exactly once each, at the anchors" api_patched
}

# ---------------------------------------------------------------- setup
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends curl ca-certificates apt-utils libjson-perl libtemplate-perl >/dev/null

curl -fsSL "$MIRROR/dists/trixie/pve-no-subscription/binary-amd64/Packages.gz" | gunzip > "$W/Packages"
versions() { awk -v p=pve-manager '/^Package: /{ok=($2==p)} ok&&/^Version: /{print $2}' "$W/Packages" | grep -E "^$1\." | sort -V; }
V92B=$(versions 9.2 | tail -1)
V92A=$(versions 9.2 | tail -2 | head -1)
V91=$(versions 9.1 | tail -1)
echo "# pve-manager versions: supported $V92A -> $V92B, unsupported $V91"

# repack <version> [suffix] [edit-command]: real files, no deps or maintainer scripts
repack() {
    local v=$1 suffix=${2:-} edit=${3:-}
    local f d=$W/tmp/pm-$v$suffix
    f=$(awk -v p=pve-manager -v v="$v" '/^Package: /{ok=($2==p)} ok&&/^Version: /{vv=$2} ok&&/^Filename: /&&vv==v{print $2}' "$W/Packages")
    [ -f "$W/tmp/$(basename "$f")" ] || curl -fsSL -o "$W/tmp/$(basename "$f")" "$MIRROR/$f"
    rm -rf "$d" && dpkg-deb -R "$W/tmp/$(basename "$f")" "$d"
    sed -i -E '/^(Depends|Pre-Depends|Recommends|Suggests|Conflicts|Breaks|Replaces|Provides):/d' "$d/DEBIAN/control"
    rm -f "$d"/DEBIAN/{preinst,postinst,prerm,postrm,triggers,config,templates}
    if [ -n "$suffix" ]; then
        sed -i "s/^Version: .*/Version: $v$suffix/" "$d/DEBIAN/control"
        (cd "$d" && eval "$edit")
        (cd "$d" && find usr -type f -exec md5sum {} + | sort -k2 > DEBIAN/md5sums.new && \
            awk 'NR==FNR{m[$2]=$1;next} ($2 in m){$1=m[$2]} {print $1"  "$2}' DEBIAN/md5sums.new DEBIAN/md5sums > DEBIAN/md5sums.tmp && \
            mv DEBIAN/md5sums.tmp DEBIAN/md5sums && rm DEBIAN/md5sums.new)
    fi
    dpkg-deb -b --root-owner-group "$d" "$REPO/pve-manager_$v${suffix}_all.deb" >/dev/null
}
repack "$V92A"; repack "$V92B"; repack "$V91"
repack "$V92B" +noanchor1 "sed -i '/pvemanagerlib.js/d' .$TPL"
repack "$V92B" +dupanchor1 "sed -i 's|^\\(.*pvemanagerlib.js.*\\)\$|\\1\\n\\1|' .$TPL"
repack "$V92B" +noapianchor1 "sed -i '/^use PVE::API2::VZDump;/d' .$NODES"
PM() { echo "$REPO/pve-manager_$1_all.deb"; }

# upgraded build of our own package: same files, new version
OUR2=$W/tmp/our2
dpkg-deb -R "$OURDEB" "$OUR2"
OURV=$(dpkg-deb -f "$OURDEB" Version)
sed -i "s/^Version: .*/Version: $OURV+lc1/" "$OUR2/DEBIAN/control"
sed -i "s/'$OURV'/'$OURV+lc1'/" "$OUR2/usr/sbin/pve-cloudinit-extras-patch"
(cd "$OUR2" && find usr -type f -exec md5sum {} + | sort -k2 > DEBIAN/md5sums)
OURDEB2=$W/pve-cloudinit-extras_${OURV}+lc1_all.deb
dpkg-deb -b --root-owner-group "$OUR2" "$OURDEB2" >/dev/null

(cd "$REPO" && apt-ftparchive packages . > Packages)
echo "deb [trusted=yes] file:$REPO ./" > /etc/apt/sources.list.d/local.list
apt-get update -qq -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/local.list -o Dir::Etc::sourceparts=- >/dev/null

echo 'SKIP_LOAD_TEST=1' > /etc/pve-cloudinit-extras.conf

# ---------------------------------------------------------------- tests
dpkg_ok "install pve-manager $V92A" dpkg -i "$(PM "$V92A")"
check "stock pve-manager $V92A verifies" both_stock

dpkg_ok "install our package" dpkg -i "$OURDEB"
patched_ok "install"
check "install: JS file shipped" test -f "$JS"
check "install: status recorded" grep -q applied /var/lib/pve-cloudinit-extras/status-gui
H1=$(md5sum "$TPL" "$NODES")

dpkg_ok "reinstall our package" dpkg -i "$OURDEB"
patched_ok "reinstall"
check "reinstall: files identical to first install" test "$(md5sum "$TPL" "$NODES")" = "$H1"

dpkg_ok "upgrade our package to $OURV+lc1" dpkg -i "$OURDEB2"
patched_ok "upgrade"
check "upgrade: GUI line carries the new version" grep -q "ver=$OURV+lc1\"" "$TPL"
dpkg_ok "downgrade our package to $OURV" dpkg -i "$OURDEB"
patched_ok "downgrade"
check "downgrade: files identical to first install" test "$(md5sum "$TPL" "$NODES")" = "$H1"

dpkg_ok "reinstall pve-manager $V92A (simulated upgrade, same version)" dpkg -i "$(PM "$V92A")"
check "reinstall pve-manager: our trigger ran" trigger_ran
patched_ok "reinstall pve-manager"

dpkg_ok "upgrade pve-manager $V92A -> $V92B" dpkg -i "$(PM "$V92B")"
check "upgrade pve-manager: our trigger ran" trigger_ran
patched_ok "upgrade pve-manager"

dpkg_ok "downgrade pve-manager to unsupported $V91" dpkg -i "$(PM "$V91")"
check "unsupported $V91: our trigger ran" trigger_ran
check "unsupported $V91: both files stock (md5sums, dpkg --verify)" both_stock
check "unsupported $V91: reason logged" grep -q 'not in the tested range' /var/lib/pve-cloudinit-extras/status-gui

echo 'SKIP_LOAD_TEST=1' > /etc/pve-cloudinit-extras.conf; echo 'FORCE=1' >> /etc/pve-cloudinit-extras.conf
/usr/sbin/pve-cloudinit-extras-patch apply > "$W/last.log"
patched_ok "FORCE=1 on $V91"
echo 'SKIP_LOAD_TEST=1' > /etc/pve-cloudinit-extras.conf
/usr/sbin/pve-cloudinit-extras-patch apply > "$W/last.log"
check "FORCE removed: $V91 back to stock" both_stock

dpkg_ok "upgrade pve-manager $V91 -> $V92B" dpkg -i "$(PM "$V92B")"
patched_ok "upgrade from unsupported"

dpkg_ok "pve-manager variant without the GUI anchor" dpkg -i "$(PM "$V92B+noanchor1")"
check "missing GUI anchor: template left stock" is_stock "$TPL"
check "missing GUI anchor: reason logged" grep -q 'found 0 times' /var/lib/pve-cloudinit-extras/status-gui
check "missing GUI anchor: API still patched" api_patched

dpkg_ok "pve-manager variant with a duplicated GUI anchor" dpkg -i "$(PM "$V92B+dupanchor1")"
check "duplicated GUI anchor: template left stock" is_stock "$TPL"
check "duplicated GUI anchor: reason logged" grep -q 'found 2 times' /var/lib/pve-cloudinit-extras/status-gui

dpkg_ok "pve-manager variant without the API anchor" dpkg -i "$(PM "$V92B+noapianchor1")"
check "missing API anchor: Nodes.pm left stock" is_stock "$NODES"
check "missing API anchor: GUI still patched" gui_patched

dpkg_ok "back to pve-manager $V92B" dpkg -i "$(PM "$V92B")"
patched_ok "back to $V92B"

for i in 1 2 3 4 5 6; do /usr/sbin/pve-cloudinit-extras-patch apply >/dev/null & done; wait
patched_ok "6 concurrent applies"

dpkg_ok "remove our package" dpkg -r pve-cloudinit-extras
check "remove: both files byte-identical to stock (md5sums, dpkg --verify)" both_stock
check "remove: JS file gone" test ! -e "$JS"
check "remove: no marker left" test "$(gui_marks)" = 0 -a "$(api_marks)" = 0

dpkg_ok "purge our package" dpkg -P pve-cloudinit-extras
check "purge: state and config removed" test ! -e /var/lib/pve-cloudinit-extras -a ! -e /etc/pve-cloudinit-extras.conf
check "purge: files still stock" both_stock

# someone else also edited the template: removal restores it from the .deb (local apt repo)
echo 'SKIP_LOAD_TEST=1' > /etc/pve-cloudinit-extras.conf
dpkg_ok "install on $V92B again" dpkg -i "$OURDEB"
patched_ok "reinstall after purge"
echo '<!-- another local modification -->' >> "$TPL"
dpkg_ok "remove with a foreign modification present" dpkg -r pve-cloudinit-extras
check "foreign modification: template restored from the pve-manager .deb" both_stock
check "foreign modification: restore reported" grep -q 'restored from the pve-manager .deb' "$W/last.log"

# ... and when the .deb cannot be fetched, removal still succeeds and says what to do
dpkg_ok "install again" dpkg -i "$OURDEB"
echo '<!-- another local modification -->' >> "$TPL"
rm -f /etc/apt/sources.list.d/local.list /var/cache/apt/archives/pve-manager_*.deb
apt-get update -qq >/dev/null 2>&1
dpkg_ok "remove with the .deb unavailable" dpkg -r pve-cloudinit-extras
check "no .deb: our lines removed anyway" test "$(gui_marks)" = 0 -a "$(api_marks)" = 0
check "no .deb: advice printed" grep -q 'apt install --reinstall pve-manager' "$W/last.log"
check "no .deb: Nodes.pm stock" is_stock "$NODES"

# fresh install on an unsupported version, then upgrade into the supported range
dpkg_ok "pve-manager $V91 (unsupported)" dpkg -i "$(PM "$V91")"
dpkg_ok "install our package on $V91" dpkg -i "$OURDEB"
check "install on $V91: files stock" both_stock
dpkg_ok "upgrade pve-manager $V91 -> $V92B" dpkg -i "$(PM "$V92B")"
patched_ok "installed on $V91, upgraded to $V92B"
dpkg_ok "purge" dpkg -P pve-cloudinit-extras
check "final purge: files stock" both_stock

echo "1..$N"
[ "$FAILED" = 0 ] && echo "# all $N passed" || echo "# $FAILED of $N FAILED"
exit $((FAILED > 0))
