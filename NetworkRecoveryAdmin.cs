// Fixed-scope machine proxy helper. Never accepts commands, service names or registry paths.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace FlowSwitch.Recovery {
    public sealed class MachineSnapshot {
        public string[] Values = new string[3];
        public int[] Kinds = new int[3];
        public int AccessType;
        public string Proxy = "", Bypass = "";
    }
    public interface IMachineStore {
        MachineSnapshot Read();
        void SetEnvironment(int index, string value, int kind);
        void SetWinHttp(int accessType, string proxy, string bypass);
    }
    public sealed class MachineResult {
        public string State, Code, Backup;
        public bool SettingsVerified;
        public string[] Preserved = new string[0];
    }
    public static class MachineRecovery {
        public static readonly string[] Names = {"HTTP_PROXY","HTTPS_PROXY","ALL_PROXY"};
        public static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
        public static string Hash(byte[] value) {
            using(var sha=SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(value)).Replace("-", "");
        }
        public static string Revision(MachineSnapshot value) { return Hash(Encoding.UTF8.GetBytes(Json.Serialize(value))); }
        public static bool WinSame(MachineSnapshot a, MachineSnapshot b) {
            return a.AccessType==b.AccessType && a.Proxy==b.Proxy && a.Bypass==b.Bypass;
        }
        public static MachineResult Reset(IMachineStore store, string revision, bool environment, bool winHttp, Action<MachineSnapshot> backup) {
            var before=store.Read();
            if(!environment && !winHttp) return new MachineResult {State="Rejected",Code="EmptyScope"};
            if(Revision(before)!=revision) return new MachineResult {State="Rejected",Code="StateChanged"};
            // Backup failure must happen before the first setting write.
            backup(before);
            if(Revision(store.Read())!=revision) return new MachineResult {State="Rejected",Code="StateChanged"};
            var target=Json.Deserialize<MachineSnapshot>(Json.Serialize(before));
            if(environment) for(int i=0;i<3;i++){target.Values[i]=null;target.Kinds[i]=0;}
            if(winHttp){target.AccessType=1;target.Proxy="";target.Bypass="";}
            var written=new bool[3]; bool winAttempted=false;
            try {
                var expected=Json.Deserialize<MachineSnapshot>(Json.Serialize(before));
                if(environment) for(int i=0;i<3;i++) {
                    if(Revision(store.Read())!=Revision(expected)) throw new InvalidOperationException("StateChanged");
                    if(before.Values[i]!=null){written[i]=true;store.SetEnvironment(i,null,0);}
                    expected.Values[i]=null;expected.Kinds[i]=0;
                }
                if(Revision(store.Read())!=Revision(expected)) throw new InvalidOperationException("StateChanged");
                if(winHttp && !WinSame(before,target)){winAttempted=true;store.SetWinHttp(1,"","");}
                if(Revision(store.Read())!=Revision(target)) throw new InvalidOperationException("VerifyFailed");
                return new MachineResult {State="Applied",Code="MachineSettingsReset",SettingsVerified=true};
            } catch {
                var preserved=new List<string>();
                try {
                    if(winAttempted){var now=store.Read();if(WinSame(now,target)) store.SetWinHttp(before.AccessType,before.Proxy,before.Bypass);else if(!WinSame(now,before)) preserved.Add("WinHTTP");}
                } catch {preserved.Add("WinHTTP");}
                for(int i=2;i>=0;i--) if(written[i]) {
                    try {var now=store.Read();if(now.Values[i]==null) store.SetEnvironment(i,before.Values[i],before.Kinds[i]);else if(now.Values[i]!=before.Values[i] || now.Kinds[i]!=before.Kinds[i]) preserved.Add(Names[i]);}
                    catch {preserved.Add(Names[i]);}
                }
                return new MachineResult {State="Failed",Code=preserved.Count==0?"FailedRolledBack":"ExternalChangesPreserved",Preserved=preserved.ToArray()};
            }
        }
    }
    public sealed class WindowsMachineStore : IMachineStore {
        const string EnvironmentKey=@"SYSTEM\CurrentControlSet\Control\Session Manager\Environment";
        [StructLayout(LayoutKind.Sequential)] struct ProxyInfo { public int AccessType; public IntPtr Proxy,Bypass; }
        [DllImport("winhttp.dll",SetLastError=true)] static extern bool WinHttpGetDefaultProxyConfiguration(out ProxyInfo info);
        [DllImport("winhttp.dll",SetLastError=true)] static extern bool WinHttpSetDefaultProxyConfiguration(ref ProxyInfo info);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr ptr);
        public MachineSnapshot Read() {
            var s=new MachineSnapshot();
            using(var root=RegistryKey.OpenBaseKey(RegistryHive.LocalMachine,RegistryView.Registry64))
            using(var key=root.OpenSubKey(EnvironmentKey,false)) {
                if(key==null) throw new InvalidOperationException("MachineReadUnavailable");
                for(int i=0;i<3;i++) {
                    var value=key.GetValue(MachineRecovery.Names[i],null,RegistryValueOptions.DoNotExpandEnvironmentNames);
                    if(value!=null){var kind=key.GetValueKind(MachineRecovery.Names[i]);if(!(value is string) || (kind!=RegistryValueKind.String && kind!=RegistryValueKind.ExpandString)) throw new InvalidOperationException("UnsupportedValue");s.Values[i]=(string)value;s.Kinds[i]=(int)kind;}
                }
            }
            ProxyInfo p;
            if(!WinHttpGetDefaultProxyConfiguration(out p)) throw new Win32Exception(Marshal.GetLastWin32Error());
            try{s.AccessType=p.AccessType;s.Proxy=Marshal.PtrToStringUni(p.Proxy)??"";s.Bypass=Marshal.PtrToStringUni(p.Bypass)??"";}
            finally{if(p.Proxy!=IntPtr.Zero)GlobalFree(p.Proxy);if(p.Bypass!=IntPtr.Zero)GlobalFree(p.Bypass);}
            if(s.AccessType!=1 && s.AccessType!=3) throw new InvalidOperationException("UnsupportedWinHttp");
            return s;
        }
        public void SetEnvironment(int index,string value,int kind) {
            if(index<0 || index>=3) throw new ArgumentOutOfRangeException("index");
            using(var root=RegistryKey.OpenBaseKey(RegistryHive.LocalMachine,RegistryView.Registry64))
            using(var key=root.OpenSubKey(EnvironmentKey,true)) {
                if(value==null) key.DeleteValue(MachineRecovery.Names[index],false);
                else key.SetValue(MachineRecovery.Names[index],value,(RegistryValueKind)kind);
            }
        }
        public void SetWinHttp(int accessType,string proxy,string bypass) {
            ProxyInfo p=new ProxyInfo();p.AccessType=accessType;
            p.Proxy=String.IsNullOrEmpty(proxy)?IntPtr.Zero:Marshal.StringToHGlobalUni(proxy);
            p.Bypass=String.IsNullOrEmpty(bypass)?IntPtr.Zero:Marshal.StringToHGlobalUni(bypass);
            try{if(!WinHttpSetDefaultProxyConfiguration(ref p))throw new Win32Exception(Marshal.GetLastWin32Error());}
            finally{if(p.Proxy!=IntPtr.Zero)Marshal.FreeHGlobal(p.Proxy);if(p.Bypass!=IntPtr.Zero)Marshal.FreeHGlobal(p.Bypass);}
        }
    }
    public sealed class AdminRequest {
        public int Schema, ParentId;
        public string Id, UserSid, CreatedAt, ParentStartTicks, Revision;
        public bool ClearEnvironment, ResetWinHttp;
    }
    public sealed class CallerContext {public string Sid,Root,StartTicks;}
    public static class AdminProgram {
        [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr SendMessageTimeout(IntPtr window,uint message,IntPtr wParam,string lParam,uint flags,uint timeout,out IntPtr result);
        static void NotifyEnvironment(){IntPtr ignored;SendMessageTimeout(new IntPtr(0xffff),0x1a,IntPtr.Zero,"Environment",2,2000,out ignored);}
        [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int id);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr process,out long created,out long exited,out long kernel,out long user);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
        [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath(ref Guid id,uint flags,IntPtr token,out IntPtr path);
        [StructLayout(LayoutKind.Sequential)] struct PrivilegeState {public int Count;public uint Low;public int High;public uint Attributes;}
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LookupPrivilegeValue(string system,string name,out long luid);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token,bool disable,ref PrivilegeState next,int length,out PrivilegeState previous,out int required);
        public static CallerContext ReadCaller(int id) {
            IntPtr process=OpenProcess(0x1000,false,id),token=IntPtr.Zero,folder=IntPtr.Zero;
            if(process==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                long created,exited,kernel,user;
                if(!GetProcessTimes(process,out created,out exited,out kernel,out user) || !OpenProcessToken(process,0x0e,out token))throw new Win32Exception(Marshal.GetLastWin32Error());
                var localAppData=new Guid("F1B32785-6FBA-4FCF-9D55-7B8E7F157091");
                int hr=SHGetKnownFolderPath(ref localAppData,0,token,out folder);if(hr!=0)Marshal.ThrowExceptionForHR(hr);
                using(var identity=new WindowsIdentity(token))return new CallerContext{Sid=identity.User.Value,Root=Path.Combine(Marshal.PtrToStringUni(folder),"FlowSwitch","RecoveryAdmin"),StartTicks=DateTime.FromFileTimeUtc(created).Ticks.ToString()};
            }finally{if(folder!=IntPtr.Zero)Marshal.FreeCoTaskMem(folder);if(token!=IntPtr.Zero)CloseHandle(token);CloseHandle(process);}
        }
        static CallerContext ReadElevatedCaller(int id) {
            try{return ReadCaller(id);}catch(Win32Exception){
                // Cross-account UAC may need debug privilege to query the original caller's token.
                // Enable it only around this fixed identity/folder query, then restore its prior state.
                IntPtr token;using(var self=Process.GetCurrentProcess()){if(!OpenProcessToken(self.Handle,0x28,out token))throw;}
                PrivilegeState previous=new PrivilegeState();bool changed=false;
                try{
                    long luid;if(!LookupPrivilegeValue(null,"SeDebugPrivilege",out luid))throw new Win32Exception(Marshal.GetLastWin32Error());
                    var next=new PrivilegeState{Count=1,Low=(uint)luid,High=(int)(luid>>32),Attributes=2};int required;
                    if(!AdjustTokenPrivileges(token,false,ref next,Marshal.SizeOf(typeof(PrivilegeState)),out previous,out required) || Marshal.GetLastWin32Error()!=0)throw new Win32Exception(Marshal.GetLastWin32Error());
                    changed=true;return ReadCaller(id);
                }finally{if(changed){PrivilegeState ignored;int required;AdjustTokenPrivileges(token,false,ref previous,Marshal.SizeOf(typeof(PrivilegeState)),out ignored,out required);}CloseHandle(token);}
            }
        }
        public static bool MatchesCaller(AdminRequest request,CallerContext caller,string path,DateTimeOffset now) {
            return caller!=null && ValidRequest(request,now,caller.Sid) && request.ParentStartTicks==caller.StartTicks &&
                String.Equals(Path.GetDirectoryName(Path.GetFullPath(path)),Path.GetFullPath(caller.Root),StringComparison.OrdinalIgnoreCase) && Path.GetFileName(path)==request.Id+".request.json";
        }
        public static string RequestRoot {get{return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"FlowSwitch","RecoveryAdmin");}}
        public static bool Elevated {get{return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);}}
        public static void RejectReparse(string path) {
            string full=Path.GetFullPath(path);
            while(!String.IsNullOrEmpty(full)) {
                if((Directory.Exists(full)||File.Exists(full)) && (File.GetAttributes(full)&FileAttributes.ReparsePoint)!=0) throw new InvalidOperationException("ReparsePath");
                full=Path.GetDirectoryName(full);
            }
        }
        static void PrivateFile(string path,string text,string callerSid) {
            var security=new FileSecurity();security.SetAccessRuleProtection(true,false);
            foreach(var sid in new[]{new SecurityIdentifier(callerSid),new SecurityIdentifier(WellKnownSidType.LocalSystemSid,null),new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid,null)})
                security.AddAccessRule(new FileSystemAccessRule(sid,FileSystemRights.FullControl,AccessControlType.Allow));
            RejectReparse(Path.GetDirectoryName(path));
            using(var file=new FileStream(path,FileMode.CreateNew,FileSystemRights.Write,FileShare.None,4096,FileOptions.WriteThrough,security)) {
                var bytes=Encoding.UTF8.GetBytes(text);file.Write(bytes,0,bytes.Length);file.Flush(true);
            }
        }
        public static bool ValidRequest(AdminRequest r,DateTimeOffset now,string sid) {
            DateTimeOffset created;Guid id;
            return r!=null && r.Schema==1 && Guid.TryParseExact(r.Id,"N",out id) && r.UserSid==sid && r.ParentId>0 &&
                !String.IsNullOrEmpty(r.ParentStartTicks) && System.Text.RegularExpressions.Regex.IsMatch(r.Revision??"","^[A-F0-9]{64}$") &&
                DateTimeOffset.TryParse(r.CreatedAt,out created) && (now-created).TotalSeconds>=-5 && (now-created).TotalSeconds<=120 && (r.ClearEnvironment||r.ResetWinHttp);
        }
        [STAThread] public static int Main(string[] args) {
            string resultPath=null,callerSid=null;
            try {
                if(args.Length==1 && args[0]=="--inspect") {
                    var s=new WindowsMachineStore().Read();var names=new List<string>();for(int i=0;i<3;i++)if(s.Values[i]!=null)names.Add(MachineRecovery.Names[i]);
                    Console.WriteLine(MachineRecovery.Json.Serialize(new {State="Available",NeedsRepair=names.Count>0||s.AccessType!=1,EnvironmentNames=names.ToArray(),WinHttpState=s.AccessType==1?"Direct":"Proxy",Revision=MachineRecovery.Revision(s),Elevated=Elevated}));return 0;
                }
                if(args.Length!=3 || args[0]!="--apply" || !System.Text.RegularExpressions.Regex.IsMatch(args[2],"^[A-F0-9]{64}$"))return 2;
                if(!Elevated)return 5;
                string path=Path.GetFullPath(args[1]);RejectReparse(path);
                byte[] bytes;using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read)){
                    if(stream.Length>8192)return 2;bytes=new byte[(int)stream.Length];int offset=0,n;while(offset<bytes.Length && (n=stream.Read(bytes,offset,bytes.Length-offset))>0)offset+=n;if(offset!=bytes.Length)return 2;
                }
                if(MachineRecovery.Hash(bytes)!=args[2])return 2;
                var r=MachineRecovery.Json.Deserialize<AdminRequest>(Encoding.UTF8.GetString(bytes).TrimStart('\uFEFF'));
                if(r==null || r.ParentId<=0)return 2;
                var caller=ReadElevatedCaller(r.ParentId);
                if(!MatchesCaller(r,caller,path,DateTimeOffset.UtcNow))return 2;
                callerSid=caller.Sid;string requestRoot=Path.GetFullPath(caller.Root);
                resultPath=Path.Combine(requestRoot,r.Id+".result.json");
                using(var mutex=new Mutex(false,@"Global\FlowSwitch.MachineProxyRecovery")) {
                    bool held=false;try {
                        try{held=mutex.WaitOne(0);}catch(AbandonedMutexException){held=true;}
                        if(!held)return 6;
                        // CreateNew consumes the request before any privileged setting mutation.
                        PrivateFile(Path.Combine(requestRoot,r.Id+".consumed"),"1",callerSid);
                        string backup=Path.Combine(requestRoot,r.Id+".backup.json");
                        var result=MachineRecovery.Reset(new WindowsMachineStore(),r.Revision,r.ClearEnvironment,r.ResetWinHttp,
                            delegate(MachineSnapshot state){PrivateFile(backup,MachineRecovery.Json.Serialize(state),callerSid);});
                        if(r.ClearEnvironment && result.State!="Rejected")NotifyEnvironment();
                        if(File.Exists(backup))result.Backup=backup;
                        PrivateFile(resultPath,MachineRecovery.Json.Serialize(result),callerSid);
                        return result.State=="Applied"?0:3;
                    } finally {if(held)mutex.ReleaseMutex();}
                }
            } catch {
                if(resultPath!=null)try{PrivateFile(resultPath,MachineRecovery.Json.Serialize(new MachineResult{State="Failed",Code="HelperFailed"}),callerSid);}catch{}
                return 3;
            }
        }
    }
}
