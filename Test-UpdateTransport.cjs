'use strict';
const assert = require('node:assert/strict'), fs = require('node:fs'), https = require('node:https'), http = require('node:http'), tls = require('node:tls'), net = require('node:net');
const { request } = require('./UpdateEngine.cjs');
async function main() {
  const cert = fs.readFileSync(__dirname + '/test-fixtures/web-transport/localhost-cert.pem'), key = fs.readFileSync(__dirname + '/test-fixtures/web-transport/localhost-test-key.pem');
  let mode = 'range', calls = 0, tunnels = 0;
  const server = https.createServer({ cert, key }, (req, res) => {
    calls++;
    if (mode === 'range') { assert.equal(req.headers.range, 'bytes=2-4'); res.writeHead(206, { 'Content-Range': 'bytes 2-4/8', 'Content-Length': '3' }); res.end('234'); }
    else if (mode === 'whole') { res.writeHead(200, { 'Content-Length': '70000000' }); res.flushHeaders(); }
    else if (mode === 'wrong-range') { res.writeHead(206, { 'Content-Range': 'bytes 1-3/8' }); res.end('123'); }
    else if (mode === 'oversize') { res.writeHead(200, { 'Content-Length': '9000' }); res.flushHeaders(); }
    else if (mode === 'rate') { res.writeHead(429); res.end(); }
    else if (mode === 'redirect') { res.writeHead(302, { Location: 'https://evil.example/update' }); res.end(); }
    else if (mode === 'wait') { res.writeHead(200); res.flushHeaders(); }
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const proxy = http.createServer(); const sockets = new Set();
  proxy.on('connect', (req, socket) => { tunnels++; assert.equal(req.url, 'github.com:443'); const target = net.connect(server.address().port, '127.0.0.1', () => { socket.write('HTTP/1.1 200 Connection established\r\n\r\n'); socket.pipe(target); target.pipe(socket); }); sockets.add(socket); sockets.add(target); socket.on('error', () => target.destroy()); target.on('error', () => socket.destroy()); });
  await new Promise(r => proxy.listen(0, '127.0.0.1', r));
  const originalRequest = https.request, originalTLS = tls.connect;
  // Test-only socket redirection; production URLs and TLS verification remain enforced.
  https.request = (options, callback) => originalRequest({ ...options, hostname: '127.0.0.1', port: server.address().port, ca: cert, servername: 'localhost' }, callback);
  tls.connect = options => originalTLS({ ...options, ca: cert, servername: 'localhost' });
  const url = 'https://github.com/NOXEVYR/proxy-switch/releases/download/v3.9.5/a.zip', range = { start: 2, end: 4, total: 8 }; let checks = 0;
  try {
    assert.equal((await request(url, { limit: 3, range })).toString(), '234'); checks++;
    assert.equal((await request(url, { limit: 3, range, proxy: 'http://127.0.0.1:' + proxy.address().port })).toString(), '234'); assert.equal(tunnels, 1); checks++;
    for (const [next, code, options] of [['whole', 'range-not-supported', { limit: 3, range }], ['wrong-range', 'invalid-content-range', { limit: 3, range }], ['oversize', 'download-limit', { limit: 20 }], ['rate', 'http-429', { limit: 20 }], ['redirect', 'untrusted-update-source', { limit: 20 }]]) { mode = next; const before = calls; await assert.rejects(request(url, options), new RegExp(code)); assert.equal(calls, before + 1); checks++; }
    mode = 'wait'; const controller = new AbortController(); const pending = request(url, { limit: 20, signal: controller.signal }); setTimeout(() => controller.abort(), 100); await assert.rejects(pending, /update-cancelled/); checks++;
    console.log(`PASS: ${checks} real local TLS/CONNECT/range/cancellation checks.`);
  } finally { https.request = originalRequest; tls.connect = originalTLS; for (const socket of sockets) socket.destroy(); server.closeAllConnections(); proxy.closeAllConnections(); await Promise.all([new Promise(r => server.close(r)), new Promise(r => proxy.close(r))]); }
}
main().catch(e => { console.error(e); process.exitCode = 1; });
