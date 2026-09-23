// pve-cloudinit-extras: "Custom files", "Commands", "Boot commands" and "Include" rows for the
// VM Cloud-Init panel. Loaded after pvemanagerlib.js; does nothing but console.warn unless every
// guard holds, so an incompatible pve-manager only loses these rows. Design: PLAN.md §3.
// No 'use strict': ExtJS callParent() relies on Function.caller.
(function () {
    const TAG = 'pve-cloudinit-extras';
    const disable = (why) => console.warn(`${TAG}: disabled: ${why}`);

    try {
        if (typeof Ext === 'undefined' || typeof PVE === 'undefined' || typeof Proxmox === 'undefined') {
            return disable('ExtJS/PVE not loaded');
        }
        const CI = Ext.ClassManager.get('PVE.qemu.CloudInit');
        const OG = Ext.ClassManager.get('Proxmox.grid.ObjectGrid');
        if (!CI || !OG) {
            return disable('Cloud-Init panel not found');
        }
        // The rows are added through ObjectGrid's gridRows loop, which runs after the panel has
        // built me.rows and before the store is created.
        if (!String(OG.prototype.initComponent).includes('gridRows')) {
            return disable('ObjectGrid has no gridRows hook');
        }
        if ((CI.prototype.gridRows || []).length) {
            return disable('Cloud-Init panel already uses gridRows');
        }
        if (String(CI.prototype.initComponent).includes('cicustom')) {
            return disable('the stock Cloud-Init panel edits cicustom itself');
        }
        for (const cls of ['PVE.form.StorageSelector', 'PVE.form.FileSelector', 'Proxmox.window.Edit']) {
            if (!Ext.ClassManager.get(cls)) {
                return disable(`${cls} not found`);
            }
        }

        const SLOTS = ['user', 'network', 'meta'];
        const GENERATED_RE = /^([a-z][a-z0-9\-_.]*[a-z0-9]):snippets\/cix-(\d+)-vendor\.yaml$/i;
        const enc = (s) => Ext.String.htmlEncode(s);
        const mono = (s) => `<span style="font-family: monospace">${enc(s)}</span>`;

        const TEXT = {
            runcmd: gettext(
                'One command per line (cloud-init runcmd). Runs once per instance, at the end of' +
                    ' the first boot. Changing it does not affect a VM that has already booted, until' +
                    ' "cloud-init clean" is run in the guest.',
            ),
            bootcmd: gettext(
                'One command per line (cloud-init bootcmd). Runs on every boot, early, before most' +
                    ' of cloud-init; do not rely on the network. Changes apply from the next VM start.',
            ),
            include: gettext(
                'One more cloud-init file, applied as vendor data under the generated user data. A' +
                    ' URL is fetched by the guest at boot, never by the host. Like Commands, it takes' +
                    ' effect on first boot.',
            ),
            userWarn: gettext(
                'A custom user file replaces the generated user, password and SSH keys; a runcmd or' +
                    ' bootcmd in it overrides Commands / Boot commands.',
            ),
            noApi: gettext('pve-cloudinit-extras API not active on this node'),
            nocloud: gettext('Commands and Include need Cloud-Init type "nocloud".'),
            local: gettext(
                'This storage is not shared: the VM fails to start on another node until the file is copied.',
            ),
        };

        const parseCicustom = function (value) {
            const res = {};
            for (const kv of (value || '').split(',')) {
                const i = kv.indexOf('=');
                if (i > 0) {
                    res[kv.slice(0, i).trim()] = kv.slice(i + 1).trim();
                }
            }
            return res;
        };
        const printCicustom = (o) =>
            [...SLOTS, 'vendor']
                .filter((k) => o[k])
                .map((k) => `${k}=${o[k]}`)
                .join(',');

        // Effective (pending if any) value of a config key, from the unfiltered store.
        const currentValue = function (panel, key) {
            const rec = panel.rstore.getById(key);
            if (!rec) {
                return '';
            }
            const d = rec.data;
            if (d.pending !== undefined && d.pending !== '') {
                return String(d.pending);
            }
            return d.delete ? '' : String(d.value ?? '');
        };

        const request = (opts) =>
            new Promise((resolve, reject) =>
                Proxmox.Utils.API2Request(
                    Ext.apply(
                        {
                            success: (response) => resolve(response.result.data),
                            failure: (response) => reject(response.htmlStatus || response.statusText),
                        },
                        opts,
                    ),
                ),
            );

        const apiBase = (panel) => `/nodes/${panel.pveSelNode.data.node}/cloudinit-extras`;

        const emptyData = () => ({ bootcmd: '', runcmd: '', url: '', snippet: '', storage: '' });

        // Keeps panel.cix.data in sync with cicustom.vendor; called on every store load.
        const sync = function (panel) {
            const cix = panel.cix;
            if (cix.api === undefined) {
                cix.api = null; // probing
                request({ url: apiBase(panel), method: 'GET' })
                    .then(() => (cix.api = true))
                    .catch(() => (cix.api = false))
                    .finally(() => sync(panel));
                return;
            }
            if (cix.api === null) {
                return;
            }
            const vendor = parseCicustom(currentValue(panel, 'cicustom')).vendor || '';
            if (vendor === cix.vendor) {
                return;
            }
            cix.vendor = vendor;
            const m = vendor.match(GENERATED_RE);
            if (!m || m[2] !== String(panel.pveSelNode.data.vmid) || !cix.api) {
                cix.data = Ext.apply(emptyData(), { snippet: vendor });
                cix.error = null;
                panel.getView().refresh();
                return;
            }
            cix.loading = true;
            request({
                url: `${apiBase(panel)}/vendor/${panel.pveSelNode.data.vmid}`,
                method: 'GET',
                params: { storage: m[1] },
            })
                .then((d) => {
                    cix.data = {
                        bootcmd: d.bootcmd || '',
                        runcmd: d.runcmd || '',
                        url: d['include-url'] || '',
                        snippet: d['include-snippet'] || '',
                        storage: m[1],
                    };
                    cix.error = null;
                })
                .catch((err) => {
                    cix.data = emptyData();
                    cix.error = err;
                    cix.vendor = undefined; // retry on next load
                })
                .finally(() => {
                    cix.loading = false;
                    if (!panel.isDestroyed) {
                        panel.getView().refresh();
                    }
                });
        };

        // Write the generated snippet, then point cicustom vendor= at it via the stock config API.
        const save = async function (panel, data, storage) {
            const vmid = panel.pveSelNode.data.vmid;
            const params = { storage };
            for (const k of ['bootcmd', 'runcmd']) {
                if (data[k].trim()) {
                    params[k] = data[k];
                }
            }
            if (data.url) {
                params['include-url'] = data.url;
            } else if (data.snippet) {
                params['include-snippet'] = data.snippet;
            }
            const res = await request({ url: `${apiBase(panel)}/vendor/${vmid}`, method: 'PUT', params });

            const parts = parseCicustom(currentValue(panel, 'cicustom'));
            const oldStorage = panel.cix.data.storage;
            if ((parts.vendor || '') !== res.vendor) {
                parts.vendor = res.vendor;
                const value = printCicustom(parts);
                await request({
                    url: `${panel.baseurl}/config`,
                    method: 'PUT',
                    params: value ? { cicustom: value } : { delete: 'cicustom' },
                });
            }
            if (oldStorage && oldStorage !== storage) {
                // best effort: drop our file on the previous storage
                await request({
                    url: `${apiBase(panel)}/vendor/${vmid}`,
                    method: 'PUT',
                    params: { storage: oldStorage },
                }).catch(() => {});
            }
            panel.cix.vendor = undefined;
        };

        const storageField = (panel, name, value) => ({
            xtype: 'pveStorageSelector',
            name,
            fieldLabel: gettext('Store file on'),
            storageContent: 'snippets',
            nodename: panel.pveSelNode.data.node,
            autoSelect: false,
            value: value || undefined,
            listeners: {
                afterrender: function (field) {
                    // Prefer a shared storage, so the VM can start on any node.
                    field.getStore().on('load', (store) => {
                        if (!field.getValue()) {
                            const recs = store.getRange();
                            const pick = recs.find((r) => r.data.shared) || recs[0];
                            if (pick) {
                                field.setValue(pick.data.storage);
                                field.resetOriginalValue();
                            }
                        }
                        field.fireEvent('change', field, field.getValue());
                    });
                },
                change: function (field, value) {
                    const rec = value && field.getStore().getById(value);
                    const warn = field.up('window')?.down('#cixLocalWarn');
                    if (warn) {
                        warn.setHidden(!rec || !!rec.data.shared);
                    }
                },
            },
        });

        const snippetFields = (panel, prefix, volid) => {
            const storage = volid ? volid.split(':')[0] : undefined;
            return [
                {
                        xtype: 'pveStorageSelector',
                        name: `${prefix}_storage`,
                        storageContent: 'snippets',
                        nodename: panel.pveSelNode.data.node,
                        fieldLabel: gettext('Storage'),
                        allowBlank: true,
                        autoSelect: false,
                        value: storage,
                        listeners: {
                            change: function (field, value) {
                                const file = field.up('window')?.down(`field[name=${prefix}_file]`);
                                if (!file) {
                                    return;
                                }
                                if (value) {
                                    file.setStorage(value);
                                } else {
                                    file.setValue('');
                                }
                                file.setDisabled(!value);
                            },
                        },
                },
                {
                        xtype: 'pveFileSelector',
                        name: `${prefix}_file`,
                        storageContent: 'snippets',
                        nodename: panel.pveSelNode.data.node,
                        storage,
                        fieldLabel: gettext('File'),
                        allowBlank: true,
                        disabled: !storage,
                        value: volid || undefined,
                        filter: (rec) => !GENERATED_RE.test(rec.data.volid),
                },
            ];
        };

        Ext.define('PVE.CloudinitExtras.CustomEdit', {
            extend: 'Proxmox.window.Edit',
            alias: 'widget.cixCustomEdit',
            subject: gettext('Custom files'),
            width: 560,

            initComponent: function () {
                const me = this;
                const panel = me.cixPanel;
                const cur = parseCicustom(currentValue(panel, 'cicustom'));
                const items = [];
                for (const slot of SLOTS) {
                    items.push({ xtype: 'displayfield', value: `<b>${slot}</b>` });
                    items.push(...snippetFields(panel, slot, cur[slot]));
                    if (slot === 'user') {
                        items.push({ xtype: 'displayfield', userCls: 'pmx-hint', value: TEXT.userWarn });
                    }
                }
                if (cur.vendor) {
                    items.push({
                        xtype: 'displayfield',
                        fieldLabel: 'vendor',
                        value: `${mono(cur.vendor)} (${gettext('set by Commands / Include')})`,
                    });
                }
                me.items = [
                    {
                        xtype: 'inputpanel',
                        items,
                        onGetValues: function (values) {
                            const parts = { vendor: cur.vendor };
                            for (const slot of SLOTS) {
                                if (values[`${slot}_storage`] && values[`${slot}_file`]) {
                                    parts[slot] = values[`${slot}_file`];
                                }
                            }
                            const value = printCicustom(parts);
                            return value ? { cicustom: value } : { delete: 'cicustom' };
                        },
                    },
                ];
                me.callParent();
            },
        });

        // Editor for one of the generated-snippet fields: runcmd, bootcmd or include.
        Ext.define('PVE.CloudinitExtras.VendorEdit', {
            extend: 'Proxmox.window.Edit',
            alias: 'widget.cixVendorEdit',
            width: 640,

            load: Ext.emptyFn, // values come from the panel state, not from /config

            initComponent: function () {
                const me = this;
                const panel = me.cixPanel;
                const data = panel.cix.data;
                const items = [];
                if (panel.cix.api !== true || panel.cix.loading || panel.cix.error) {
                    me.cixBlocked = true;
                    me.items = [{ xtype: 'displayfield', value: enc(panel.cix.api === false ? TEXT.noApi : panel.cix.error || '...') }];
                    me.callParent();
                    return;
                }
                if (me.cixField === 'include') {
                    const mode = data.url ? 'url' : data.snippet ? 'snippet' : 'none';
                    items.push(
                        {
                            xtype: 'radiogroup',
                            fieldLabel: gettext('Include'),
                            columns: 3,
                            items: [
                                { boxLabel: Proxmox.Utils.noneText, name: 'cix_mode', inputValue: 'none', checked: mode === 'none' },
                                { boxLabel: gettext('Snippet'), name: 'cix_mode', inputValue: 'snippet', checked: mode === 'snippet' },
                                { boxLabel: 'URL', name: 'cix_mode', inputValue: 'url', checked: mode === 'url' },
                            ],
                            listeners: {
                                change: (group, value) => me.cixMode(value.cix_mode),
                            },
                        },
                        ...snippetFields(panel, 'cix_snippet', data.snippet),
                        {
                            xtype: 'textfield',
                            name: 'cix_url',
                            fieldLabel: 'URL',
                            value: data.url,
                            emptyText: 'https://example.com/cloud-config.yaml',
                            maxLength: 2048,
                            regex: /^https?:\/\/[^/?#\s@]+([/?#][\x21-\x7e]*)?$/i,
                            regexText: gettext('http(s) URL without spaces or user info'),
                        },
                    );
                } else {
                    items.push({
                        xtype: 'textarea',
                        name: 'cix_text',
                        fieldLabel: me.subject,
                        value: data[me.cixField],
                        height: 220,
                        fieldStyle: 'font-family: monospace; white-space: pre',
                        emptyText: me.cixField === 'bootcmd' ? 'echo "$(date) boot" >> /var/log/boots.log' : 'apt-get install -y htop',
                        validator: (v) => !/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(v) || gettext('Control characters are not allowed'),
                    });
                }
                items.push({ xtype: 'displayfield', userCls: 'pmx-hint', value: TEXT[me.cixField] });
                if (parseCicustom(currentValue(panel, 'cicustom')).user && me.cixField !== 'include') {
                    items.push({ xtype: 'displayfield', userCls: 'pmx-hint', value: TEXT.userWarn });
                }
                const citype = currentValue(panel, 'citype');
                if (citype && citype !== 'nocloud') {
                    items.push({ xtype: 'displayfield', userCls: 'pmx-hint', value: TEXT.nocloud });
                }
                items.push(storageField(panel, 'cix_storage', data.storage));
                items.push({ xtype: 'displayfield', itemId: 'cixLocalWarn', userCls: 'pmx-hint', hidden: true, value: TEXT.local });
                me.items = items;
                me.callParent();
                if (me.cixField === 'include') {
                    me.cixMode(data.url ? 'url' : data.snippet ? 'snippet' : 'none');
                }
            },

            cixMode: function (mode) {
                const me = this;
                const snip = mode === 'snippet';
                me.down('field[name=cix_snippet_storage]').setHidden(!snip).setDisabled(!snip);
                const file = me.down('field[name=cix_snippet_file]');
                file.setHidden(!snip);
                file.setDisabled(!snip || !me.down('field[name=cix_snippet_storage]').getValue());
                file.allowBlank = !snip;
                const url = me.down('field[name=cix_url]');
                url.setHidden(mode !== 'url').setDisabled(mode !== 'url');
                url.allowBlank = mode !== 'url';
                me.formPanel.getForm().checkValidity();
            },

            submit: function () {
                const me = this;
                if (me.cixBlocked) {
                    return;
                }
                const panel = me.cixPanel;
                const v = me.formPanel.getForm().getValues();
                const data = Ext.apply({}, panel.cix.data);
                if (me.cixField === 'include') {
                    data.url = v.cix_mode === 'url' ? v.cix_url.trim() : '';
                    data.snippet = v.cix_mode === 'snippet' ? v.cix_snippet_file || '' : '';
                } else {
                    data[me.cixField] = v.cix_text;
                }
                me.setLoading(true);
                save(panel, data, v.cix_storage)
                    .then(() => me.close())
                    .catch((err) => Ext.Msg.alert(gettext('Error'), err))
                    .finally(() => !me.isDestroyed && me.setLoading(false));
            },
        });

        // The store's reader got its own copy of me.rows before gridRows ran and only reads keys
        // listed there, so our keys must be registered with it as well.
        const registerWithReader = function (panel, keys) {
            const reader = panel.rstore.getProxy().getReader();
            if (reader.rows && reader.rows !== panel.rows) {
                for (const k of keys) {
                    reader.rows[k] = panel.rows[k];
                }
            }
        };

        Ext.define('PVE.CloudinitExtras.CloudInit', {
            override: 'PVE.qemu.CloudInit',

            gridRows: [
                { xtype: 'cixcustom', name: 'cicustom' },
                { xtype: 'cixvendor', name: 'cix_runcmd', field: 'runcmd' },
                { xtype: 'cixvendor', name: 'cix_bootcmd', field: 'bootcmd' },
                { xtype: 'cixvendor', name: 'cix_include', field: 'include' },
            ],

            add_cixcustom_row: function (name) {
                const me = this;
                if (me.rows[name]) {
                    return; // upstream defines it
                }
                me.cix = { data: emptyData() };
                me.mon(me.rstore, 'load', () => sync(me));
                me.rows.citype = { visible: false };
                const caps = Ext.state.Manager.get('GuiCap');
                const canEdit = caps.vms['VM.Config.Cloudinit'] || caps.vms['VM.Config.Network'];
                me.rows[name] = {
                    header: gettext('Custom files'),
                    iconCls: 'fa fa-file-code-o',
                    never_delete: true, // vendor= belongs to the other rows; clear in the editor
                    defaultValue: '',
                    editor: canEdit ? { xtype: 'cixCustomEdit', cixPanel: me } : undefined,
                    renderer: function (value) {
                        const parts = parseCicustom(value);
                        const shown = SLOTS.filter((k) => parts[k]).map((k) => `${k}=${parts[k]}`);
                        return shown.length ? mono(shown.join(', ')) : Proxmox.Utils.noneText;
                    },
                };
                registerWithReader(me, [name, 'citype']);
            },

            add_cixvendor_row: function (name, text, opts) {
                const me = this;
                if (!me.cix) {
                    return;
                }
                const field = opts.field;
                const caps = Ext.state.Manager.get('GuiCap');
                const header = {
                    runcmd: gettext('Commands'),
                    bootcmd: gettext('Boot commands'),
                    include: gettext('Include'),
                }[field];
                me.rows[name] = {
                    header,
                    iconCls: { runcmd: 'fa fa-terminal', bootcmd: 'fa fa-power-off', include: 'fa fa-plus-square' }[field],
                    never_delete: true,
                    defaultValue: '',
                    editor: caps.vms['VM.Config.Cloudinit']
                        ? { xtype: 'cixVendorEdit', cixPanel: me, cixField: field, subject: header }
                        : undefined,
                    renderer: function () {
                        const cix = me.cix;
                        if (cix.api === false) {
                            return enc(TEXT.noApi);
                        }
                        if (cix.error) {
                            return enc(`${gettext('Error')}: ${cix.error}`);
                        }
                        if (cix.api !== true || cix.loading) {
                            return '...';
                        }
                        const d = cix.data;
                        if (field === 'include') {
                            return d.url || d.snippet ? mono(d.url || d.snippet) : Proxmox.Utils.noneText;
                        }
                        const lines = d[field].split('\n').filter((l) => l.trim());
                        if (!lines.length) {
                            return Proxmox.Utils.noneText;
                        }
                        const more = lines.length > 3 ? `<br>(+${lines.length - 3} ${gettext('more')})` : '';
                        return lines.slice(0, 3).map(mono).join('<br>') + more;
                    },
                };
                registerWithReader(me, [name]);
            },
        });

    } catch (e) {
        console.warn(`${TAG}: disabled`, e);
    }
})();
