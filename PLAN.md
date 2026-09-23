# pve-cloudinit-extras: plan

Status: **plan only**. Nothing is built or installed.

Facts about the target cluster were read (read-only) during planning and are not recorded here.

## 1. The three fields

Confirmed by the user:

| row | meaning | cloud-init slot |
| --- | --- | --- |
| **Custom files** | edit `cicustom` `user` / `network` / `meta` | as chosen |
| **Commands** | one command per line, run as `runcmd` | `vendor=` (generated file) |
| **Include** | one more file: an existing snippet or a URL | `vendor=` (the snippet itself, or the generated file) |

**Why vendor-data:** `cicustom user=` *replaces* the whole generated user-data (user,
password, SSH keys, hostname, `package_upgrade`; see `cloudinit_userdata` in
`PVE/QemuServer/Cloudinit.pm`). qemu-server leaves vendor-data empty by default. cloud-init
merges it *under* user-data, so Commands and Include add to the Proxmox config without
displacing it.

**Proxmox's generated user-data never sets `runcmd`, `bootcmd` or `write_files`.** This was checked
in qemu-server 9.2.4: `cloudinit_userdata` emits only `hostname`, `manage_etc_hosts`, `fqdn`,
`user`, `disable_root`, `password`, `ssh_authorized_keys`, `chpasswd`, `users` and `package_upgrade`.
A grep over `PVE/QemuServer*` and `PVE/API2/Qemu.pm` finds no `runcmd`/`bootcmd`/`write_files`.

Merge rules
([vendordata](https://docs.cloud-init.io/en/latest/explanation/vendordata.html),
[merging](https://docs.cloud-init.io/en/latest/reference/merging.html)):

- "User-supplied cloud-config is merged over cloud-config from vendor-data", and merging is **not** done
  *across* config types. A user-data `runcmd` would therefore **replace** ours wholesale.
- With stock generated user-data this never happens, and **our commands survive**.
- It does happen if the VM also sets `cicustom user=` to a snippet that defines `runcmd`, or
  sets `vendor_data: {enabled: false}`. The Commands editor warns when `user=` is set.
  This is a must-test item (§9).

**Semantics, stated in the plan and in the GUI help text:** `runcmd` runs **once per
instance, at first boot**. Changing Commands or Include on an existing VM has **no effect** until
`cloud-init clean` in the guest or a new instance. There is a further catch: the NoCloud `instance-id` is
`sha1(user-data . network-data)` only (`nocloud_gen_metadata`), so a vendor-data change does not
even make a new instance.

## 2. Generated vendor file

The file is one per VM, with a fixed name: `<storage>:snippets/cix-<vmid>-vendor.yaml`.

[Vendor-data "is handled exactly like user-data … can supply multi-part input"](https://docs.cloud-init.io/en/latest/explanation/vendordata.html).
The generated file is therefore always a **MIME multipart** document, even for a single part, so it has one
format to parse and one header to recognise:

```
Content-Type: multipart/mixed; boundary="cix-<random>"
MIME-Version: 1.0
X-Managed-By: pve-cloudinit-extras/1          <- "our header"; overwrite/delete only if present

--cix-<random>
Content-Type: text/x-include-url              <- URL include
Content-Transfer-Encoding: base64
    base64("https://example/x.yaml\n")
--cix-<random>
Content-Type: text/plain                      <- snippet include, inlined copy
Content-Transfer-Encoding: base64
X-PVE-Source: shared:snippets/foo.yaml
    base64(<snippet content>)
--cix-<random>
Content-Type: text/cloud-config               <- Commands, always the LAST part
Content-Transfer-Encoding: base64
    base64('#cloud-config\n{"merge_how":[{"name":"list","settings":["append"]},{"name":"dict","settings":["no_replace","recurse_list"]}],"runcmd":["cmd 1","cmd 2"]}\n')
--cix-<random>--
```

Why each part looks like this:
- `text/x-include-url`: cloud-init fetches each non-`#` line and processes the result recursively
  (`_do_include` in [`cloudinit/user_data.py`](https://github.com/canonical/cloud-init/blob/main/cloudinit/user_data.py)).
  The **guest** fetches the URL. The host never does.
- Snippet inlined as `text/plain`: cloud-init content-sniffs `text/plain` parts (`TYPE_NEEDED`
  → `type_from_starts_with`), so a `#cloud-config`, `#!` script or `#include` snippet each works
  unchanged. The guest cannot reach a snippet, so the snippet has to be inlined. That makes it a **snapshot**: the file is
  regenerated whenever Commands or Include is saved, and the editor offers "re-read snippet".
- The Commands `merge_how` is the documented recipe for appending `runcmd` across parts
  ([merging](https://docs.cloud-init.io/en/latest/reference/merging.html)). It keeps the included file's own
  `runcmd`, and the Commands part runs after it.
- **Injection-safe:**
  - The cloud-config body is **JSON** (a YAML subset), built with Perl `JSON->canonical->encode`.
  - User text only ever becomes JSON string values, so it cannot add keys.
  - All parts are base64 encoded, so no content can collide with the boundary or forge headers.
- Command validation:
  - Split on `\n`, drop blank lines, at most 200 lines of at most 4096 bytes each.
  - Reject C0/DEL control chars and invalid UTF-8.
  - Each line runs via `sh -c`, as for any string `runcmd` item.
  - The whole file must be under 1 MiB, qemu-server's per-snippet read cap.

| Commands | Include | result |
| --- | --- | --- |
| – | – | delete the managed file; clear `vendor=` |
| – | snippet | `vendor=<that snippet>` directly (live, no copy); delete the managed file |
| – | URL | managed file: include-url part |
| set | – | managed file: cloud-config part |
| set | URL | managed file: include-url + cloud-config |
| set | snippet | managed file: inlined snippet + cloud-config |

If `vendor=` points at a snippet we don't manage, and the user sets Commands without choosing an
Include, the editor asks: "Keep `<volid>` as the Include?"

## 3. GUI design

The panel is `PVE.qemu.CloudInit` (xtype `pveCiPanel`, extends
`Proxmox.grid.PendingObjectGrid`). It is a key/value grid built from `me.rows`, with
Edit/Remove/Regenerate Image buttons.

Three new rows, styled like the existing ones:

| row | icon | value shown | editor (`proxmoxWindowEdit`) |
| --- | --- | --- | --- |
| **Custom files** (`cicustom`) | `fa-file-code-o` | `user=…, network=…` or "none" | `user`/`network`/`meta`: `pveStorageSelector` (`storageContent: 'snippets'`) + `pveFileSelector` each. Warning under `user`: "replaces the generated user, password, SSH keys, and overrides Commands' `runcmd` if it has one". `vendor` is shown read-only when managed |
| **Commands** (virtual) | `fa-terminal` | first command + "(N more)", or "none" | monospace `textareafield`, one command per line. Help: "Run once, at first boot of a new instance (cloud-init `runcmd`). Changes do not affect an already initialised VM." Plus a storage selector for where the file lives |
| **Include** (virtual) | `fa-plus-square` | snippet volid / URL / "none" | radiogroup *None / Snippet / URL*, with selectors or an http(s) text field |

- Commands and Include are both virtual rows derived from `cicustom.vendor`, with
  `never_delete: true`. They are cleared in their editors.
- Both editors load the state with `GET …/vendor/{vmid}` and submit **both values** in one
  `PUT …/vendor/{vmid}`. They then set `cicustom` with the stock `PUT /config`, merging the other parts, so pending state and
  permissions stay upstream's.
- **Hook point:** `Proxmox.grid.ObjectGrid.initComponent` runs `me['add_<xtype>_row']` for each
  `me.gridRows` entry. It does this *after* `PVE.qemu.CloudInit` has built `me.rows`, and before the store is built. The extension is one
  `Ext.define({ override: 'PVE.qemu.CloudInit' })` that sets `gridRows` and adds the row
  functions. No stock method is wrapped.
- If the backend patch is not active (version gate, §6), the probe `GET /nodes/{node}/cloudinit-extras`
  returns 404. Commands and URL/snippet-inline are then disabled with a tooltip. Custom files and the direct snippet
  Include still work.

## 4. Packaging and injection

There is **one binary package, `pve-cloudinit-extras`**, containing the GUI and the backend. Commands
cannot work without the endpoint, and a separate package only adds a half-installed state to
test. (The alternative, a GUI package that depends on an `-api` package, gives the same result
with more moving parts.)

| option | verdict |
| --- | --- |
| patch `pvemanagerlib.js` (2.4 MB, rebuilt every release) | **no**. Fragile anchors, and a bad patch breaks the entire GUI |
| **separate JS file + one `<script>` line in `index.html.tpl`** | **yes** |
| `dpkg-divert` of `index.html.tpl` / `Nodes.pm` | **no**. pve-manager's updates to those files would be silently lost, leaving a stale file loaded against new code |

The package owns:
- `/usr/share/pve-manager/js/pve-cloudinit-extras.js`. pveproxy already serves `/pve2/js/` from that
  directory (`add_dirs` in `PVE/Service/pveproxy.pm`), so no pveproxy patch is needed.
- `/usr/share/perl5/PVE/API2/CloudinitExtras.pm` (the endpoint).
- `/usr/share/perl5/PVE/CloudinitExtras/Vendor.pm` (the file generator).
- `/usr/sbin/pve-cloudinit-extras` (the CLI; see §6).
- `/usr/sbin/pve-cloudinit-extras-patch`.

It patches two pve-manager files. Every added line carries a marker:
- `index.html.tpl`: one `<script … src="/pve2/js/pve-cloudinit-extras.js?ver=<pkgver>" data-pve-cloudinit-extras>`
  line, inserted after the stock `pvemanagerlib.js` script line. The template is re-read on every request.
- `PVE/API2/Nodes.pm` (package `PVE::API2::Nodes::Nodeinfo`):
  - `use PVE::API2::CloudinitExtras; # pve-cloudinit-extras` after `use PVE::API2::VZDump;`;
  - `__PACKAGE__->register_method({subclass => 'PVE::API2::CloudinitExtras', path => 'cloudinit-extras'}); # pve-cloudinit-extras`
    before the `subclass => "PVE::API2::Qemu"` block;
  - then `systemctl reload-or-restart pvedaemon pveproxy`.

The JS is defensive: the whole body is wrapped in `try`, and it does nothing unless `PVE.qemu.CloudInit` exists, the
`gridRows` hook exists, and upstream has not added its own `cicustom` row.

Prior art:
- [pve-modkit](https://github.com/the-wondersmith/pve-modkit): script tag in `index.html.tpl`,
  `interest-noawait` triggers, idempotent patches, restore on remove.
- [pve-nag-buster](https://github.com/foundObjects/pve-nag-buster): an update hook re-`sed`s `proxmoxlib.js`.
- [Meliox/PVE-mods](https://github.com/Meliox/PVE-mods): patches `pvemanagerlib.js` and `Nodes.pm`,
  and does not survive upgrades.
- Proxmox offers no supported extension point
  ([forum](https://forum.proxmox.com/threads/supported-way-to-extend-the-pve-web-ui-for-a-third-party-package.185017/)).

## 5. Surviving pve-manager updates

**dpkg file triggers** (`debian/pve-cloudinit-extras.triggers`):
```
interest-noawait /usr/share/pve-manager/index.html.tpl
interest-noawait /usr/share/perl5/PVE/API2/Nodes.pm
```
When pve-manager unpacks new copies, dpkg runs our `postinst triggered`, which runs
`pve-cloudinit-extras-patch apply`. With `noawait`, pve-manager does not block on us. pve-manager itself
uses the same mechanism (`interest-noawait /usr/share/perl5/PVE`).

Rejected alternatives:
- **apt `DPkg::Post-Invoke`**: runs after every apt run, never for `dpkg -i`, and is an `/etc/apt` conffile.
- **systemd `.path` unit**: would race with dpkg.

The patch script, per file:
1. `flock`.
2. If the marker is already present → done.
3. Run the version gate (§6). If it fails → log and continue with the next file. **Never fail dpkg.**
4. Require the anchor to match **exactly once**.
5. Write a temp file, then:
   - template: `perl -MTemplate` compile;
   - `Nodes.pm`: after the atomic `mv`, `perl -e 'use PVE::API2::Nodes'` load test. If it fails → restore (§8) and log.

## 6. Version check and backend

**Version gate.** `/usr/share/pve-cloudinit-extras/supported` holds a range per target:

| target | initial range | risk if wrong |
| --- | --- | --- |
| `gui` (template line) | `>= 9.2 << 9.3` | the rows don't appear |
| `api` (`Nodes.pm`) | `>= 9.2 << 9.3` | a Perl load failure; guarded by the load test and restore |

`/etc/pve-cloudinit-extras.conf` `FORCE=1` overrides the gate for testing a new version.

**What exists** (read from the installed API):
- `cicustom` (`meta|network|user|vendor=<volid>`) is set via `PUT /nodes/{node}/qemu/{vmid}/config`
  with `VM.Config.Cloudinit` or `VM.Config.Network`. The referenced snippet's storage permissions are not checked.
- Listing snippets: `GET /nodes/{node}/storage/{storage}/content?content=snippets`.
- **Writing snippets: impossible.** `upload` and `download-url` accept only `import | iso | vztmpl`.
- qemu-server reads snippets with a 1 MiB cap each and 3 MiB in total, and requires `vtype eq 'snippets'`.

**Endpoint**, `PVE::API2::CloudinitExtras` (`proxyto => 'node'`, `protected => 1`, so it runs in pvedaemon on the VM's node):

| method | path | params | permissions |
| --- | --- | --- | --- |
| GET | `/nodes/{node}/cloudinit-extras` | – | any authenticated (feature probe → `{version}`) |
| GET | `…/vendor/{vmid}` | `storage` | `VM.Audit` → `{commands[], include:{type,url\|volid}, volid}` (no inlined content returned) |
| PUT | `…/vendor/{vmid}` | `storage`, `commands?`, `include-url?` \| `include-snippet?` | `VM.Config.Cloudinit` on `/vms/{vmid}` **and** `Datastore.AllocateSpace` on `/storage/{storage}`; plus `Datastore.Audit` on the source storage when inlining a snippet → `{vendor: <volid or ''>}` for the GUI to put in `cicustom` |
| DELETE | `…/vendor/{vmid}` | `storage` | same as PUT; removes only a file carrying `X-Managed-By` |

Rules:
- `{vmid}` must exist on this node.
- The storage must be enabled, have `content snippets`, and be path-based.
- The file name is fixed and derives only from the integer vmid, so there is no traversal. The path comes from `PVE::Storage::path`.
- `include-url` must match `^https?://[\x21-\x7e]{1,2040}$`.
- `include-snippet` must parse as a `snippets` volid.
- An existing file without our header is never overwritten.
- Writes are atomic (`file_set_contents`).
- The endpoint writes only the file. The VM config is changed by the GUI through the stock API.

**CLI** (`pve-cloudinit-extras vendor <vmid> --storage … [--commands-file f] [--include-url u | --include-snippet v]`):
root-only, uses the same generator, prints the resulting `vendor=` value. It is the fallback if the user
chooses "no new endpoint" (open question 1).

## 7. Cluster behaviour

- **Install on every node.** Each node serves its own GUI, and the endpoint runs on the VM's node.
  Nodes still on the old version fall back as described in §3.
- **Shared snippet storage** (e.g. CephFS): the file is visible everywhere, and migration and HA work.
- **Node-local snippet storage:** the file exists only where it was written, so VM start fails after migration.
  The GUI defaults to shared storages and warns if a local one is chosen.
- `cicustom` itself lives in pmxcfs and is cluster-wide.

## 8. Uninstall guarantees

- `prerm remove|upgrade|deconfigure`: delete the marker lines. The upgrade case is included because the new postinst re-applies.
- **Proof of stock:** afterwards, compare both files to `/var/lib/dpkg/info/pve-manager.md5sums`
  (equivalent to `dpkg --verify pve-manager`). If they don't match → restore the file from the matching `.deb`
  (`apt-get download pve-manager=<installed>`, `dpkg-deb --fsys-tarfile | tar -xO <path>`).
  If the download fails, print `apt install --reinstall pve-manager`, and never fail the removal.
  Then `reload-or-restart pvedaemon pveproxy`.
- `purge` removes `/var/lib/pve-cloudinit-extras` and `/etc/pve-cloudinit-extras.conf`.
- **Generated `cix-*-vendor.yaml` files and `cicustom` values are never touched.** Guests do not change
  when the package is removed; qemu-server keeps reading the files. The README documents how to find them.

## 9. Build and test

- Build: `dpkg-buildpackage -us -uc -b` in `debian:trixie`, Arch `all`.
  Lint: `lintian`, `eslint`, `perl -c` against a PVE 9.2 perl tree.
  Unit tests for `Vendor.pm`: every row of the §2 table, hostile input (`\n`, `\r`, `": x`, `\u0000`,
  a boundary string inside a command, 1 MiB overflow); parse the output back with Python `email` + `yaml.safe_load`.
- **Never test on the production nodes.** Use a throwaway nested PVE 9.2 VM with a `dir` storage with snippets enabled, and a
  Debian 13 genericcloud template.
- Test matrix, each step asserting `dpkg --verify pve-manager` output and GUI load:
  1. install → both markers present, rows visible, stock rows unchanged;
  2. `apt install --reinstall pve-manager` → both triggers re-apply;
  3. pve-manager 9.1 ↔ 9.2 → re-applies, or stays stock per the gate;
  4. broken anchor / out-of-range version → stock GUI, API unpatched, reason logged;
  5. `apt remove` → `dpkg --verify` clean, no markers, JS 404, `…/cloudinit-extras` 404; then `purge`;
  6. API permission matrix with a non-root user, and a foreign file at the fixed path → refused;
  7. **must-test in a guest:**
     - commands only, URL only, snippet only, both;
     - `runcmd` executes, and the generated user/keys are still applied;
     - an included cloud-config that has its own `runcmd` → both run (`merge_how` append);
     - `cicustom user=` with its own `runcmd` → confirm ours is replaced, as documented;
     - check with `cloud-init query vendordata` and `/var/log/cloud-init.log`.
- JS fast loop: a local static harness serving ExtJS, `proxmoxlib.js` and `pvemanagerlib.js` copied from the
  test VM, with mocked `/api2/extjs/...`.

## 10. Risks and open questions

Risks:
- **Changes do not re-run cloud-init on existing VMs** (§1).
- Include and Commands are safe only with `citype nocloud`. `configdrive2` puts vendor data in
  `vendor_data.json`, which is parsed differently. The GUI warns for other types.
- A full snippet storage blocks writes and VM starts.
- A snippet Include combined with Commands is an inlined **copy**. Later edits to that snippet are not seen until the file is saved again.
- Patching `Nodes.pm` can break the API. This is guarded by the strict gate, the load test and the restore.
- Upstream may add its own `cicustom` field. The runtime guard then turns ours off.

Open questions for the user:
1. **Commands and URL include from the GUI through the endpoint** (the recommendation: one new endpoint and a `Nodes.pm` patch),
   or **both CLI-only** (no new endpoint; the GUI keeps only Custom files and the direct snippet Include)?
2. Also add a **`bootcmd` toggle** ("run on every boot") to Commands? `bootcmd` runs early, before networking, on every boot.
3. Which storage should hold snippets? Enable `snippets` on an existing storage, or a small dedicated one?
4. Version policy for the GUI line: strict minor allowlist, or "anchor present"? (`Nodes.pm` stays strict.)
5. Permission for writing the vendor file: `Datastore.AllocateSpace` (proposed) or `Datastore.AllocateTemplate`, as `upload` uses?
6. Where to build and test: which host or storage for the throwaway nested PVE VM?
