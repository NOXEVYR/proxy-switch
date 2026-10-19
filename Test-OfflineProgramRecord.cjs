'use strict';
// Real Windows Node -> PowerShell lock handoff, against private temporary data.
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),crypto=require('node:crypto');
const net=require('node:net'),{execFileSync}=require('node:child_process');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'FlowSwitch-offline-record-locks-'));
process.env.PROXY_SWITCH_DATA_DIR=root;delete process.env.PROXY_SWITCH_PROFILES;
const r=require('./IndependentRouter.cjs');let checks=0;
const check=(value,message)=>{assert.ok(value,message);checks++;};
const config={Version:3,Profiles:[{Id:'gateway',Name:'Own',Protocol:'http',Host:'127.0.0.1',Port:18790,CorePath:'C:\\Fixture\\offline-own.exe'},{Id:'a',Name:'A',Protocol:'http',Host:'127.0.0.1',Port:21001}],Routing:{Adapter:'standalone',ProfileId:'gateway',UnifiedMode:'gateway'}};
const configPath=path.join(root,'config.json'),statePath=path.join(root,'app-rules.json');
fs.writeFileSync(configPath,JSON.stringify(config));fs.writeFileSync(statePath,JSON.stringify({version:3,entries:[],programIngresses:[],siteRules:[],defaultRoute:'a'}));
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const before=[hash(configPath),hash(statePath)];
const plan={Version:2,Action:'repair-path',Execution:'saved-only',DataDirectory:root,SavedPath:'C:\\Missing\\old.exe',CurrentPath:'C:\\Missing\\new.exe',Mode:'engine',CreatedAt:new Date(Date.now()-180000).toISOString(),SnapshotFingerprint:'fixture',IdentityFingerprint:'fixture',ServiceFingerprint:'fixture'};
const freePort=()=>new Promise((resolve,reject)=>{const server=net.createServer();server.once('error',reject);server.listen(0,'127.0.0.1',()=>{const port=server.address().port;server.close(()=>resolve(port));});});
(async()=>{
 try{
  await assert.rejects(r.repairOfflineRecord({...plan,Action:'ambiguous'}),/预览无效/);checks++;
  await assert.rejects(r.repairOfflineRecord({...plan,DataDirectory:path.join(root,'other')}),/预览无效/);checks++;
  const startFile=path.join(r.ROOT,'start.lock'),mutationFile=path.join(r.ROOT,'mutation.lock');fs.mkdirSync(r.ROOT,{recursive:true});
  const start=await r.claimLock(startFile);
  try{await assert.rejects(r.repairOfflineRecord(plan),/正在更新/);checks++;}finally{await r.releaseLock(startFile,start);}
  const mutation=await r.claimLock(mutationFile);
  try{await assert.rejects(r.repairOfflineRecord(plan),/正在更新/);checks++;check(!fs.existsSync(startFile),'failed mutation claim releases the start guard');}finally{await r.releaseLock(mutationFile,mutation);}
  // This error occurs after the real PS child has verified its Node parent and
  // both lock tokens and entered Use-ChangeLock, before it reads any package.
  await assert.rejects(r.repairOfflineRecord(plan),/预览已过期/);checks++;
  check(!fs.existsSync(startFile)&&!fs.existsSync(mutationFile),'real PS rejection releases both service locks');
  check(hash(configPath)===before[0]&&hash(statePath)===before[1],'rejected child preserves exact settings and policy bytes');
  check(!fs.existsSync(path.join(r.ROOT,'runtime.yaml'))&&!fs.existsSync(path.join(r.ROOT,'process.json')),'specialized worker does not start or configure a core');
  // A real successful child transaction: current file identity, no application
  // is launched, no owned service exists, and dynamically reserved test ports
  // have been closed before the fresh TCP observation.
  const client=path.join(root,'inert-client.exe');fs.writeFileSync(client,'identity fixture; never executed');
  const port=await freePort();let ingressPort=await freePort();while(ingressPort===port)ingressPort=await freePort();
  config.Profiles[0].Port=port;config.Profiles[0].CorePath=path.join(root,'unstarted-owned-core-'+crypto.randomUUID()+'.exe');fs.writeFileSync(configPath,JSON.stringify(config));
  const saved={version:3,installed:true,metadata:'preserve',entries:[{path:'C:\\Unrelated\\other.exe',route:'Direct'}],defaultRoute:'a',programIngresses:[{id:'a'.repeat(32),path:client,route:'a',port:ingressPort}],siteRules:[{id:'b'.repeat(32),scope:'global',type:'domain',domain:'example.invalid',route:'Direct'}]};fs.writeFileSync(statePath,JSON.stringify(saved));
  fs.writeFileSync(path.join(root,'selection.json'),'retained selection bytes');fs.writeFileSync(path.join(r.ROOT,'runtime.yaml'),'retained stopped runtime bytes');
  const quote=value=>"'"+value.replace(/'/g,"''")+"'";
  const command='. '+quote(path.join(__dirname,'ProxyBackend.ps1'))+' -DataDirectory '+quote(root)+'; Get-ProgramOfflineReleasePlan -SavedPath '+quote(client)+' | ConvertTo-Json -Depth 8 -Compress';
  const ps=path.join(process.env.SystemRoot,'System32','WindowsPowerShell','v1.0','powershell.exe');
  const release=JSON.parse(execFileSync(ps,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command',command],{windowsHide:true,encoding:'utf8',timeout:20000}).trim().replace(/^\uFEFF/,''));
  check(release.Action==='release-system'&&release.Execution==='saved-only','real preview distinguishes cancellation from unified Follow');
  const configHash=hash(configPath),selectionHash=hash(path.join(root,'selection.json')),runtimeHash=hash(path.join(r.ROOT,'runtime.yaml'));
  const result=await r.repairOfflineRecord(release),after=JSON.parse(fs.readFileSync(statePath,'utf8'));
  check(result.Removed&&result.RulesLoaded===false&&after.programIngresses.length===0,'real child removes exactly the inert program ingress without claiming loaded routing');
  check(after.defaultRoute===saved.defaultRoute&&JSON.stringify(after.entries)===JSON.stringify(saved.entries)&&JSON.stringify(after.siteRules)===JSON.stringify(saved.siteRules)&&after.metadata===saved.metadata,'real successful cancellation retains default, unrelated programs, global sites and metadata');
  check(hash(configPath)===configHash&&hash(path.join(root,'selection.json'))===selectionHash&&hash(path.join(r.ROOT,'runtime.yaml'))===runtimeHash,'real successful child preserves configuration, selection and stopped runtime bytes');
  check(fs.existsSync(result.Backup)&&!fs.existsSync(startFile)&&!fs.existsSync(mutationFile),'real success writes a private backup and releases both locks');
  console.log('PASS: '+checks+' real offline-record lock handoff assertions; isolated successful cancellation and guarded rejection, no core starts.');
 }finally{
  const resolved=path.resolve(root),prefix=path.resolve(os.tmpdir())+path.sep;
  if(!resolved.toLowerCase().startsWith(prefix.toLowerCase())||!path.basename(resolved).startsWith('FlowSwitch-offline-record-locks-'))throw Error('Refusing cleanup outside the verified temporary fixture directory');
  fs.rmSync(resolved,{recursive:true,force:true});
 }
})().catch(error=>{console.error(error);process.exitCode=1;});
