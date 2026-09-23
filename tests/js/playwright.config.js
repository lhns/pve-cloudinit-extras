export default {
    testDir: '.',
    testMatch: /.*\.spec\.js/,
    timeout: 60000,
    retries: 0,
    reporter: [['list']],
    use: { browserName: 'chromium', headless: true, viewport: { width: 1200, height: 900 } },
};
