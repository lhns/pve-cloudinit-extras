# pve-cloudinit-extras

Adds three rows to the Proxmox VE Cloud-Init tab (VM → Cloud-Init):

- **Custom files**: edit `cicustom` (`user` / `network` / `meta` snippets) instead of using `qm set --cicustom`.
- **Commands**: one command per line, run as cloud-init `runcmd` (once, at first boot of a new instance).
- **Include**: one more file, either an existing snippet or a URL.

Commands and Include go into cloud-init **vendor-data**, as one generated per-VM multipart
snippet (`snippets/cix-<vmid>-vendor.yaml`). The generated user, password, SSH keys and IP config
therefore stay in effect. A small API endpoint writes that snippet, because the stock API cannot
write snippets.

The package survives pve-manager upgrades via dpkg triggers, refuses unknown versions (GUI and
API stay stock), and restores the stock files exactly on removal. Generated snippets and
`cicustom` values stay in place on removal. To find them:
`grep -l cicustom /etc/pve/nodes/*/qemu-server/*.conf` and `ls <storage>/snippets/cix-*`.

**Status: planned, not built.** See [PLAN.md](PLAN.md). The `debian/` and `src/` files are stubs.

Install on every cluster node.
