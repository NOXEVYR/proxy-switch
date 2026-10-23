'use strict';
// Owned loopback processes only. No external network, user config or Windows writes.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const https = require('node:https');
const net = require('node:net');
const {spawn} = require('node:child_process');
if (process.argv[2] === '--owned-proxy') {
  const sockets = new Set();
  const server = net.createServer(socket => {
    sockets.add(socket); socket.on('error', () => {}); socket.on('close', () => sockets.delete(socket));
    let input = '';
    socket.on('data', function request(chunk) {
      input += chunk.toString();
      if (!input.includes('\r\n\r\n')) return;
      socket.removeListener('data', request);
      if (process.argv[3] === 'silent') return;
      // Never resolve or forward a requested host. The only destination is our own TLS fixture.
      if (!input.startsWith('CONNECT localhost:' + process.argv[4] + ' HTTP/1.1\r\n')) {
        socket.end('HTTP/1.1 403 Forbidden\r\n\r\n'); return;
      }
      const upstream = net.connect(Number(process.argv[4]), '127.0.0.1', () => {
        socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        socket.pipe(upstream); upstream.pipe(socket);
      });
      upstream.on('error', () => socket.destroy()); socket.on('close', () => upstream.destroy());
    });
  });
  server.listen(0, '127.0.0.1', () => process.send({port:server.address().port}));
  return;
}
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'FlowSwitch-RecoveryTransport-'));
const children = new Set();
const sockets = new Set();
const certRoot = path.join(__dirname, 'test-fixtures/web-transport');
const origin = https.createServer({key:fs.readFileSync(path.join(certRoot,'localhost-test-key.pem')),cert:fs.readFileSync(path.join(certRoot,'localhost-cert.pem'))}, (req,res) => {res.writeHead(204);res.end();});
origin.on('connection', socket => {sockets.add(socket);socket.on('close',()=>sockets.delete(socket));socket.on('error',()=>{});});
async function fixture(mode, port) {
  const child = spawn(process.execPath, [__filename,'--owned-proxy',mode,String(port)], {windowsHide:true,stdio:['ignore','ignore','pipe','ipc']});
  children.add(child);child.on('exit',()=>children.delete(child));
  const info = await new Promise((resolve,reject) => {child.once('message',resolve);child.once('error',reject);child.once('exit',code=>reject(new Error('Owned fixture exited '+code)));});
  return {child,port:info.port};
}
async function main() {
  await new Promise(resolve=>origin.listen(0,'127.0.0.1',resolve));
  const originPort=origin.address().port;
  const healthy=await fixture('healthy',originPort),silent=await fixture('silent',originPort),terminated=await fixture('healthy',originPort);
  const stopped=new Promise(resolve=>terminated.child.once('exit',resolve));terminated.child.kill();await stopped;
  const file=path.join(scratch,'fixture.json');
  fs.writeFileSync(file,JSON.stringify({OriginPort:originPort,Cases:[{Name:'healthy',Port:healthy.port},{Name:'silent',Port:silent.port},{Name:'terminated',Port:terminated.port}]}));
  const exe=path.join(process.env.SystemRoot || 'C:\\Windows','System32/WindowsPowerShell/v1.0/powershell.exe');
  const child=spawn(exe,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'Test-NetworkRecovery.ps1'),'-FixturePath',file],{windowsHide:true,stdio:['ignore','pipe','pipe']});
  children.add(child);let errors='';child.stdout.on('data',chunk=>process.stdout.write(chunk));child.stderr.on('data',chunk=>{errors+=chunk;});
  const code=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve);});children.delete(child);
  if(code!==0)throw Error('Recovery transport test failed ('+code+'): '+errors);
  console.log('PASS: owned loopback healthy, accepted-without-forwarding and force-terminated fixtures.');
}
main().catch(error=>{console.error(error);process.exitCode=1;}).finally(async()=>{
  for(const child of children)child.kill();
  for(const socket of sockets)socket.destroy();
  await new Promise(resolve=>origin.close(resolve));
  const resolved=path.resolve(scratch),root=path.resolve(os.tmpdir())+path.sep;
  if(resolved.startsWith(root)&&path.basename(resolved).startsWith('FlowSwitch-RecoveryTransport-'))fs.rmSync(resolved,{recursive:true,force:true});
});
