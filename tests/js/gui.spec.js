// Headless test of the Cloud-Init rows: real ExtJS, proxmoxlib.js and pvemanagerlib.js (from the
// Proxmox .debs, see fetch-libs.sh) plus our file, against a mocked /api2.
import { test, expect } from '@playwright/test';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, 'vendor', 'root');
const STATIC = {
    '/ext-all.js': `${root}/usr/share/javascript/extjs/ext-all.js`,
    '/charts.js': `${root}/usr/share/javascript/extjs/charts.js`,
    '/theme.css': `${root}/usr/share/javascript/extjs/theme-crisp/resources/theme-crisp-all.css`,
    '/proxmoxlib.js': `${root}/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js`,
    '/pvemanagerlib.js': `${root}/usr/share/pve-manager/js/pvemanagerlib.js`,
    '/pve-cloudinit-extras.js': path.join(here, '..', '..', 'src', 'js', 'pve-cloudinit-extras.js'),
};
const VMID = 100;
const GEN = (s) => `${s}:snippets/cix-${VMID}-vendor.yaml`;

// order: 'normal' | 'before-pvemanagerlib' | 'upstream-cicustom'
function harness(order) {
    const s = (src) => `<script src="${src}"></script>`;
    const upstream =
        order === 'upstream-cicustom'
            ? `<script>Ext.define(null, { override: 'PVE.qemu.CloudInit',
                 initComponent: function () { /* upstream now edits cicustom */ this.callParent(arguments); } });</script>`
            : '';
    return `<!DOCTYPE html><html><head>
<link rel="stylesheet" href="/theme.css">
<script>
function gettext(m) { return m; }
function ngettext(a, b, n) { return n === 1 ? a : b; }
function pgettext(c, m) { return m; }
Proxmox = { Setup: { auth_cookie_name: 'PVEAuthCookie' }, defaultLang: 'en', NodeName: 'node1',
    NodeArch: 'amd64', UserName: 'root@pam', CSRFPreventionToken: 'x', ConsentText: '' };
</script>
${s('/ext-all.js')}${s('/charts.js')}${s('/proxmoxlib.js')}
${order === 'before-pvemanagerlib' ? s('/pve-cloudinit-extras.js') + s('/pvemanagerlib.js') : s('/pvemanagerlib.js') + upstream + s('/pve-cloudinit-extras.js')}
<script>
Ext.onReady(function () {
    Ext.state.Manager.setProvider(Ext.create('Ext.state.Provider'));
    Ext.state.Manager.set('GuiCap', { vms: window.CAPS, storage: {}, nodes: {}, dc: {}, access: {}, sdn: {}, mapping: {} });
    window.panel = Ext.create('PVE.qemu.CloudInit', {
        pveSelNode: { data: { node: 'node1', vmid: ${VMID} } },
        renderTo: Ext.getBody(), width: 1000, height: 800,
    });
    window.panel.rstore.load();
});
</script></head><body></body></html>`;
}

// Mock PVE API. Records every write.
function mockApi(page, opts = {}) {
    const st = {
        config: { ide2: `local:vm-${VMID}-cloudinit,media=cdrom`, citype: 'nocloud', ...(opts.config || {}) },
        files: { ...(opts.files || {}) }, // storage -> {bootcmd, runcmd, include-url, include-snippet}
        writes: [],
        api: opts.api !== false,
    };
    const json = (route, data, extjs) =>
        route.fulfill({ contentType: 'application/json', body: JSON.stringify(extjs ? { success: 1, data } : { data }) });
    const params = (req) => {
        const u = new URL(req.url());
        const p = Object.fromEntries(u.searchParams);
        if (req.method() !== 'GET' && req.postData()) {
            Object.assign(p, Object.fromEntries(new URLSearchParams(req.postData())));
        }
        return p;
    };

    return page
        .route('http://pve.test/**', async (route) => {
            const req = route.request();
            const url = new URL(req.url());
            const p = url.pathname;
            const extjs = p.startsWith('/api2/extjs/');
            const api = p.replace(/^\/api2\/(json|extjs)/, '');
            const m = req.method();

            if (p === '/') {
                return route.fulfill({ contentType: 'text/html', body: harness(opts.order || 'normal') });
            }
            if (STATIC[p]) {
                return route.fulfill({ path: STATIC[p] });
            }
            if (/^\/theme-crisp-all_\d+\.css$/.test(p)) {
                return route.fulfill({ path: `${root}/usr/share/javascript/extjs/theme-crisp/resources${p}` });
            }
            if (api === `/nodes/node1/qemu/${VMID}/pending`) {
                return json(route, Object.entries(st.config).map(([key, value]) => ({ key, value })), extjs);
            }
            if (api === `/nodes/node1/qemu/${VMID}/config` && m === 'GET') {
                return json(route, { ...st.config, digest: 'd1' }, extjs);
            }
            if (api === `/nodes/node1/qemu/${VMID}/config` && m === 'PUT') {
                const q = params(req);
                st.writes.push({ api: 'config', ...q });
                if (q.delete) {
                    delete st.config[q.delete];
                }
                if (q.cicustom) {
                    st.config.cicustom = q.cicustom;
                }
                return json(route, null, extjs);
            }
            if (api === '/nodes/node1/storage') {
                return json(route, [
                    { storage: 'local', type: 'dir', shared: 0, content: 'snippets,iso', active: 1, total: 1e10, avail: 5e9 },
                    { storage: 'shared1', type: 'cephfs', shared: 1, content: 'snippets', active: 1, total: 1e10, avail: 5e9 },
                ], extjs);
            }
            const sc = api.match(/^\/nodes\/node1\/storage\/([^/]+)\/content$/);
            if (sc) {
                return json(route, [
                    { volid: `${sc[1]}:snippets/extra.yaml`, content: 'snippets', format: 'snippet', size: 100 },
                    { volid: `${sc[1]}:snippets/user.yaml`, content: 'snippets', format: 'snippet', size: 100 },
                    { volid: GEN(sc[1]), content: 'snippets', format: 'snippet', size: 100 },
                ], extjs);
            }
            if (api === '/nodes/node1/cloudinit-extras') {
                return st.api ? json(route, { version: '0.1.0' }, extjs) : route.fulfill({ status: 501, body: 'Not Implemented' });
            }
            if (api === `/nodes/node1/cloudinit-extras/vendor/${VMID}`) {
                const q = params(req);
                if (m === 'GET') {
                    return json(route, { volid: GEN(q.storage), exists: 1, bootcmd: '', runcmd: '', ...st.files[q.storage] }, extjs);
                }
                st.writes.push({ api: 'vendor', ...q });
                const any = q.bootcmd || q.runcmd || q['include-url'];
                if (any) {
                    st.files[q.storage] = q;
                } else {
                    delete st.files[q.storage];
                }
                return json(route, { vendor: any ? GEN(q.storage) : q['include-snippet'] || '' }, extjs);
            }
            return route.fulfill({ status: 404, body: `unmocked ${m} ${p}` });
        })
        .then(() => st);
}

async function open(page, opts = {}) {
    const errors = [];
    const warnings = [];
    page.on('pageerror', (e) => errors.push(e.stack));
    page.on('console', (msg) => msg.type() === 'warning' && warnings.push(msg.text()));
    if (process.env.CIX_DEBUG) {
        page.on('console', (msg) => console.log('console', msg.type(), msg.text()));
        page.on('pageerror', (e) => console.log('pageerror', e.stack));
        page.on('response', (r) => (r.url().includes('/api2/') || r.status() >= 400) && console.log('http', r.request().method(), r.url(), r.status()));
    }
    await page.addInitScript((caps) => (window.CAPS = caps), opts.caps || { 'VM.Config.Cloudinit': 1, 'VM.Config.Network': 1, 'VM.Audit': 1 });
    const st = await mockApi(page, opts);
    await page.goto('http://pve.test/');
    await page.waitForFunction(() => window.panel && window.panel.rstore.getCount() > 0);
    if (process.env.CIX_DEBUG) {
        await page.waitForTimeout(2000);
        console.log('state', await page.evaluate(() => JSON.stringify({ cix: window.panel.cix, rows: document.querySelectorAll('.x-grid-row').length, h: window.panel.getHeight() })));
    }
    return { st, errors, warnings };
}

const row = (page, header) => page.locator('.x-grid-row', { hasText: header }).first();
const openEditor = async (page, header) => {
    await row(page, header).dblclick();
    return page.locator('.x-window').last();
};
const setMode = (page, mode) =>
    page.evaluate((m) => Ext.ComponentQuery.query('cixVendorEdit radiogroup')[0].setValue({ cix_mode: m }), mode);
const clickOk = (win) => win.getByRole('button', { name: 'OK' }).click();

test('rows render next to the stock rows, values from the generated file', async ({ page }) => {
    const { errors } = await open(page, {
        config: { cicustom: `user=local:snippets/user.yaml,vendor=${GEN('shared1')}` },
        files: { shared1: { runcmd: 'echo one\necho two', bootcmd: 'date >> /b', 'include-url': 'https://example.com/x.yaml' } },
    });
    for (const h of ['User', 'SSH public key', 'Custom files', 'Commands', 'Boot commands', 'Include']) {
        await expect(row(page, h)).toBeVisible();
    }
    await expect(row(page, 'Custom files')).toContainText('user=local:snippets/user.yaml');
    await expect(row(page, 'Custom files')).not.toContainText('vendor=');
    await expect(row(page, 'Commands')).toContainText('echo one');
    await expect(row(page, 'Commands')).toContainText('echo two');
    await expect(row(page, 'Boot commands')).toContainText('date >> /b');
    await expect(row(page, 'Include')).toContainText('https://example.com/x.yaml');
    await page.screenshot({ path: 'test-results/rows.png' });
    expect(errors).toEqual([]);
});

test('command text is HTML-escaped in the grid', async ({ page }) => {
    await open(page, {
        config: { cicustom: `vendor=${GEN('shared1')}` },
        files: { shared1: { runcmd: '<img src=x onerror="window.pwned=1">' } },
    });
    await expect(row(page, 'Commands')).toContainText('<img src=x');
    expect(await page.evaluate(() => window.pwned)).toBeUndefined();
    await expect(page.locator('.x-grid-row img')).toHaveCount(0);
});

test('Boot commands on a fresh VM: writes the snippet on a shared storage, then sets cicustom', async ({ page }) => {
    const { st, errors } = await open(page);
    await expect(row(page, 'Boot commands')).toContainText('none');
    const win = await openEditor(page, 'Boot commands');
    await expect(win).toContainText('Runs on every boot');
    await expect(win.locator('input[name=cix_storage]')).toHaveValue('shared1'); // shared preferred
    await win.locator('textarea[name=cix_text]').fill('echo "$(date)" >> /var/log/boots\n\n  \necho second');
    await clickOk(win);
    await expect(win).toBeHidden();
    expect(st.writes[0]).toMatchObject({ api: 'vendor', storage: 'shared1', bootcmd: 'echo "$(date)" >> /var/log/boots\n\n  \necho second' });
    expect(st.writes[0].runcmd).toBeUndefined();
    expect(st.writes[1]).toEqual({ api: 'config', cicustom: `vendor=${GEN('shared1')}` });
    await expect(row(page, 'Boot commands')).toContainText('echo second');
    expect(errors).toEqual([]);
});

test('Commands edit keeps the other generated fields and the other cicustom parts', async ({ page }) => {
    const { st } = await open(page, {
        config: { cicustom: `network=local:snippets/net.yaml,vendor=${GEN('shared1')}` },
        files: { shared1: { runcmd: 'old', bootcmd: 'keep boot', 'include-url': 'https://example.com/x.yaml' } },
    });
    await expect(row(page, 'Commands')).toContainText('old');
    const win = await openEditor(page, 'Commands');
    await expect(win).toContainText('Runs once per instance');
    await win.locator('textarea[name=cix_text]').fill('new command');
    await clickOk(win);
    await expect(win).toBeHidden();
    expect(st.writes).toEqual([
        { api: 'vendor', storage: 'shared1', runcmd: 'new command', bootcmd: 'keep boot', 'include-url': 'https://example.com/x.yaml' },
    ]); // vendor= unchanged, so no config write
});

test('Include: URL validation, then switching to a snippet alone references it directly', async ({ page }) => {
    const { st } = await open(page);
    let win = await openEditor(page, 'Include');
    await setMode(page, 'url');
    const url = win.locator('input[name=cix_url]');
    await url.fill('file:///etc/shadow');
    await expect(win.getByRole('button', { name: 'OK' })).toBeDisabled();
    await url.fill('https://example.com/extra.yaml');
    await clickOk(win);
    await expect(win).toBeHidden();
    expect(st.writes[0]).toMatchObject({ api: 'vendor', storage: 'shared1', 'include-url': 'https://example.com/extra.yaml' });
    expect(st.config.cicustom).toBe(`vendor=${GEN('shared1')}`);
    await expect(row(page, 'Include')).toContainText('https://example.com/extra.yaml');

    win = await openEditor(page, 'Include');
    await setMode(page, 'snippet');
    await page.evaluate(() => {
        const w = Ext.ComponentQuery.query('cixVendorEdit')[0];
        w.down('field[name=cix_snippet_storage]').setValue('local');
        w.down('field[name=cix_snippet_file]').setValue('local:snippets/extra.yaml');
    });
    await clickOk(win);
    await expect(win).toBeHidden();
    expect(st.writes.at(-2)).toEqual({ api: 'vendor', storage: 'shared1', 'include-snippet': 'local:snippets/extra.yaml' });
    expect(st.writes.at(-1)).toEqual({ api: 'config', cicustom: 'vendor=local:snippets/extra.yaml' });
    await expect(row(page, 'Include')).toContainText('local:snippets/extra.yaml');
});

test('Custom files editor sets user/network/meta and preserves vendor=', async ({ page }) => {
    const { st } = await open(page, {
        config: { cicustom: `vendor=${GEN('shared1')}` },
        files: { shared1: { runcmd: 'x' } },
    });
    const win = await openEditor(page, 'Custom files');
    await expect(win).toContainText('replaces the generated user');
    await page.evaluate(() => {
        const w = Ext.ComponentQuery.query('cixCustomEdit')[0];
        w.down('field[name=user_storage]').setValue('local');
        w.down('field[name=user_file]').setValue('local:snippets/user.yaml');
    });
    await clickOk(win);
    await expect(win).toBeHidden();
    expect(st.writes.at(-1)).toMatchObject({ api: 'config', cicustom: `user=local:snippets/user.yaml,vendor=${GEN('shared1')}` });
});

test('without the API on the node the vendor rows say so and do not write', async ({ page }) => {
    const { st } = await open(page, { api: false });
    await expect(row(page, 'Commands')).toContainText('API not active');
    const win = await openEditor(page, 'Commands');
    await expect(win).toContainText('API not active');
    await expect(win.locator('textarea')).toHaveCount(0);
    expect(st.writes).toEqual([]);
});

test('read-only user gets no editors', async ({ page }) => {
    await open(page, { caps: { 'VM.Audit': 1 } });
    await expect(row(page, 'Commands')).toBeVisible();
    await row(page, 'Commands').dblclick();
    await expect(page.locator('.x-window')).toHaveCount(0);
});

for (const order of ['before-pvemanagerlib', 'upstream-cicustom']) {
    test(`inert when a guard fails (${order}): stock panel unchanged`, async ({ page }) => {
        const { errors, warnings } = await open(page, { order });
        await expect(row(page, 'User')).toBeVisible();
        await expect(row(page, 'SSH public key')).toBeVisible();
        await expect(page.locator('.x-grid-row', { hasText: 'Boot commands' })).toHaveCount(0);
        await expect(page.locator('.x-grid-row', { hasText: 'Custom files' })).toHaveCount(0);
        expect(errors).toEqual([]);
        expect(warnings.join('\n')).toContain('pve-cloudinit-extras: disabled');
    });
}
