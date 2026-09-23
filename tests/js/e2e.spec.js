// GUI checks against a real Proxmox VE (tests/e2e/run.sh). Skipped unless PVE_URL is set.
// E2E_MODE=edit: rows render, then Commands, Boot commands and Include are set through the GUI.
// E2E_MODE=rows: rows render. E2E_MODE=stock: our rows are absent and the stock panel works.
import { test, expect } from '@playwright/test';

const { PVE_URL, PVE_PASSWORD, E2E_MODE = 'rows', E2E_VMID = '100', E2E_INCLUDE_URL = '' } = process.env;
const SHOTS = process.env.E2E_SHOTS || 'test-results';

test.skip(!PVE_URL, 'PVE_URL not set');
test.setTimeout(240000);
test.use({ ignoreHTTPSErrors: true });

const RUNCMD = [
    'echo from-runcmd >> /var/tmp/cix-order',
    'touch /var/tmp/cix-runcmd',
    `echo 'key: value' "--cix.boundary-1--" '#cloud-config' > /var/tmp/cix-hostile`,
].join('\n');
const BOOTCMD = 'echo boot >> /var/tmp/cix-boots';

async function login(page, request) {
    const res = await request.post(`${PVE_URL}/api2/json/access/ticket`, {
        form: { username: 'root@pam', password: PVE_PASSWORD },
    });
    expect(res.ok()).toBeTruthy();
    const { ticket } = (await res.json()).data;
    const host = new URL(PVE_URL).hostname;
    await page.context().addCookies([{ name: 'PVEAuthCookie', value: ticket, domain: host, path: '/', secure: true }]);
}

async function openCloudInit(page) {
    await page.goto(`${PVE_URL}/`);
    await page.waitForFunction(() => window.Ext && Ext.ComponentQuery.query('pveResourceTree').length > 0);
    // the resource tree fills asynchronously: keep selecting until the VM config panel shows
    await page.waitForFunction(
        (vmid) => {
            Ext.ComponentQuery.query('pveResourceTree')[0].selectById(`qemu/${vmid}`);
            return Ext.ComponentQuery.query('*').some((c) => c.$className === 'PVE.qemu.Config');
        },
        E2E_VMID,
        { polling: 1000, timeout: 60000 },
    );
    await page.evaluate(() =>
        Ext.ComponentQuery.query('*').find((c) => c.$className === 'PVE.qemu.Config').selectById('cloudinit'),
    );
    await page.waitForFunction(() => {
        const p = Ext.ComponentQuery.query('pveCiPanel')[0];
        return p && p.rstore.getCount() > 0;
    });
    await page.waitForTimeout(1500); // probe + vendor GET
}

const panelRow = (page, header) => page.locator('.x-grid-row', { hasText: header }).first();

async function editText(page, header, text) {
    await panelRow(page, header).dblclick();
    const win = page.locator('.x-window').last();
    await win.locator('textarea[name=cix_text]').fill(text);
    await win.getByRole('button', { name: 'OK' }).click();
    await expect(win).toBeHidden({ timeout: 20000 });
}

test('Cloud-Init tab on a real PVE', async ({ page, request }) => {
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.stack));
    const warnings = [];
    page.on('console', (m) => m.type() === 'warning' && warnings.push(m.text()));
    await login(page, request);
    await openCloudInit(page);

    for (const h of ['User', 'SSH public key', 'Upgrade packages']) {
        await expect(panelRow(page, h)).toBeVisible();
    }

    if (E2E_MODE === 'stock') {
        await expect(page.locator('.x-grid-row', { hasText: 'Boot commands' })).toHaveCount(0);
        await expect(page.locator('.x-grid-row', { hasText: 'Custom files' })).toHaveCount(0);
        const js = await request.get(`${PVE_URL}/pve2/js/pve-cloudinit-extras.js`);
        expect(js.status()).toBe(404);
        await page.screenshot({ path: `${SHOTS}/e2e-stock.png` });
        expect(errors).toEqual([]);
        return;
    }

    for (const h of ['Custom files', 'Commands', 'Boot commands', 'Include']) {
        await expect(panelRow(page, h)).toBeVisible();
    }
    await expect(panelRow(page, 'Commands')).not.toContainText('not active');

    if (E2E_MODE === 'edit') {
        await editText(page, 'Boot commands', BOOTCMD);
        await editText(page, 'Commands', RUNCMD);

        await panelRow(page, 'Include').dblclick();
        const win = page.locator('.x-window').last();
        await page.evaluate(() => Ext.ComponentQuery.query('cixVendorEdit radiogroup')[0].setValue({ cix_mode: 'url' }));
        await win.locator('input[name=cix_url]').fill(E2E_INCLUDE_URL);
        await win.getByRole('button', { name: 'OK' }).click();
        await expect(win).toBeHidden({ timeout: 20000 });

        await page.waitForTimeout(4000); // store reload
        await expect(panelRow(page, 'Commands')).toContainText('from-runcmd');
        await expect(panelRow(page, 'Boot commands')).toContainText('cix-boots');
        await expect(panelRow(page, 'Include')).toContainText(E2E_INCLUDE_URL);
    }
    await page.screenshot({ path: `${SHOTS}/e2e-${E2E_MODE}.png` });
    expect(errors).toEqual([]);
    expect(warnings.filter((w) => w.includes('pve-cloudinit-extras'))).toEqual([]);
});
