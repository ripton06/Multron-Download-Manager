(() => {
  const modes = ['system', 'light', 'dark', 'multron'];
  const mode = (value) => modes.includes(value) ? value : 'multron';
  const defaults = Object.freeze({ themeMode: 'multron', uiTheme: 'system' });
  const resolve = (settings, systemLight) => {
    const selected = mode(settings.themeMode);
    const theme = selected === 'multron' ? settings.uiTheme : selected;
    return theme === 'light' || (theme !== 'dark' && systemLight) ? 'light' : 'dark';
  };
  const bind = (storage, system, apply) => {
    let state = { ...defaults };
    const touched = new Set();
    const render = (values) => {
      state = { ...state, ...values };
      apply(resolve(state, system.matches), mode(state.themeMode));
    };
    const update = (values) => {
      Object.keys(values).forEach((key) => touched.add(key));
      render(values);
    };
    storage.local.get(defaults).then((values) => render(Object.fromEntries(Object.entries(values).filter(([key]) => !touched.has(key))))).catch(() => render({}));
    storage.onChanged.addListener((changes, area) => {
      if (area !== 'local' || (!changes.uiTheme && !changes.themeMode)) return;
      const values = {};
      if (changes.uiTheme) values.uiTheme = changes.uiTheme.newValue;
      if (changes.themeMode) values.themeMode = changes.themeMode.newValue;
      update(values);
    });
    system.addEventListener('change', () => render({}));
    return Object.freeze({
      setMode: (value) => {
        const themeMode = mode(value);
        update({ themeMode });
        return storage.local.set({ themeMode }).catch(() => storage.local.get(defaults).then(render));
      }
    });
  };
  globalThis.MultronTheme = Object.freeze({
    defaults, mode, resolve, bind
  });
})();
