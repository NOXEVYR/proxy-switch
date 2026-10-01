'use strict';
// Official-release discovery and bounded file-range staging. No installer/network settings writes.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const https = require('node:https');
const http = require('node:http');
const tls = require('node:tls');
const zlib = require('node:zlib');
const REPO = 'NOXEVYR/proxy-switch';
const LIMIT = 50 * 1024 * 1024;
const META_LIMIT = 1024 * 1024;
const hash = b => crypto.createHash('sha256').update(b).digest('hex');
const fail = code => { throw new Error(code); };
const json = file => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
function atomic(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = file + '.' + crypto.randomBytes(8).toString('hex') + '.tmp';
  const fd = fs.openSync(temp, 'wx');
  try { fs.writeFileSync(fd, JSON.stringify(value, null, 2)); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(temp, file);
}
function version(v) {
  if (typeof v !== 'string' || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(v)) fail('invalid-version');
  const result = v.split('.').map(Number);
  if (result.some(n => !Number.isSafeInteger(n))) fail('invalid-version');
  return result;
}
function compare(a, b) { const x = version(a), y = version(b); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] > y[i] ? 1 : -1; return 0; }
function safePath(root, rel) {
  if (typeof rel !== 'string' || !rel || rel.length > 220 || rel.includes('\\') || rel.includes(':') || rel.split('/').some(s => !s || s === '.' || s === '..' || /[. ]$/.test(s) || /^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\.|$)/i.test(s))) fail('unsafe-path');
  const base = path.resolve(root), dest = path.resolve(base, ...rel.split('/'));
  if (!dest.startsWith(base + path.sep)) fail('unsafe-path');
  let cursor = base;
  for (const part of ['', ...rel.split('/')]) { cursor = path.join(cursor, part); if (fs.existsSync(cursor) && fs.lstatSync(cursor).isSymbolicLink()) fail('reparse-path'); }
  return dest;
}
function entries(list) {
  if (!Array.isArray(list) || !list.length || list.length > 256) fail('invalid-file-list');
  const seen = new Set();
  for (const f of list) {
    safePath(process.cwd(), f.path);
    if (seen.has(f.path.toLowerCase()) || !/^[a-f0-9]{64}$/.test(f.sha256) || !Number.isSafeInteger(f.bytes) || f.bytes < 0 || f.bytes > 160 * 1024 * 1024) fail('invalid-file-entry');
    seen.add(f.path.toLowerCase());
  }
  return list;
}
function registration(root) {
  const reg = json(path.join(root, 'update-install.json'));
  if (reg.schema !== 1 || reg.product !== 'FlowSwitch' || reg.platform !== 'windows' || reg.arch !== 'x64' || reg.channel !== 'stable') fail('unregistered-installation');
  version(reg.version);
  const bytes = fs.readFileSync(path.join(root, 'manifest.json'));
  if (hash(bytes) !== reg.manifestSha256 || reg.build !== reg.manifestSha256) fail('installation-manifest-mismatch');
  const files = entries(JSON.parse(bytes.toString('utf8').replace(/^\uFEFF/, '')));
  if (!files.some(f => f.path === 'FlowSwitch.exe') || !files.some(f => f.path === 'app/Preferences.ps1')) fail('invalid-installation');
  const prefs = fs.readFileSync(safePath(root, 'app/Preferences.ps1'), 'utf8');
  if (!prefs.includes("ProductVersion='" + reg.version + "'")) fail('installation-version-mismatch');
  return { reg, files };
}
function allowedURL(value) {
  const u = new URL(value);
  if (u.protocol !== 'https:' || u.username || u.password || (u.port && u.port !== '443') || !['api.github.com', 'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com'].includes(u.hostname)) fail('untrusted-update-source');
  return u;
}
// Abort before reading a 200 response to a range request. Never silently fetch a whole ZIP.
function request(url, { limit, range, proxy = '', signal }, redirects = 0) {
  const u = allowedURL(url);
  return new Promise((resolve, reject) => {
    let settled = false, req, connector;
    const timer = setTimeout(() => finish(new Error('update-timeout')), 45000);
    function finish(error, value) { if (settled) return; settled = true; clearTimeout(timer); if (signal) signal.removeEventListener('abort', abort); if (req) req.destroy(); if (connector) connector.destroy(); error ? reject(error) : resolve(value); }
    const abort = () => finish(new Error('update-cancelled'));
    if (signal) { if (signal.aborted) { abort(); return; } signal.addEventListener('abort', abort, { once: true }); }
    const headers = { 'User-Agent': 'FlowSwitch-Updater/1', Accept: 'application/vnd.github+json', 'Accept-Encoding': 'identity' };
    if (range) headers.Range = `bytes=${range.start}-${range.end}`;
    const options = { hostname: u.hostname, path: u.pathname + u.search, method: 'GET', headers, agent: false };
    function response(res) {
      if ([301, 302, 303, 307, 308].includes(res.statusCode)) {
        res.destroy();
        if (redirects >= 5 || !res.headers.location) return finish(new Error('invalid-redirect'));
        let next; try { next = allowedURL(new URL(res.headers.location, u).href).href; } catch (e) { return finish(e); }
        request(next, { limit, range, proxy, signal }, redirects + 1).then(v => finish(null, v), e => finish(e)); return;
      }
      if (res.statusCode !== (range ? 206 : 200)) { res.destroy(); return finish(new Error(range && res.statusCode === 200 ? 'range-not-supported' : 'http-' + res.statusCode)); }
      if (range && !new RegExp(`^bytes ${range.start}-${range.end}/${range.total}$`).test(res.headers['content-range'] || '')) { res.destroy(); return finish(new Error('invalid-content-range')); }
      if (Number(res.headers['content-length'] || 0) > limit) { res.destroy(); return finish(new Error('download-limit')); }
      const chunks = []; let size = 0;
      res.on('data', b => { size += b.length; if (size > limit) { res.destroy(); finish(new Error('download-limit')); } else chunks.push(b); });
      res.on('error', () => finish(new Error('download-interrupted')));
      res.on('end', () => { if (range && size !== range.end - range.start + 1) return finish(new Error('short-range')); finish(null, Buffer.concat(chunks)); });
    }
    function start(socket) {
      if (socket) { options.agent = new https.Agent(); options.agent.createConnection = () => socket; }
      req = https.request(options, response); req.on('error', () => finish(new Error('network-unavailable'))); req.end();
    }
    if (!proxy) return start();
    let p; try { p = new URL(proxy); if (p.protocol !== 'http:' || p.username || p.password) fail('unsupported-proxy'); } catch (e) { finish(e); return; }
    connector = http.request({ hostname: p.hostname, port: p.port || 80, method: 'CONNECT', path: u.hostname + ':443', headers: { Host: u.hostname + ':443' } });
    connector.on('connect', (res, socket, head) => {
      if (res.statusCode !== 200 || head.length) { socket.destroy(); return finish(new Error('proxy-connect-failed')); }
      const secure = tls.connect({ socket, servername: u.hostname }); secure.on('error', () => finish(new Error('tls-failed'))); secure.once('secureConnect', () => start(secure));
    });
    connector.on('error', () => finish(new Error('proxy-unavailable'))); connector.end();
  });
}
function asset(release, name) {
  const found = (release.assets || []).filter(a => a.name === name);
  if (found.length !== 1 || found[0].state !== 'uploaded' || !/^sha256:[a-f0-9]{64}$/.test(found[0].digest || '') || !Number.isSafeInteger(found[0].size) || found[0].size <= 0) fail('missing-bound-asset');
  const a = found[0]; const expected = `https://github.com/${REPO}/releases/download/${release.tag_name}/${name}`;
  if (a.browser_download_url !== expected) fail('asset-source-mismatch');
  return a;
}
function validateTarget(m, release, current) {
  if (m.schema !== 1 || m.product !== 'FlowSwitch' || m.platform !== 'windows' || m.arch !== 'x64' || m.channel !== 'stable' || m.minUpdater !== 1 || m.version !== release.tag_name.slice(1) || !/^[a-f0-9]{64}$/.test(m.manifestSha256) || m.build !== m.manifestSha256) fail('incompatible-manifest');
  if (compare(m.version, current.reg.version) <= 0) fail('not-a-new-version');
  const bundle = asset(release, `FlowSwitch-v${m.version}-Windows-x64.zip`);
  if (m.archive.name !== bundle.name || m.archive.bytes !== bundle.size || 'sha256:' + m.archive.sha256 !== bundle.digest) fail('archive-binding-mismatch');
  entries(m.files);
  const previous = new Map(current.files.map(f => [f.path, f]));
  const applicationFiles = m.files.filter(f => f.path !== 'manifest.json' && f.path !== 'update-install.json');
  if (applicationFiles.length !== previous.size || applicationFiles.some(f => !previous.has(f.path))) fail('file-layout-requires-full-package');
  if (!m.files.some(f => f.path === 'manifest.json') || !m.files.some(f => f.path === 'update-install.json')) fail('missing-package-metadata');
  for (const f of m.files) {
    if (!Number.isSafeInteger(f.start) || f.start < 0 || !Number.isSafeInteger(f.length) || f.length < 0 || f.start + f.length > bundle.size || ![0, 8].includes(f.method)) fail('invalid-range');
    if (f.path.startsWith('app/runtime/') && previous.get(f.path)?.sha256 !== f.sha256) fail('runtime-requires-full-package');
  }
  return bundle;
}
function localPlan(root, current, target) {
  const previous = new Map(current.files.map(f => [f.path, f]));
  previous.set('manifest.json', { sha256: current.reg.manifestSha256 });
  previous.set('update-install.json', { sha256: hash(fs.readFileSync(path.join(root, 'update-install.json'))) });
  const changes = [];
  for (const f of target.files) {
    const local = safePath(root, f.path), before = previous.get(f.path);
    if (!before || !fs.existsSync(local) || hash(fs.readFileSync(local)) !== before.sha256) fail('locally-modified-program');
    if (f.sha256 !== before.sha256) changes.push({ ...f, beforeSha256: before.sha256 });
  }
  return { changes, downloadBytes: changes.reduce((n, f) => n + f.length, 0) };
}
async function check({ root, data, manual = false, allowLarge = false, proxy = '', transport = request, now = Date.now() }) {
  const dir = path.join(data, 'updates'); fs.mkdirSync(dir, { recursive: true });
  const stateFile = path.join(dir, 'background.json');
  let state = { enabled: true, nextCheck: 0, failures: 0 };
  if (fs.existsSync(stateFile)) state = { ...state, ...json(stateFile) };
  if (!manual && (state.enabled === false || now < state.nextCheck)) return { phase: 'throttled', nextCheck: state.nextCheck };
  const saveState = () => { if (fs.existsSync(stateFile)) state.enabled = json(stateFile).enabled !== false; atomic(stateFile, state); };
  // Claim the attempt before network access: repeated host restarts cannot spam the source.
  state.nextCheck = now + 15 * 60000; saveState();
  const abort = new AbortController(), started = Date.now();
  const cancellation = setInterval(() => { if (fs.existsSync(path.join(dir, 'cancel')) || Date.now() - started > 300000) abort.abort(); }, 250);
  cancellation.unref();
  const fetch = (url, options) => { if (abort.signal.aborted) fail('update-cancelled'); return transport(url, { ...options, proxy, signal: abort.signal }); };
  try {
    const current = registration(root);
    const releaseBytes = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { limit: META_LIMIT });
    const release = JSON.parse(releaseBytes.toString());
    if (release.draft || release.prerelease || !/^v\d+\.\d+\.\d+$/.test(release.tag_name)) fail('wrong-release-channel');
    const newer = compare(release.tag_name.slice(1), current.reg.version);
    if (newer < 0) fail('older-release');
    if (newer === 0) {
      const meta = asset(release, 'Windows-update.json');
      if (meta.size > META_LIMIT) fail('metadata-too-large');
      const same = await fetch(meta.browser_download_url, { limit: META_LIMIT });
      if (same.length !== meta.size || 'sha256:' + hash(same) !== meta.digest) fail('metadata-digest-mismatch');
      const build = JSON.parse(same.toString());
      if (build.schema !== 1 || build.product !== 'FlowSwitch' || build.platform !== 'windows' || build.arch !== 'x64' || build.channel !== 'stable' || build.version !== current.reg.version || build.build !== current.reg.build || build.manifestSha256 !== current.reg.manifestSha256) fail('same-version-build-mismatch');
      state.failures = 0; state.nextCheck = now + 86400000; saveState();
      return { phase: 'current', version: current.reg.version };
    }
    const metadata = asset(release, 'Windows-update.json');
    if (metadata.size > META_LIMIT) fail('metadata-too-large');
    const bytes = await fetch(metadata.browser_download_url, { limit: META_LIMIT });
    if (bytes.length !== metadata.size || 'sha256:' + hash(bytes) !== metadata.digest) fail('metadata-digest-mismatch');
    const target = JSON.parse(bytes.toString('utf8'));
    const bundle = validateTarget(target, release, current), plan = localPlan(root, current, target);
    let result = { phase: 'consent-required', version: target.version, downloadBytes: plan.downloadBytes };
    if (plan.downloadBytes <= LIMIT || allowLarge) {
      const stage = path.join(dir, 'stage-' + target.version + '-' + target.build.slice(0, 16));
      fs.mkdirSync(stage, { recursive: true });
      let received = 0;
      for (const f of plan.changes) {
        const dest = safePath(stage, f.path);
        if (fs.existsSync(dest) && hash(fs.readFileSync(dest)) === f.sha256) continue;
        const compressed = f.length ? await fetch(bundle.browser_download_url, { limit: f.length, range: { start: f.start, end: f.start + f.length - 1, total: bundle.size } }) : Buffer.alloc(0);
        received += compressed.length;
        const value = f.method === 8 ? zlib.inflateRawSync(compressed, { maxOutputLength: f.bytes + 1 }) : compressed;
        if (value.length !== f.bytes || hash(value) !== f.sha256) fail('file-digest-mismatch');
        fs.mkdirSync(path.dirname(dest), { recursive: true }); fs.writeFileSync(dest, value);
      }
      const stagedReg = json(path.join(stage, 'update-install.json'));
      if (stagedReg.schema !== 1 || stagedReg.product !== 'FlowSwitch' || stagedReg.platform !== 'windows' || stagedReg.arch !== 'x64' || stagedReg.channel !== 'stable' || stagedReg.version !== target.version || stagedReg.build !== target.build || stagedReg.manifestSha256 !== target.manifestSha256 || hash(fs.readFileSync(path.join(stage, 'manifest.json'))) !== target.manifestSha256) fail('staged-binding-mismatch');
      const targetFiles = entries(json(path.join(stage, 'manifest.json')));
      if (targetFiles.length !== current.files.length || targetFiles.some(f => !target.files.some(t => t.path === f.path && t.bytes === f.bytes && t.sha256 === f.sha256))) fail('inner-manifest-mismatch');
      const ticket = { schema: 1, root: path.resolve(root), stage, data: path.resolve(data), from: current.reg, target: stagedReg, changes: plan.changes, targetFiles };
      atomic(path.join(stage, 'candidate.json'), ticket);
      result = { phase: 'staged', version: target.version, downloadBytes: plan.downloadBytes, receivedBytes: received, candidate: path.join(stage, 'candidate.json') };
      atomic(path.join(dir, 'ready.json'), result);
    }
    state.failures = 0; state.nextCheck = now + 86400000; saveState(); return result;
  } catch (error) {
    state.failures = Math.min((state.failures || 0) + 1, 8); state.nextCheck = now + Math.min(86400000, 900000 * 2 ** (state.failures - 1)); saveState();
    return { phase: 'failed', reason: /^[a-z0-9-]+$/.test(error.message) ? error.message : 'update-check-failed', nextCheck: state.nextCheck };
  } finally { clearInterval(cancellation); }
}
module.exports = { hash, atomic, json, version, compare, safePath, entries, registration, allowedURL, request, asset, validateTarget, localPlan, check, LIMIT };
if (require.main === module) {
  const args = process.argv.slice(2); const input = {};
  for (let i = 0; i < args.length; i += 2) { if (!['--root', '--data', '--manual', '--allow-large'].includes(args[i])) fail('invalid-option'); input[args[i].slice(2).replace('allow-large', 'allowLarge')] = args[i + 1]; }
  input.manual = input.manual === 'true'; input.allowLarge = input.allowLarge === 'true'; input.proxy = process.env.FLOWSWITCH_UPDATE_PROXY || '';
  if (!input.root || !input.data) fail('missing-path');
  check(input).then(value => process.stdout.write(JSON.stringify(value)), () => { process.stdout.write(JSON.stringify({ phase: 'failed', reason: 'update-worker-failed' })); process.exitCode = 1; });
}
