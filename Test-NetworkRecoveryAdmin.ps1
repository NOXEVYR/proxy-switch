$ErrorActionPreference='Stop'
# In-memory stores and mocked elevation only. Never instantiate WindowsMachineStore.
$fixture=@'
using System;
using FlowSwitch.Recovery;
public sealed class RecoveryMemoryStore : IMachineStore {
    public MachineSnapshot Value=new MachineSnapshot {Values=new[]{"http://fixture.invalid:18080","http://fixture.invalid:18080","socks5://fixture.invalid:18081"},Kinds=new[]{1,2,1},AccessType=3,Proxy="fixture.invalid:18080",Bypass="<local>"};
    public int Writes, Reads, FailWrite;
    public Action<RecoveryMemoryStore> OnRead, AfterWrite;
    public MachineSnapshot Read(){Reads++;if(OnRead!=null)OnRead(this);return MachineRecovery.Json.Deserialize<MachineSnapshot>(MachineRecovery.Json.Serialize(Value));}
    public void SetEnvironment(int index,string value,int kind){Writes++;if(Writes==FailWrite)throw new Exception("fixture");Value.Values[index]=value;Value.Kinds[index]=kind;if(AfterWrite!=null)AfterWrite(this);}
    public void SetWinHttp(int accessType,string proxy,string bypass){Writes++;if(Writes==FailWrite)throw new Exception("fixture");Value.AccessType=accessType;Value.Proxy=proxy;Value.Bypass=bypass;if(AfterWrite!=null)AfterWrite(this);}
}
public static class RecoveryAdminTests {
    static int Count;
    static void Check(bool value,string message){if(!value)throw new Exception(message);Count++;}
    static MachineResult Run(RecoveryMemoryStore s,bool env,bool win){return MachineRecovery.Reset(s,MachineRecovery.Revision(s.Read()),env,win,delegate(MachineSnapshot b){});}
    public static int Execute(){
        var s=new RecoveryMemoryStore();var original=MachineRecovery.Revision(s.Read());bool backed=false;
        var result=MachineRecovery.Reset(s,original,true,true,delegate(MachineSnapshot b){Check(s.Writes==0,"backup precedes writes");Check(MachineRecovery.Revision(b)==original,"complete backup");backed=true;});
        Check(backed&&result.State=="Applied"&&result.SettingsVerified,"successful reset verified");
        Check(s.Value.Values[0]==null&&s.Value.Values[1]==null&&s.Value.Values[2]==null&&s.Value.AccessType==1,"only fixed machine targets reset");
        Check(MachineRecovery.Names.Length==3&&Array.IndexOf(MachineRecovery.Names,"NO_PROXY")==-1,"NO_PROXY excluded");
        s=new RecoveryMemoryStore();result=Run(s,false,true);Check(s.Value.Values[0]!=null&&s.Value.AccessType==1,"WinHTTP-only preserves env");
        s=new RecoveryMemoryStore();result=Run(s,true,false);Check(s.Value.Values[0]==null&&s.Value.AccessType==3,"env-only preserves WinHTTP");
        s=new RecoveryMemoryStore();result=Run(s,false,false);Check(result.State=="Rejected"&&s.Writes==0,"empty scope rejected");
        s=new RecoveryMemoryStore();result=MachineRecovery.Reset(s,new string('A',64),true,true,delegate(MachineSnapshot b){throw new Exception("must not back up stale state");});Check(result.Code=="StateChanged"&&s.Writes==0,"stale revision rejected");
        s=new RecoveryMemoryStore();bool failed=false;try{MachineRecovery.Reset(s,MachineRecovery.Revision(s.Read()),true,true,delegate(MachineSnapshot b){throw new Exception("disk full");});}catch{failed=true;}Check(failed&&s.Writes==0,"backup failure writes nothing");
        s=new RecoveryMemoryStore();original=MachineRecovery.Revision(s.Read());s.FailWrite=2;result=Run(s,true,true);Check(result.Code=="FailedRolledBack"&&MachineRecovery.Revision(s.Read())==original,"partial failure rolls back owned fields");
        s=new RecoveryMemoryStore();s.AfterWrite=delegate(RecoveryMemoryStore x){if(x.Writes==1)x.Value.Values[0]="http://external.invalid:19090";};result=Run(s,true,true);Check(result.Code=="ExternalChangesPreserved"&&s.Value.Values[0]=="http://external.invalid:19090"&&s.Value.Values[1]!=null,"external writer preserved");
        s=new RecoveryMemoryStore();original=MachineRecovery.Revision(s.Read());result=MachineRecovery.Reset(s,original,true,true,delegate(MachineSnapshot b){s.Value.Bypass="changed";});Check(result.State=="Rejected"&&s.Writes==0,"post-backup compare prevents overwrite");
        s=new RecoveryMemoryStore();s.AfterWrite=delegate(RecoveryMemoryStore x){if(x.Writes==4)x.Value.Proxy="external.invalid:19090";};result=Run(s,true,true);Check(result.State=="Failed"&&Array.IndexOf(result.Preserved,"WinHTTP")>=0&&s.Value.Proxy=="external.invalid:19090","post-write mismatch not success and preserves external WinHTTP");
        var request=new AdminRequest{Schema=1,Id=Guid.NewGuid().ToString("N"),UserSid="S-1-5-21-fixture",ParentId=1,ParentStartTicks="1",Revision=new string('A',64),CreatedAt=DateTimeOffset.UtcNow.ToString("o"),ClearEnvironment=true};
        Check(AdminProgram.ValidRequest(request,DateTimeOffset.UtcNow,request.UserSid),"fresh fixed-scope request");
        Check(!AdminProgram.ValidRequest(request,DateTimeOffset.UtcNow,"different-user"),"different account rejected");
        request.CreatedAt=DateTimeOffset.UtcNow.AddMinutes(-3).ToString("o");Check(!AdminProgram.ValidRequest(request,DateTimeOffset.UtcNow,request.UserSid),"expired request rejected");
        request.CreatedAt=DateTimeOffset.UtcNow.AddMinutes(1).ToString("o");Check(!AdminProgram.ValidRequest(request,DateTimeOffset.UtcNow,request.UserSid),"future request rejected");
        request.CreatedAt=DateTimeOffset.UtcNow.ToString("o");request.ClearEnvironment=false;Check(!AdminProgram.ValidRequest(request,DateTimeOffset.UtcNow,request.UserSid),"empty privileged request rejected");
        request.ClearEnvironment=true;
        var caller=new CallerContext{Sid=request.UserSid,Root=System.IO.Path.Combine(System.IO.Path.GetTempPath(),"caller-fixture","RecoveryAdmin"),StartTicks="1"};
        var requestPath=System.IO.Path.Combine(caller.Root,request.Id+".request.json");
        Check(AdminProgram.MatchesCaller(request,caller,requestPath,DateTimeOffset.UtcNow),"request binds original caller regardless of elevation account");
        Check(!AdminProgram.MatchesCaller(request,caller,System.IO.Path.Combine(System.IO.Path.GetTempPath(),request.Id+".request.json"),DateTimeOffset.UtcNow),"other request root rejected");
        caller.StartTicks="2";Check(!AdminProgram.MatchesCaller(request,caller,requestPath,DateTimeOffset.UtcNow),"PID reuse rejected");
        caller.StartTicks="1";caller.Sid="different-user";Check(!AdminProgram.MatchesCaller(request,caller,requestPath,DateTimeOffset.UtcNow),"forged caller SID rejected");
        using(var self=System.Diagnostics.Process.GetCurrentProcess()){
            var actual=AdminProgram.ReadCaller(self.Id);
            Check(actual.Sid==System.Security.Principal.WindowsIdentity.GetCurrent().User.Value&&actual.StartTicks==self.StartTime.ToUniversalTime().Ticks.ToString(),"native caller identity matches current own process, read-only");
            Check(actual.Root==AdminProgram.RequestRoot,"known folder resolved from caller token");
        }
        Check(MachineRecovery.Json.Serialize(result).IndexOf("external.invalid",StringComparison.Ordinal)<0,"receipt excludes raw settings");
        return Count;
    }
}
'@
$helper=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'NetworkRecoveryAdmin.cs'))
Add-Type -TypeDefinition ($helper+"`r`nnamespace FlowSwitch.Recovery {`r`n"+$fixture.Replace('using System;','').Replace('using FlowSwitch.Recovery;','')+"`r`n}") -ReferencedAssemblies @('System.Web.Extensions','System','System.Core') -ErrorAction Stop
$count=[FlowSwitch.Recovery.RecoveryAdminTests]::Execute()
. (Join-Path $PSScriptRoot 'NetworkRecoveryAdmin.ps1')
$qa=Join-Path $env:TEMP ('FlowSwitch-admin-test-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($qa)
$fake=Join-Path $qa 'helper-fixture.txt';[IO.File]::WriteAllText($fake,'not an executable')
function Get-NetworkRecoveryAdminHelper {$fake}
function Get-NetworkRecoveryAdminStatus {[pscustomobject]@{State='Available';NeedsRepair=$true;EnvironmentNames=@('HTTP_PROXY');WinHttpState='Direct';Revision=('A'*64);Elevated=$false;Message='fixture'}}
function New-NetworkRecoveryAdminRequest($Plan) {$script:RequestCount++;[pscustomobject]@{Path=(Join-Path $qa 'request.json');Hash=('B'*64);Result=(Join-Path $qa 'result.json')}}
function Start-NetworkRecoveryAdminHelper {throw (New-Object ComponentModel.Win32Exception(1223))}
function Check-Admin($Value,[string]$Message){if(-not $Value){throw $Message};$script:count++}
$script:RequestCount=0;$plan=Get-NetworkRecoveryAdminPlan
$result=Invoke-NetworkRecoveryAdminPlan -Plan $plan -Confirmed
Check-Admin ($result.State -eq 'Cancelled' -and $result.Code -eq 'ElevationCancelled') 'Cancelled UAC is a distinct non-success outcome'
$plan.CreatedAt=[DateTimeOffset]::UtcNow.AddMinutes(-3).ToString('o');$result=Invoke-NetworkRecoveryAdminPlan -Plan $plan -Confirmed
Check-Admin ($result.State -eq 'Rejected' -and $script:RequestCount -eq 1) 'Expired plan never requests elevation'
$plan=Get-NetworkRecoveryAdminPlan;$plan.HelperHash='C'*64;$result=Invoke-NetworkRecoveryAdminPlan -Plan $plan -Confirmed
Check-Admin ($result.Code -eq 'StateChanged' -and $script:RequestCount -eq 1) 'Changed helper rejected before elevation'
$plan=Get-NetworkRecoveryAdminPlan;$plan.ClearEnvironment=$false;$result=Invoke-NetworkRecoveryAdminPlan -Plan $plan -Confirmed
Check-Admin ($result.Code -eq 'StateChanged' -and $script:RequestCount -eq 1) 'Tampered scope rejected before elevation'
Write-Output ('PASS: '+$count+' machine recovery and elevation checks; in-memory stores, no privileged writes or UAC.')
