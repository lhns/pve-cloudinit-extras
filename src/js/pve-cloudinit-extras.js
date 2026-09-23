// STUB. See PLAN.md §2. Must be inert (console.warn only) if any guard fails.
(function () {
    try {
        if (!Ext.ClassManager.get('PVE.qemu.CloudInit') || !Ext.ClassManager.get('Proxmox.grid.ObjectGrid')) {
            console.warn('pve-cloudinit-extras: Cloud-Init panel not found, disabled');
            return;
        }
        Ext.define('PVE.CloudinitExtras.CloudInitOverride', {
            override: 'PVE.qemu.CloudInit',
            // Consumed by Proxmox.grid.ObjectGrid.initComponent after me.rows is built.
            gridRows: [
                { xtype: 'cixcustom', name: 'cicustom' },
                { xtype: 'cixinclude', name: 'cix_include' }, // virtual row, derived from cicustom.vendor
            ],
            add_cixcustom_row: function (name, text, opts) {
                // TODO: me.rows.cicustom = { header, iconCls, renderer, editor: user/network/meta selectors }
            },
            add_cixinclude_row: function (name, text, opts) {
                // TODO: me.rows.cix_include = { never_delete: true, defaultValue: '', renderer from cicustom.vendor,
                //       editor: None / Snippet / URL (URL needs GET /nodes/{node}/cloudinit-extras) }
            },
        });
    } catch (e) {
        console.warn('pve-cloudinit-extras: disabled', e);
    }
})();
