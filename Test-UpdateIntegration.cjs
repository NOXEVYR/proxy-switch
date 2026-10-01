'use strict';
// Real packaged UI -> graceful handoff -> standalone installer -> new packaged UI receipt.
const fs = require('node:fs'), path = require('node:path'), os = require('node:os'), cp = require('node:child_process'), assert = require('node:assert/strict');
const e = require('./UpdateEngine.cjs'), { build } = require('./Build-UpdateManifest.cjs'), { zipDirectory } = require('./Test-UpdateEngine.cjs');
const delay = ms => new Promise(r => setTimeout(r, ms));
function refresh(root, version) {
  const files = e.json(path.join(root, 'manifest.json'));
  for (const f of files) { const b = fs.readFileSync(path.join(root, f.path)); f.bytes = b.length; f.sha256 = e.hash(b); }
  const value = Buffer.from(JSON.stringify(files)); fs.writeFileSync(path.join(root, 'manifest.json'), value);
  e.atomic(path.join(root, 'update-install.json'), { schema: 1, product: 'FlowSwitch', platform: 'windows', arch: 'x64', channel: 'stable', version, build: e.hash(value), manifestSha256: e.hash(value) });
}
async function run(packagePath) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'FlowSwitch-update-e2e-')), root = path.join(base, 'installed'), target = path.join(base, 'target'), data = path.join(base, 'data');
  fs.cpSync(packagePath, root, { recursive: true }); fs.cpSync(packagePath, target, { recursive: true });
  const fixtureCode = `
$form.Opacity=0;$form.ShowInTaskbar=$false
$fixtureStarted=[DateTime]::UtcNow
$timer.Add_Tick({
    if($script:ProductVersion -eq '3.9.4' -and $script:UpdateUiReady -and -not $script:FixtureUpdateStarted){
        $script:FixtureUpdateStarted=$true
        $script:UpdateReady=Get-Content (Join-Path $script:DataRoot 'updates\\ready.json') -Raw|ConvertFrom-Json
        $script:UpdateRequested=$true;Request-FlowExit
        if(-not $form.IsDisposed -and -not $script:UpdateRequested){[IO.File]::WriteAllText((Join-Path $script:DataRoot 'fixture-failure.txt'),$script:ActivityForFixture);$script:ExitRequested=$true;$form.Close()}
    }
    if($script:ProductVersion -eq '3.9.5' -and (Test-Path (Join-Path $script:DataRoot 'updates\\pending-install.json'))){
        $p=Get-Content (Join-Path $script:DataRoot 'updates\\pending-install.json') -Raw|ConvertFrom-Json
        $state=Get-Content (Join-Path $p.stage 'install-state.json') -Raw|ConvertFrom-Json
        if($state.phase -eq 'completed'){$script:ExitRequested=$true;$form.Close()}
    }
    if(([DateTime]::UtcNow-$fixtureStarted).TotalSeconds -gt 70){$script:ExitRequested=$true;$form.Close()}
})
`;
  for (const dir of [root, target]) {
    const file = path.join(dir, 'app/ProxyWindow.ps1'); let text = fs.readFileSync(file, 'utf8');
    text = text.replace("$timer.Start();[Windows.Forms.Application]::Run($form);$form.Dispose()", fixtureCode + '\n$timer.Start();[Windows.Forms.Application]::Run($form);$form.Dispose()');
    text = text.replace('if(-not $Text){return}', 'if(-not $Text){return};$script:ActivityForFixture=$Text'); fs.writeFileSync(file, text);
  }
  const pref = path.join(target, 'app/Preferences.ps1'); fs.writeFileSync(pref, fs.readFileSync(pref, 'utf8').replace("ProductVersion='3.9.4'", "ProductVersion='3.9.5'"));
  const note = path.join(target, '使用说明.txt'); fs.writeFileSync(note, fs.readFileSync(note, 'utf8').replace('FlowSwitch 3.9.4', 'FlowSwitch 3.9.5'));
  const version = path.join(base, 'FixtureVersion.cs'); fs.writeFileSync(version, '[assembly:System.Reflection.AssemblyVersion("3.9.5.0")]\n[assembly:System.Reflection.AssemblyFileVersion("3.9.5.0")]');
  cp.execFileSync(path.join(process.env.SystemRoot, 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'), ['/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/codepage:65001', '/reference:System.Windows.Forms.dll', '/win32icon:' + path.join(target, 'app/assets/FlowSwitch.ico'), '/out:' + path.join(target, 'FlowSwitch.exe'), path.join(__dirname, 'Launcher.cs'), path.join(__dirname, 'DesktopBranding.cs'), version], { windowsHide: true });
  refresh(root, '3.9.4'); refresh(target, '3.9.5'); fs.mkdirSync(data, { recursive: true });
  fs.writeFileSync(path.join(root, 'user-keep.txt'), 'untouched local file'); fs.writeFileSync(path.join(data, 'user-secret-canary.txt'), 'synthetic not a credential');
  e.atomic(path.join(data, 'config.json'), { Version: 3, Profiles: [], Routing: { Adapter: 'none', ProfileId: '' }, DiscoveryIgnored: [] });
  e.atomic(path.join(data, 'updates/background.json'), { enabled: false });
  const archive = path.join(base, 'FlowSwitch-v3.9.5-Windows-x64.zip'), metadata = path.join(base, 'Windows-update.json'); zipDirectory(target, archive); build(archive, target, metadata);
  const release = { tag_name: 'v3.9.5', draft: false, prerelease: false, assets: [archive, metadata].map(f => ({ name: path.basename(f), state: 'uploaded', size: fs.statSync(f).size, digest: 'sha256:' + e.hash(fs.readFileSync(f)), browser_download_url: 'https://github.com/NOXEVYR/proxy-switch/releases/download/v3.9.5/' + path.basename(f) })) };
  const result = await e.check({ root, data, manual: true, transport: async (url, opts) => { if (url.endsWith('/latest')) return Buffer.from(JSON.stringify(release)); if (url.endsWith('.json')) return fs.readFileSync(metadata); assert(opts.range); return fs.readFileSync(archive).subarray(opts.range.start, opts.range.end + 1); } });
  assert.equal(result.phase, 'staged');
  const stage = path.dirname(result.candidate), stateFile = path.join(stage, 'install-state.json');
  const child = cp.spawn(path.join(root, 'FlowSwitch.exe'), ['--quiet', '--data-directory', data], { cwd: root, windowsHide: true, stdio: ['ignore','pipe','pipe'] }); let exited = false, hostError=''; child.stderr.on('data', b=>{hostError+=b.toString();}); child.stdout.resume(); child.once('exit', code => { exited = true; if(code) fs.writeFileSync(path.join(data,'fixture-failure.txt'), hostError || ('launcher exit '+code)); });
  const end = Date.now() + 105000; let state;
  while (Date.now() < end) {
    if (fs.existsSync(path.join(data, 'fixture-failure.txt'))) throw Error('Fixture host refused update: ' + fs.readFileSync(path.join(data, 'fixture-failure.txt'), 'utf8'));
    if (fs.existsSync(stateFile)) { state = e.json(stateFile); if (['completed', 'cancelled', 'rolled-back', 'rollback-blocked', 'installed-restart-unconfirmed'].includes(state.phase)) break; }
    await delay(200);
  }
  assert(state, 'Installer journal must be created'); assert.equal(state.phase, 'completed', JSON.stringify({ state, base })); assert(exited, 'old compiled launcher exited naturally');
  assert.equal(e.registration(root).reg.version, '3.9.5');
  assert.equal(fs.readFileSync(path.join(root, 'user-keep.txt'), 'utf8'), 'untouched local file'); assert.equal(fs.readFileSync(path.join(data, 'user-secret-canary.txt'), 'utf8'), 'synthetic not a credential');
  for (const f of e.registration(root).files) assert.equal(e.hash(fs.readFileSync(path.join(root, f.path))), f.sha256);
  const ack = e.json(path.join(stage, 'restart-ack.json')); assert.equal(ack.launcherPID, state.restartPID);
  fs.writeFileSync(path.join(base, 'evidence.json'), JSON.stringify({ phase: state.phase, actualOldLauncherExited: exited, actualNewUIAcknowledged: true, downloadBytes: result.downloadBytes, runtimeUnchanged: true, userFilesPreserved: true, processTerminationUsed: false, root, stage }, null, 2));
  console.log('PASS: actual packaged UI check/stage/exit/install/restart with preserved runtime and user canaries. ' + base);
}
run(process.argv[2]).catch(err => { console.error(err); process.exitCode = 1; });
