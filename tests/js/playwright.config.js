export default {
    testDir: '.',
    testMatch: /.*\.spec\.js/,
    timeout: 60000,
    retries: 0,
    reporter: [['list']],
    use: { browserName: 'chromium', headless: true, viewport: { width: 1400, height: 900 }, screenshot: 'only-on-failure' },
};
