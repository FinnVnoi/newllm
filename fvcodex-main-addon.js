// OAIC usage main-process addon: registers IPC handlers used by preload.
;(()=>{
  try {
    const electron = require('electron');
    const { ipcMain, shell, app } = electron;
    const https = require('https');
    const http = require('http');
    const fs = require('fs');
    const path = require('path');
    const os = require('os');

    const DEFAULT_BASE = 'https://codex.finnvnoi.top';
    const DEFAULT_SHOP = 'https://finnvnoi.top/shop/quota.php';

    function readJson(p) {
      try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) { return null; }
    }

    function configPaths() {
      const out = [];
      const appData = process.env.APPDATA || (app && app.getPath ? app.getPath('appData') : '');
      if (appData) out.push(path.join(appData, 'oaic-usage', 'config.json'));
      out.push(path.join(os.homedir(), '.oaic-usage.json'));
      return out;
    }

    function readConfig() {
      for (const p of configPaths()) {
        const v = readJson(p);
        if (v && typeof v === 'object') return v;
      }
      return {};
    }

    function readCodexConfig() {
      const p = path.join(os.homedir(), '.codex', 'config.toml');
      try { return fs.readFileSync(p, 'utf8'); } catch (e) { return ''; }
    }

    function tomlString(src, key) {
      const re = new RegExp('^\\s*' + key + '\\s*=\\s*"([^"]*)"', 'm');
      const m = src.match(re);
      return m ? m[1] : '';
    }

    function resolveSettings() {
      const cfg = readConfig();
      const toml = readCodexConfig();
      let base = String(cfg.baseUrl || process.env.OAIC_USAGE_BASE_URL || '').trim();
      if (!base) {
        const codexBase = tomlString(toml, 'base_url');
        if (codexBase) {
          try { base = new URL(codexBase).origin; } catch (e) { /* ignore */ }
        }
      }
      if (!base) base = DEFAULT_BASE;
      base = base.replace(/\/+$/, '');
      let key = String(cfg.apiKey || '').trim();
      if (!key) {
        const envKey = tomlString(toml, 'env_key') || 'CODEX_API_KEY';
        key = String(process.env[envKey] || process.env.CODEX_API_KEY || '').trim();
      }
      const shop = String(cfg.shopUrl || DEFAULT_SHOP);
      return { base, key, shop };
    }

    function requestJson(urlStr, key) {
      return new Promise((resolve, reject) => {
        let u;
        try { u = new URL(urlStr); } catch (e) { return reject(e); }
        const transport = u.protocol === 'http:' ? http : https;
        const headers = { Accept: 'application/json' };
        if (key) headers.Authorization = 'Bearer ' + key;
        const req = transport.request({
          protocol: u.protocol, hostname: u.hostname, port: u.port || undefined,
          path: u.pathname + u.search, method: 'GET', headers, timeout: 15000
        }, (res) => {
          let data = '';
          res.setEncoding('utf8');
          res.on('data', (x) => { data += x; });
          res.on('end', () => {
            let value = null;
            try { value = data ? JSON.parse(data) : {}; } catch (e) { return reject(new Error('Invalid JSON from ' + urlStr)); }
            if (res.statusCode < 200 || res.statusCode >= 300) {
              const msg = (value && value.error && value.error.message) || (value && value.detail) || ('HTTP ' + res.statusCode);
              return reject(new Error(String(msg)));
            }
            resolve(value);
          });
        });
        req.on('timeout', () => req.destroy(new Error('Request timed out')));
        req.on('error', reject);
        req.end();
      });
    }

    ipcMain.handle('oaic:usage', async () => {
      const s = resolveSettings();
      if (!s.key) return { ok: false, error: 'CODEX_API_KEY is not set', baseUrl: s.base };
      try {
        const value = await requestJson(s.base + '/v1/usage', s.key);
        return { ok: true, baseUrl: s.base, value };
      } catch (e) {
        return { ok: false, error: String(e && e.message || e), baseUrl: s.base };
      }
    });

    ipcMain.handle('oaic:settings', async () => {
      const s = resolveSettings();
      return { baseUrl: s.base, hasKey: !!s.key, shopUrl: s.shop };
    });

    ipcMain.handle('oaic:open-shop', async () => {
      const s = resolveSettings();
      try { await shell.openExternal(s.shop); return true; } catch (e) { return false; }
    });

    console.log('[oaic-usage] main handlers registered');
  } catch (e) {
    try { console.error('[oaic-usage main addon]', e && e.stack || e); } catch (_) {}
  }
})();
