import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { test } from 'node:test';
import { root } from './lib.mjs';

const source = (name) => fs.readFileSync(path.join(root, 'extension', name), 'utf8');

function browserView(script, stored, systemLight = true) {
  const attributes = new Map();
  const elements = new Map();
  const changes = [];
  const systemListeners = [];
  const media = { matches: systemLight, addEventListener: (_, listener) => systemListeners.push(listener) };
  const element = (id) => {
    if (!elements.has(id)) elements.set(id, { value: '', textContent: '', events: new Map(), addEventListener(name, callback) { this.events.set(name, callback); } });
    return elements.get(id);
  };
  const document = {
    documentElement: { setAttribute: (name, value) => attributes.set(name, value) },
    body: {}, readyState: 'loading',
    getElementById: element, querySelectorAll: () => [],
    addEventListener: () => {}
  };
  const chrome = {
    i18n: { getMessage: () => '' },
    storage: {
      local: {
        get: async (defaults) => ({ ...(typeof defaults === 'object' ? defaults : {}), ...stored }),
        set: async (values) => {
          const update = {};
          for (const [key, value] of Object.entries(values)) { update[key] = { oldValue: stored[key], newValue: value }; stored[key] = value; }
          changes.forEach((listener) => listener(update, 'local'));
        }
      },
      onChanged: { addListener: (listener) => changes.push(listener) }
    },
    runtime: { onMessage: { addListener: () => {} }, sendMessage: async () => null }
  };
  const context = vm.createContext({ document, chrome, location: { hostname: 'example.org', pathname: '/', search: '', hash: '' }, console, URL, setTimeout: () => 0, clearTimeout: () => {}, setInterval: () => 0, clearInterval: () => {}, MutationObserver: class { observe() {} disconnect() {} }, ResizeObserver: class { observe() {} unobserve() {} disconnect() {} } });
  context.window = context;
  context.top = context;
  context.matchMedia = () => media;
  context.addEventListener = () => {};
  vm.runInContext(source('theme.js'), context);
  vm.runInContext(source(script), context);
  return {
    attributes, elements,
    async update(values) { await chrome.storage.local.set(values); await Promise.resolve(); },
    system(light) { media.matches = light; systemListeners.forEach((listener) => listener({ matches: light })); }
  };
}

for (const [script, attribute] of [['popup.js', 'data-theme'], ['content.js', 'data-multron-theme']]) {
  test(`${script}: custom theme survives desktop updates and reopening`, async () => {
    const stored = { themeMode: 'dark', uiTheme: 'light' };
    const view = browserView(script, stored);
    await Promise.resolve();
    assert.equal(view.attributes.get(attribute), 'dark');
    await view.update({ uiTheme: 'light' });
    view.system(true);
    assert.equal(view.attributes.get(attribute), 'dark');
    const reopened = browserView(script, stored);
    await Promise.resolve();
    assert.equal(reopened.attributes.get(attribute), 'dark');
  });

  test(`${script}: system and follow-Multron update independently`, async () => {
    const view = browserView(script, { themeMode: 'system', uiTheme: 'dark' }, true);
    await Promise.resolve();
    assert.equal(view.attributes.get(attribute), 'light');
    view.system(false);
    assert.equal(view.attributes.get(attribute), 'dark');
    await view.update({ themeMode: 'multron', uiTheme: 'light' });
    assert.equal(view.attributes.get(attribute), 'light');
    view.system(false);
    assert.equal(view.attributes.get(attribute), 'light');
    await view.update({ uiTheme: 'dark' });
    assert.equal(view.attributes.get(attribute), 'dark');
  });

  test(`${script}: legacy preferences fall back to desktop or system`, async () => {
    const view = browserView(script, { uiTheme: 'light' }, false);
    await Promise.resolve();
    assert.equal(view.attributes.get(attribute), 'light');
    await view.update({ uiTheme: 'system' });
    assert.equal(view.attributes.get(attribute), 'dark');
    await view.update({ themeMode: 'invalid', uiTheme: 'light' });
    assert.equal(view.attributes.get(attribute), 'light');
  });
}

test('popup selector persists the preference separately from the desktop cache', async () => {
  const stored = { uiTheme: 'dark' };
  const view = browserView('popup.js', stored);
  await Promise.resolve();
  const selector = view.elements.get('themeMode');
  selector.value = 'light';
  selector.events.get('change')();
  await Promise.resolve();
  assert.equal(stored.themeMode, 'light');
  assert.equal(stored.uiTheme, 'dark');
  assert.equal(view.attributes.get('data-theme'), 'light');
});

test('both extension surfaces load the shared helper before their main script', () => {
  const manifest = JSON.parse(source('manifest.json'));
  for (const content of manifest.content_scripts) {
    assert.ok(content.js.indexOf('theme.js') < content.js.indexOf('content.js'));
  }
  const html = source('popup.html');
  assert.ok(html.indexOf('src="theme.js"') < html.indexOf('src="popup.js"'));
});

test('a slow initial storage reply cannot overwrite a new user choice', async () => {
  const context = vm.createContext({});
  vm.runInContext(source('theme.js'), context);
  let reply;
  let latest;
  const storage = { local: { get: () => new Promise((resolve) => { reply = resolve; }), set: async () => {} }, onChanged: { addListener: () => {} } };
  const binding = context.MultronTheme.bind(storage, { matches: false, addEventListener: () => {} }, (theme) => { latest = theme; });
  await binding.setMode('light');
  reply({ themeMode: 'dark', uiTheme: 'dark' });
  await Promise.resolve();
  assert.equal(latest, 'light');
});
