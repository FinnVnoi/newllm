'use strict';
/* FVCodex patch core: builds a portable Codex desktop copy or patches the installed
   MSIX directly, patches the VS Code Codex extension, and shares the newllm
   endpoint/API-key configuration through %APPDATA%\oaic-usage\config.json. */

const fs = require('fs');
const path = require('path');
const os = require('os');
const cp = require('child_process');
const crypto = require('crypto');

const args = process.argv.slice(2);
function has(name) { return args.indexOf('--' + name) >= 0; }
function arg(name, def) {
  const pre = '--' + name + '=';
  const hit = args.find(function (a) { return a.indexOf(pre) === 0; });
  return hit ? hit.slice(pre.length) : (def === undefined ? '' : def);
}

const ROOT = path.resolve(arg('root', __dirname));
const MODE = String(arg('mode', 'portable')).toLowerCase();
const UNINSTALL = has('uninstall');
const RESTORE_ONLY = has('restore');
const DOCTOR = has('doctor');
const KEEP_CONFIG = has('keep-config');
const DELETE_CONFIG = has('delete-config');
const CONFIG_ONLY = has('config');
const ACCOUNT_CONFIG = has('account');
const CONFIG_MODE = String(arg('config-mode', ACCOUNT_CONFIG ? 'account' : 'custom-endpoint')).toLowerCase();
const PROFILE_MODE = String(arg('profile', has('isolated') ? 'isolated' : 'shared')).toLowerCase();
const ISOLATED_PROFILE = PROFILE_MODE === 'isolated';
const NO_VSCODE = has('no-vscode');
const NO_LAUNCH = has('no-launch');
const VSCODE_PATCH_ONLY = has('vscode-patch');
const VSCODE_RESTORE_ONLY = has('vscode-restore');
const PORTABLE_REMOVE_ONLY = has('portable-remove');
const DIRECT_RESTORE_ONLY = has('direct-restore');
const BACKUP_UNINSTALL = has('backup');
const BASE_ARG = String(arg('base-url', '') || '').trim();
const SHOP = String(arg('shop', 'https://finnvnoi.top/shop/quota.php'));
const API_KEY = String(arg('api-key', '') || '').trim();
const MODEL_ARG = String(arg('model', '') || '').trim();
const EFFORT_ARG = String(arg('effort', '') || '').trim();
const SHORTCUT_NAME = String(arg('shortcut', 'FVCodex'));
const SELECTION_ARG = String(arg('selection', '') || '').trim();
const CATALOG_NAME = 'legacy_direct_model_catalog.json';

const APP_DATA = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
const LOCAL_APP_DATA = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
const FV_HOME = path.join(LOCAL_APP_DATA, 'FVCodex');
const PROFILE_HOME = path.join(FV_HOME, 'profile');
const ISOLATED_CODEX_HOME = path.join(PROFILE_HOME, 'codex-home');
const ISOLATED_USER_DATA = path.join(PROFILE_HOME, 'user-data');
const STATE_DIR = path.join(APP_DATA, 'FVCodex');
const INSTALL_STATE = path.join(STATE_DIR, 'install-state.json');
const DIRECT_STATE = path.join(STATE_DIR, 'direct-state.json');
const BACKUP_DIR = path.join(STATE_DIR, 'backups');
const OAIC_CONFIG = ISOLATED_PROFILE
  ? path.join(PROFILE_HOME, 'oaic-usage', 'config.json')
  : path.join(APP_DATA, 'oaic-usage', 'config.json');
const EXE_NAME = 'ChatGPT.exe';

function log(s) { console.log(s); }
function ok(s) { console.log('[OK] ' + s); }
function info(s) { console.log('[..] ' + s); }
function warn(s) { console.log('[!!] ' + s); }

/* ---------------- ASAR ---------------- */
function asarRead(buf) {
  const jsonLen = buf.readUInt32LE(12);
  const dataStart = 8 + buf.readUInt32LE(4);
  return { jsonLen: jsonLen, dataStart: dataStart, obj: JSON.parse(buf.slice(16, 16 + jsonLen).toString('utf8')) };
}

function walkLeaves(node, prefix, cb) {
  if (!node) return;
  if (node.files) {
    const keys = Object.keys(node.files);
    for (let i = 0; i < keys.length; i++) walkLeaves(node.files[keys[i]], prefix + '/' + keys[i], cb);
    return;
  }
  cb(node, prefix);
}

function hashBlocks(content, bs) {
  const blocks = [];
  for (let i = 0; i < content.length; i += bs) {
    blocks.push(crypto.createHash('sha256').update(content.slice(i, Math.min(i + bs, content.length))).digest('hex'));
  }
  return blocks;
}

function asarNeedles(asarPath, patches) {
  const buf = fs.readFileSync(asarPath);
  const h = asarRead(buf);
  let changed = 0;
  walkLeaves(h.obj, '', function (entry, filePath) {
    if (typeof entry.size !== 'number' || entry.unpacked || !entry.integrity) return;
    for (let i = 0; i < patches.length; i++) {
      const p = patches[i];
      if (!p.path.test(filePath)) continue;
      const off = parseInt(entry.offset, 10);
      const start = h.dataStart + off;
      const content = buf.slice(start, start + entry.size);
      if (p.reapply && p.new && content.indexOf(p.new) >= 0) continue;
      const idx = content.indexOf(p.old);
      if (idx < 0) { warn('needle khong thay: ' + filePath + ' (' + p.desc + ')'); continue; }
      const rep = p.new + '\n'.repeat(Math.max(0, p.old.length - p.new.length));
      if (rep.length !== p.old.length) { warn('length mismatch: ' + filePath); continue; }
      buf.write(rep, start + idx, 'latin1');
      const bs = entry.integrity.blockSize || 4194304;
      const next = buf.slice(start, start + entry.size);
      entry.integrity.blocks = hashBlocks(next, bs);
      entry.integrity.hash = crypto.createHash('sha256').update(next).digest('hex');
      changed++;
      ok('patch ' + filePath + ' (' + p.desc + ')');
    }
  });
  if (changed) {
    const newJson = JSON.stringify(h.obj);
    if (Buffer.byteLength(newJson) !== h.jsonLen) {
      throw new Error('header length changed (' + h.jsonLen + ' -> ' + Buffer.byteLength(newJson) + ')');
    }
    buf.write(newJson, 16, 'utf8');
    fs.writeFileSync(asarPath, buf);
  }
  return changed;
}

function asarAppend(asarPath, addonBuf, target, marker) {
  const old = fs.readFileSync(asarPath);
  const h = asarRead(old);
  const payload = old.slice(h.dataStart);
  let entry = null;
  walkLeaves(h.obj, '', function (e, p) { if (p === target) entry = e; });
  if (!entry) throw new Error('khong thay entry ' + target);
  const oldOffset = parseInt(entry.offset, 10);
  const oldContent = payload.slice(oldOffset, oldOffset + entry.size);
  if (marker && oldContent.indexOf(marker) >= 0) { info('addon da co trong ' + target); return false; }
  const newContent = Buffer.concat([oldContent, Buffer.from('\n'), addonBuf]);
  const newPayload = Buffer.concat([payload, newContent]);
  const bs = (entry.integrity && entry.integrity.blockSize) || 4194304;
  entry.offset = String(payload.length);
  entry.size = newContent.length;
  entry.integrity = Object.assign({}, entry.integrity || {}, {
    algorithm: 'SHA256',
    hash: crypto.createHash('sha256').update(newContent).digest('hex'),
    blockSize: bs,
    blocks: hashBlocks(newContent, bs)
  });
  const newJson = JSON.stringify(h.obj);
  const jsonBytes = Buffer.byteLength(newJson);
  const pad = (4 - (jsonBytes % 4)) % 4;
  const payloadSize = 4 + jsonBytes + pad;
  const pickleSize = 4 + payloadSize;
  const header = Buffer.alloc(8 + pickleSize);
  header.writeUInt32LE(4, 0);
  header.writeUInt32LE(pickleSize, 4);
  header.writeUInt32LE(payloadSize, 8);
  header.writeUInt32LE(jsonBytes, 12);
  header.write(newJson, 16, 'utf8');
  for (let i = 0; i < pad; i++) header.write(' ', 16 + jsonBytes + i, 'latin1');
  fs.writeFileSync(asarPath, Buffer.concat([header, newPayload]));
  ok('chen addon vao ' + target + ' (+' + addonBuf.length + ' bytes)');
  return true;
}

function asarHeaderHash(asarPath) {
  const buf = fs.readFileSync(asarPath);
  const jsonLen = buf.readUInt32LE(12);
  return crypto.createHash('sha256').update(buf.slice(16, 16 + jsonLen)).digest('hex');
}

function patchExeHash(asarPath, exePath, originalHashHex) {
  const exe = fs.readFileSync(exePath);
  let idx = -1;
  if (originalHashHex) idx = exe.indexOf(Buffer.from(originalHashHex, 'ascii'));
  if (idx < 0) idx = exe.indexOf(Buffer.from(asarHeaderHash(asarPath), 'ascii'));
  if (idx < 0) throw new Error('khong tim thay header hash trong ' + EXE_NAME);
  const current = exe.slice(idx, idx + 64).toString('ascii');
  if (!/^[0-9a-f]{64}$/.test(current)) throw new Error('offset hash khong hop le: ' + idx);
  const want = asarHeaderHash(asarPath);
  if (current === want) { info('exe hash da dung'); return; }
  exe.write(want, idx, 'utf8');
  fs.writeFileSync(exePath, exe);
  ok('va hash nhung trong ' + EXE_NAME + ' @' + idx);
}

/* ---------------- App patches ---------------- */
const APP_PATCHES = [
  {
    path: /\/webview\/assets\/composer-content-.*\.js$/,
    old: 'V=i===`local`&&y||Qg(g,r)',
    new: 'V=!1',
    reapply: true,
    desc: 'chan Codex local'
  },
  {
    path: /\/webview\/assets\/app-initial-.*\.js$/,
    old: 'sendBlockReason:d?.block_reason??null,sendBlocked:d!=null',
    new: 'sendBlockReason:null,sendBlocked:!1',
    reapply: true,
    desc: 'state rate-limit'
  },
  {
    path: /\/webview\/assets\/app-primary-.*\.js$/,
    old: 'if(n.sendBlocked)return Ie(!1),!1;',
    new: 'if(!1)return Ie(!1),!1;',
    reapply: true,
    desc: 'guard submit'
  },
  {
    path: /\/webview\/assets\/codex-composer-adapter-.*\.js$/,
    old: 'let Ti=vt||Ur||Pn||on&&sn||Hn||Cr&&sr||Nr?.isLoading===!0||In||Gr,',
    new: 'let Ti=!1,',
    reapply: true,
    desc: 'submitDisabled OR-gate'
  }
];

function readAddon(name) {
  const p = path.join(ROOT, name);
  if (!fs.existsSync(p)) throw new Error('thieu addon: ' + p);
  return fs.readFileSync(p);
}

function patchApp(appDir) {
  const resDir = path.join(appDir, 'resources');
  const asarPath = path.join(resDir, 'app.asar');
  const exePath = findAppExe(appDir);
  if (!fs.existsSync(asarPath)) throw new Error('khong thay app.asar trong ' + appDir);
  if (!exePath) throw new Error('khong thay file exe cua app trong ' + appDir);

  const originalHash = asarHeaderHash(asarPath);
  const n = asarNeedles(asarPath, APP_PATCHES);
  if (n === 0) warn('khong patch duoc needle nao (app co the da doi version)');

  asarAppend(asarPath, readAddon('fvcodex-preload-addon.js'), '/.vite/build/preload.js', 'oaicBridge');
  asarAppend(asarPath, readAddon('fvcodex-main-addon.js'), '/.vite/build/early-bootstrap.js', 'oaic:usage');
  patchExeHash(asarPath, exePath, originalHash);
  return exePath;
}

/* ---------------- MSIX detection ---------------- */
function windowsAppsDirs() {
  const out = [];
  [process.env.ProgramFiles, process.env.ProgramW6432, 'C:\\Program Files'].forEach(function (p) {
    if (!p) return;
    const w = path.join(p, 'WindowsApps');
    if (fs.existsSync(w) && out.indexOf(w) < 0) out.push(w);
  });
  return out;
}

function appVersion(name) {
  const m = String(name).match(/Codex_(\d+(?:\.\d+)*)_/i);
  return m ? m[1].split('.').map(Number) : [0];
}

function compareVersion(a, b) {
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) {
    const x = a[i] || 0, y = b[i] || 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}

function findAppExe(appDir) {
  const direct = path.join(appDir, EXE_NAME);
  if (fs.existsSync(direct)) return direct;
  let names = [];
  try { names = fs.readdirSync(appDir); } catch (e) { return ''; }
  const cand = names.filter(function (n) { return /\.exe$/i.test(n) && /^(chatgpt|codex)\.exe$/i.test(n); }).map(function (n) {
    return path.join(appDir, n);
  }).filter(function (p) {
    try { return fs.statSync(p).isFile(); } catch (e) { return false; }
  });
  cand.sort(function (a, b) {
    try { return fs.statSync(b).size - fs.statSync(a).size; } catch (e) { return 0; }
  });
  return cand[0] || '';
}

function findMsixApp() {
  const ps = runPS("$p=Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1; " +
    "if(-not $p){$p=Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*Codex*' } | Sort-Object Version -Descending | Select-Object -First 1}; " +
    "if($p){$p.InstallLocation}");
  const loc = String(ps.out || '').trim();
  if (loc && fs.existsSync(path.join(loc, 'app')) && findAppExe(path.join(loc, 'app'))) return loc;

  const cands = [];
  windowsAppsDirs().forEach(function (root) {
    let names = [];
    try { names = fs.readdirSync(root); } catch (e) { return; }
    names.forEach(function (n) {
      if (!/Codex_\d/i.test(n)) return;
      const dir = path.join(root, n);
      const appDir = path.join(dir, 'app');
      if (!fs.existsSync(appDir) || !findAppExe(appDir)) return;
      let t = 0;
      try { t = fs.statSync(dir).mtimeMs; } catch (e) { t = 0; }
      cands.push({ dir: dir, ver: appVersion(n), t: t });
    });
  });
  if (!cands.length) return '';
  cands.sort(function (a, b) {
    const v = compareVersion(a.ver, b.ver);
    return v !== 0 ? v : a.t - b.t;
  });
  return cands[cands.length - 1].dir;
}

/* ---------------- Process helpers ---------------- */
function psEscape(s) { return String(s == null ? '' : s).replace(/'/g, "''"); }

function runPS(script) {
  const r = cp.spawnSync('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script], { encoding: 'utf8' });
  return { code: r.status, out: String(r.stdout || '').trim(), err: String(r.stderr || '').trim() };
}

function isAdmin() {
  const r = cp.spawnSync('net', ['session'], { stdio: 'ignore' });
  return r.status === 0;
}

function runningCodexPaths() {
  const r = runPS("Get-Process ChatGPT,Codex -ErrorAction SilentlyContinue | ForEach-Object { $_.Path }");
  return String(r.out || '').split(/\r?\n/).map(function (s) { return s.trim(); }).filter(Boolean);
}

function killProcessAt(prefix) {
  if (!prefix) return;
  // Kill matching processes, then wait until their file locks are released.
  const script =
    "for($i=0;$i -lt 60;$i++){" +
    "$p=Get-Process -Name ChatGPT,Codex -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith('" + psEscape(prefix) + "',[StringComparison]::OrdinalIgnoreCase) };" +
    "if(-not $p){break};" +
    "$p | Stop-Process -Force -ErrorAction SilentlyContinue;" +
    "Start-Sleep -Milliseconds 250" +
    "}";
  runPS(script);
}

function sleepMs(ms) {
  try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch (e) { /* ignore */ }
}

function rmrf(p, tries) {
  const n = tries || 12;
  for (let i = 0; i < n; i++) {
    if (!fs.existsSync(p)) return;
    try { fs.rmSync(p, { recursive: true, force: true }); return; }
    catch (e) {
      if (i === n - 1) throw e;
      sleepMs(500);
    }
  }
}

function robocopy(src, dst) {
  const r = cp.spawnSync('robocopy', [src, dst, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1'], { stdio: 'ignore' });
  if (r.status === null) throw new Error('khong chay duoc robocopy');
  if (r.status >= 8) throw new Error('robocopy loi ma ' + r.status);
}

/* ---------------- Shortcuts ---------------- */
function specialFolder(name) {
  const r = runPS("[Environment]::GetFolderPath('" + name + "')");
  return r.out || '';
}

function shortcutPaths() {
  const out = [];
  const desktop = specialFolder('Desktop');
  if (desktop) out.push(path.join(desktop, SHORTCUT_NAME + '.lnk'));
  const programs = specialFolder('Programs');
  if (programs) out.push(path.join(programs, SHORTCUT_NAME + '.lnk'));
  return out;
}

function makeShortcut(lnk, target, argString, workDir, icon) {
  const script = [
    "$s=(New-Object -ComObject WScript.Shell).CreateShortcut('" + psEscape(lnk) + "');",
    "$s.TargetPath='" + psEscape(target) + "';",
    "$s.Arguments='" + psEscape(argString || '') + "';",
    "$s.WorkingDirectory='" + psEscape(workDir || path.dirname(target)) + "';",
    "$s.IconLocation='" + psEscape(icon || target) + "';",
    "$s.Description='FVCodex';",
    '$s.Save();'
  ].join('');
  const r = runPS(script);
  if (r.code !== 0) warn('khong tao duoc shortcut ' + lnk + ': ' + (r.err || r.out));
  else ok('shortcut: ' + lnk);
}

function removeShortcuts() {
  shortcutPaths().forEach(function (p) {
    if (fs.existsSync(p)) { try { fs.unlinkSync(p); ok('xoa shortcut: ' + p); } catch (e) { warn('khong xoa duoc ' + p); } }
  });
  const publicDesktop = path.join(process.env.PUBLIC || 'C:\\Users\\Public', 'Desktop', SHORTCUT_NAME + '.lnk');
  if (fs.existsSync(publicDesktop)) { try { fs.unlinkSync(publicDesktop); } catch (e) { /* ignore */ } }
}

function codexAumid() {
  const script = "$p=Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Select-Object -First 1; " +
    "if(-not $p){$p=Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*Codex*' } | Select-Object -First 1}; " +
    "if($p){$a=Get-StartApps -ErrorAction SilentlyContinue | Where-Object { $_.AppID -like ($p.PackageFamilyName + '*') } | Select-Object -First 1; " +
    "if($a){$a.AppID}else{$p.PackageFamilyName + '!App'}}";
  return runPS(script).out;
}

function createPortableShortcut(exePath) {
  if (ISOLATED_PROFILE) {
    const launcher = path.join(PROFILE_HOME, 'launch-fvcodex.ps1');
    fs.mkdirSync(PROFILE_HOME, { recursive: true });
    function psQuote(value) {
      return "'" + String(value).replace(/'/g, "''") + "'";
    }
    const ps = [
      "$ErrorActionPreference = 'Stop'",
      '$env:CODEX_HOME = ' + psQuote(ISOLATED_CODEX_HOME),
      '$env:FVCODEX_OAIC_CONFIG = ' + psQuote(OAIC_CONFIG),
      '$env:FVCODEX_USER_DATA = ' + psQuote(ISOLATED_USER_DATA),
      '$env:CODEX_BASE_URL = ' + psQuote(resolveBase()),
      '$env:CODEX_MODEL = ' + psQuote(resolveModel()),
      '$env:CODEX_REASONING_EFFORT = ' + psQuote(resolveEffort()),
      '$cfg = Get-Content -LiteralPath ' + psQuote(OAIC_CONFIG) + ' -Raw | ConvertFrom-Json',
      '$env:CODEX_API_KEY = [string]$cfg.apiKey',
      'Start-Process -FilePath ' + psQuote(exePath) + ' -ArgumentList ' + psQuote('--user-data-dir=' + ISOLATED_USER_DATA) + ' -WorkingDirectory ' + psQuote(path.dirname(exePath))
    ].join('\r\n') + '\r\n';
    fs.writeFileSync(launcher, ps, 'utf8');
    shortcutPaths().forEach(function (lnk) {
      if (fs.existsSync(lnk)) { try { fs.unlinkSync(lnk); } catch (e) { /* ignore */ } }
      makeShortcut(lnk, process.env.SystemRoot ? path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe') : 'powershell.exe', '-NoProfile -ExecutionPolicy Bypass -File "' + launcher + '"', PROFILE_HOME, exePath);
    });
    return;
  }
  shortcutPaths().forEach(function (lnk) {
    if (fs.existsSync(lnk)) { try { fs.unlinkSync(lnk); } catch (e) { /* ignore */ } }
    makeShortcut(lnk, exePath, '', path.dirname(exePath), exePath);
  });
}

function createDirectShortcut(msixExe) {
  const aumid = codexAumid();
  const explorer = path.join(process.env.SystemRoot || 'C:\\Windows', 'explorer.exe');
  shortcutPaths().forEach(function (lnk) {
    if (fs.existsSync(lnk)) { try { fs.unlinkSync(lnk); } catch (e) { /* ignore */ } }
    if (aumid) makeShortcut(lnk, explorer, 'shell:AppsFolder\\' + aumid, '', msixExe);
    else makeShortcut(lnk, msixExe, '', path.dirname(msixExe), msixExe);
  });
}

/* ---------------- Config ---------------- */
function appData() { return process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'); }

function readText(p) { try { return fs.readFileSync(p, 'utf8'); } catch (e) { return ''; } }

function tomlString(src, key) {
  const re = new RegExp('^\\s*' + key + '\\s*=\\s*"([^"]*)"', 'm');
  const m = src.match(re);
  return m ? m[1] : '';
}

function resolveBase() {
  let configured = {};
  try { configured = JSON.parse(fs.readFileSync(OAIC_CONFIG, 'utf8')) || {}; } catch (e) { configured = {}; }
  let base = String(BASE_ARG || process.env.CODEX_BASE_URL || process.env.OAIC_USAGE_BASE_URL || configured.baseUrl || '').trim();
  if (!base) {
    const t = tomlString(readText(path.join(codexHome(), 'config.toml')), 'base_url');
    if (t) { try { base = new URL(t).origin; } catch (e) { base = t; } }
  }
  if (!base) base = 'https://codex.finnvnoi.top';
  try {
    const u = new URL(base);
    if (/\/backend-api\/codex\/?$/i.test(u.pathname)) { u.pathname = ''; u.search = ''; u.hash = ''; base = u.toString().replace(/\/+$/, ''); }
  } catch (e) { /* keep user value for diagnostics */ }
  return base.replace(/\/+$/, '');
}

function resolveKey() {
  let configured = {};
  try { configured = JSON.parse(fs.readFileSync(OAIC_CONFIG, 'utf8')) || {}; } catch (e) { configured = {}; }
  return String(API_KEY || process.env.CODEX_API_KEY || configured.apiKey || '').trim();
}

function writeConfig() {
  const dir = path.dirname(OAIC_CONFIG);
  fs.mkdirSync(dir, { recursive: true });
  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(OAIC_CONFIG, 'utf8')) || {}; } catch (e) { prev = {}; }
  const cfg = Object.assign({}, prev, { baseUrl: resolveBase(), shopUrl: SHOP });
  const key = resolveKey();
  if (key) cfg.apiKey = key;
  fs.writeFileSync(OAIC_CONFIG, JSON.stringify(cfg, null, 2));
  ok('config: ' + OAIC_CONFIG);
  ok('base URL: ' + cfg.baseUrl);
  if (!key) warn('chua co CODEX_API_KEY - OAIC usage se bao thieu key cho den khi cau hinh newllm.');
}

/* ---------------- Codex TOML config ---------------- */
function codexHome() {
  if (ISOLATED_PROFILE) return ISOLATED_CODEX_HOME;
  const env = String(process.env.CODEX_HOME || '').trim();
  if (env) return path.resolve(env);
  return path.join(os.homedir(), '.codex');
}

function tomlStr(s) {
  return '"' + String(s == null ? '' : s)
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\r/g, '\\r')
    .replace(/\n/g, '\\n')
    .replace(/\t/g, '\\t') + '"';
}

// Set/remove top-level keys. A null value deletes the key.
function tomlSet(text, updates) {
  const lines = String(text || '').split(/\r?\n/);
  const pending = new Map(updates);
  const out = [];
  let inTop = true;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^\s*\[/.test(line)) inTop = false;
    if (inTop) {
      const m = line.match(/^\s*([A-Za-z0-9_-]+)\s*=/);
      if (m && pending.has(m[1])) {
        const v = pending.get(m[1]);
        pending.delete(m[1]);
        if (v !== null) out.push(m[1] + ' = ' + v);
        continue;
      }
    }
    out.push(line);
  }
  if (pending.size) {
    const inserts = [];
    pending.forEach(function (v, k) { if (v !== null) inserts.push(k + ' = ' + v); });
    let idx = -1;
    for (let i = 0; i < out.length; i++) { if (/^\s*\[/.test(out[i])) { idx = i; break; } }
    if (idx < 0) idx = out.length;
    out.splice.apply(out, [idx, 0].concat(inserts));
  }
  return out.join('\n').replace(/\n{3,}/g, '\n\n').replace(/^\n+/, '');
}

function tomlReplaceTable(text, tableName, bodyLines) {
  const lines = String(text || '').split(/\r?\n/);
  const out = [];
  let skip = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const m = line.match(/^\s*\[([^\[\]][^\]]*)\]\s*$/);
    if (m) skip = (m[1].trim() === tableName);
    if (!skip) out.push(line);
  }
  while (out.length && out[out.length - 1].trim() === '') out.pop();
  out.push('', '[' + tableName + ']');
  for (let i = 0; i < bodyLines.length; i++) out.push(bodyLines[i]);
  return out.join('\n') + '\n';
}

function resolveModel() {
  return String(MODEL_ARG || process.env.CODEX_MODEL || 'gpt-5.6-sol').trim();
}

function resolveEffort() {
  return String(EFFORT_ARG || process.env.CODEX_REASONING_EFFORT || 'xhigh').trim();
}

function setUserEnv(name, value) {
  if (ISOLATED_PROFILE) { info('isolated: khong ghi User env ' + name); return; }
  if (process.env.FVCODEX_SKIP_ENV === '1') { info('skip env ' + name + ' (test)'); return; }
  const r = runPS("[Environment]::SetEnvironmentVariable('" + psEscape(name) + "', '" + psEscape(value) + "', 'User')");
  if (r.code !== 0) warn('khong dat duoc ' + name + ': ' + (r.err || r.out));
  else ok('env ' + name + (name === 'CODEX_API_KEY' ? ' (da dat)' : ' = ' + value));
}

function configure() {
  log(CONFIG_MODE === 'account' ? '=== FVCodex account config ===' : '=== FVCodex config ===');
  const home = codexHome();
  fs.mkdirSync(home, { recursive: true });
  const cfgPath = path.join(home, 'config.toml');
  const base = resolveBase();
  const endpoint = base.replace(/\/+$/, '') + '/backend-api/codex';
  const model = resolveModel();
  const effort = resolveEffort();
  const key = resolveKey();

  let text = readText(cfgPath);
  text = tomlSet(text, [
    ['model', tomlStr(model)],
    ['model_provider', tomlStr('codex')],
    ['model_reasoning_effort', tomlStr(effort)],
    ['model_catalog_json', CONFIG_MODE === 'custom-endpoint' ? tomlStr(path.join(home, CATALOG_NAME)) : null]
  ]);
  const providerLines = [
    'name = "openai"',
    'base_url = ' + tomlStr(endpoint),
    'env_key = "CODEX_API_KEY"',
    'wire_api = "responses"',
    'supports_standalone_web_search = true'
  ];
  if (CONFIG_MODE === 'account') {
    providerLines.push('supports_websockets = false', 'requires_openai_auth = true');
  }
  text = tomlReplaceTable(text, 'model_providers.codex', providerLines);
  fs.writeFileSync(cfgPath, text);
  if (CONFIG_MODE === 'custom-endpoint') {
    const bundled = path.join(ROOT, CATALOG_NAME);
    const catalogPath = path.join(home, CATALOG_NAME);
    if (!fs.existsSync(bundled)) throw new Error('thieu catalog: ' + bundled);
    fs.copyFileSync(bundled, catalogPath);
    ok('catalog: ' + catalogPath);
  }
  ok('config.toml: ' + cfgPath);
  ok('endpoint: ' + endpoint);
  ok('model: ' + model + ' (effort ' + effort + ')');

  setUserEnv('CODEX_BASE_URL', endpoint);
  setUserEnv('CODEX_MODEL', model);
  setUserEnv('CODEX_REASONING_EFFORT', effort);
  if (key) setUserEnv('CODEX_API_KEY', key);
  else warn('chua co API key. Chay lai voi -ApiKey hoac dat bien CODEX_API_KEY.');

  writeConfig();
  if (CONFIG_MODE === 'account' && !NO_VSCODE) {
    const vs = patchVsCode();
    if (vs) log('VS Code files patched: ' + vs);
  }
  log('');
  log(CONFIG_MODE === 'account'
    ? 'XONG. Account/native-catalog config da duoc ap dung. Khoi dong lai Codex/FVCodex va VS Code de ap dung.'
    : 'XONG. Khoi dong lai FVCodex (va terminal moi) de ap dung cau hinh.');
  return 0;
}

/* ---------------- State ---------------- */
function readJsonFile(p) { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) { return null; } }

function readInstallState() { return readJsonFile(INSTALL_STATE); }

function readDirectState() { return readJsonFile(DIRECT_STATE); }

function writeJsonFile(p, v) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(v, null, 2));
}

function saveInstallState(extra) {
  const prev = readInstallState() || {};
  const state = Object.assign({}, prev, extra, {
    schemaVersion: 1,
    installedAt: new Date().toISOString(),
    shortcutName: SHORTCUT_NAME
  });
  writeJsonFile(INSTALL_STATE, state);
  return state;
}

/* ---------------- Portable ---------------- */
function buildPortable(msixDir) {
  killProcessAt(path.join(FV_HOME, 'portable'));
  const portable = path.join(FV_HOME, 'portable');
  const appDir = path.join(portable, 'app');
  const srcApp = path.join(msixDir, 'app');
  rmrf(portable, 20);
  fs.mkdirSync(appDir, { recursive: true });
  info('copy app tu ' + srcApp);
  robocopy(srcApp, appDir);
  ok('copy xong -> ' + appDir);
  const exePath = patchApp(appDir);
  createPortableShortcut(exePath);
  return exePath;
}

/* ---------------- Direct ---------------- */
function buildDirect(msixDir) {
  const appDir = path.join(msixDir, 'app');
  const asarPath = path.join(appDir, 'resources', 'app.asar');
  const exePath = findAppExe(appDir);
  if (!fs.existsSync(asarPath) || !exePath) {
    throw new Error('khong thay app.asar hoac exe cua app trong MSIX');
  }
  try {
    const probe = path.join(appDir, '.fvcodex-write-test');
    fs.writeFileSync(probe, 'x');
    fs.unlinkSync(probe);
  } catch (e) {
    throw new Error('khong ghi duoc vao MSIX (' + (e && e.message || e) + '). Hay chay installer bang quyen Administrator.');
  }
  killProcessAt(appDir);

  const exeName = path.basename(exePath);
  let state = readDirectState();
  if (!state || state.asarPath !== asarPath) {
    const backupDir = path.join(BACKUP_DIR, Date.now().toString());
    fs.mkdirSync(backupDir, { recursive: true });
    fs.copyFileSync(asarPath, path.join(backupDir, 'app.asar.original'));
    fs.copyFileSync(exePath, path.join(backupDir, exeName + '.original'));
    state = {
      schemaVersion: 1,
      mode: 'direct',
      msixDir: msixDir,
      asarPath: asarPath,
      exePath: exePath,
      exeName: exeName,
      backupDir: backupDir,
      originalAsarHash: asarHeaderHash(asarPath),
      createdAt: new Date().toISOString()
    };
    writeJsonFile(DIRECT_STATE, state);
    ok('backup MSIX: ' + backupDir);
  }

  patchApp(appDir);
  state.patchedAt = new Date().toISOString();
  state.patchedAsarHash = asarHeaderHash(asarPath);
  writeJsonFile(DIRECT_STATE, state);
  createDirectShortcut(exePath);
  ok('direct MSIX da patch: ' + msixDir);
  return exePath;
}

function restoreDirect() {
  const state = readDirectState();
  if (!state) { info('khong co direct patch de khoi phuc'); return true; }
  if (!state.backupDir || !fs.existsSync(state.backupDir)) {
    warn('thieu backup direct: ' + (state.backupDir || '(khong ro)'));
    return false;
  }
  if (!fs.existsSync(state.asarPath)) {
    warn('MSIX da duoc cap nhat hoac di chuyen; patch cu khong con ap dung. Backup giu tai ' + state.backupDir);
    try { fs.unlinkSync(DIRECT_STATE); } catch (e) { /* ignore */ }
    return true;
  }
  const asarBackup = path.join(state.backupDir, 'app.asar.original');
  const exeBackup = path.join(state.backupDir, (state.exeName || EXE_NAME) + '.original');
  if (!fs.existsSync(asarBackup) || !fs.existsSync(exeBackup)) {
    warn('backup direct khong day du trong ' + state.backupDir);
    return false;
  }
  killProcessAt(state.msixDir);
  if (fs.existsSync(state.asarPath) && state.patchedAsarHash && asarHeaderHash(state.asarPath) !== state.patchedAsarHash) {
    warn('app.asar da thay doi sau khi patch; van khoi phuc tu backup goc');
  }
  fs.copyFileSync(asarBackup, state.asarPath);
  fs.copyFileSync(exeBackup, state.exePath);
  ok('direct MSIX da duoc khoi phuc');
  try { fs.unlinkSync(DIRECT_STATE); } catch (e) { /* ignore */ }
  if (fs.existsSync(BACKUP_DIR)) { try { fs.rmSync(BACKUP_DIR, { recursive: true, force: true }); } catch (e) { /* ignore */ } }
  return true;
}

/* ---------------- VS Code extension ---------------- */
const VS_PATCHES = [
  {
    file: /^composer-content-.*\.js$/,
    pairs: [
      ['ie=i===`local`&&v||T_(h,r)', 'ie=!1'],
      ['V=i===`local`&&y||Qg(g,r)', 'V=!1']
    ],
    regex: [/([A-Za-z_$][\w$]*)=i===`local`&&[^,;)]*\|\|[A-Za-z_$][\w$]*\([^)]*\)/, '$1=!1'],
    desc: 'nguon chan Codex (local)'
  },
  {
    file: /^chatgpt-conversation-queries-.*\.js$/,
    pairs: [['sendBlockReason:d?.block_reason??null,sendBlocked:d!=null', 'sendBlockReason:null,sendBlocked:!1']],
    desc: 'state rate-limit'
  },
  {
    file: /^chatgpt-conversation-composer-submit-.*\.js$/,
    pairs: [['if(n.sendBlocked)return k(!1),!1;', 'if(!1)return k(!1),!1;']],
    regex: [/if\(([A-Za-z_$][\w$]*)\.sendBlocked\)return/, 'if(!1)return'],
    desc: 'guard submit'
  },
  {
    file: /^codex-composer-adapter-.*\.js$/,
    pairs: [],
    regex: [/let ([A-Za-z_$][\w$]*)=[\w$]+\|\|[\w$]+\|\|[\w$]+\|\|[\w$]+&&[\w$]+\|\|[\w$]+\|\|[\w$]+&&[\w$]+\|\|[\w$]+\?\.isLoading===!0\|\|[\w$]+\|\|[\w$]+,\s*/, 'let $1=!1, '],
    desc: 'composer submitDisabled'
  }
];

const VS_BAK_SUFFIX = '.codex-unblock.bak';

function vscodeExtDirs() {
  const out = [];
  const home = os.homedir();
  ['.vscode', '.vscode-insiders', '.cursor', '.windsurf'].forEach(function (d) {
    const base = path.join(home, d, 'extensions');
    if (!fs.existsSync(base)) return;
    fs.readdirSync(base).forEach(function (name) {
      if (/^openai\.chatgpt-/.test(name)) out.push(path.join(base, name, 'webview', 'assets'));
    });
  });
  return out;
}

function patchVsCode() {
  const dirs = vscodeExtDirs();
  if (!dirs.length) { info('khong thay extension openai.chatgpt cua VS Code'); return 0; }
  let total = 0;
  dirs.forEach(function (assets) {
    let files = [];
    try { files = fs.readdirSync(assets).filter(function (f) { return /\.js$/.test(f); }); } catch (e) { return; }
    VS_PATCHES.forEach(function (p) {
      files.filter(function (f) { return p.file.test(f); }).forEach(function (f) {
        const full = path.join(assets, f);
        let src;
        try { src = fs.readFileSync(full, 'utf8'); } catch (e) { return; }
        let next = src, hit = false;
        p.pairs.forEach(function (pair) {
          if (next.indexOf(pair[0]) >= 0) { next = next.split(pair[0]).join(pair[1]); hit = true; }
        });
        if (!hit && p.regex && p.regex[0] && p.regex[0].test(next)) { next = next.replace(p.regex[0], p.regex[1]); hit = true; }
        if (!hit) return;
        const bak = full + VS_BAK_SUFFIX;
        if (!fs.existsSync(bak)) fs.copyFileSync(full, bak);
        fs.writeFileSync(full, next);
        ok('VS Code: ' + f + ' (' + p.desc + ')');
        total++;
      });
    });
  });
  return total;
}

function restoreVsCode() {
  const dirs = vscodeExtDirs();
  if (!dirs.length) { info('khong thay extension openai.chatgpt cua VS Code'); return 0; }
  let total = 0;
  dirs.forEach(function (assets) {
    let files = [];
    try { files = fs.readdirSync(assets); } catch (e) { return; }
    files.filter(function (f) { return f.slice(-VS_BAK_SUFFIX.length) === VS_BAK_SUFFIX; }).forEach(function (bakName) {
      const bak = path.join(assets, bakName);
      const original = bakName.slice(0, -VS_BAK_SUFFIX.length);
      const target = path.join(assets, original);
      try {
        fs.copyFileSync(bak, target);
        fs.unlinkSync(bak);
        ok('restore VS Code: ' + original);
        total++;
      } catch (e) {
        warn('khong restore duoc ' + target + ': ' + (e && e.message || e));
      }
    });
  });
  return total;
}

function restoreVsCodeOnly() {
  log('=== FVCodex VS Code restore ===');
  const n = restoreVsCode();
  log('VS Code files restored: ' + n);
  return 0;
}

function restoreDirectOnly() {
  log('=== FVCodex direct restore ===');
  return restoreDirect() ? 0 : 1;
}

function removePortableOnly() {
  log('=== FVCodex portable uninstall ===');
  killProcessAt(path.join(FV_HOME, 'portable'));
  removeShortcuts();
  rmrf(path.join(FV_HOME, 'portable'), 20);
  if (fs.existsSync(INSTALL_STATE)) {
    const st = readInstallState();
    if (st && st.portableExe) { delete st.portableExe; st.portableRemovedAt = new Date().toISOString(); writeJsonFile(INSTALL_STATE, st); }
  }
  ok('da go portable FVCodex va shortcut (giu profile neu co)');
  return 0;
}

function uninstallBackupRoot() {
  return path.join(STATE_DIR, 'uninstall-backups', new Date().toISOString().replace(/[:.]/g, '-'));
}

function backupUninstallItem(root, source, relativeName) {
  if (!source || !fs.existsSync(source)) return '';
  const destination = path.join(root, relativeName);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  const stat = fs.statSync(source);
  if (stat.isDirectory()) {
    fs.cpSync(source, destination, { recursive: true, force: true });
  } else {
    fs.copyFileSync(source, destination);
  }
  return destination;
}

function askBackupBeforeUninstall() {
  if (BACKUP_UNINSTALL) return true;
  if (SELECTION_ARG) return false;
  const r = cp.spawnSync('powershell', ['-NoProfile', '-Command', "Read-Host 'Backup selected files before uninstall? [y/N]'"], { stdio: ['inherit', 'pipe', 'inherit'], encoding: 'utf8' });
  return /^(y|yes|1)$/i.test(String(r.stdout || '').trim());
}

function removeProfileOnly() {
  log('=== FVCodex isolated profile uninstall ===');
  killProcessAt(path.join(FV_HOME, 'profile'));
  rmrf(PROFILE_HOME, 20);
  ok('da xoa profile/history/config FVCodex');
  return 0;
}

function vscodeBackupCount() {
  let n = 0;
  vscodeExtDirs().forEach(function (assets) {
    try { n += fs.readdirSync(assets).filter(function (f) { return f.slice(-VS_BAK_SUFFIX.length) === VS_BAK_SUFFIX; }).length; } catch (e) { /* ignore */ }
  });
  return n;
}

function uninstallSelection() {
  const st = readInstallState();
  const items = [];
  if (fs.existsSync(path.join(FV_HOME, 'portable'))) items.push({ n: 1, label: 'FVCodex portable + shortcut' });
  if ((st && st.profile === 'isolated' && fs.existsSync(PROFILE_HOME)) || fs.existsSync(ISOLATED_CODEX_HOME)) items.push({ n: 2, label: 'FVCodex isolated profile/history/config' });
  if (readDirectState()) items.push({ n: 3, label: 'direct MSIX patch (restore original)' });
  const vs = vscodeBackupCount();
  if (vs) items.push({ n: 4, label: 'VS Code patch (' + vs + ' backup file(s))' });
  const sharedOaic = path.join(APP_DATA, 'oaic-usage', 'config.json');
  const isolatedOaic = path.join(PROFILE_HOME, 'oaic-usage', 'config.json');
  if (fs.existsSync(sharedOaic)) items.push({ n: 5, label: 'shared OAIC config (' + sharedOaic + ')' });
  if (fs.existsSync(isolatedOaic)) items.push({ n: 6, label: 'isolated OAIC config (' + isolatedOaic + ')' });
  if (!items.length) { info('khong tim thay thanh phan FVCodex/newllm de go.'); return new Set(); }
  log('');
  log('Phat hien cac thanh phan da cai/patch:');
  items.forEach(function (x) { log('  ' + x.n + '. ' + x.label); });
  log('Nhap so cach nhau boi dau phay, hoac all de chon tat ca. Enter = huy.');
  let answer = SELECTION_ARG.toLowerCase();
  if (!answer) {
    const r = cp.spawnSync('powershell', ['-NoProfile', '-Command', "Read-Host 'Chon'"], { stdio: ['inherit', 'pipe', 'inherit'], encoding: 'utf8' });
    answer = String(r.stdout || '').trim().toLowerCase();
  }
  if (!answer) return new Set();
  if (answer === 'all' || answer === 'a') return new Set(items.map(function (x) { return x.n; }));
  const selected = new Set();
  answer.split(',').forEach(function (v) { const n = parseInt(v.trim(), 10); if (items.some(function (x) { return x.n === n; })) selected.add(n); });
  return selected;
}

/* ---------------- Launch ---------------- */
function launch() {
  const state = readInstallState();
  if (!state) return;
  const running = runningCodexPaths();
  if (running.length) {
    info('Codex dang chay; khong tu khoi dong. Mo shortcut ' + SHORTCUT_NAME + ' de dung ban moi.');
    return;
  }
  if (state.mode === 'portable' && state.portableExe && fs.existsSync(state.portableExe)) {
    info('khoi dong ' + state.portableExe);
    const env = Object.assign({}, process.env);
    if (state.profile === 'isolated') {
      env.CODEX_HOME = state.codexHome || ISOLATED_CODEX_HOME;
      env.FVCODEX_OAIC_CONFIG = state.oaicConfig || OAIC_CONFIG;
      env.FVCODEX_USER_DATA = state.userData || ISOLATED_USER_DATA;
      env.CODEX_BASE_URL = state.baseUrl || env.CODEX_BASE_URL || '';
      env.CODEX_API_KEY = resolveKey() || env.CODEX_API_KEY || '';
      env.CODEX_MODEL = state.model || env.CODEX_MODEL || '';
      env.CODEX_REASONING_EFFORT = state.effort || env.CODEX_REASONING_EFFORT || '';
    }
    const launchArgs = state.profile === 'isolated' && state.userData
      ? ['--user-data-dir=' + state.userData]
      : [];
    const child = cp.spawn(state.portableExe, launchArgs, { detached: true, stdio: 'ignore', cwd: path.dirname(state.portableExe), env: env });
    child.unref();
    return;
  }
  if (state.mode === 'direct') {
    const aumid = codexAumid();
    if (aumid) {
      info('khoi dong ' + aumid);
      runPS("Start-Process 'shell:AppsFolder\\" + aumid.replace(/'/g, "''") + "'");
    }
  }
}

/* ---------------- Commands ---------------- */
function install() {
  log('=== FVCodex installer ===');
  log('root: ' + ROOT);
  log('mode: ' + MODE);
  if (MODE !== 'portable' && MODE !== 'direct') throw new Error('mode khong hop le: ' + MODE);

  const running = runningCodexPaths();
  if (running.length) warn('Codex dang chay (' + running.length + ' tien trinh). Nen dong Codex truoc khi cai de tranh xung dot file.');

  const prevState = readInstallState();
  if (prevState && prevState.mode && prevState.mode !== MODE) {
    throw new Error('da cai o mode ' + prevState.mode + '. Hay chay uninstall truoc khi chuyen sang mode ' + MODE + '.');
  }
  if (MODE === 'portable' && readDirectState()) {
    throw new Error('MSIX dang duoc patch truc tiep. Hay chay uninstall truoc khi cai portable.');
  }

  const msixDir = findMsixApp();
  if (!msixDir) throw new Error('khong tim thay goi Codex desktop (MSIX). Hay cai Codex truoc.');
  info('MSIX: ' + msixDir);

  let portableExe = '';
  if (MODE === 'portable') {
    portableExe = buildPortable(msixDir);
  } else {
    if (!isAdmin()) throw new Error('direct mode can quyen Administrator. Hay chay lai bang quyen admin.');
    buildDirect(msixDir);
  }

  writeConfig();

  let vs = 0;
  if (!NO_VSCODE) vs = patchVsCode();

  saveInstallState({
    mode: MODE,
    profile: ISOLATED_PROFILE ? 'isolated' : 'shared',
    configMode: CONFIG_MODE,
    msixDir: msixDir,
    portableExe: portableExe,
    vsCodeFiles: vs,
    codexHome: ISOLATED_PROFILE ? ISOLATED_CODEX_HOME : codexHome(),
    userData: ISOLATED_PROFILE ? ISOLATED_USER_DATA : '',
    oaicConfig: OAIC_CONFIG,
    baseUrl: resolveBase(),
    model: resolveModel(),
    effort: resolveEffort(),
    apiKeyConfigured: !!resolveKey()
  });

  log('');
  log('XONG.');
  if (portableExe) log('- Desktop portable: ' + portableExe);
  if (MODE === 'direct') log('- Desktop: da patch truc tiep MSIX (backup trong ' + STATE_DIR + ')');
  if (vs) log('- VS Code: ' + vs + ' file da patch. Reload Window de ap dung.');

  if (!NO_LAUNCH) launch();
  return 0;
}

function restoreOnly() {
  log('=== FVCodex restore ===');
  const directOk = restoreDirect();
  let vs = 0;
  if (!NO_VSCODE) vs = restoreVsCode();
  if (vs) ok('da restore ' + vs + ' file VS Code');
  if (fs.existsSync(INSTALL_STATE)) { try { fs.unlinkSync(INSTALL_STATE); } catch (e) { /* ignore */ } }
  return directOk ? 0 : 1;
}

function uninstall() {
  log('=== FVCodex uninstall ===');
  const state = readInstallState();
  const selected = uninstallSelection();
  if (!selected.size) { info('Khong co thay doi nao duoc thuc hien.'); return 0; }
  const makeBackup = askBackupBeforeUninstall();
  const backupRoot = makeBackup ? uninstallBackupRoot() : '';
  if (makeBackup) fs.mkdirSync(backupRoot, { recursive: true });
  if (selected.has(1)) {
    if (makeBackup) backupUninstallItem(backupRoot, path.join(FV_HOME, 'portable'), 'portable');
    killProcessAt(path.join(FV_HOME, 'portable')); removeShortcuts(); rmrf(path.join(FV_HOME, 'portable'), 20); ok('da go portable FVCodex');
  }
  if (selected.has(3)) {
    const direct = readDirectState();
    if (makeBackup && direct) {
      backupUninstallItem(backupRoot, direct.asarPath, path.join('direct', 'app.asar.current'));
      backupUninstallItem(backupRoot, direct.exePath, path.join('direct', direct.exeName || EXE_NAME));
    }
    restoreDirect();
  }
  let vs = 0;
  if (selected.has(4) && !NO_VSCODE) {
    if (makeBackup) {
      vscodeExtDirs().forEach(function (assets) {
        try { fs.readdirSync(assets).filter(function (f) { return f.slice(-VS_BAK_SUFFIX.length) === VS_BAK_SUFFIX; }).forEach(function (f) { backupUninstallItem(backupRoot, path.join(assets, f), path.join('vscode', path.basename(path.dirname(path.dirname(assets))), f)); }); } catch (e) { /* ignore */ }
      });
    }
    vs = restoreVsCode();
  }
  if (selected.has(2)) { if (makeBackup) backupUninstallItem(backupRoot, PROFILE_HOME, 'profile'); killProcessAt(path.join(FV_HOME, 'profile')); rmrf(PROFILE_HOME, 20); ok('da xoa profile FVCodex tach rieng'); }
  if (selected.has(5)) {
    const sharedConfig = path.join(APP_DATA, 'oaic-usage', 'config.json');
    if (makeBackup) backupUninstallItem(backupRoot, sharedConfig, path.join('oaic', 'shared-config.json'));
    if (fs.existsSync(sharedConfig)) { try { fs.unlinkSync(sharedConfig); ok('xoa config OAIC shared'); } catch (e) { warn('khong xoa duoc config OAIC shared'); } }
  }
  if (selected.has(6)) {
    const isolatedConfig = path.join(PROFILE_HOME, 'oaic-usage', 'config.json');
    if (makeBackup) backupUninstallItem(backupRoot, isolatedConfig, path.join('oaic', 'isolated-config.json'));
    if (fs.existsSync(isolatedConfig)) { try { fs.unlinkSync(isolatedConfig); ok('xoa config OAIC isolated'); } catch (e) { warn('khong xoa duoc config OAIC isolated'); } }
  }
  if (selected.has(1) && fs.existsSync(INSTALL_STATE)) {
    const next = readInstallState();
    if (next) { delete next.portableExe; next.portableRemovedAt = new Date().toISOString(); writeJsonFile(INSTALL_STATE, next); }
  }

  log('');
  log('XONG.');
  if (makeBackup) log('- Backup: ' + backupRoot);
  if (vs) log('- VS Code: da restore ' + vs + ' file. Reload Window de ap dung.');
  if (state && state.mode === 'direct') log('- Desktop: da khoi phuc MSIX goc.');
  if (selected.has(1)) log('- Shortcut ' + SHORTCUT_NAME + ' da duoc xoa.');
  return 0;
}

function doctor() {
  log('=== FVCodex doctor ===');
  log('node: ' + process.version);
  log('root: ' + ROOT);
  const msix = findMsixApp();
  log('MSIX: ' + (msix || 'khong thay'));
  log('baseUrl: ' + resolveBase());
  const key = resolveKey();
  log('apiKey: ' + (key ? 'da co (' + key.length + ' ky tu)' : 'chua co'));
  log('oaic config: ' + OAIC_CONFIG + (fs.existsSync(OAIC_CONFIG) ? ' (co)' : ' (chua co)'));
  log('profile: ' + (ISOLATED_PROFILE ? 'isolated' : 'shared'));
  log('codex home: ' + codexHome());
  const portableExe = findAppExe(path.join(FV_HOME, 'portable', 'app'));
  log('portable: ' + (portableExe || 'chua cai'));
  log('direct state: ' + (fs.existsSync(DIRECT_STATE) ? 'co' : 'khong'));
  const st = readInstallState();
  if (st) log('install state: mode=' + st.mode + ', installedAt=' + st.installedAt);
  const vsDirs = vscodeExtDirs();
  log('VS Code extension: ' + (vsDirs.length ? vsDirs.join('; ') : 'khong thay'));
  return 0;
}

function patchVsCodeOnly() {
  log('=== FVCodex VS Code patch ===');
  const n = patchVsCode();
  if (!n) log('khong co file nao can patch (hoac extension chua cai)');
  else log('VS Code files patched: ' + n);
  return 0;
}

function main() {
  if (DOCTOR) return doctor();
  if (UNINSTALL) return uninstall();
  if (RESTORE_ONLY) return restoreOnly();
  if (CONFIG_ONLY) return configure();
  if (VSCODE_PATCH_ONLY) return patchVsCodeOnly();
  if (VSCODE_RESTORE_ONLY) return restoreVsCodeOnly();
  if (PORTABLE_REMOVE_ONLY) return removePortableOnly();
  if (has('profile-remove')) return removeProfileOnly();
  if (DIRECT_RESTORE_ONLY) return restoreDirectOnly();
  return install();
}

try {
  process.exitCode = main();
} catch (e) {
  console.error('[LOI] ' + (e && e.stack || e));
  process.exitCode = 1;
}
