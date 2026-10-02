# Session-only relationship evidence. Every returned member is rechecked against the current inventory.
# This cache never changes application rules, environment, shortcuts or network settings.
$familyTypeGate=[string]::Intern('LocalProxySwitch.ProgramFamilyTracker.TypeGate.v1')
[Threading.Monitor]::Enter($familyTypeGate)
try {
if(-not ('LocalProxySwitch.ProgramFamilyTracker' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Linq;
namespace LocalProxySwitch {
    public sealed class ProgramFamilyEvidence {
        public int Id, ParentId;
        public long StartTicks;
        public string Path="", FileId="";
        public bool Verified, Root, Inside;
        public ProgramFamilyEvidence Copy() { return (ProgramFamilyEvidence)MemberwiseClone(); }
        public bool Same(ProgramFamilyEvidence other) {
            return other!=null && Verified && other.Verified && Id==other.Id && StartTicks==other.StartTicks &&
                String.Equals(Path,other.Path,StringComparison.OrdinalIgnoreCase) && FileId==other.FileId;
        }
        public string Key {get{return Id+"|"+StartTicks+"|"+Path.ToUpperInvariant()+"|"+FileId;}}
    }
    public sealed class ProgramFamilyResult {
        public int[] MemberIds=new int[0], UnknownIds=new int[0], RetainedIds=new int[0];
        public int RootSessionCount;
    }
    public sealed class ProgramFamilyObservationResult {
        public int[] MemberIds=new int[0], ExternalIds=new int[0], UnknownIds=new int[0];
        public bool Truncated;
    }
    public static class ProgramFamilyTracker {
        sealed class Member {public ProgramFamilyEvidence Identity;public long Seen;}
        sealed class Session {
            public ProgramFamilyEvidence Root;
            public Dictionary<int,Member> Members=new Dictionary<int,Member>();
            public long Touched;
        }
        sealed class Family {
            public Dictionary<string,Session> Sessions=new Dictionary<string,Session>();
            public long Observed, Touched;
        }
        static readonly object Gate=new object();
        static readonly Dictionary<string,Family> Families=new Dictionary<string,Family>(StringComparer.OrdinalIgnoreCase);
        const int MaxFamilies=64, MaxSessions=8, MaxMembers=256, MaxTotalMembers=8192;
        static readonly long UnknownRetention=TimeSpan.FromMinutes(2).Ticks, IdleRetention=TimeSpan.FromMinutes(10).Ticks;
        static Session CopySession(Session source) {
            var result=new Session{Root=source.Root.Copy(),Touched=source.Touched};
            foreach(var pair in source.Members)result.Members[pair.Key]=new Member{Identity=pair.Value.Identity.Copy(),Seen=pair.Value.Seen};
            return result;
        }
        public static ProgramFamilyResult Observe(string scope,ProgramFamilyEvidence[] snapshot,long observed,bool available) {
            lock(Gate) {
                long now=DateTime.UtcNow.Ticks;
                foreach(var key in Families.Where(x=>now-x.Value.Touched>IdleRetention).Select(x=>x.Key).ToArray())Families.Remove(key);
                Family saved;
                if(!Families.TryGetValue(scope,out saved))saved=new Family();
                if(!available) return new ProgramFamilyResult{UnknownIds=saved.Sessions.Values.SelectMany(x=>x.Members.Keys).Distinct().ToArray(),RootSessionCount=saved.Sessions.Count};
                // A slower older runspace may observe its own snapshot, but cannot replace newer evidence.
                var family=new Family{Observed=observed,Touched=now};
                foreach(var pair in saved.Sessions)family.Sessions[pair.Key]=CopySession(pair.Value);
                var current=new Dictionary<int,ProgramFamilyEvidence>();
                var duplicate=new HashSet<int>();
                foreach(var row in snapshot??new ProgramFamilyEvidence[0]) {
                    if(row.Id<=0)continue;
                    if(current.ContainsKey(row.Id)){duplicate.Add(row.Id);continue;}
                    current[row.Id]=row;
                }
                foreach(int id in duplicate)current.Remove(id);
                var members=new HashSet<int>();var unknown=new HashSet<int>();var retained=new HashSet<int>();
                foreach(var row in current.Values.Where(x=>x.Root)) {
                    // An exact-path root is observable even when creation-time identity is unavailable;
                    // it cannot seed or extend a parent/child relationship.
                    members.Add(row.Id);
                    if(!row.Verified){unknown.Add(row.Id);continue;}
                    if(!family.Sessions.ContainsKey(row.Key))family.Sessions[row.Key]=new Session{Root=row.Copy(),Touched=now};
                }
                foreach(var pair in family.Sessions.ToArray()) {
                    var session=pair.Value;var live=new Dictionary<int,ProgramFamilyEvidence>();
                    ProgramFamilyEvidence root;
                    bool rootAlive=current.TryGetValue(session.Root.Id,out root)&&session.Root.Same(root);
                    if(rootAlive)live[root.Id]=root;
                    foreach(var item in session.Members.ToArray()) {
                        ProgramFamilyEvidence row;
                        if(current.TryGetValue(item.Key,out row)) {
                            if(item.Value.Identity.Same(row)){live[row.Id]=row;item.Value.Seen=now;}
                            else if(!row.Verified && now-item.Value.Seen<=UnknownRetention)unknown.Add(row.Id);
                            else session.Members.Remove(item.Key);
                        } else if(duplicate.Contains(item.Key)){unknown.Add(item.Key);}
                        else session.Members.Remove(item.Key);
                    }
                    bool changed;
                    do {
                        changed=false;
                        foreach(var row in current.Values) {
                            if(live.ContainsKey(row.Id)||row.ParentId<=0)continue;
                            ProgramFamilyEvidence parent;
                            if(!live.TryGetValue(row.ParentId,out parent))continue;
                            if(!row.Verified){unknown.Add(row.Id);continue;}
                            if(!row.Inside||row.StartTicks<parent.StartTicks||live.Count>=MaxMembers)continue;
                            live[row.Id]=row;changed=true;
                        }
                    }while(changed);
                    foreach(var row in live.Values) {
                        members.Add(row.Id);
                        if(!rootAlive)retained.Add(row.Id);
                        session.Members[row.Id]=new Member{Identity=row.Copy(),Seen=now};
                    }
                    foreach(var member in session.Members.OrderByDescending(x=>live.ContainsKey(x.Key)).ThenByDescending(x=>x.Value.Seen).Skip(MaxMembers).ToArray())session.Members.Remove(member.Key);
                    if(live.Count>0)session.Touched=now;
                    if(session.Members.Count==0||now-session.Touched>UnknownRetention)family.Sessions.Remove(pair.Key);
                }
                foreach(var pair in family.Sessions.OrderByDescending(x=>x.Value.Touched).Skip(MaxSessions).ToArray())family.Sessions.Remove(pair.Key);
                if(observed>=saved.Observed) {
                    if(family.Sessions.Count>0)Families[scope]=family;else Families.Remove(scope);
                    foreach(var pair in Families.OrderByDescending(x=>x.Value.Touched).Skip(MaxFamilies).ToArray())Families.Remove(pair.Key);
                    int total=Families.Values.Sum(x=>x.Sessions.Values.Sum(y=>y.Members.Count));
                    foreach(var pair in Families.OrderBy(x=>x.Value.Touched).ToArray()) {
                        if(total<=MaxTotalMembers)break;
                        total-=pair.Value.Sessions.Values.Sum(x=>x.Members.Count);Families.Remove(pair.Key);
                    }
                }
                return new ProgramFamilyResult{MemberIds=members.ToArray(),UnknownIds=unknown.ToArray(),RetainedIds=retained.ToArray(),RootSessionCount=family.Sessions.Count};
            }
        }
        public static void Clear(string scope) {lock(Gate){Families.Remove(scope);}}
        public static int FamilyCount {get{lock(Gate){return Families.Count;}}}
        // Independent, current-snapshot observation only. No cross-directory
        // relationship is stored in Sessions or used by writable family rules.
        public static ProgramFamilyObservationResult ObserveCurrent(ProgramFamilyEvidence[] snapshot,bool available) {
            const int limit=128;
            if(!available)return new ProgramFamilyObservationResult();
            var rows=(snapshot??new ProgramFamilyEvidence[0]).Where(x=>x!=null&&x.Id>0).ToArray();
            var groups=rows.GroupBy(x=>x.Id).ToDictionary(x=>x.Key,x=>x.ToArray());
            var children=rows.Where(x=>x.ParentId>0).GroupBy(x=>x.ParentId).ToDictionary(x=>x.Key,x=>x.OrderBy(y=>y.Id).ToArray());
            var members=new Dictionary<int,ProgramFamilyEvidence>();var unknown=new HashSet<int>();var queue=new Queue<ProgramFamilyEvidence>();bool truncated=false;
            Action<int> markUnknown=id=>{if(unknown.Count<limit)unknown.Add(id);else truncated=true;};
            Func<ProgramFamilyEvidence,bool> verified=x=>x.Verified&&x.StartTicks>0&&!String.IsNullOrEmpty(x.Path)&&!String.IsNullOrEmpty(x.FileId);
            foreach(var group in groups.Values.Where(x=>x.Any(y=>y.Root)).OrderBy(x=>x[0].Id)) {
                var root=group[0];
                if(group.Length!=1||!verified(root)){markUnknown(root.Id);continue;}
                if(members.Count>=limit){truncated=true;continue;}
                members[root.Id]=root;queue.Enqueue(root);
            }
            while(queue.Count>0) {
                var parent=queue.Dequeue();ProgramFamilyEvidence[] descendants;
                if(!children.TryGetValue(parent.Id,out descendants))continue;
                foreach(var child in descendants) {
                    if(members.ContainsKey(child.Id))continue;
                    if(groups[child.Id].Length!=1||!verified(child)||child.StartTicks<parent.StartTicks){markUnknown(child.Id);continue;}
                    if(members.Count>=limit){truncated=true;continue;}
                    members[child.Id]=child;queue.Enqueue(child);
                }
            }
            return new ProgramFamilyObservationResult{MemberIds=members.Keys.ToArray(),ExternalIds=members.Values.Where(x=>!x.Inside&&!x.Root).Select(x=>x.Id).ToArray(),UnknownIds=unknown.ToArray(),Truncated=truncated};
        }
    }
}
'@
}
}finally{[Threading.Monitor]::Exit($familyTypeGate)}

function Get-ProgramFamilyTrackingScope([string]$Executable) {
    $data=Get-Variable DataRoot -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    ([string]$data).ToLowerInvariant()+'|'+(ConvertTo-ProgramIdentityPath $Executable).ToLowerInvariant()
}
function Get-ProgramFamilyTrackingSnapshot([string]$Executable,$Processes,$IdentityContext=$null,[bool]$ProcessesAvailable=$true) {
    $observed=[DateTime]::UtcNow.Ticks
    if($null -eq $IdentityContext){$IdentityContext=New-ProgramIdentityContext -Processes $Processes}
    # Context creation predates all family reads in the same refresh and orders competing runspaces.
    if($IdentityContext.PSObject.Properties['Created'] -and $IdentityContext.Created){$observed=([DateTime]$IdentityContext.Created).ToUniversalTime().Ticks}
    $normalized=ConvertTo-ProgramIdentityPath $Executable
    $root=Get-ProgramIdentityDescriptor $Executable $IdentityContext
    $directory='';if($root.CanonicalPath){$directory=[IO.Path]::GetDirectoryName($root.CanonicalPath)+'\'}
    $rows=New-Object 'Collections.Generic.List[LocalProxySwitch.ProgramFamilyEvidence]'
    $byId=@{}
    if($ProcessesAvailable){foreach($p in @($Processes)){
        $id=[int](Get-ProgramIdentityValue $p 'Id' 0);if($id -le 0){continue}
        $row=New-Object LocalProxySwitch.ProgramFamilyEvidence
        $row.Id=$id;$row.ParentId=[int](Get-ProgramIdentityValue $p 'ParentId' 0)
        $path=[string](Get-ProgramIdentityValue $p 'Path' '')
        if($path){
            $identity=Get-ProgramIdentityDescriptor $path $IdentityContext
            $row.Path=[string]$identity.CanonicalPath;$row.FileId=[string]$identity.FileId
            $row.Root=((ConvertTo-ProgramIdentityPath $path) -ieq $normalized) -or ($identity.Exists -and $root.Exists -and (($root.FileId -and $root.FileId -eq $identity.FileId) -or ($root.CanonicalPath -and $root.CanonicalPath -ieq $identity.CanonicalPath)))
            $row.Inside=$directory -and $row.Path -and $row.Path.StartsWith($directory,[StringComparison]::OrdinalIgnoreCase)
            $start=Get-ProgramIdentityValue $p 'StartTime' $null
            if($start -and [DateTime]$start -ne [DateTime]::MinValue){$row.StartTicks=([DateTime]$start).ToUniversalTime().Ticks}
            $pathStatus=[string](Get-ProgramIdentityValue $p 'PathStatus' 'Available')
            $row.Root=$row.Root -and $pathStatus -eq 'Available'
            $row.Verified=$row.StartTicks -gt 0 -and $identity.Exists -and $identity.PathStatus -eq 'Available' -and $pathStatus -eq 'Available' -and $row.Path -and $row.FileId
        }
        $rows.Add($row);$byId[$id]=$p
    }}
    $result=[LocalProxySwitch.ProgramFamilyTracker]::Observe((Get-ProgramFamilyTrackingScope $Executable),$rows.ToArray(),$observed,$ProcessesAvailable)
    $members=@(foreach($id in $result.MemberIds){if($byId.ContainsKey($id)){$byId[$id]}})
    $observation=[LocalProxySwitch.ProgramFamilyTracker]::ObserveCurrent($rows.ToArray(),$ProcessesAvailable)
    # Preserve existing same-installation orphan semantics, but extend observation
    # only through roots and intermediate parents verified in this very snapshot.
    $observationIds=@(@($result.MemberIds)+@($observation.MemberIds)|Select-Object -Unique)
    $observationUnknown=@(@($result.UnknownIds)+@($observation.UnknownIds)|Select-Object -Unique)
    $truncated=$observation.Truncated -or $observationIds.Count -gt 128 -or $observationUnknown.Count -gt 128
    $observationIds=@($observationIds|Select-Object -First 128);$observationUnknown=@($observationUnknown|Select-Object -First 128)
    $observationMembers=@(foreach($id in $observationIds){if($byId.ContainsKey($id)){$byId[$id]}})
    [pscustomobject]@{Members=$members;UnknownIds=@($result.UnknownIds);RetainedIds=@($result.RetainedIds);RootSessionCount=$result.RootSessionCount;Available=$ProcessesAvailable;ObservationMembers=$observationMembers;ObservationOnlyIds=@($observationIds|Where-Object {$result.MemberIds -notcontains $_});ObservationExternalIds=@($observation.ExternalIds|Where-Object {$observationIds -contains $_});ObservationUnknownIds=$observationUnknown;ObservationTruncated=$truncated;ObservationCoverage='跨目录成员仅用于本轮连接观察；须有当前完整父子身份链，最多128成员，不写程序规则或保留跨目录孤儿关系。';Coverage='本次工具会话内已观察并复核的同安装目录父子身份；未观察到的孤儿、身份不可读或跨安装目录进程不自动写入家族规则'}
}
