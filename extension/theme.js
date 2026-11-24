(() => {
  const modes = ['system', 'light', 'dark', 'multron'];
  const mode = (value) => modes.includes(value) ? value : 'multron';
  globalThis.MultronTheme = Object.freeze({
    defaults: Object.freeze({ themeMode: 'multron', uiTheme: 'system' }),
    mode,
    resolve: (settings, systemLight) => {
      const selected = mode(settings.themeMode);
      const theme = selected === 'multron' ? settings.uiTheme : selected;
      return theme === 'light' || (theme !== 'dark' && systemLight) ? 'light' : 'dark';
    }
  });
})();
