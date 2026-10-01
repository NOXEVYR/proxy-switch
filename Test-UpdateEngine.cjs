'use strict';
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const zlib = require('node:zlib');
const e = require('./UpdateEngine.cjs'), { build } = require('./Build-UpdateManifest.cjs');
const REPO = 'https://github.com/NOXEVYR/proxy-switch/releases/download/';
function crc(b) { let c = -1; for (const byte of b) { c ^= byte; for (let i = 0; i < 8; i++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1)); } return (c ^ -1) >>> 0; }
function zipDirectory(root, dest) {
  const locals = [], central = []; let offset = 0;
  function walk(dir, prefix = '') { for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
    const rel = prefix + item.name; if (item.isDirectory()) { walk(path.join(dir, item.name), rel + '/'); continue; }
    const raw = fs.readFileSync(path.join(dir, item.name)), name = Buffer.from('FlowSwitch/' + rel), value = zlib.deflateRawSync(raw);
    const h = Buffer.alloc(30); h.writeUInt32LE(0x04034b50); h.writeUInt16LE(20, 4); h.writeUInt16LE(0x800, 6); h.writeUInt16LE(8, 8); h.writeUInt32LE(crc(raw), 14); h.writeUInt32LE(value.length, 18); h.writeUInt32LE(raw.length, 22); h.writeUInt16LE(name.length, 26);
    const c = Buffer.alloc(46); c.writeUInt32LE(0x02014b50); c.writeUInt16LE(20, 4); c.writeUInt16LE(20, 6); h.copy(c, 8, 6, 28); c.writeUInt32LE(offset, 42);
    locals.push(h, name, value); central.push(c, name); offset += h.length + name.length + value.length;
  } }
  walk(root); const size = central.reduce((s, b) => s + b.length, 0), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(central.length / 2, 8); end.writeUInt16LE(central.length / 2, 10); end.writeUInt32LE(size, 12); end.writeUInt32LE(offset, 16);
  fs.writeFileSync(dest, Buffer.concat([...locals, ...central, end]));
}
function writePackage(root, ver, extra = {}) {
  fs.mkdirSync(path.join(root, 'app/runtime'), { recursive: true });
  const files = { 'FlowSwitch.exe': 'fixture-exe-' + ver, 'app/Preferences.ps1': "$script:ProductVersion='" + ver + "'", 'app/runtime/node.exe': 'immutable-runtime', '使用说明.txt': '流向 FlowSwitch ' + ver, ...extra };
  const manifest = [];
  for (const [rel, value] of Object.entries(files)) { const b = Buffer.from(value); fs.writeFileSync(path.join(root, rel), b); manifest.push({ path: rel, bytes: b.length, sha256: e.hash(b) }); }
  const bytes = Buffer.from(JSON.stringify(manifest)); fs.writeFileSync(path.join(root, 'manifest.json'), bytes);
  e.atomic(path.join(root, 'update-install.json'), { schema: 1, product: 'FlowSwitch', platform: 'windows', arch: 'x64', channel: 'stable', version: ver, build: e.hash(bytes), manifestSha256: e.hash(bytes) });
}
function fixture(base, oldVersion = '3.9.4', newVersion = '3.9.5') {
  const dir = fs.mkdtempSync(path.join(base, 'case-')), root = path.join(dir, 'installed'), target = path.join(dir, 'target'), data = path.join(dir, 'data');
  writePackage(root, oldVersion); writePackage(target, newVersion);
  const archive = path.join(dir, `FlowSwitch-v${newVersion}-Windows-x64.zip`); zipDirectory(target, archive);
  const meta = path.join(dir, 'Windows-update.json'); const manifest = build(archive, target, meta), tag = 'v' + newVersion;
  const release = { tag_name: tag, draft: false, prerelease: false, assets: [] };
  function rebind() { fs.writeFileSync(meta, JSON.stringify(manifest)); release.assets = [archive, meta].map(file => ({ name: path.basename(file), state: 'uploaded', size: fs.statSync(file).size, digest: 'sha256:' + e.hash(fs.readFileSync(file)), browser_download_url: REPO + tag + '/' + path.basename(file) })); }
  rebind(); const calls = [];
  async function transport(url, options) {
    calls.push({ url, ...options });
    if (url.endsWith('/latest')) return Buffer.from(JSON.stringify(release));
    if (url.endsWith('Windows-update.json')) return fs.readFileSync(meta);
    assert(options.range, 'ZIP may only be downloaded with a byte range');
    const bytes = fs.readFileSync(archive); return bytes.subarray(options.range.start, options.range.end + 1);
  }
  return { dir, root, target, data, archive, manifest, release, meta, rebind, calls, transport };
}
async function run() {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'FlowSwitch-update-engine-')); let checks = 0;
  const check = (v, m) => { assert(v, m); checks++; };
  let f = fixture(base); let result = await e.check({ ...f, manual: true });
  check(result.phase === 'staged', 'small differential update stages');
  const candidate = e.json(result.candidate);
  check(candidate.changes.length === 5 && !candidate.changes.some(x => x.path.startsWith('app/runtime/')), 'runtime reused, metadata staged');
  check(f.calls.filter(c => c.range).length === 5, 'only changed compressed file ranges fetched');
  check(e.registration(f.root).reg.version === '3.9.4', 'staging never modifies installation');
  const count = f.calls.length; check((await e.check(f)).phase === 'throttled' && f.calls.length === count, 'cross-process persisted throttle');
  check((await e.check({ ...f, manual: true })).receivedBytes === 0, 'verified staged bytes reused');
  for (const [name, mutate, reason] of [
    ['channel', x => { x.release.prerelease = true; }, 'wrong-release-channel'],
    ['arch', x => { x.manifest.arch = 'arm64'; x.rebind(); }, 'incompatible-manifest'],
    ['path', x => { x.manifest.files[0].path = '../config.json'; x.rebind(); }, 'unsafe-path'],
    ['duplicate', x => { x.manifest.files.push(x.manifest.files[0]); x.rebind(); }, 'invalid-file-entry'],
    ['range', x => { x.manifest.files[0].start = -1; x.rebind(); }, 'invalid-range'],
    ['runtime', x => { x.manifest.files.find(a => a.path === 'app/runtime/node.exe').sha256 = 'a'.repeat(64); x.rebind(); }, 'runtime-requires-full-package'],
    ['local-edit', x => fs.writeFileSync(path.join(x.root, 'FlowSwitch.exe'), 'user-changed'), 'locally-modified-program'],
    ['remote-digest', x => fs.appendFileSync(x.meta, ' '), 'metadata-digest-mismatch'],
    ['file-digest', x => { x.manifest.files[0].sha256 = 'b'.repeat(64); x.rebind(); }, 'file-digest-mismatch'],
    ['unregistered-file', x => { x.manifest.files[0].path = 'user-config.json'; x.rebind(); }, 'file-layout-requires-full-package']
  ]) {
    f = fixture(base); mutate(f); result = await e.check({ ...f, manual: true }); check(result.reason === reason, name + ': ' + JSON.stringify(result));
  }
  f = fixture(base); result = await e.check({ ...f, manual: true, transport: async () => { throw Error('network-unavailable'); }, now: 1000 });
  const first = e.json(path.join(f.data, 'updates/background.json')); check(first.failures === 1 && first.nextCheck === 901000, 'first failure backs off');
  await e.check({ ...f, manual: true, transport: async () => { throw Error('network-unavailable'); }, now: 2000 });
  check(e.json(path.join(f.data, 'updates/background.json')).nextCheck === 1802000, 'backoff persists across calls');
  e.atomic(path.join(f.data, 'updates/background.json'), { enabled: false }); check((await e.check(f)).phase === 'throttled', 'automatic disabled persists');
  f = fixture(base); const toggleTransport=f.transport;
  await e.check({...f, manual:true, transport:async (url, opts)=>{ e.atomic(path.join(f.data, 'updates/background.json'), {enabled:false}); return toggleTransport(url,opts); }});
  check(e.json(path.join(f.data, 'updates/background.json')).enabled === false, 'disable during check survives worker completion');
  f = fixture(base, '3.9.5', '3.9.5'); check((await e.check({ ...f, manual: true })).phase === 'current', 'same release build matches');
  f.manifest.build = 'c'.repeat(64); f.rebind(); check((await e.check({ ...f, manual: true })).reason === 'same-version-build-mismatch', 'same version replacement is not silently current');
  f = fixture(base, '3.9.6', '3.9.5'); check((await e.check({ ...f, manual: true })).reason === 'older-release', 'no downgrade');
  f = fixture(base); const oldTransport = f.transport;
  result = await e.check({ ...f, manual: true, transport: (url, options) => options.range ? Promise.reject(Error('range-not-supported')) : oldTransport(url, options) });
  check(result.reason === 'range-not-supported', 'no fallback when range is unavailable');
  // Signed metadata can advertise a large changed compressed range; do not fetch it without consent.
  f = fixture(base); f.manifest.archive.bytes = e.LIMIT * 2; const archiveAsset = f.release.assets[0];
  f.manifest.files[0].length = e.LIMIT + 1; f.manifest.files[0].start = 0;
  fs.writeFileSync(f.meta, JSON.stringify(f.manifest)); f.release.assets[1].size = fs.statSync(f.meta).size; f.release.assets[1].digest = 'sha256:' + e.hash(fs.readFileSync(f.meta)); archiveAsset.size = e.LIMIT * 2;
  result = await e.check({ ...f, manual: true }); check(result.phase === 'consent-required' && !f.calls.some(c => c.range), 'over 50 MiB cannot start background transfer');
  for (const p of ['../x', '/x', 'app/../x', 'app/x:ads', 'app/CON.txt', 'app/x.', 'app//x', 'app\\x']) assert.throws(() => e.safePath(base, p)); checks++;
  assert.throws(() => e.allowedURL('https://evil.example/a')); assert.throws(() => e.allowedURL('http://github.com/a')); checks++;
  console.log(`PASS: ${checks} updater discovery/staging checks; no real network or installation writes. Fixtures: ${base}`);
}
module.exports = { crc, zipDirectory, writePackage, fixture };
if (require.main === module) {
  if (process.argv[2] === '--fixture') { const base = fs.mkdtempSync(path.join(os.tmpdir(), 'FlowSwitch-update-install-')); const f = fixture(base); e.check({ ...f, manual: true }).then(r => { if (r.phase !== 'staged') throw Error(r.reason); console.log(r.candidate); }).catch(e => { console.error(e); process.exitCode = 1; }); }
  else run().catch(e => { console.error(e); process.exitCode = 1; });
}
