// STUB. See PLAN.md §3. Must be inert (console.warn only) if any guard fails.
(function () {
    try {
        if (!Ext.ClassManager.get('PVE.qemu.CloudInit') || !Ext.ClassManager.get('Proxmox.grid.ObjectGrid')) {
            console.warn('pve-cloudinit-extras: Cloud-Init panel not found, disabled');
            return;
        }
        const RUNCMD_HELP = gettext(
            'One command per line (cloud-init runcmd). Runs once, at first boot of a new instance; '
            + 'changes do not affect an already initialised VM until "cloud-init clean".',
        );
        Ext.define('PVE.CloudinitExtras.CloudInitOverride', {
            override: 'PVE.qemu.CloudInit',
            // Consumed by Proxmox.grid.ObjectGrid.initComponent after me.rows is built.
            gridRows: [
                { xtype: 'cixcustom', name: 'cicustom' },
                { xtype: 'cixcommands', name: 'cix_commands' }, // virtual, derived from cicustom.vendor
                { xtype: 'cixinclude', name: 'cix_include' }, // virtual, derived from cicustom.vendor
            ],
            add_cixcustom_row: function (name, text, opts) {
                // TODO: me.rows.cicustom = { header: 'Custom files', iconCls: 'fa fa-file-code-o', renderer,
                //       editor: user/network/meta storage+file selectors; vendor read-only when managed;
                //       warn under user=: replaces generated user-data, and its runcmd overrides Commands }
            },
            add_cixcommands_row: function (name, text, opts) {
                // TODO: me.rows.cix_commands = { header: 'Commands', iconCls: 'fa fa-terminal', never_delete: true,
                //       defaultValue: '', renderer: first line + "(N more)",
                //       editor: monospace textareafield (help RUNCMD_HELP) + storage selector.
                //       Submit: PUT /nodes/{node}/cloudinit-extras/vendor/{vmid} {storage, commands, include-*},
                //       then stock PUT /config with cicustom vendor=<result> merged with user/network/meta }
                void RUNCMD_HELP;
            },
            add_cixinclude_row: function (name, text, opts) {
                // TODO: me.rows.cix_include = { header: 'Include', iconCls: 'fa fa-plus-square', never_delete: true,
                //       editor: radiogroup None / Snippet / URL; same two-step submit as Commands }
            },
        });
    } catch (e) {
        console.warn('pve-cloudinit-extras: disabled', e);
    }
})();
