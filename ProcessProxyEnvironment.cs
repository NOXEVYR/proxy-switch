using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace LocalProxySwitch {
    public sealed class ProcessProxyVariable {
        public string Name, State = "Absent", ReasonCode = "NotPresent", Scheme = "", LoopbackHost = "", EndpointKind = "None";
        public int Port;
        public bool HasCredentials;
    }
    public sealed class ProcessProxyEnvironmentResult {
        public string State = "Unknown", ReasonCode = "CollectionError", Architecture = "Unknown";
        public int ProcessId;
        public long CreationTicks;
        public bool? NoProxyPresent, NoProxyBroadBypass;
        public ProcessProxyVariable[] Variables = new ProcessProxyVariable[0];
    }
    // Explicit, single-target diagnostic only. Never used by ProcessCatalog or background inventory.
    // The only remote reads are two pointer fields (PEB -> parameters -> environment)
    // and a bounded environment block. No module/heap enumeration, target writes or privileges.
    public static class ProcessProxyEnvironment {
        public const uint QueryAccess = 0x0400 | 0x0010;
        public const int MaximumEnvironmentBytes = 256 * 1024;
        [StructLayout(LayoutKind.Sequential)] struct FileTime { public uint Low, High; }
        [StructLayout(LayoutKind.Sequential)] struct BasicInfo { public IntPtr ExitStatus, Peb, Affinity, Priority, Id, Parent; }
        [StructLayout(LayoutKind.Sequential)] struct MemoryInfo {
            public IntPtr Base, AllocationBase; public uint AllocationProtect; public UIntPtr Size;
            public uint State, Protect, Type;
        }
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint id);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] static extern uint GetProcessId(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr handle, out FileTime created, out FileTime exited, out FileTime kernel, out FileTime user);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageNameW(IntPtr handle, uint flags, StringBuilder path, ref uint size);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsWow64Process2(IntPtr handle, out ushort processMachine, out ushort nativeMachine);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr handle, IntPtr address, byte[] bytes, UIntPtr size, out UIntPtr read);
        [DllImport("kernel32.dll", SetLastError=true)] static extern UIntPtr VirtualQueryEx(IntPtr handle, IntPtr address, out MemoryInfo info, UIntPtr length);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token, int kind, IntPtr value, int size, out int required);
        [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int kind, out BasicInfo value, int size, out int returned);
        [DllImport("ntdll.dll", EntryPoint="NtQueryInformationProcess")] static extern int QueryWow64(IntPtr process, int kind, out IntPtr value, int size, out int returned);

        static string Normalize(string value) {
            if(String.IsNullOrWhiteSpace(value) || value.IndexOfAny(new char[]{'\0','\r','\n','"'})>=0)return "";
            if(value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase))value=value.Substring(4);
            if(value.Length<3 || !Char.IsLetter(value[0]) || value[1]!=':' || (value[2]!='\\' && value[2]!='/'))return "";
            try{return Path.GetFullPath(value).TrimEnd('\\');}catch{return "";}
        }
        static string Identity(IntPtr handle, int id, string expectedPath, long ticks) {
            if(GetProcessId(handle)!=(uint)id)return "IdentityChanged";
            uint code; if(!GetExitCodeProcess(handle,out code))return "IdentityUnavailable";
            if(code!=259)return "ProcessExited";
            FileTime created, exited, kernel, user;
            if(!GetProcessTimes(handle,out created,out exited,out kernel,out user))return "IdentityUnavailable";
            long actual=DateTime.FromFileTimeUtc(((long)created.High<<32)|created.Low).Ticks;
            uint length=32768; var text=new StringBuilder((int)length);
            if(!QueryFullProcessImageNameW(handle,0,text,ref length))return "IdentityUnavailable";
            return actual==ticks && String.Equals(Normalize(text.ToString()),expectedPath,StringComparison.OrdinalIgnoreCase)?"Verified":"IdentityChanged";
        }
        static bool TokenScope(IntPtr process, out string sid, out int session) {
            sid="";session=-1;IntPtr token=IntPtr.Zero, buffer=IntPtr.Zero;
            try {
                if(!OpenProcessToken(process,8,out token))return false;
                int required;GetTokenInformation(token,1,IntPtr.Zero,0,out required);
                if(required< IntPtr.Size || required>65536)return false;
                buffer=Marshal.AllocHGlobal(required);
                if(!GetTokenInformation(token,1,buffer,required,out required))return false;
                sid=new SecurityIdentifier(Marshal.ReadIntPtr(buffer)).Value;
                if(!GetTokenInformation(token,12,buffer,4,out required))return false;
                session=Marshal.ReadInt32(buffer);return true;
            } finally {if(buffer!=IntPtr.Zero)Marshal.FreeHGlobal(buffer);if(token!=IntPtr.Zero)CloseHandle(token);}
        }
        // Reject ARM64 and 32-bit callers rather than interpreting a different PEB layout.
        public static string GetArchitectureSupport(int pointerSize, ushort processMachine, ushort nativeMachine) {
            if(pointerSize!=8 || nativeMachine!=0x8664)return "UnknownUnsupported";
            if(processMachine==0)return "X64";
            return processMachine==0x014c?"X86":"UnknownUnsupported";
        }
        static bool Address(ulong value, int width) {return value>=65536 && (value&1)==0 && value<(width==4?0x100000000UL:0x800000000000UL);}
        static ulong Pointer(IntPtr handle, ulong address, int width) {
            if(!Address(address,width))throw new InvalidOperationException();
            var bytes=new byte[width];
            try {UIntPtr read;if(!ReadProcessMemory(handle,new IntPtr((long)address),bytes,(UIntPtr)width,out read) || read.ToUInt64()!=(ulong)width)throw new InvalidOperationException();return width==4?BitConverter.ToUInt32(bytes,0):BitConverter.ToUInt64(bytes,0);}
            finally {Array.Clear(bytes,0,bytes.Length);}
        }
        static byte[] EnvironmentBytes(IntPtr handle, ulong environment, int width) {
            if(!Address(environment,width))throw new InvalidOperationException();
            MemoryInfo info;
            if(VirtualQueryEx(handle,new IntPtr((long)environment),out info,(UIntPtr)Marshal.SizeOf(typeof(MemoryInfo)))==UIntPtr.Zero || info.State!=0x1000 || (info.Protect&0x101)!=0)throw new InvalidOperationException();
            ulong start=(ulong)info.Base.ToInt64(), size=info.Size.ToUInt64();
            if(start>environment || size>ulong.MaxValue-start || start+size<=environment)throw new InvalidOperationException();
            int limit=(int)Math.Min((ulong)MaximumEnvironmentBytes,start+size-environment);limit&=~1;
            var result=new byte[MaximumEnvironmentBytes];var chunk=new byte[512];int count=0;bool previousNull=false;
            try {
                while(count<limit) {
                    int length=Math.Min(chunk.Length,limit-count);UIntPtr read;
                    if(!ReadProcessMemory(handle,new IntPtr((long)(environment+(ulong)count)),chunk,(UIntPtr)length,out read) || read.ToUInt64()!=(ulong)length)throw new InvalidOperationException();
                    for(int i=0;i<length;i+=2) {
                        result[count++]=chunk[i];result[count++]=chunk[i+1];
                        bool zero=chunk[i]==0 && chunk[i+1]==0;
                        if(zero && previousNull){var exact=new byte[count];Buffer.BlockCopy(result,0,exact,0,count);return exact;}
                        previousNull=zero;
                    }
                }
                throw new InvalidOperationException();
            } finally {Array.Clear(result,0,result.Length);Array.Clear(chunk,0,chunk.Length);}
        }
        public static ProcessProxyVariable SummarizeValue(string name, string value) {
            // Name is allowlisted too: callers cannot smuggle arbitrary environment names into output.
            if(name!="HTTP_PROXY" && name!="HTTPS_PROXY" && name!="ALL_PROXY")name="";
            var row=new ProcessProxyVariable();row.Name=name;
            if(value==null)return row;
            if(value.Length==0){row.ReasonCode="EmptyVariable";return row;}
            row.State="Unknown";row.ReasonCode="InvalidProxyValue";row.EndpointKind="Unknown";
            if(name.Length==0 || value.Length>8192 || value.IndexOfAny(new char[]{'\0','\r','\n',';','\\',' ','\t'})>=0)return row;
            Uri uri;string candidate=value.IndexOf("://",StringComparison.Ordinal)>=0?value:"http://"+value;
            if(!Uri.TryCreate(candidate,UriKind.Absolute,out uri))return row;
            string scheme=uri.Scheme.ToLowerInvariant();
            if(scheme!="http" && scheme!="https" && scheme!="socks5" && scheme!="socks5h")return row;
            row.HasCredentials=uri.UserInfo.Length>0;
            // Paths, queries and fragments may contain secrets or represent non-proxy configuration.
            if(uri.AbsolutePath!="/" && uri.AbsolutePath!="" || uri.Query.Length>0 || uri.Fragment.Length>0 || uri.Host.Length==0 || uri.Port<1 || uri.Port>65535)return row;
            string host=uri.Host.Trim('[',']').ToLowerInvariant();
            IPAddress address;if(IPAddress.TryParse(host,out address) && address.Equals(IPAddress.IPv6Loopback))host="::1";
            row.Scheme=scheme;row.State="Observed";
            if(host=="localhost" || host=="127.0.0.1" || host=="::1") {
                // .NET Uri accepts noncanonical numeric IPv4. Require the original literal too.
                string authority=candidate.Substring(candidate.IndexOf("://",StringComparison.Ordinal)+3).TrimEnd('/');int at=authority.LastIndexOf('@');if(at>=0)authority=authority.Substring(at+1);
                string rawHost=authority.StartsWith("[")?authority.Substring(0,authority.IndexOf(']')+1):authority.Split(':')[0];
                if(rawHost.Trim('[',']').ToLowerInvariant()!=host){row.State="Unknown";row.ReasonCode="NonCanonicalHost";row.EndpointKind="Unknown";row.Scheme="";return row;}
                row.EndpointKind="Loopback";row.LoopbackHost=host;row.Port=uri.Port;row.ReasonCode="LoopbackProxy";
            } else {row.EndpointKind="External";row.ReasonCode="ExternalProxy";}
            return row;
        }
        static ProcessProxyEnvironmentResult Summarize(byte[] bytes) {
            var result=new ProcessProxyEnvironmentResult();var values=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);var duplicates=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            // Decode ONLY the four allowlisted values. Other values never become managed strings.
            int begin=0;
            for(int end=0;end+1<bytes.Length;end+=2) {
                if(bytes[end]!=0 || bytes[end+1]!=0)continue;
                int equals=-1;for(int i=begin;i<end;i+=2)if(bytes[i]==61 && bytes[i+1]==0){equals=i;break;}
                if(equals>begin && equals-begin<=22) {
                    string name=Encoding.Unicode.GetString(bytes,begin,equals-begin).ToUpperInvariant();
                    if(name=="HTTP_PROXY" || name=="HTTPS_PROXY" || name=="ALL_PROXY" || name=="NO_PROXY") {
                        if(values.ContainsKey(name))duplicates.Add(name);
                        else values[name]=Encoding.Unicode.GetString(bytes,equals+2,end-equals-2);
                    }
                }
                begin=end+2;
            }
            var rows=new List<ProcessProxyVariable>();bool any=false;
            foreach(string name in new string[]{"HTTP_PROXY","HTTPS_PROXY","ALL_PROXY"}) {
                string value;values.TryGetValue(name,out value);var row=SummarizeValue(name,value);
                if(duplicates.Contains(name)){row=new ProcessProxyVariable();row.Name=name;row.State="Unknown";row.ReasonCode="AmbiguousVariable";row.EndpointKind="Unknown";}
                if(row.State!="Absent")any=true;rows.Add(row);
            }
            result.Variables=rows.ToArray();result.NoProxyPresent=values.ContainsKey("NO_PROXY");
            result.NoProxyBroadBypass=false;
            if(duplicates.Contains("NO_PROXY"))result.NoProxyBroadBypass=null;
            else if(result.NoProxyPresent==true)foreach(string entry in values["NO_PROXY"].Split(',')){string item=entry.Trim();if(item=="*" || item=="0.0.0.0/0" || item=="::/0")result.NoProxyBroadBypass=true;}
            result.State=any || result.NoProxyPresent==true?"Observed":"Absent";result.ReasonCode="Verified";return result;
        }
        public static ProcessProxyEnvironmentResult Observe(int id, string expectedPath, long expectedCreationTicks) {
            var result=new ProcessProxyEnvironmentResult();result.ProcessId=id;IntPtr handle=IntPtr.Zero;byte[] first=null,second=null;
            try {
                string path=Normalize(expectedPath);
                if(id<=4 || path.Length==0 || expectedCreationTicks<=0){result.ReasonCode="InvalidIdentity";return result;}
                if(IntPtr.Size!=8){result.ReasonCode="UnknownUnsupported";return result;}
                handle=OpenProcess(QueryAccess,false,(uint)id);
                if(handle==IntPtr.Zero){result.ReasonCode=Marshal.GetLastWin32Error()==5?"AccessDenied":"ProcessUnavailable";return result;}
                string identity=Identity(handle,id,path,expectedCreationTicks);if(identity!="Verified"){result.ReasonCode=identity;return result;}
                string owner,currentOwner;int session,currentSession;
                if(!TokenScope(handle,out owner,out session) || !TokenScope(GetCurrentProcess(),out currentOwner,out currentSession)){result.ReasonCode="ScopeUnavailable";return result;}
                if(owner!=currentOwner || session!=currentSession){result.ReasonCode="ScopeMismatch";return result;}
                ushort machine,native;
                if(!IsWow64Process2(handle,out machine,out native)){result.ReasonCode="UnknownUnsupported";return result;}
                string arch=GetArchitectureSupport(IntPtr.Size,machine,native);result.Architecture=arch;
                if(arch=="UnknownUnsupported"){result.ReasonCode="UnknownUnsupported";return result;}
                int width=arch=="X86"?4:8, returned;ulong peb;
                if(width==4){IntPtr wow;if(QueryWow64(handle,26,out wow,IntPtr.Size,out returned)!=0){result.ReasonCode="PebUnavailable";return result;}peb=(ulong)wow.ToInt64();}
                else {BasicInfo basic;if(NtQueryInformationProcess(handle,0,out basic,Marshal.SizeOf(typeof(BasicInfo)),out returned)!=0){result.ReasonCode="PebUnavailable";return result;}peb=(ulong)basic.Peb.ToInt64();}
                ulong parameters=Pointer(handle,peb+(ulong)(width==4?0x10:0x20),width);
                ulong environment=Pointer(handle,parameters+(ulong)(width==4?0x48:0x80),width);
                first=EnvironmentBytes(handle,environment,width);
                if(parameters!=Pointer(handle,peb+(ulong)(width==4?0x10:0x20),width) || environment!=Pointer(handle,parameters+(ulong)(width==4?0x48:0x80),width)){result.ReasonCode="EnvironmentChanged";return result;}
                second=EnvironmentBytes(handle,environment,width);
                if(first.Length!=second.Length){result.ReasonCode="EnvironmentChanged";return result;}
                for(int i=0;i<first.Length;i++)if(first[i]!=second[i]){result.ReasonCode="EnvironmentChanged";return result;}
                if(parameters!=Pointer(handle,peb+(ulong)(width==4?0x10:0x20),width) || environment!=Pointer(handle,parameters+(ulong)(width==4?0x48:0x80),width)){result.ReasonCode="EnvironmentChanged";return result;}
                identity=Identity(handle,id,path,expectedCreationTicks);if(identity!="Verified"){result.ReasonCode=identity;return result;}
                if(!TokenScope(handle,out owner,out session) || owner!=currentOwner || session!=currentSession){result.ReasonCode="ScopeChanged";return result;}
                // Do not publish any partial data until identity and both environment reads agree.
                result=Summarize(first);result.ProcessId=id;result.CreationTicks=expectedCreationTicks;result.Architecture=arch;return result;
            } catch(EntryPointNotFoundException){result.ReasonCode="UnknownUnsupported";return result;}
            catch(DllNotFoundException){result.ReasonCode="UnknownUnsupported";return result;}
            catch {result.ReasonCode="EnvironmentUnreadable";return result;}
            finally {if(first!=null)Array.Clear(first,0,first.Length);if(second!=null)Array.Clear(second,0,second.Length);if(handle!=IntPtr.Zero)CloseHandle(handle);}
        }
    }
}
