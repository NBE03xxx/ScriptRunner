const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const staticDirectory = path.join(__dirname, '..', 'app', 'static');

test('ヘルプを開いて閉じるとボタンへフォーカスが戻る', () => {
    const elements = Object.fromEntries(['help-modal', 'help-btn', 'help-close-btn'].map(id => [id, {
        style: { display: 'none' },
        focused: false,
        focus() { this.focused = true; },
    }]));
    const context = vm.createContext({
        document: {
            addEventListener() {},
            getElementById: id => elements[id],
        },
    });
    const source = fs.readFileSync(path.join(staticDirectory, 'app.js'), 'utf8');
    vm.runInContext(source, context);
    vm.runInContext('openHelp()', context);
    assert.equal(elements['help-modal'].style.display, 'block');
    assert.equal(elements['help-close-btn'].focused, true);
    vm.runInContext('closeHelp()', context);
    assert.equal(elements['help-modal'].style.display, 'none');
    assert.equal(elements['help-btn'].focused, true);
});

test('画面にヘルプ操作とアプリ情報がある', () => {
    const html = fs.readFileSync(path.join(staticDirectory, 'index.html'), 'utf8');
    assert.match(html, /id="help-btn"/);
    assert.match(html, /id="help-modal"[^>]*role="dialog"/);
    assert.match(html, /このアプリについて/);
});
