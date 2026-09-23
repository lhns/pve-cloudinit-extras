# pve-cloudinit-extras: design

Status: **implemented** (v0.1.0). This file records the design and why; the README says how to use it.

## 1. The four fields

| row | meaning | cloud-init slot |
| --- | --- | --- |
| **Custom files** | edit `cicustom` `user` / `network` / `meta` | as chosen |
| **Commands** | one command per line, run as `runcmd` | `vendor=` (generated file) |
| **Boot commands** | one command per line, run as `bootcmd` | `vendor=` (generated file) |
| **Include** | one more file: an existing snippet or an http(s) URL | `vendor=` (the snippet itself, or the generated file) |

**Why vendor-data:** `cicustom user=` *replaces* the whole generated user-data (user,
password, SSH keys, hostname, `package_upgrade`; see `cloudinit_userdata` in
`PVE/QemuServer/Cloudinit.pm`). qemu-server leaves vendor-data empty by default. cloud-init
merges it *under* user-data, so Commands, Boot commands and Include add to the Proxmox config
without displacing it.

**Proxmox's generated user-data never sets `runcmd`, `bootcmd` or `write_files`** (checked in
qemu-server 9.2: `cloudinit_userdata` emits only `hostname`, `manage_etc_hosts`, `fqdn`, `user`,
`disable_root`, `password`, `ssh_authorized_keys`, `chpasswd`, `users`, `package_upgrade`).

Merge rules ([vendordata](https://docs.cloud-init.io/en/latest/explanation/vendordata.html),
[merging](https://docs.cloud-init.io/en/latest/reference/merging.html)): user-data is merged over
vendor-data. A `runcmd`/`bootcmd` in user-data therefore **replaces** ours. With the generated
user-data this never happens (the e2e test proves our `runcmd` runs); it does if `cicustom user=`
points at a file with its own `runcmd`/`bootcmd`. The editors warn when `user=` is set.

**Semantics** (GUI help text and README):
- `runcmd`: once per instance, at the end of first boot. A change does not run on an existing
  instance until `cloud-init clean`. The NoCloud `instance-id` is `sha1(user-data . network-data)`
  (`nocloud_gen_metadata`), so a vendor-data change does not make a new instance.
- `bootcmd`: every boot, early in cloud-init's init stage; the network may not be up.
- Proxmox rebuilds the cloud-init drive on VM start, not on a guest-initiated reboot. Whether a
  changed `bootcmd` is picked up on an existing instance is measured by the e2e test; see README.

## 2. Generated vendor file

One file per VM, fixed name `<storage>:snippets/cix-<vmid>-vendor.yaml`, always a MIME multipart
document ([vendor-data takes multi-part input](https://docs.cloud-init.io/en/latest/explanation/vendordata.html)):

```
X-Managed-By: pve-cloudinit-extras/1        <- our header; we overwrite/delete only files with it
Content-Type: multipart/mixed; boundary="cix.boundary-1"
MIME-Version: 1.0

--cix.boundary-1
Content-Type: text/x-include-url            <- Include = URL
Content-Transfer-Encoding: base64
--cix.boundary-1
Content-Type: text/plain                    <- Include = snippet, combined with commands: inlined copy
X-PVE-Source: <volid>
--cix.boundary-1
Content-Type: text/cloud-config             <- Commands / Boot commands, always last
    #cloud-config
    {"bootcmd":[...],"merge_how":[{"name":"list","settings":["append"]},{"name":"dict","settings":["no_replace","recurse_list"]}],"runcmd":[...]}
--cix.boundary-1--
```

- `text/x-include-url`: the **guest** fetches the URL at boot. The host never does.
- `text/plain` snippet: cloud-init content-sniffs it, so a `#cloud-config`, `#!` script or
  `#include` snippet all work. It is a copy, refreshed whenever a field is saved.
- `merge_how` appends our lists to those of an included cloud-config, so both run, include first.
- **Injection-safe:** the cloud-config body is JSON (a YAML subset) from `JSON->canonical`; user
  text only ever becomes string values. Every part is base64, so nothing can forge a boundary
  or a header. The boundary contains `.` and `-`, which base64 never produces.
- Command validation: blank lines dropped; ≤ 200 lines of ≤ 4096 bytes; C0 (except TAB), DEL,
  C1, U+2028/2029 and U+FFFE/FFFF rejected (what PyYAML would not read back verbatim). The file
  must stay under qemu-server's 1 MiB snippet cap.

| commands (either) | include | result |
| --- | --- | --- |
| – | – | delete our file; `vendor=` cleared |
| – | snippet | `vendor=<that snippet>` directly; delete our file |
| – | URL | our file: include-url part |
| set | – | our file: cloud-config part |
| set | URL | our file: include-url + cloud-config |
| set | snippet | our file: inlined snippet + cloud-config |

## 3. GUI

`PVE.qemu.CloudInit` (xtype `pveCiPanel`) is a `Proxmox.grid.PendingObjectGrid`. One
`Ext.define({ override: 'PVE.qemu.CloudInit' })` sets `gridRows`, which
`Proxmox.grid.ObjectGrid.initComponent` turns into rows after the panel has built `me.rows`.
No stock method is wrapped. The store's reader holds its own copy of the rows, so our keys
(`cicustom`, `citype`, the virtual rows) are registered with it too.

- **Custom files**: `cicustom`, edited with a storage + snippet picker per slot; `vendor=` is kept.
  `never_delete`, because `vendor=` belongs to the other rows.
- **Commands / Boot commands / Include**: virtual rows derived from `cicustom.vendor`. Their
  editors call `PUT …/cloudinit-extras/vendor/{vmid}` with all generated fields, then set
  `cicustom vendor=` through the stock `PUT /config` (pending state, locking, permissions stay
  upstream's). The storage picker offers every storage with `snippets` content and preselects a
  shared one; a local one gets a warning (VM start fails on another node).
- Guards: the JS does nothing but `console.warn` unless `PVE.qemu.CloudInit` exists,
  `ObjectGrid.initComponent` still has the `gridRows` loop, the stock panel does not already
  handle `cicustom`, and the pickers exist. No `'use strict'`: ExtJS `callParent` needs `caller`.
- If the API probe fails (patch not active on that node) the three rows say so and have no editor.

## 4. Packaging and injection

One binary package. It owns `/usr/share/pve-manager/js/pve-cloudinit-extras.js` (pveproxy
already serves `/pve2/js/` from there), `PVE/API2/CloudinitExtras.pm`,
`PVE/CloudinitExtras/Vendor.pm` and `/usr/sbin/pve-cloudinit-extras-patch`.

| option | verdict |
| --- | --- |
| patch `pvemanagerlib.js` | **no**: 2.4 MB, rebuilt every release; a bad patch breaks the whole GUI |
| separate JS + one `<script>` line in `index.html.tpl` | **yes** |
| `dpkg-divert` | **no**: pve-manager's updates to the file would be silently lost |

Marker lines:
- `index.html.tpl`: `<script … src="/pve2/js/pve-cloudinit-extras.js?ver=<pkgver>" data-pve-cloudinit-extras></script>`
  after the `pvemanagerlib.js` line (template re-read on every request).
- `PVE/API2/Nodes.pm`: `use PVE::API2::CloudinitExtras; # pve-cloudinit-extras` after
  `use PVE::API2::VZDump;`, and a `register_method({ subclass => …, path => 'cloudinit-extras' })`
  line before the `PVE::API2::Qemu` block; then `try-reload-or-restart pvedaemon pveproxy`.

Prior art: [pve-modkit](https://github.com/the-wondersmith/pve-modkit) (same shape),
[pve-nag-buster](https://github.com/foundObjects/pve-nag-buster),
[Meliox/PVE-mods](https://github.com/Meliox/PVE-mods). Proxmox has no supported GUI extension point.

## 5. Surviving pve-manager updates

`debian/pve-cloudinit-extras.triggers`: `interest-noawait` on both files. When pve-manager
unpacks new copies, `postinst triggered` re-runs `pve-cloudinit-extras-patch apply`.

`apply`, per file, under a lock: strip our lines; version gate; anchor must match exactly once;
insert; compile check (Template Toolkit for the template, `use PVE::API2::Nodes` for `Nodes.pm`,
reverted on failure); atomic rename. Always exits 0: the worst outcome is "left stock", logged to
syslog and `/var/lib/pve-cloudinit-extras/status-{gui,api}`.

## 6. Version gate and backend

`/usr/share/pve-cloudinit-extras/supported`: `gui 9.2 9.3~`, `api 9.2 9.3~` (pve-manager
major.minor that was tested). Any other version stays stock. `FORCE=1` in
`/etc/pve-cloudinit-extras.conf` overrides it for testing a new version.

Stock API facts: `cicustom` is set via `PUT /config` with `VM.Config.Cloudinit` or
`VM.Config.Network`, without storage checks on the referenced snippet. Snippets cannot be written
through the stock API (`upload` and `download-url` take only `import|iso|vztmpl`).

**Endpoint** `PVE::API2::CloudinitExtras` (`proxyto => 'node'`, `protected => 1`: runs as root in
pvedaemon on the VM's node):

| method | path | permissions |
| --- | --- | --- |
| GET | `/nodes/{node}/cloudinit-extras` | any user (probe: `{version}`) |
| GET | `…/vendor/{vmid}?storage=` | `VM.Audit` → `{bootcmd, runcmd, include-url, include-snippet}` |
| PUT | `…/vendor/{vmid}` `storage, bootcmd?, runcmd?, include-url? \| include-snippet?` | `VM.Config.Cloudinit` on the VM **and** `Datastore.AllocateTemplate` on the storage; `Datastore.Audit` on the snippet's storage when it is inlined → `{vendor}` |

- The VM must exist on this node; the storage must be enabled, have `snippets` content and be file based.
- The file name derives only from the integer vmid; the path from `PVE::Storage::path`. No traversal.
- A file without our header, or a symlink, at that path is never overwritten, read or deleted.
- A generated file of another VM (after a clone) is referenced, never inlined.
- The endpoint writes only the file; the VM config is changed by the GUI through the stock API.
- No storage config is ever changed; snippets must already be enabled on some storage.

## 7. Cluster behaviour

Install on every node: each node serves its own GUI, and the endpoint runs on the VM's node.
With shared snippet storage, migration and HA work. With node-local storage the VM fails to
start elsewhere until the file is copied (the editor warns). `cicustom` lives in pmxcfs.

## 8. Uninstall

`prerm remove|upgrade|deconfigure` strips our lines, then compares each file to pve-manager's
md5sums. If it differs, it is restored from the matching `.deb` (apt cache, else
`apt-get download pve-manager=<installed>`); if that fails, it prints
`apt install --reinstall pve-manager` and still succeeds. `purge` removes the state directory and
`/etc/pve-cloudinit-extras.conf`. **Generated snippets and `cicustom` values are left alone**, so
guests do not change.

## 9. Tests

See README "Tests". In short: Perl unit tests (generator, endpoint), dpkg lifecycle against real
pve-manager `.deb`s, headless GUI tests against real ExtJS/`pvemanagerlib.js`, and an end-to-end
run on a nested PVE 9.2 installed from the official ISO, with a cloud-init guest.
