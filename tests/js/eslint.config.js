import js from '@eslint/js';
import globals from 'globals';

export default [
    js.configs.recommended,
    {
        files: ['**/*.js'],
        languageOptions: {
            ecmaVersion: 2022,
            sourceType: 'script',
            globals: { ...globals.browser, Ext: 'readonly', PVE: 'readonly', Proxmox: 'readonly', gettext: 'readonly' },
        },
        rules: {
            'no-control-regex': 'off', // the validators match control characters on purpose
            eqeqeq: 'error',
            'no-var': 'error',
            'prefer-const': 'error',
        },
    },
];
