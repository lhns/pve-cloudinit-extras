# pve-cloudinit-extras

Adds four rows to the Proxmox VE 9.2 Cloud-Init tab (VM → Cloud-Init):

| row | what it does |
| --- | --- |
| **Custom files** | edits `cicustom` `user` / `network` / `meta` with storage and snippet pickers, instead of `qm set --cicustom` |
| **Commands** | cloud-init `runcmd`, one command per line |
| **Boot commands** | cloud-init `bootcmd`, one command per line |
| **Include** | one more cloud-init file: an existing snippet, or an http(s) URL |

Commands, Boot commands and Include go into cloud-init **vendor data**, as one generated snippet
per VM (`<storage>:snippets/cix-<vmid>-vendor.yaml`, referenced as `cicustom vendor=`). The
Proxmox-generated user, password, SSH keys and network config stay in effect. A small API
endpoint writes that snippet, because the stock API cannot write snippets.

## Semantics

- **Commands (`runcmd`)** run **once per instance**, at the end of the first boot. Changing them
  on a VM that has already booted does nothing until `cloud-init clean` in the guest (or a new
  instance, e.g. a fresh clone).
- **Boot commands (`bootcmd`)** run on **every boot**, early in cloud-init's init stage. Do not
  rely on the network. A change takes effect at the next VM **start from Proxmox** (Start, or
  Shutdown then Start), without `cloud-init clean`: Proxmox rebuilds the cloud-init drive then and
  NoCloud re-reads it on every boot. A reboot from inside the guest keeps the old drive, so it
  runs the old list.

Measured by the end-to-end test (Debian 13 cloud image): the Proxmox-generated user data does
**not** override our `runcmd`; the URL include and our commands both run, include first; a
changed `bootcmd` ran after a stop/start but not after an in-guest reboot; a changed `runcmd`
did not run again.
- **Include** is applied at first boot, like Commands. A URL is fetched **by the guest**, never by
  the host. A snippet alone is referenced directly; combined with commands it is copied into the
  generated file (re-copied whenever a field is saved).
- All of this needs `citype nocloud` (the Linux default). A `cicustom user=` file with its own
  `runcmd`/`bootcmd` overrides ours: user data is merged over vendor data. The generated user
  data never sets them, so it does not interfere.
- Commands are passed as JSON strings inside the cloud-config, so no text can add keys; the
  snippet parts are base64. Control characters are rejected.

## Install

On **every** node of the cluster:

```sh
apt install ./pve-cloudinit-extras_0.1.0_all.deb
pve-cloudinit-extras-patch status
```

Reload the browser tab. Snippets must already be enabled on some storage
(Datacenter → Storage → Edit → Content: Snippets); the package never changes storage config.
Prefer a shared storage: with a node-local one, the VM will not start on another node.

## Uninstall

```sh
apt remove pve-cloudinit-extras   # or: apt purge
```

Removal deletes the marker lines and checks both pve-manager files against pve-manager's
md5sums; if they differ, it restores them from the pve-manager `.deb`. Generated snippets and
`cicustom` values are **left in place**, so guests do not change. To find them:
`grep -l cicustom /etc/pve/nodes/*/qemu-server/*.conf` and `ls <storage path>/snippets/cix-*`.

## How it hooks in and survives upgrades

- The GUI is a separate file, `/usr/share/pve-manager/js/pve-cloudinit-extras.js`, loaded by one
  marked `<script>` line in `/usr/share/pve-manager/index.html.tpl`. `pvemanagerlib.js` is never
  touched. If its checks fail, the script does nothing and the rows simply do not appear.
- The endpoint `/nodes/{node}/cloudinit-extras` is registered by two marked lines in
  `/usr/share/perl5/PVE/API2/Nodes.pm`; after patching, the module is load-tested and reverted if
  it fails.
- dpkg file triggers (`interest-noawait`) re-apply the lines whenever pve-manager replaces those
  files. The patch step holds a lock, is idempotent, requires its anchor line exactly once, and
  never fails dpkg.
- **Version policy:** only pve-manager **9.2.x** is patched (`/usr/share/pve-cloudinit-extras/supported`).
  On any other version both files stay stock and the reason is logged (`pve-cloudinit-extras-patch status`,
  syslog). A new Proxmox minor needs a package update after testing. `FORCE=1` in
  `/etc/pve-cloudinit-extras.conf` overrides the check, for testing only.

## Permissions

| action | needs |
| --- | --- |
| see the rows' content | `VM.Audit` |
| edit Custom files | `VM.Config.Cloudinit` or `VM.Config.Network` (stock `cicustom` rule) |
| edit Commands / Boot commands / Include | `VM.Config.Cloudinit` on the VM **and** `Datastore.AllocateTemplate` on the snippet storage |
| Include a snippet together with commands (it is copied) | additionally `Datastore.Audit` on that snippet's storage |

The endpoint writes only `cix-<vmid>-vendor.yaml` (name derived from the integer VM ID, no user
path), only if absent or carrying its own header, never through a symlink, and changes no VM or
storage config itself.

## Defaults chosen (to confirm)

1. Fields: Custom files, Include, Commands (`runcmd`) and Boot commands (`bootcmd`).
2. Commands and URL includes are set from the GUI through the new endpoint.
3. Storage: any storage with `snippets` content; shared ones are preselected. Nothing is enabled automatically.
4. Version policy: allowlist of pve-manager major.minor (9.2) plus the exact-anchor check.
5. Writing the snippet needs `Datastore.AllocateTemplate` on the storage and `VM.Config.Cloudinit` on the VM.

## Test on a throwaway PVE

Do not try it on production nodes first. The CI end-to-end job (`tests/e2e/run.sh`) does this on
a GitHub runner: it installs PVE 9.2 from the official ISO with an answer file into a nested
VM, installs the package, drives the GUI with Playwright, boots a Debian 13 cloud image, reboots
it, reinstalls pve-manager and removes the package. To do the same by hand, install PVE 9.2 in
a VM, add a `dir` storage with snippets content, install the `.deb`, and create a cloud-init VM.

## Tests

| suite | what | where |
| --- | --- | --- |
| build | `dpkg-buildpackage` on Debian 13, `lintian --fail-on warning`, `dpkg-deb --contents` checks | `tests/deb-contents.sh` |
| Perl | generator and endpoint: permissions, path handling, header-guarded overwrite, URL validation, all bootcmd × runcmd × include combinations with hostile text, parsed back with Python `email` + `yaml.safe_load` | `t/` |
| lifecycle | real pve-manager `.deb`s in a Debian 13 container: install, reinstall, upgrade, pve-manager reinstall/upgrade/downgrade (trigger), unsupported version, missing/duplicated anchors, concurrency, remove/purge byte-identical, restore from `.deb` | `tests/lifecycle.sh` |
| GUI | ESLint; headless Chromium with the real ExtJS, `proxmoxlib.js` and `pvemanagerlib.js` against a mocked API | `tests/js/gui.spec.js` |
| e2e | nested PVE 9.2 from the ISO, real API/GUI, cloud-init guest | `tests/e2e/run.sh` |

## License

AGPL-3.0-or-later, like Proxmox VE.
