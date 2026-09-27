'use strict';
// Loopback-only HTTPS POST/stream/error transport acceptance. No account or live website.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const http=require('node:http'),https=require('node:https'),net=require('node:net'),tls=require('node:tls'),assert=require('node:assert/strict');
const supplied=process.argv[2];
if(!supplied||!path.isAbsolute(supplied)||!fs.existsSync(supplied))throw Error('Pass the pinned core executable');
const data=fs.mkdtempSync(path.join(os.tmpdir(),'FlowSwitch-WebTransport-'));
process.env.PROXY_SWITCH_DATA_DIR=data;
const core=path.join(data,'FlowSwitch-TestEngine.exe');fs.copyFileSync(supplied,core);
const router=require('./IndependentRouter.cjs'),sockets=new Set(),servers=[];
const fixture=path.join(__dirname,'test-fixtures/web-transport');
const cert=fs.readFileSync(path.join(fixture,'localhost-cert.pem'));
const key=fs.readFileSync(path.join(fixture,'localhost-test-key.pem'));
const payload=JSON.stringify({message:'isolated unicode fixture \u6d4b\u8bd5',padding:'x'.repeat(8192)});
let checks=0,received=0,originPort;
const check=(value,message)=>{assert.ok(value,message);checks++;console.log('PASS: '+message);};
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function track(socket){sockets.add(socket);socket.on('close',()=>sockets.delete(socket));socket.on('error',()=>{});return socket;}
async function listen(server){servers.push(server);server.on('connection',track);await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));return server.address().port;}
async function proxy(){
 const record={connects:0,port:0};
 const server=http.createServer((req,res)=>{res.writeHead(405);res.end();});
 server.on('connect',(req,client,head)=>{
  // Refuse all destinations except this test's own TLS origin.
  if(req.url!=='localhost:'+originPort&&req.url!=='127.0.0.1:'+originPort){client.end('HTTP/1.1 403 Forbidden\r\n\r\n');return;}
  record.connects++;
  const remote=track(net.connect(originPort,'127.0.0.1',()=>{
   client.write('HTTP/1.1 200 Connection Established\r\n\r\n');if(head.length)remote.write(head);
   remote.pipe(client);client.pipe(remote);
  }));
  client.on('close',()=>remote.destroy());remote.on('close',()=>client.destroy());
 });
 record.port=await listen(server);return record;
}
async function tunnel(port){
 const socket=track(net.connect(port,'127.0.0.1'));
 socket.setTimeout(8000,()=>socket.destroy(Error('isolated tunnel timeout')));
 await new Promise((resolve,reject)=>{
  let buffer=Buffer.alloc(0);
  const onError=e=>reject(e);
  const onData=chunk=>{buffer=Buffer.concat([buffer,chunk]);const end=buffer.indexOf('\r\n\r\n');if(end<0)return;
   socket.removeListener('data',onData);socket.removeListener('error',onError);
   if(!buffer.subarray(0,end).toString().startsWith('HTTP/1.1 200'))return reject(Error('CONNECT not ready'));
   if(buffer.length>end+4)socket.unshift(buffer.subarray(end+4));resolve();
  };
  socket.on('data',onData);socket.once('error',onError);
  socket.once('connect',()=>socket.write('CONNECT localhost:'+originPort+' HTTP/1.1\r\nHost: localhost:'+originPort+'\r\n\r\n'));
 });
 const secure=track(tls.connect({socket,servername:'localhost',ca:cert}));
 await new Promise((resolve,reject)=>{secure.once('secureConnect',resolve);secure.once('error',reject);});
 assert.equal(secure.authorized,true);return secure;
}
async function request(port,route,abort=false){
 const socket=await tunnel(port);let first=0;const started=Date.now(),chunks=[];
 return new Promise((resolve,reject)=>{
  const finish=()=>resolve({raw:Buffer.concat(chunks).toString(),first,elapsed:Date.now()-started});
  socket.on('data',chunk=>{chunks.push(chunk);if(Buffer.concat(chunks).includes(Buffer.from('data: first'))&&!first){first=Date.now()-started;if(abort){socket.destroy();finish();}}});
  socket.once('end',finish);socket.once('error',reject);
  socket.write('POST '+route+' HTTP/1.1\r\nHost: localhost:'+originPort+'\r\nContent-Type: application/json\r\nContent-Length: '+Buffer.byteLength(payload)+'\r\nConnection: close\r\n\r\n'+payload);
 });
}
async function main(){
 originPort=await listen(https.createServer({key,cert},(req,res)=>{
  const body=[];req.on('data',chunk=>body.push(chunk));req.on('end',()=>{
   if(req.method!=='POST'||Buffer.concat(body).toString()!==payload){res.writeHead(400);res.end('fixture body mismatch');return;}
   received++;
   const code=Number(req.url.slice(1));
   if([403,429,500].includes(code)){res.writeHead(code,{'Content-Type':'application/json'});res.end(JSON.stringify({fixtureStatus:code}));return;}
   res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-cache'});res.write('data: first\n\n');
   const middle=setTimeout(()=>res.write('data: second\n\n'),180);
   const end=setTimeout(()=>res.end('data: done\n\n'),400);
   res.on('close',()=>{clearTimeout(middle);clearTimeout(end);});
  });
 }));
 const a=await proxy(),b=await proxy();const reserve=net.createServer();await new Promise(resolve=>reserve.listen(0,'127.0.0.1',resolve));const port=reserve.address().port;await new Promise(resolve=>reserve.close(resolve));
 const config={Version:3,Profiles:[{Id:'gateway',Name:'own',Protocol:'http',Host:'127.0.0.1',Port:port,CorePath:core},{Id:'a',Name:'A',Protocol:'http',Host:'127.0.0.1',Port:a.port},{Id:'b',Name:'B',Protocol:'http',Host:'127.0.0.1',Port:b.port}],Routing:{Adapter:'standalone',ProfileId:'gateway',UnifiedMode:'gateway',Failover:{Enabled:false,Order:[],AllowDirect:false}}};
 fs.writeFileSync(path.join(data,'config.json'),JSON.stringify(config));fs.writeFileSync(path.join(data,'app-rules.json'),JSON.stringify({version:3,installed:true,entries:[],defaultRoute:'a',programIngresses:[],siteRules:[]}));
 await router.start();
 const firstCore=JSON.parse(fs.readFileSync(path.join(router.ROOT,'process.json'))).core;
 const first=await request(port,'/stream');
 check(first.raw.startsWith('HTTP/1.1 200')&&first.raw.includes('data: first')&&first.raw.includes('data: second')&&first.raw.includes('data: done'),'HTTPS POST preserves Unicode and 8 KiB body through CONNECT and actual core');
 check(first.first<first.elapsed-200,'Streaming first segment arrives before completion instead of being buffered until end');
 check(a.connects===1&&b.connects===0,'First HTTPS stream uses selected A');
 await router.replace([],'b');const second=await request(port,'/stream');
 check(second.raw.includes('data: done')&&b.connects===1&&a.connects===1,'New HTTPS stream moves to B after switching behind the same ingress');
 for(const code of [403,429,500]){const result=await request(port,'/'+code);check(result.raw.startsWith('HTTP/1.1 '+code)&&result.raw.includes('"fixtureStatus":'+code),'Target HTTP '+code+' remains a target response, not a fabricated transport success');}
 await request(port,'/stream',true);const retry=await request(port,'/stream');
 check(retry.raw.includes('data: done'),'Cancelling one streaming request leaves the next request usable');
 check(received===7&&JSON.parse(fs.readFileSync(path.join(router.ROOT,'process.json'))).core===firstCore,'All seven POST bodies arrive intact without restarting the core');
}
async function cleanup(){
 try{
  await router.main({action:'stop'});
  const deadline=Date.now()+16000;while(fs.existsSync(path.join(router.ROOT,'supervisor.lock'))&&Date.now()<deadline)await delay(100);
  assert.ok(!fs.existsSync(path.join(router.ROOT,'supervisor.lock')),'Own supervisor must exit');
 }finally{
  for(const socket of sockets)socket.destroy();
  await Promise.all(servers.map(server=>new Promise(resolve=>server.close(resolve))));
 }
 check(true,'Owned supervisor, TLS sockets and loopback servers released');
}
(async()=>{try{await main();}finally{await cleanup();}console.log('PASS: '+checks+' real HTTPS/POST/stream/error transport checks. No browser account or live login tested.');})().catch(error=>{console.error(error.stack);process.exitCode=1;});
