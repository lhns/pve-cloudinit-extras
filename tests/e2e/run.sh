#!/bin/bash
# End-to-end test on a real Proxmox VE 9.2, on a GitHub-hosted Ubuntu runner with /dev/kvm:
#   1. install PVE from the official ISO into a nested VM (automated installer, answer file);
#   2. install our .deb and check the real API, the real GUI (Playwright) and a cloud-init guest;
#   3. reinstall pve-manager (trigger re-applies), then remove and purge our package.
# Usage: tests/e2e/run.sh <pve-cloudinit-extras.deb>
# Everything lives in the runner; the nested PVE is reachable only via forwarded localhost ports.
set -uo pipefail

DEB=$(realpath "$1")
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
W=${E2E_WORK:-$HOME/e2e}
ISO_NAME=proxmox-ve_9.2-1.iso
ISO_URL=http://download.proxmox.com/iso/$ISO_NAME # integrity: pinned sha256 below
ISO_SHA256=4e88fe416df9b527624a175f24c9aa07c714d3332afb1ee3dbf3879573ef2c6c
GUEST_IMG=https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
NODE=pve-e2e
PW=e2e-throwaway-password # the nested PVE only listens on the runner's localhost
VMID=100
GUEST_IP=10.0.2.100
SHOTS=$W/artifacts
mkdir -p "$W" "$SHOTS"

N=0 FAILED=0
ok() { N=$((N + 1)); echo "ok $N - $1" | tee -a "$SHOTS/results.tap"; }
nok() { N=$((N + 1)); FAILED=$((FAILED + 1)); echo "not ok $N - $1" | tee -a "$SHOTS/results.tap"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }
note() { echo "# $*" | tee -a "$SHOTS/results.tap"; }
group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }
die() { nok "$1"; finish; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -i "$W/id_e2e")
pve() { ssh "${SSH_OPTS[@]}" -p 2222 root@127.0.0.1 "$@"; }
pve_put() { scp "${SSH_OPTS[@]}" -P 2222 "$1" "root@127.0.0.1:$2"; }
pve_get() { scp "${SSH_OPTS[@]}" -P 2222 "root@127.0.0.1:$1" "$2"; }
# run in the guest, via the PVE host (same bridge)
# (the command is quoted once more so redirections and pipes run in the guest, not on the host)
guest() { pve "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -i /root/.ssh/e2e debian@$GUEST_IP $(printf '%q' "$*")"; }
api() { curl -fsSk -b "PVEAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF" "$@"; }

finish() {
    group "collect logs"
    pve 'journalctl -b --no-pager | tail -n 300' > "$SHOTS/pve-journal.log" 2>/dev/null
    pve 'cat /var/lib/pve-cloudinit-extras/status-* ; dpkg -l | grep -E "pve-manager|pve-cloudinit"' > "$SHOTS/pve-status.log" 2>/dev/null
    guest 'sudo cat /var/log/cloud-init.log' > "$SHOTS/guest-cloud-init.log" 2>/dev/null
    guest 'sudo cat /var/log/cloud-init-output.log' > "$SHOTS/guest-cloud-init-output.log" 2>/dev/null
    cp "$W"/*.log "$SHOTS/" 2>/dev/null
    endgroup
    echo "1..$N" | tee -a "$SHOTS/results.tap"
    [ "$FAILED" = 0 ] && note "all $N passed" || note "$FAILED of $N FAILED"
    exit $((FAILED > 0))
}

wait_for() { # seconds description command...
    local t=$1 d=$2; shift 2
    local end=$((SECONDS + t))
    until "$@" >/dev/null 2>&1; do
        [ $SECONDS -ge $end ] && { nok "timeout after ${t}s: $d"; return 1; }
        sleep 5
    done
    ok "$d"
}

qmp() { # qmp <socket> <command-json>
    python3 - "$1" "$2" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile('rw')
f.readline(); f.write('{"execute":"qmp_capabilities"}\n'); f.flush(); f.readline()
f.write(sys.argv[2] + '\n'); f.flush(); print(f.readline())
PY
}
# wait until the guest runs a boot other than $1 and cloud-init has finished it
boot_id() { guest 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null; }
wait_boot() {
    local old=$1 d=$2 end=$((SECONDS + BOOT_T)) id
    while :; do
        id=$(boot_id)
        [ -n "$id" ] && [ "$id" != "$old" ] && break
        [ $SECONDS -ge $end ] && { nok "timeout after ${BOOT_T}s: $d"; return 1; }
        sleep 10
    done
    ok "$d"
    guest 'cloud-init status --wait >/dev/null 2>&1; true'
    check "$d: cloud-init finished" guest 'test -f /var/lib/cloud/instance/boot-finished'
}
screenshot() { qmp "$W/qmp.sock" "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$SHOTS/$1.ppm\"}}" >/dev/null 2>&1; }

# ------------------------------------------------------------------ 1. install PVE
group "prepare ISO"
[ -f "$W/id_e2e" ] || ssh-keygen -q -t ed25519 -N '' -C e2e -f "$W/id_e2e"
mkdir -p "$W/iso"
if ! echo "$ISO_SHA256  $W/iso/$ISO_NAME" | sha256sum -c --quiet 2>/dev/null; then
    curl -fsSL -o "$W/iso/$ISO_NAME" "$ISO_URL"
fi
check "official ISO $ISO_NAME, sha256 verified" sh -c "echo '$ISO_SHA256  $W/iso/$ISO_NAME' | sha256sum -c --quiet"
cat > "$W/answer.toml" <<EOF
[global]
keyboard = "en-us"
country = "us"
fqdn = "$NODE.example.test"
mailto = "root@example.test"
timezone = "UTC"
root-password = "$PW"
root-ssh-keys = ["$(cat "$W/id_e2e.pub")"]
reboot-mode = "power-off"

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "ext4"
disk-list = ["vda"]
EOF
docker run --rm -v "$W:/w" debian:trixie bash -ec '
    apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null
    curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg -o /usr/share/keyrings/proxmox-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring.gpg] http://download.proxmox.com/debian/pve trixie pve-no-subscription" > /etc/apt/sources.list.d/pve.list
    apt-get update -qq && apt-get install -y -qq proxmox-auto-install-assistant xorriso >/dev/null
    proxmox-auto-install-assistant validate-answer /w/answer.toml
    proxmox-auto-install-assistant prepare-iso /w/iso/'"$ISO_NAME"' --fetch-from iso --answer-file /w/answer.toml --output /w/auto.iso --tmp /w
    chmod a+r /w/auto.iso' > "$W/prepare-iso.log" 2>&1
check "answer file validated and auto-install ISO prepared" test -s "$W/auto.iso"
endgroup

group "automated installation"
KVM_CPU="-machine q35,accel=kvm -cpu host -smp 4 -m 8192"
qemu-img create -q -f qcow2 "$W/pve.qcow2" 64G
START=$SECONDS
timeout 3000 qemu-system-x86_64 $KVM_CPU \
    -drive file="$W/pve.qcow2",if=virtio,cache=unsafe,discard=unmap \
    -cdrom "$W/auto.iso" -boot once=d \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -vga std -serial file:"$W/install-serial.log" \
    -qmp unix:"$W/qmp.sock",server=on,wait=off -no-reboot &
QEMU=$!
while kill -0 $QEMU 2>/dev/null; do
    sleep 60
    screenshot install-progress
    echo "installing... $((SECONDS - START))s"
done
wait $QEMU; RC=$?
note "installer ran $((SECONDS - START))s, qemu exit $RC"
check "PVE installed from the ISO with the answer file (VM powered off by the installer)" test $RC = 0
[ $RC = 0 ] || die "installation failed"
endgroup

group "boot PVE"
qemu-system-x86_64 $KVM_CPU \
    -drive file="$W/pve.qcow2",if=virtio,cache=unsafe,discard=unmap \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8006-:8006 \
    -device virtio-net-pci,netdev=n0 \
    -display none -vga std -serial file:"$W/pve-serial.log" \
    -qmp unix:"$W/qmp.sock",server=on,wait=off -daemonize -pidfile "$W/pve.pid"
wait_for 600 "PVE boots, SSH reachable" pve true || die "PVE did not boot"
wait_for 300 "pveproxy answers on 8006" curl -fsk https://127.0.0.1:8006/ || die "no GUI"
endgroup

group "configure PVE (test setup only)"
pve bash -es > "$W/pve-setup.log" 2>&1 <<'EOF'
rm -f /etc/apt/sources.list.d/*enterprise* /etc/apt/sources.list.d/ceph.sources
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOT
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOT
apt-get update -qq
# a snippets storage for the test; the package itself never changes storage config
mkdir -p /var/lib/e2e-snippets
pvesm add dir e2e-snippets --path /var/lib/e2e-snippets --content snippets
ssh-keygen -q -t ed25519 -N '' -C e2e-guest -f /root/.ssh/e2e
EOF
check "PVE test setup (repo, snippets storage)" test $? = 0
PM_VERSION=$(pve "dpkg-query -W -f='\${Version}' pve-manager")
note "pve-manager $PM_VERSION, qemu-server $(pve "dpkg-query -W -f='\${Version}' qemu-server"), kernel $(pve uname -r)"
AUTH=$(curl -fsSk -d "username=root@pam&password=$PW" https://127.0.0.1:8006/api2/json/access/ticket)
TICKET=$(echo "$AUTH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["ticket"])')
CSRF=$(echo "$AUTH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["CSRFPreventionToken"])')
pve 'md5sum /usr/share/pve-manager/index.html.tpl /usr/share/perl5/PVE/API2/Nodes.pm' > "$W/stock.md5"
endgroup

# ------------------------------------------------------------------ 2. install our package
group "install pve-cloudinit-extras"
pve_put "$DEB" /root/
pve "apt-get install -y /root/$(basename "$DEB")" > "$W/install.log" 2>&1
check "apt install of our .deb succeeds" test $? = 0
check "GUI patch applied (real template)" pve 'grep -q "^applied" /var/lib/pve-cloudinit-extras/status-gui'
check "API patch applied and the patched Nodes.pm loads (real load test)" pve 'grep -q "^applied" /var/lib/pve-cloudinit-extras/status-api'
check "exactly one GUI marker line" test "$(pve 'grep -c data-pve-cloudinit-extras /usr/share/pve-manager/index.html.tpl')" = 1
check "exactly two API marker lines" test "$(pve 'grep -c "# pve-cloudinit-extras$" /usr/share/perl5/PVE/API2/Nodes.pm')" = 2
sleep 5
check "API probe answers" sh -c "curl -fsSk -b 'PVEAuthCookie=$TICKET' https://127.0.0.1:8006/api2/json/nodes/$NODE/cloudinit-extras | grep -q version"
check "JS served by pveproxy" curl -fsSk -o /dev/null https://127.0.0.1:8006/pve2/js/pve-cloudinit-extras.js
check "stock API still works (qemu list)" sh -c "curl -fsSk -b 'PVEAuthCookie=$TICKET' https://127.0.0.1:8006/api2/json/nodes/$NODE/qemu | grep -q data"
endgroup

group "guest VM"
KVM_GUEST=1
pve 'test -e /dev/kvm' || KVM_GUEST=0
note "nested KVM inside PVE: $KVM_GUEST (0 = guest runs under TCG emulation)"
pve bash -es > "$W/vm-create.log" 2>&1 <<EOF
curl -fsSL -o /root/guest.qcow2 $GUEST_IMG
qm create $VMID --name cix-guest --memory 1536 --cores 2 --net0 virtio,bridge=vmbr0 \
    --scsihw virtio-scsi-pci --scsi0 local-lvm:0,import-from=/root/guest.qcow2 \
    --ide2 local-lvm:cloudinit --boot order=scsi0 --serial0 socket --vga serial0 \
    --ipconfig0 ip=$GUEST_IP/24,gw=10.0.2.2 --nameserver 10.0.2.3 --ciuser debian \
    --sshkeys /root/.ssh/e2e.pub --ciupgrade 0 --kvm $KVM_GUEST
EOF
check "cloud-init guest created (Debian 13 genericcloud)" test $? = 0
endgroup

RUNCMD_TEXT="echo from-runcmd >> /var/tmp/cix-order
touch /var/tmp/cix-runcmd
echo 'key: value' \"--cix.boundary-1--\" '#cloud-config' > /var/tmp/cix-hostile"
# write the vendor snippet via the endpoint and point cicustom at it (what the GUI does)
set_vendor() {
    api -X PUT --data-urlencode storage=e2e-snippets --data-urlencode "bootcmd=$1" --data-urlencode "runcmd=$2" \
        --data-urlencode include-url=http://10.0.2.2:8080/include.yaml \
        "https://127.0.0.1:8006/api2/json/nodes/$NODE/cloudinit-extras/vendor/$VMID" > /dev/null &&
        pve "qm set $VMID --cicustom vendor=e2e-snippets:snippets/cix-$VMID-vendor.yaml" > /dev/null
}

# include file served by the runner; the guest reaches the runner's localhost as 10.0.2.2
mkdir -p "$W/www"
cat > "$W/www/include.yaml" <<'EOF'
#cloud-config
write_files:
  - path: /var/tmp/cix-include
    content: "included\n"
runcmd:
  - echo from-include >> /var/tmp/cix-order
EOF
(cd "$W/www" && exec python3 -m http.server 8080 --bind 127.0.0.1 > "$W/http.log" 2>&1) &
HTTPD=$!
trap 'kill $HTTPD 2>/dev/null' EXIT

group "GUI: rows render and fields are set through the real GUI"
cd "$REPO_ROOT/tests/js"
PVE_URL=https://127.0.0.1:8006 PVE_PASSWORD=$PW E2E_MODE=edit E2E_VMID=$VMID E2E_SHOTS=$SHOTS \
    E2E_INCLUDE_URL=http://10.0.2.2:8080/include.yaml npx playwright test e2e.spec.js > "$W/gui-edit.log" 2>&1
GUI_RC=$?
check "GUI: four rows render; Commands, Boot commands and Include saved through the editors" test $GUI_RC = 0
cd - >/dev/null
if [ $GUI_RC != 0 ]; then
    note "GUI step failed; setting the same fields through the API so the guest checks still run"
    set_vendor "echo boot >> /var/tmp/cix-boots" "$RUNCMD_TEXT"
fi
CICUSTOM=$(pve "qm config $VMID" | sed -n 's/^cicustom: //p')
note "cicustom: $CICUSTOM"
check "cicustom vendor= points at the generated snippet" test "$CICUSTOM" = "vendor=e2e-snippets:snippets/cix-$VMID-vendor.yaml"
pve_get "/var/lib/e2e-snippets/snippets/cix-$VMID-vendor.yaml" "$SHOTS/vendor.yaml"
check "generated snippet carries our header" grep -q '^X-Managed-By: pve-cloudinit-extras/1' "$SHOTS/vendor.yaml"
python3 "$REPO_ROOT/t/parse_vendor.py" "$SHOTS/vendor.yaml" > "$SHOTS/vendor.json"
check "snippet parses as include-url + cloud-config (bootcmd, runcmd)" python3 - "$SHOTS/vendor.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
t = [p["type"] for p in d["parts"]]
assert t == ["text/x-include-url", "text/cloud-config"], t
cfg = d["parts"][1]["config"]
assert sorted(cfg) == ["bootcmd", "merge_how", "runcmd"], cfg
assert cfg["bootcmd"] == ["echo boot >> /var/tmp/cix-boots"], cfg
assert cfg["runcmd"][2].endswith("'#cloud-config' > /var/tmp/cix-hostile"), cfg
EOF
endgroup

# ------------------------------------------------------------------ guest behaviour
group "guest first boot"
check "host did not fetch the include URL while saving (no request before the guest ran)" test ! -s "$W/http.log" -o "$(grep -c 'GET /include.yaml' "$W/http.log")" = 0
pve "qm start $VMID" > "$W/qm-start.log" 2>&1
check "VM starts with the generated vendor data" test $? = 0
BOOT_T=$([ $KVM_GUEST = 1 ] && echo 900 || echo 2400)
wait_boot none "first boot: guest reachable over SSH with the Proxmox-generated user and key"
guest 'cloud-init status --long' > "$W/guest-status.log" 2>&1
check "runcmd from Commands ran (Proxmox user-data does not override vendor runcmd)" guest 'test -f /var/tmp/cix-runcmd'
check "URL include applied (write_files from the included file)" guest 'grep -qx included /var/tmp/cix-include'
check "runcmd lists merged: include first, then Commands" test "$(guest 'cat /var/tmp/cix-order' | tr '\n' ' ')" = "from-include from-runcmd "
check "hostile command text reached the shell verbatim" test "$(guest 'cat /var/tmp/cix-hostile')" = "key: value --cix.boundary-1-- #cloud-config"
check "bootcmd ran on first boot" test "$(guest 'wc -l < /var/tmp/cix-boots')" = 1
check "guest fetched the include URL from the runner" grep -q 'GET /include.yaml' "$W/http.log"
check "Proxmox-generated user-data still applied (hostname)" test "$(guest hostname)" = cix-guest
guest 'sudo cloud-init query vendordata' > "$SHOTS/guest-vendordata.txt" 2>&1
check "cloud-init sees our vendor data" grep -q 'pve-cloudinit-extras' "$SHOTS/guest-vendordata.txt"
guest 'sudo cat /var/log/cloud-init.log' > "$SHOTS/guest-cloud-init-boot1.log" 2>&1
guest 'sudo cat /var/log/cloud-init-output.log' > "$SHOTS/guest-cloud-init-output-boot1.log" 2>&1
endgroup

group "guest reboot (same instance)"
OLD=$(boot_id)
guest 'sudo systemctl reboot' >/dev/null 2>&1
wait_boot "$OLD" "guest rebooted from inside"
check "bootcmd ran again on reboot (2 lines)" test "$(guest 'wc -l < /var/tmp/cix-boots')" = 2
check "runcmd did not run again" test "$(guest 'wc -l < /var/tmp/cix-order')" = 2
endgroup

group "changed commands on an existing instance, without cloud-init clean"
set_vendor "echo boot >> /var/tmp/cix-boots
echo boot2 >> /var/tmp/cix-boots2" "$RUNCMD_TEXT
touch /var/tmp/cix-runcmd2"
check "API update of the vendor snippet" test $? = 0
OLD=$(boot_id)
guest 'sudo systemctl reboot' >/dev/null 2>&1
wait_boot "$OLD" "guest rebooted from inside after the change"
BOOT_R=$(guest 'cat /var/tmp/cix-boots2 2>/dev/null | wc -l')
note "after changing vendor data and a reboot from inside the guest: new bootcmd ran=$BOOT_R time(s)"
echo "BOOTCMD_CHANGE_AFTER_GUEST_REBOOT=$BOOT_R" >> "$SHOTS/findings.env"
OLD=$(boot_id)
pve "qm shutdown $VMID --timeout 180 --forceStop 1 && qm start $VMID" > /dev/null 2>&1
wait_boot "$OLD" "guest back after VM stop/start"
BOOT2=$(guest 'cat /var/tmp/cix-boots2 2>/dev/null | wc -l')
RUN2=$(guest 'test -f /var/tmp/cix-runcmd2 && echo yes || echo no')
note "after changing vendor data and a VM stop/start: new bootcmd ran=$BOOT2 time(s), new runcmd ran=$RUN2"
check "old bootcmd line still runs every boot (4 lines)" test "$(guest 'wc -l < /var/tmp/cix-boots')" = 4
echo "BOOTCMD_CHANGE_APPLIED=$BOOT2" >> "$SHOTS/findings.env"
echo "RUNCMD_CHANGE_APPLIED=$RUN2" >> "$SHOTS/findings.env"
pve "qm shutdown $VMID --timeout 180 --forceStop 1" > /dev/null 2>&1
endgroup

# ------------------------------------------------------------------ 3. upgrade and uninstall
group "reinstall pve-manager: trigger re-applies"
pve "apt-get install -y --reinstall pve-manager=$PM_VERSION" > "$W/reinstall-pm.log" 2>&1 \
    || { curl -fsSL -o "$W/pm.deb" "http://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-amd64/pve-manager_${PM_VERSION}_all.deb" \
         && pve_put "$W/pm.deb" /root/pm.deb && pve 'apt-get install -y --reinstall /root/pm.deb' >> "$W/reinstall-pm.log" 2>&1; }
check "pve-manager reinstall succeeds" test $? = 0
check "our trigger ran" grep -q 'Processing triggers for pve-cloudinit-extras' "$W/reinstall-pm.log"
check "GUI marker re-applied once" test "$(pve 'grep -c data-pve-cloudinit-extras /usr/share/pve-manager/index.html.tpl')" = 1
check "API markers re-applied" test "$(pve 'grep -c "# pve-cloudinit-extras$" /usr/share/perl5/PVE/API2/Nodes.pm')" = 2
sleep 10
wait_for 120 "API probe answers after reinstall" sh -c "curl -fsSk -b 'PVEAuthCookie=$TICKET' https://127.0.0.1:8006/api2/json/nodes/$NODE/cloudinit-extras | grep -q version"
cd "$REPO_ROOT/tests/js"
PVE_URL=https://127.0.0.1:8006 PVE_PASSWORD=$PW E2E_MODE=rows E2E_VMID=$VMID E2E_SHOTS=$SHOTS \
    npx playwright test e2e.spec.js > "$W/gui-rows.log" 2>&1
check "GUI: rows render after pve-manager reinstall" test $? = 0
cd - >/dev/null
endgroup

group "remove and purge"
pve 'apt-get remove -y pve-cloudinit-extras' > "$W/remove.log" 2>&1
check "apt remove succeeds" test $? = 0
pve 'md5sum /usr/share/pve-manager/index.html.tpl /usr/share/perl5/PVE/API2/Nodes.pm' > "$W/after-remove.md5"
check "both files byte-identical to before installation" cmp -s "$W/stock.md5" "$W/after-remove.md5"
pve 'dpkg --verify pve-manager' > "$SHOTS/dpkg-verify.txt" 2>&1
note "dpkg --verify pve-manager: $(tr '\n' ';' < "$SHOTS/dpkg-verify.txt")"
check "dpkg --verify pve-manager reports neither patched file" sh -c "! grep -E 'index.html.tpl|API2/Nodes.pm' '$SHOTS/dpkg-verify.txt'"
sleep 10
check "API route gone" sh -c "! curl -fsSk -b 'PVEAuthCookie=$TICKET' https://127.0.0.1:8006/api2/json/nodes/$NODE/cloudinit-extras"
cd "$REPO_ROOT/tests/js"
PVE_URL=https://127.0.0.1:8006 PVE_PASSWORD=$PW E2E_MODE=stock E2E_VMID=$VMID E2E_SHOTS=$SHOTS \
    npx playwright test e2e.spec.js > "$W/gui-stock.log" 2>&1
check "GUI: stock Cloud-Init tab without our rows, JS no longer served, no errors" test $? = 0
cd - >/dev/null
check "generated snippet left in place" pve "test -f /var/lib/e2e-snippets/snippets/cix-$VMID-vendor.yaml"
pve "qm start $VMID" > /dev/null 2>&1
check "VM with cicustom vendor= still starts after removal (guests unchanged)" test $? = 0
pve "qm stop $VMID" > /dev/null 2>&1
pve 'apt-get purge -y pve-cloudinit-extras' > "$W/purge.log" 2>&1
check "apt purge succeeds, state removed" pve 'test ! -e /var/lib/pve-cloudinit-extras'
endgroup

finish
