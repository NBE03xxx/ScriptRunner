const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const staticDirectory = path.join(__dirname, '..', 'app', 'static');
const themeSource = fs.readFileSync(path.join(staticDirectory, 'theme-init.js'), 'utf8');

function createThemeContext(systemDark, savedTheme = null) {
    const attributes = new Map();
    const storage = new Map();
    if (savedTheme !== null) storage.set('pref-theme', savedTheme);
    let systemThemeChanged;
    const mediaQuery = {
        matches: systemDark,
        addEventListener(event, listener) {
            assert.equal(event, 'change');
            systemThemeChanged = listener;
        },
    };
    const context = vm.createContext({
        window: { matchMedia: () => mediaQuery },
        document: {
            documentElement: {
                getAttribute: key => attributes.get(key),
                setAttribute: (key, value) => attributes.set(key, value),
            },
            addEventListener() {},
        },
        localStorage: {
            getItem: key => storage.get(key) ?? null,
            setItem: (key, value) => storage.set(key, value),
        },
    });
    vm.runInContext(themeSource, context);
    return {
        currentTheme: () => attributes.get('data-theme'),
        changeSystemTheme(dark) {
            mediaQuery.matches = dark;
            systemThemeChanged();
        },
        toggle: () => context.window.ScriptRunnerTheme.toggle(),
    };
}

test('テーマ初期化スクリプトをCSSより先に同期読み込みする', () => {
    const html = fs.readFileSync(path.join(staticDirectory, 'index.html'), 'utf8');
    const scriptPosition = html.indexOf('src="/static/theme-init.js');
    const cssPosition = html.indexOf('rel="stylesheet" href="/static/style.css');
    assert.ok(scriptPosition >= 0 && cssPosition > scriptPosition);
    assert.ok(!html.slice(scriptPosition, cssPosition).includes('defer'));
});

test('保存済み設定がなければシステムのダーク設定で起動する', () => {
    assert.equal(createThemeContext(true).currentTheme(), 'dark');
    assert.equal(createThemeContext(false).currentTheme(), 'light');
});

test('システムのテーマ変更に追従する', () => {
    const theme = createThemeContext(false);
    theme.changeSystemTheme(true);
    assert.equal(theme.currentTheme(), 'dark');
    theme.changeSystemTheme(false);
    assert.equal(theme.currentTheme(), 'light');
});

test('手動切替はシステム設定より優先する', () => {
    const theme = createThemeContext(true);
    theme.toggle();
    assert.equal(theme.currentTheme(), 'light');
    theme.changeSystemTheme(false);
    theme.changeSystemTheme(true);
    assert.equal(theme.currentTheme(), 'light');
    assert.equal(createThemeContext(true, 'light').currentTheme(), 'light');
});

test('不正な保存値は無視してシステム設定を使う', () => {
    assert.equal(createThemeContext(true, 'unknown').currentTheme(), 'dark');
});
