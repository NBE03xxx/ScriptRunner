/* CSSを読み込む前にテーマを確定し、起動時のライト表示を防ぐ。 */
(() => {
    const root = document.documentElement;
    const systemDarkTheme = window.matchMedia('(prefers-color-scheme: dark)');
    let manualTheme = null;

    function savedTheme() {
        if (manualTheme !== null) return manualTheme;
        try {
            const value = localStorage.getItem('pref-theme');
            return value === 'light' || value === 'dark' ? value : null;
        } catch {
            return null;
        }
    }

    function applySystemTheme() {
        if (savedTheme() !== null) return;
        root.setAttribute('data-theme', systemDarkTheme.matches ? 'dark' : 'light');
    }

    root.setAttribute('data-theme', savedTheme() || (systemDarkTheme.matches ? 'dark' : 'light'));
    systemDarkTheme.addEventListener('change', applySystemTheme);

    window.ScriptRunnerTheme = {
        toggle() {
            const theme = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
            manualTheme = theme;
            root.setAttribute('data-theme', theme);
            try {
                localStorage.setItem('pref-theme', theme);
            } catch {
                // 保存できない環境でも、この画面では手動切替を維持する。
            }
        },
    };
})();
