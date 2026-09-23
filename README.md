# pve-cloudinit-extras

Adds two rows to the Proxmox VE Cloud-Init tab (VM → Cloud-Init):

- **Custom files**: edit `cicustom` (`user` / `network` / `meta` snippets) instead of using `qm set --cicustom`.
- **Include**: add one more file on top of the generated config, either an existing snippet or a
  URL (an `#include` pointer file). It is passed as cloud-init vendor-data, so the generated
  user, password, SSH keys and IP config stay in effect.

The package survives pve-manager upgrades via a dpkg trigger, refuses unknown versions (the GUI
stays stock), and restores the stock files exactly on removal.

**Status: planned, not built.** See [PLAN.md](PLAN.md). The `debian/` and `src/` files are stubs.

Packages:

| package | contents |
| --- | --- |
| `pve-cloudinit-extras` | GUI only; no backend changes |
| `pve-cloudinit-extras-api` | optional; one endpoint that writes the URL-include snippet |

Install on every cluster node.
