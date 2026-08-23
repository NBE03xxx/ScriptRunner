/* ============================================
   Script Runner — Client-side Logic
   ============================================ */

const API_BASE = "/api";
let allScripts = [];
let currentEditingScript = "";
let isCreatingScript = false;
let hostStatus = {};  // ホスト → "online"|"offline"
let pendingDeleteName = "";
let apiToken = "";    // localStorage から取得したトークン

// ---- 認証ヘルパー ----
function getToken() {
    return localStorage.getItem('api-token') || '';
}

function setToken(token) {
    apiToken = token;
    if (token) {
        localStorage.setItem('api-token', token);
    } else {
        localStorage.removeItem('api-token');
    }
}

// API 共通ヘッダー（トークンが設定されている場合に付与）
function getAuthHeaders(extra = {}) {
    const headers = {...extra};
    if (apiToken) {
        headers['X-Secret-Token'] = apiToken;
    }
    return headers;
}

// 認証付き fetch。401 ならトークン入力モーダルを表示して Reject。
async function authFetch(url, options = {}) {
    const merged = {
        ...options,
        headers: getAuthHeaders(options.headers || {})
    };
    const res = await fetch(url, merged);
    if (res.status === 401) {
        showTokenModal();
        throw new Error('認証が必要です');
    }
    return res;
}

// ---- テーマ切替 ----
function toggleTheme() {
    const el = document.documentElement;
    const newTheme = el.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
    el.setAttribute('data-theme', newTheme);
    localStorage.setItem('pref-theme', newTheme);
}

function initTheme() {
    const saved = localStorage.getItem('pref-theme');
    if (saved) {
        document.documentElement.setAttribute('data-theme', saved);
    }
}

// ---- ユーティリティ ----
let _statusTimer = null;
function showStatus(text, type) {
    // ヘッダー右端の常設スロットにのみ表示（スクロールしても視認可能）
    const headerEl = document.getElementById('startup-message');
    if (!headerEl) return;
    headerEl.textContent = text;
    headerEl.className = type;
    headerEl.style.display = 'block';
    // 前回のタイマーをクリアして 4 秒の自動消滅を 1 本に統合（連打で早期消滅するのを防ぐ）
    if (_statusTimer) clearTimeout(_statusTimer);
    _statusTimer = setTimeout(() => {
        headerEl.style.display = 'none';
        _statusTimer = null;
    }, 4000);
}

// Natural sort key: split filename into segments, numbers as integers.
function naturalKey(name) {
    const parts = name.split('.');
    const key = [];
    for (const part of parts) {
        const subparts = part.split(/(\d+)/);
        for (const sp of subparts) {
            if (sp === '') continue;
            key.push(/^\d+$/.test(sp) ? parseInt(sp, 10) : sp.toLowerCase());
        }
    }
    return key;
}

// Cached sort-key map: reuses keys across sort operations within one render cycle.
const _sortCache = new Map();

function getCachedKey(name) {
    let k = _sortCache.get(name);
    if (k === undefined) {
        k = naturalKey(name);
        _sortCache.set(name, k);
    }
    return k;
}

// Compare two natural sort keys.
function compareNatural(a, b) {
    const ka = getCachedKey(a), kb = getCachedKey(b);
    for (let i = 0; i < Math.max(ka.length, kb.length); i++) {
        const av = ka[i], bv = kb[i];
        if (av === undefined) return -1;
        if (bv === undefined) return 1;
        if (av < bv) return -1;
        if (av > bv) return 1;
    }
    return 0;
}

// ---- トークンモーダル ----
function showTokenModal() {
    document.getElementById('token-modal').style.display = 'block';
    const input = document.getElementById('token-input');
    input.value = '';
    document.getElementById('token-error').style.display = 'none';
    input.focus();
}

function hideTokenModal() {
    document.getElementById('token-modal').style.display = 'none';
}

async function submitToken() {
    const token = document.getElementById('token-input').value.trim();
    if (!token) return;

    // トークン検証：scripts API にテストリクエストを送る
    try {
        const res = await fetch(`${API_BASE}/scripts`, {
            headers: {'X-Secret-Token': token}
        });
        if (res.ok) {
            setToken(token);
            hideTokenModal();
            showStatus('認証に成功しました', 'success');
            fetchScripts();
            fetchPings();
        } else if (res.status === 401) {
            const errData = await res.json().catch(() => ({detail: '認証に失敗しました'}));
            const errEl = document.getElementById('token-error');
            errEl.textContent = errData.detail || 'トークンが正しくありません。もう一度確認してください。';
            errEl.style.display = 'block';
        } else {
            const errEl = document.getElementById('token-error');
            errEl.textContent = 'トークンが正しくありません。もう一度確認してください。';
            errEl.style.display = 'block';
        }
    } catch (e) {
        const errEl = document.getElementById('token-error');
        errEl.textContent = '接続に失敗しました。サーバーを確認してください。';
        errEl.style.display = 'block';
    }
}

// ---- スクリプト一覧 ----
async function fetchScripts() {
    try {
        const res = await authFetch(`${API_BASE}/scripts`);
        if (!res.ok) throw new Error('Fetch failed');
        allScripts = await res.json();
        updateTagFilter();
        handleSortChange();
    } catch (e) { showStatus(e.message, 'error'); }
}

function updateTagFilter() {
    const select = document.getElementById('tag-filter');
    const selected = select.value;
    const tags = [...new Set(allScripts.flatMap(s => s.tags || []))]
        .sort((a, b) => a.localeCompare(b, 'ja'));
    select.replaceChildren(new Option('すべて', ''));
    tags.forEach(tag => select.add(new Option(tag, tag)));
    select.value = tags.includes(selected) ? selected : '';
}

function handleSortChange() {
    _sortCache.clear();
    const mode = document.getElementById('sort-select').value;
    const selectedTag = document.getElementById('tag-filter').value;
    let sorted = allScripts.filter(s => !selectedTag || (s.tags || []).includes(selectedTag));
    if (mode === 'name_asc') sorted.sort((a, b) => compareNatural(a.name, b.name));
    else if (mode === 'name_desc') sorted.sort((a, b) => compareNatural(b.name, a.name));
    else if (mode === 'mtime_desc') sorted.sort((a, b) => (b.mtime || 0) - (a.mtime || 0));
    else if (mode === 'mtime_asc') sorted.sort((a, b) => (a.mtime || 0) - (b.mtime || 0));
    else if (mode === 'group_asc') sorted.sort((a, b) => compareGroups(a, b, 1));
    else if (mode === 'group_desc') sorted.sort((a, b) => compareGroups(a, b, -1));
    render(sorted);
}

function compareGroups(a, b, direction) {
    const ag = a.group || '';
    const bg = b.group || '';
    if (!ag && bg) return 1;
    if (ag && !bg) return -1;
    const groupOrder = ag.localeCompare(bg, 'ja', {numeric: true, sensitivity: 'base'});
    if (groupOrder !== 0) return groupOrder * direction;
    return compareNatural(a.name, b.name);
}

// ---- ホスト死活チェック ----
async function fetchPings() {
    try {
        const res = await authFetch('/api/ping');
        if (!res.ok) return;
        const data = await res.json();
        hostStatus = {};
        for (const [k, v] of Object.entries(data)) {
            if (k === '_ts' || k === 'results') continue;
            hostStatus[k] = v;
        }
        updateBadges();
    } catch { /* ignore */ }
}

function updateBadges() {
    document.querySelectorAll('.status-badge').forEach((el) => {
        const host = el.dataset?.host || '';
        if (!host) return;
        const status = hostStatus[host] || 'unknown';
        if (status === 'online') el.textContent = '\u25cf オンライン';
        else if (status === 'offline') el.textContent = '\u25cb オフライン';
        else el.textContent = '\u2014 不明';
        el.className = 'status-badge ' + status;
    });
}

// ---- レンダリング ----
function render(scripts) {
    const listElement = document.getElementById('script-list');
    listElement.innerHTML = '';
    if (scripts.length === 0) {
        listElement.innerHTML = '<li style="text-align:center;color:var(--ink-light);padding:40px 0;">スクリプトが見つかりません</li>';
        return;
    }
    scripts.forEach(s => {
        const li = document.createElement('li');
        li.className = 'script-item';

        const wrapper = document.createElement('div');
        wrapper.className = 'info-actions-wrapper';

        // 情報エリア
        const infoDiv = document.createElement('div');
        infoDiv.className = 'script-info';

        const nameSpan = document.createElement('span');
        nameSpan.className = 'script-name';
        nameSpan.textContent = s.name;
        nameSpan.title = s.name;

        const hostSpan = document.createElement('span');
        hostSpan.className = 'script-host';
        hostSpan.textContent = `Host: ${s.host || 'N/A'}`;
        hostSpan.title = hostSpan.textContent;

        const groupSpan = document.createElement('span');
        groupSpan.className = 'script-metadata';
        groupSpan.textContent = `Group: ${s.group || '—'}`;
        groupSpan.title = groupSpan.textContent;

        const tagsSpan = document.createElement('span');
        tagsSpan.className = 'script-metadata';
        tagsSpan.textContent = `Tags: ${(s.tags || []).join(', ') || '—'}`;
        tagsSpan.title = tagsSpan.textContent;

        infoDiv.appendChild(nameSpan);
        infoDiv.appendChild(hostSpan);
        infoDiv.appendChild(groupSpan);
        infoDiv.appendChild(tagsSpan);

        // アクションエリア
        const actionsArea = document.createElement('div');
        actionsArea.className = 'actions-area';

        const statusBadge = document.createElement('span');
        statusBadge.className = 'status-badge';
        statusBadge.textContent = '\u2014';
        statusBadge.dataset.host = s.host || '';

        const runBtn = document.createElement('button');
        runBtn.className = 'btn-run';
        runBtn.setAttribute('aria-label', `${s.name} を実行`);
        if (!s.executable) {
            runBtn.disabled = true;
            runBtn.setAttribute('aria-label', `${s.name} は実行を許可されていません`);
            runBtn.title = '実行は許可されていません';
        } else {
            runBtn.onclick = () => runScript(s.name);
        }
        const runIcon = document.createElement('span');
        runIcon.className = 'action-icon';
        runIcon.setAttribute('aria-hidden', 'true');
        runIcon.textContent = s.executable ? '\u25b6' : '\ud83d\udd12';
        const runLabel = document.createElement('span');
        runLabel.className = 'action-label';
        runLabel.textContent = s.executable ? 'Run' : 'Run (locked)';
        runBtn.appendChild(runIcon);
        runBtn.appendChild(runLabel);

        const editBtn = document.createElement('button');
        editBtn.className = 'btn-edit';
        editBtn.setAttribute('aria-label', `${s.name} を編集`);
        editBtn.innerHTML = '<span class="action-icon" aria-hidden="true">\u270e</span><span class="action-label">Edit</span>';
        editBtn.onclick = () => openEdit(s.name);

        const delBtn = document.createElement('button');
        delBtn.className = 'btn-delete';
        delBtn.setAttribute('aria-label', `${s.name} を削除`);
        delBtn.innerHTML = '<span class="action-icon" aria-hidden="true">\ud83d\uddd1</span><span class="action-label">Delete</span>';
        delBtn.onclick = () => openDeleteConfirm(s.name);

        actionsArea.appendChild(statusBadge);
        [
            [runBtn, s.executable ? 'Run' : 'Run（実行不可）'],
            [editBtn, 'Edit'],
            [delBtn, 'Delete']
        ].forEach(([button, tooltip]) => {
            const actionControl = document.createElement('span');
            actionControl.className = 'action-control';
            actionControl.dataset.tooltip = tooltip;
            if (button.disabled) actionControl.tabIndex = 0;
            actionControl.appendChild(button);
            actionsArea.appendChild(actionControl);
        });

        wrapper.appendChild(infoDiv);
        wrapper.appendChild(actionsArea);
        li.appendChild(wrapper);
        listElement.appendChild(li);
    });

    // 死活確認が一覧取得より先に完了した場合も、保持済みの結果を反映する。
    updateBadges();
}

// ---- エディタ ----
function openCreate() {
    isCreatingScript = true;
    currentEditingScript = "";
    document.getElementById('editor-title').textContent = 'スクリプトの新規作成';
    document.getElementById('filename-group').hidden = false;
    document.getElementById('filename-input').value = '';
    document.getElementById('editor-error').textContent = '';
    document.getElementById('editor-content').value = '#!/bin/bash\n';
    document.getElementById('editor-modal').style.display = 'block';
    document.getElementById('filename-input').focus();
}

async function openEdit(name) {
    try {
        const res = await authFetch(`${API_BASE}/read/${encodeURIComponent(name)}`);
        if (!res.ok) throw new Error('Load failed');
        const data = await res.json();

        isCreatingScript = false;
        currentEditingScript = name;
        document.getElementById('editor-title').textContent = '編集: ' + name;
        document.getElementById('filename-group').hidden = true;
        document.getElementById('editor-error').textContent = '';
        document.getElementById('editor-content').value = data.content;
        document.getElementById('editor-modal').style.display = 'block';
    } catch (e) { showStatus(e.message, 'error'); }
}

async function saveScript() {
    const content = document.getElementById('editor-content').value;
    const filename = isCreatingScript
        ? document.getElementById('filename-input').value
        : currentEditingScript;
    const errorEl = document.getElementById('editor-error');
    errorEl.textContent = '';
    if (!filename) {
        errorEl.textContent = 'ファイル名を入力してください';
        document.getElementById('filename-input').focus();
        return;
    }
    if (isCreatingScript && (filename !== filename.trim() || !filename.endsWith('.sh'))) {
        errorEl.textContent = filename !== filename.trim()
            ? 'ファイル名の前後に空白は使用できません'
            : '拡張子 .sh のファイル名を入力してください';
        document.getElementById('filename-input').focus();
        return;
    }
    try {
        const action = isCreatingScript ? 'create' : 'save';
        const res = await authFetch(`${API_BASE}/${action}/${encodeURIComponent(filename)}`, {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({content})
        });
        if (!res.ok) {
            const data = await res.json().catch(() => ({}));
            throw new Error(data.detail || '保存に失敗しました');
        }
        showStatus(isCreatingScript ? `作成しました: ${filename}` : '保存しました！', 'success');
        closeEditor();
        fetchScripts();
    } catch (e) {
        if (isCreatingScript) errorEl.textContent = e.message;
        showStatus(e.message, 'error');
    }
}

function closeEditor() {
    document.getElementById('editor-modal').style.display = 'none';
    document.getElementById('filename-group').hidden = true;
    document.getElementById('filename-input').value = '';
    document.getElementById('editor-error').textContent = '';
    document.getElementById('editor-content').value = '';
    isCreatingScript = false;
    currentEditingScript = "";
}

// ---- スクリプト実行 ----
async function runScript(name) {
    try {
        const res = await authFetch(`${API_BASE}/execute/${encodeURIComponent(name)}`, {method: 'POST'});
        if (!res.ok) {
            const data = await res.json().catch(() => ({}));
            throw new Error(data.detail || 'Run failed');
        }
        const data = await res.json();
        showStatus(`ターミナルで実行: ${name}`, 'success');
    } catch (e) { showStatus(e.message, 'error'); }
}

// ---- 削除確認フロー ----
function openDeleteConfirm(name) {
    pendingDeleteName = name;
    document.getElementById('delete-target-name').textContent = name;
    document.getElementById('delete-modal').style.display = 'block';
}

function closeDeleteConfirm() {
    document.getElementById('delete-modal').style.display = 'none';
    pendingDeleteName = "";
}

async function confirmDelete() {
    const name = pendingDeleteName;
    closeDeleteConfirm();
    try {
        const res = await authFetch(`${API_BASE}/delete/${encodeURIComponent(name)}`, {method: 'DELETE'});
        if (!res.ok) throw new Error('Delete failed');
        showStatus(`削除しました: ${name}`, 'success');
        fetchScripts();
    } catch (e) { showStatus(e.message, 'error'); }
}

// ---- イベントバインディング（DOMContentLoaded 後） ----
document.addEventListener('DOMContentLoaded', () => {
    initTheme();

    apiToken = getToken();

    document.getElementById('theme-btn').addEventListener('click', toggleTheme);
    document.getElementById('create-btn').addEventListener('click', openCreate);
    document.getElementById('sort-select').addEventListener('change', handleSortChange);
    document.getElementById('tag-filter').addEventListener('change', handleSortChange);
    document.getElementById('save-btn').addEventListener('click', saveScript);
    document.getElementById('close-editor-btn').addEventListener('click', closeEditor);
    document.getElementById('delete-confirm-btn').addEventListener('click', confirmDelete);
    document.getElementById('delete-cancel-btn').addEventListener('click', closeDeleteConfirm);

    // トークンモーダル
    document.getElementById('token-submit-btn').addEventListener('click', submitToken);
    document.getElementById('token-input').addEventListener('keydown', (e) => {
        if (e.key === 'Enter') submitToken();
    });

    // モーダル外クリックで閉じる
    document.getElementById('editor-modal').addEventListener('click', (e) => {
        if (e.target.id === 'editor-modal') closeEditor();
    });
    document.getElementById('delete-modal').addEventListener('click', (e) => {
        if (e.target.id === 'delete-modal') closeDeleteConfirm();
    });

    // 認証状態を確認して初期化
    (async () => {
        try {
            const res = await fetch(`${API_BASE}/token-required`);
            const data = await res.json();

            if (!data.required) {
                // トークン不要 → 通常起動
                await fetchScripts();
                fetchPings();
                setInterval(fetchPings, 30_000);
                showStatus('Script Runner に接続しました', 'success');
                return;
            }

            if (apiToken) {
                // 保存済みトークンがある → 検証して利用
                const testRes = await fetch(`${API_BASE}/scripts`, {
                    headers: {'X-Secret-Token': apiToken}
                });
                if (testRes.ok) {
                    await fetchScripts();
                    fetchPings();
                    setInterval(fetchPings, 30_000);
                    showStatus('Script Runner に接続しました', 'success');
                    return;
                } else {
                    // トークンが無効 → 再入力
                    setToken('');
                }
            }

            // トークンなしまたは無効 → モーダル表示
            showTokenModal();
        } catch {
            // サーバー接続失敗は放置
        }
    })();
});
