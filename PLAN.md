# pve-cloudinit-extras: plan

Status: **plan only**. Nothing is built or installed.

Facts about the target cluster were read (read-only) during planning and are not recorded here.

## 1. What the two fields mean

Candidate readings of "the options for the cloud init command and also an option to include
one further file from file/snippet or url":

| # | field 1 | field 2 |
| --- | --- | --- |
| A | **`cicustom` editor**: pick snippets for user / network / meta | **Include**: one extra file, either an existing snippet or a URL, merged *on top of* the Proxmox-generated config |
| B | **Custom commands**: a textarea of `runcmd` lines | as A |
| C | a raw user-data editor (full YAML) | as A |

**Recommended: A.** It maps 1:1 to the `qm set --cicustom` command the user cited. It needs no
backend, and field 2 covers "further file". B and C both need the GUI to *write* snippet
content. Once the backend from §6 exists, B costs little: a second managed file, rendered as a
`#cloud-config` with `runcmd`. That makes it a v2 option, not a separate design.

**The key design point:** `cicustom user=` *replaces* the whole generated user-data (user,
password, SSH keys, hostname, `package_upgrade`; see `cloudinit_userdata` in
`PVE/QemuServer/Cloudinit.pm`). An "include one more file" field must therefore **not** use the
`user=` slot. It uses **`vendor=`**. qemu-server leaves vendor-data empty by default (`$vendor_data = ''`).
cloud-init merges vendor-data *under* user-data, so the Proxmox-generated user/keys/IP config
stays intact and the included file adds to it.

- Include = **snippet**: set `cicustom vendor=<storage>:snippets/<file>`. This goes through the existing API.
- Include = **URL**: write a managed snippet `cix-<vmid>-include.yaml` containing
  `#include\n<url>\n`, then set `vendor=` to it. The **guest** fetches the URL at boot.

Field 1 therefore edits `user`/`network`/`meta`, and field 2 owns `vendor`. The field 1 editor
shows `vendor` read-only as "managed by Include".

## 2. GUI design

The panel is `PVE.qemu.CloudInit` (xtype `pveCiPanel`, extends
`Proxmox.grid.PendingObjectGrid`). It is a key/value grid built from `me.rows`, with
Edit/Remove/Regenerate Image buttons. Pending values are shown the same way as for the other rows.

Two new rows, styled like the existing ones:

| row | icon | value shown | editor |
| --- | --- | --- | --- |
| **Custom files** (`cicustom`) | `fa-file-code-o` | `user=…, network=…` or "none" | `proxmoxWindowEdit` with three `pveStorageSelector` (`storageContent: 'snippets'`) + `pveFileSelector` pairs, each clearable. Warning text under `user`: "replaces the generated user, password, SSH keys" |
| **Include** (virtual, derived from `cicustom.vendor`) | `fa-plus-square` | snippet volid, or the URL of a managed include, or "none" | radiogroup *None / Snippet / URL*; snippet mode uses the same selectors; URL mode has a `proxmoxtextfield` (http/https only) plus a storage selector for where the pointer file lives |

- The Remove button works natively on `cicustom`. The Include row gets `never_delete: true`,
  because clearing it happens in its editor via *None*.
- Both editors send a normal `PUT /config` for `cicustom`, merging the other parts. Pending
  state and permissions therefore behave like any stock field.
- URL mode is disabled, with a tooltip, when the backend package is absent (`GET …/cloudinit-extras` → 404).
- Existing Regenerate Image button is unchanged.
- **Hook point:** `Proxmox.grid.ObjectGrid.initComponent` processes `me.gridRows` via
  `me['add_<xtype>_row']` *after* `PVE.qemu.CloudInit` has built `me.rows`. It does so before
  the store and filter are created. The extension is one `Ext.define({ override: 'PVE.qemu.CloudInit' })`
  that sets `gridRows` and adds `add_cixcustom_row` / `add_cixinclude_row`. No stock method is
  wrapped or replaced.

## 3. Injection mechanism

| option | verdict |
| --- | --- |
| patch `pvemanagerlib.js` (2.4 MB, rebuilt every release) | **no**. Fragile anchors, and a bad patch breaks the entire GUI |
| **separate JS file + one `<script>` line in `index.html.tpl`** | **yes** |
| `dpkg-divert` of `index.html.tpl` | **no**. pve-manager's updates to the template land in the `.distrib` file and are silently lost, so the GUI can end up loading a stale template against a new `pvemanagerlib.js` |

Details:

- The package owns `/usr/share/pve-manager/js/pve-cloudinit-extras.js`. pveproxy already serves
  `/pve2/js/` from that directory (`add_dirs` in `PVE/Service/pveproxy.pm`), so **no pveproxy patch
  and no pveproxy restart** are needed. pve-modkit, by contrast, has to patch `pveproxy.pm`.
- There is one marker line, inserted directly after the stock
  `<script … src="/pve2/js/pvemanagerlib.js?ver=[% version %]"></script>`:
  ```html
  <script type="text/javascript" src="/pve2/js/pve-cloudinit-extras.js?ver=0.1.0" data-pve-cloudinit-extras></script>
  ```
  The `ver=` query string busts the browser cache when the package is upgraded.
- The template is re-read on every request (`Template->new` in `pveproxy.pm`), so a patch takes
  effect on the next page load.
- The JS is defensive. The whole body is wrapped in `try`. It does nothing (only `console.warn`) unless
  `PVE.qemu.CloudInit` exists and `Proxmox.grid.ObjectGrid` still has the `gridRows` loop. **The
  worst case of an incompatible pve-manager is "the two rows don't appear"; the stock GUI keeps
  working.**

Prior art:
- [pve-modkit](https://github.com/the-wondersmith/pve-modkit): the same shape (script tag in
  `index.html.tpl`, `interest-noawait` triggers, idempotent patches, restore on remove).
- [pve-nag-buster](https://github.com/foundObjects/pve-nag-buster): a dpkg/apt hook that re-patches
  `proxmoxlib.js` on every update. It works, but it is a `sed` on minified library code.
- [Meliox/PVE-mods](https://github.com/Meliox/PVE-mods) (sensors): patches `pvemanagerlib.js` and
  `Nodes.pm` with backups, and **does not** survive upgrades ("reinstallation … could be required").
- Proxmox has no supported extension point for third-party GUI code
  ([forum](https://forum.proxmox.com/threads/supported-way-to-extend-the-pve-web-ui-for-a-third-party-package.185017/)).

## 4. Surviving pve-manager updates

**A dpkg file trigger** (`debian/pve-cloudinit-extras.triggers`):
```
interest-noawait /usr/share/pve-manager/index.html.tpl
```
When pve-manager unpacks a new template, dpkg runs our `postinst triggered`, which runs
`pve-cloudinit-extras-patch apply`. The apply step is idempotent. With `noawait`, pve-manager's
configure step does not block on us. pve-manager itself uses the same mechanism
(`interest-noawait /usr/share/perl5/PVE`).

Rejected alternatives:
- **apt `DPkg::Post-Invoke`**: runs after *every* apt run, and not at all for `dpkg -i`. It also
  leaves a config file in `/etc/apt` that dpkg treats as a conffile, which gets awkward on purge.
  The trigger fires exactly when the file changes.
- **systemd `.path` unit** on the template: it would race with dpkg. Not needed.

The patch script:
1. `flock /run/lock/pve-cloudinit-extras.lock`
2. If the marker is already present → exit 0.
3. Run the **version gate** (§5). If it fails → log to syslog and `/var/lib/pve-cloudinit-extras/status`, exit 0 (**never fail dpkg**).
4. Require the anchor line to match **exactly once**. Otherwise → treat it as unknown and leave the file stock.
5. Write a temp file, then `perl -MTemplate -e` compile it (a Template Toolkit syntax check, as pve-modkit does), then `mv` it into place atomically.

## 5. Version check

The check has two layers, because the risks are different:

| layer | rule | on failure |
| --- | --- | --- |
| install time (`patch apply`) | `dpkg-query -W pve-manager` ∈ `SUPPORTED` range (initially `>= 9.2 << 9.3`) **and** anchor matches exactly once | skip the patch, log the reason, GUI stays stock |
| runtime (JS) | the classes and `gridRows` hook exist, and `PVE.qemu.CloudInit.prototype.rows` is not already defining `cicustom` (i.e. upstream has added its own field) | do nothing |
| backend (`-api` pkg) | exact pve-manager minor allowlist, plus `perl -c`-style load test of `PVE::API2::Nodes` after patching | restore the pristine file (§6), log |

`SUPPORTED` lives in `/usr/share/pve-cloudinit-extras/supported`. An admin can override it with
`/etc/pve-cloudinit-extras.conf` (`FORCE=1`) when testing a new pve-manager version. The GUI
layer is low-risk, so the policy for it could relax to "anchor present" alone (open question 4).

## 6. Backend and security

**What exists** (read from the installed API):
- `cicustom` is a normal qemu config property (`pve-qm-cicustom`: `meta|network|user|vendor=<volid>`).
  It is settable via `PUT /nodes/{node}/qemu/{vmid}/config` with **`VM.Config.Cloudinit` or
  `VM.Config.Network`** (`$cloudinitoptions` in `PVE/API2/Qemu.pm`). qemu-server does **not**
  check storage permissions on the referenced snippet. That is upstream's trust model, and we do not change it.
- Listing snippets: `GET /nodes/{node}/storage/{storage}/content?content=snippets` (needs `Datastore.Audit`/`AllocateSpace`).
- Writing snippets: **not possible**. `upload` and `download-url` both accept only `import | iso | vztmpl`.
- qemu-server reads snippets with a 1 MiB cap each and 3 MiB in total, and requires `vtype eq 'snippets'`.

**Therefore:**
- Field 1 and snippet-mode Include: **pure GUI, no backend.**
- URL-mode Include: needs one small write endpoint. It ships as a **separate, optional binary
  package `pve-cloudinit-extras-api`**, so the GUI package never patches Perl.

`pve-cloudinit-extras-api`:
- `/usr/share/perl5/PVE/API2/CloudinitExtras.pm` (owned by the package, never overwritten).
- Two marker lines in `/usr/share/perl5/PVE/API2/Nodes.pm` (owned by pve-manager, package
  `PVE::API2::Nodes::Nodeinfo`): a `use` after `use PVE::API2::VZDump;`, and a
  `register_method({subclass => 'PVE::API2::CloudinitExtras', path => 'cloudinit-extras'})` before
  the `subclass => "PVE::API2::Qemu"` block. Both are re-applied by
  `interest-noawait /usr/share/perl5/PVE/API2/Nodes.pm`, then `systemctl reload-or-restart pvedaemon pveproxy`.
- Endpoints (`proxyto => 'node'`, `protected => 1`, so they run in pvedaemon as root on the VM's node):
  - `GET  /nodes/{node}/cloudinit-extras` → `{ version }` (feature probe)
  - `GET  /nodes/{node}/cloudinit-extras/include/{vmid}?storage=` → `{ url }` (`VM.Audit`)
  - `PUT  /nodes/{node}/cloudinit-extras/include/{vmid}` `{storage, url}` → writes the file, returns volid
  - `DELETE …/include/{vmid}?storage=` → removes the managed file
- Rules:
  - Permissions: **`VM.Config.Cloudinit` on `/vms/{vmid}` AND `Datastore.AllocateSpace` on `/storage/{storage}`**.
  - `{vmid}` must exist on this node.
  - The storage must be enabled on the node, have `content snippets`, and be path-based.
  - The filename is **fixed**, `cix-<vmid>-include.yaml`. It derives only from the integer vmid,
    so there is **no user-controlled path and no traversal**. The path comes from `PVE::Storage::path`, never from string joins.
  - `url`: `^https?://[\x21-\x7e]{1,2040}$`. No whitespace or control chars, which blocks injecting extra `#include` lines.
  - Content is exactly `#include\n# managed by pve-cloudinit-extras\n<url>\n`. cloud-init skips `#` lines in include files.
  - Existing files are overwritten only if they carry that header. Writes are atomic (`file_set_contents`).
  - The endpoint writes **only the file**. The GUI then sets `cicustom` via the stock `PUT /config`, so
    pending, locking and permission semantics stay upstream's.
- **No SSRF on the host**: the node never fetches the URL. The guest does.
- Stale managed files are harmless. `DELETE` is best-effort when switching to *None*.

**Alternative with zero new endpoints:** skip the `-api` package. URL mode is then unavailable,
and a root-only CLI `pve-cloudinit-extras include <vmid> <storage> <url>` writes the pointer
file. This fully satisfies "no new privileged endpoints" but loses URL-from-GUI.

## 7. Cluster behaviour

- **Install on every node.** Each node serves its own GUI, and the backend runs on the VM's node.
  Mixed states degrade cleanly: without the GUI package a node shows stock rows, and without the API package URL mode is disabled.
- **Shared snippet storage** (e.g. CephFS mounted on all nodes): the file is visible
  everywhere, and migration and HA just work.
- **Node-local snippet storage** (for example `local` with `snippets` enabled): the file exists
  only on the node where it was written. After migration, VM start fails
  (`volume … does not exist`) until the file is copied. The GUI filters to shared storages by
  default and shows a warning if a local one is chosen.
- Setting `cicustom` changes `/etc/pve/qemu-server/<vmid>.conf` (pmxcfs), which is cluster-wide as always.

## 8. Uninstall guarantees

- `prerm remove|upgrade|deconfigure` runs `patch remove`: delete lines carrying the marker, exactly as inserted.
  The upgrade case is included because the new postinst re-applies the patch.
- **Proof of stock:** afterwards, compare the file against pve-manager's own
  `/var/lib/dpkg/info/pve-manager.md5sums`, which is equivalent to `dpkg --verify pve-manager`. If it matches → done.
  If not (marker damaged, or another mod present) → restore from the matching `.deb`:
  `apt-get download pve-manager=<installed>` → `dpkg-deb --fsys-tarfile | tar -xO ./usr/share/pve-manager/index.html.tpl`.
  This avoids `apt install --reinstall pve-manager`. If the download fails, print exactly that command, and do not fail the removal.
- The same applies to `Nodes.pm` (also owned by pve-manager), followed by a pvedaemon/pveproxy reload.
- `purge` removes `/var/lib/pve-cloudinit-extras` and `/etc/pve-cloudinit-extras.conf`.
  **Snippets and `cicustom` values in VM configs are never touched.** Removing the package must not change guests.
  `README` documents how to find them: `grep -l cicustom /etc/pve/nodes/*/qemu-server/*.conf`, `ls <storage>/snippets/cix-*`.
- Files we own (`.js`, `.pm`) are removed by dpkg as normal.

## 9. Build and test

- Build: `dpkg-buildpackage -us -uc -b` in a `debian:trixie` container. Arch `all`, no compiled code.
  Lint: `lintian`, `eslint` (Proxmox's ESLint config), `perlcritic`/`perl -c` against a PVE 9.2 perl tree.
- **Never test on the production nodes.** Use a throwaway **nested PVE 9.2 VM** (on the cluster, or local
  Hyper-V/VirtualBox) with a `dir` storage with `snippets` enabled and a Debian 13 genericcloud template.
- Test matrix, each step asserting `dpkg --verify pve-manager` output and GUI load:
  1. install → marker present, rows visible, stock rows unchanged;
  2. `apt install --reinstall pve-manager` → the trigger re-applies;
  3. upgrade/downgrade pve-manager across a minor (9.1 → 9.2) → the patch re-applies or stays stock per the gate;
  4. edit the anchor in a test copy / set an out-of-range version → GUI stock, reason logged;
  5. `apt remove` → `dpkg --verify` clean, no marker, `/pve2/js/pve-cloudinit-extras.js` 404;
     then `apt purge`;
  6. API: permission matrix with a non-root user (with/without `VM.Config.Cloudinit`, `Datastore.AllocateSpace`),
     bad URLs (newline, `file://`, spaces), foreign existing file, local vs shared storage;
  7. guest: vendor snippet and URL include actually applied (`cloud-init query vendordata`, `/var/log/cloud-init.log`),
     with generated user/keys still present.
- JS fast loop without a PVE VM: a local static harness serving ExtJS + `proxmoxlib.js` +
  `pvemanagerlib.js` copied from the test VM, with a mock of `/api2/extjs/...` (pending/config/storage content).

## 10. Risks and open questions

Risks:
- **Changes to vendor data do not re-run cloud-init on existing VMs.** The NoCloud
  `instance-id` is `sha1(user-data . network-data)` only, so an Include change is seen
  only on a fresh instance or after `cloud-init clean` in the guest. The GUI states this in the editor.
- `citype configdrive2` puts vendor data in `vendor_data.json`, which OpenStack datasources parse differently.
  Include is supported for `nocloud` (the Linux default) only. Other types get a warning.
- A full snippet storage blocks snippet writes and VM starts that need them.
- Upstream could add its own `cicustom` GUI field. The runtime guard (§5) then turns ours off.
- Patching `Nodes.pm` is the one piece that can break the API. It is isolated in the optional package with a strict allowlist and a load test.

Open questions for the user:
1. Is reading **A** right (cicustom editor + one include), or do you want inline `runcmd` (B) too?
2. URL include from the GUI: accept the optional `-api` package (one new endpoint, `Nodes.pm`
   patch), or keep zero new endpoints and use the root CLI for URLs?
3. Which storage should hold snippets? Options: enable `snippets` on an existing
   storage, or create a small dedicated CephFS/dir storage. This is a cluster config change you decide.
4. Version policy for the GUI patch: strict minor allowlist (safe, but needs a package bump each
   PVE minor) or "anchor present" (keeps working across minors)?
5. Permission for writing the include file: `Datastore.AllocateSpace` (proposed) or the stricter
   `Datastore.AllocateTemplate`, as `upload` uses?
6. Where to build and test: a nested PVE VM on this cluster (which one, which storage) or on your workstation?
