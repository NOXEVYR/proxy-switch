'use strict';
// Real curl, loopback-only delayed CONNECT/TLS fixtures. Never contacts a user
// proxy, alters trust stores, starts a core, or writes Windows proxy settings.
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const http=require('node:http'),https=require('node:https'),net=require('node:net');
const {spawn}=require('node:child_process'),assert=require('node:assert/strict');
const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'FlowSwitch-ProbeBudget-'));
const previous={};for(const name of ['CURL_HOME','PROXY_SWITCH_DATA_DIR','PROXY_SWITCH_TEST_HEALTH_URL'])previous[name]=process.env[name];
process.env.PROXY_SWITCH_DATA_DIR=path.join(scratch,'data');
const fixture=path.join(__dirname,'test-fixtures/web-transport');
// curl's private configuration trusts only the existing disposable test CA.
// CURL_HOME is inherited only by these test children; no trust store is changed.
fs.writeFileSync(path.join(scratch,'.curlrc'),'cacert = "'+path.join(fixture,'localhost-cert.pem').replace(/\\/g,'/')+'"\n');
process.env.CURL_HOME=scratch;
const router=require('./IndependentRouter.cjs'),sockets=new Set(),servers=[],timers=new Set();
let checks=0,originPort;
const check=(value,message)=>{assert.ok(value,message);checks++;console.log('PASS: '+message);};
function track(socket){sockets.add(socket);socket.on('close',()=>sockets.delete(socket));socket.on('error',()=>{});return socket;}
function later(action,ms){const timer=setTimeout(()=>{timers.delete(timer);action();},ms);timers.add(timer);return timer;}
async function listen(server){servers.push(server);server.on('connection',track);await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));return server.address().port;}
async function proxy(name){
 const server=http.createServer((req,res)=>{res.writeHead(405);res.end();});
 server.on('connect',(req,client,head)=>{
  if(req.url!=='localhost:'+originPort){client.end('HTTP/1.1 403 Forbidden\r\n\r\n');return;}
  if(name==='proxyAuth'){client.end('HTTP/1.1 407 Proxy Authentication Required\r\n\r\n');return;}
  if(name==='tlsFailure'){client.write('HTTP/1.1 200 Connection Established\r\n\r\n');client.end('This deliberately is not a TLS record.\r\n');return;}
  if(name==='stallConnect')return;
  const connect=()=>{
   if(client.destroyed)return;
   const remote=track(net.connect(originPort,'127.0.0.1',()=>{
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n');if(head.length)remote.write(head);
    remote.pipe(client);client.pipe(remote);
   }));
   client.on('close',()=>remote.destroy());remote.on('close',()=>client.destroy());
  };
  if(name==='slow')later(connect,4300);else connect();
 });
 return {Name:name,Port:await listen(server)};
}
function powershell(file){return new Promise((resolve,reject)=>{
 const exe=path.join(process.env.SystemRoot||'C:\\Windows','System32/WindowsPowerShell/v1.0/powershell.exe');
 const child=spawn(exe,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'Test-ProxyProbeBudget.ps1'),'-FixturePath',file],{windowsHide:true,env:{...process.env},stdio:['ignore','pipe','pipe']});
 let output='',errors='';child.stdout.on('data',c=>{output+=c;process.stdout.write(c);});child.stderr.on('data',c=>errors+=c);
 child.on('error',reject);child.on('exit',code=>code===0?resolve(output):reject(Error('PowerShell probe-budget exit '+code+': '+errors)));
 });}
async function routerChecks(cases){
 const options={Profiles:cases.map(c=>({Id:c.Name,Protocol:'http',Host:'127.0.0.1',Port:c.Port})),Routing:{Failover:{Enabled:true,Order:['slow','rejected'],AllowDirect:false}}};
 for(const name of ['slow','late','rejected','unauthenticated','proxyAuth','stallConnect','stallTotal']){
  const route=name==='late'?'/late':name==='rejected'?'/403':name==='unauthenticated'?'/401':name==='stallTotal'?'/stall':'/204';
  process.env.PROXY_SWITCH_TEST_HEALTH_URL='https://localhost:'+originPort+route;
  const started=Date.now(),result=await router.healthCheck(name,options),seconds=(Date.now()-started)/1000;
  if(name==='slow'||name==='late'){
   check(result.healthy===true&&result.reason==='probe-ok',name+': supervisor accepts delayed verified TLS ('+seconds.toFixed(2)+'s)');
   check(seconds>=(name==='slow'?4:7.5)&&seconds<11.5,name+': inner curl and outer execFile permit the intended budget');
  }else{
   check(result.healthy===false,name+': supervisor does not mark a refusal or silent endpoint healthy ('+seconds.toFixed(2)+'s)');
   if(name.startsWith('stall'))check(result.reason==='probe-timeout'&&seconds>=5&&seconds<13,name+': actual curl timeout remains bounded and classified as failure');
  }
 }
 check(router.decide({current:'slow',failures:0,changed:0},['slow','rejected'],{slow:true,rejected:false},Date.now(),router.policy(options)).current==='slow','A slow healthy active route does not trigger failover');
 check(router.decide({current:'rejected',failures:0,changed:0},['slow','rejected'],{slow:true,rejected:true},Date.now(),router.policy(options)).current==='rejected','Recovered preferred route never resets a healthy current backup');
 check((await router.healthCheck('missing',options)).healthy===null,'Missing probe profile remains unknown');
}
async function main(){
 originPort=await listen(https.createServer({key:fs.readFileSync(path.join(fixture,'localhost-test-key.pem')),cert:fs.readFileSync(path.join(fixture,'localhost-cert.pem'))},(req,res)=>{
  if(req.url==='/stall')return;
  const reply=()=>{if(res.destroyed)return;res.writeHead(req.url==='/401'?401:req.url==='/403'?403:204);res.end();};
  if(req.url==='/late')later(reply,9000);else reply();
 }));
 const cases=[];for(const name of ['slow','late','early','rejected','unauthenticated','proxyAuth','tlsFailure','stallConnect','stallTotal'])cases.push(await proxy(name));
 const file=path.join(scratch,'fixtures.json');fs.writeFileSync(file,JSON.stringify({OriginPort:originPort,Cases:cases}));
 // Both production call paths use these same local fixtures and real curl.
 const results=await Promise.allSettled([routerChecks(cases),powershell(file)]);
 for(const result of results)if(result.status==='rejected')throw result.reason;
 console.log('PASS: '+checks+' supervisor probe-budget assertions');
}
main().catch(error=>{console.error(error);process.exitCode=1;}).finally(async()=>{
 for(const timer of timers)clearTimeout(timer);
 for(const socket of sockets)socket.destroy();
 await Promise.all(servers.map(server=>new Promise(resolve=>server.close(resolve))));
 for(const [name,value] of Object.entries(previous)){if(value===undefined)delete process.env[name];else process.env[name]=value;}
 fs.rmSync(scratch,{recursive:true,force:true});
});
