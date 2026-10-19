# Explicit, read-only observation of an already configured external controller.
# Never enable a controller, discover ports, follow redirects, or return raw API data.
function Get-ExternalMihomoConfigPath {
    Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'
}
function ConvertFrom-ExternalMihomoScalar([string]$Value) {
    $text=$Value.Trim()
    if($text.StartsWith('"')){
        if($text -notmatch '^"(?:[^"\\]|\\.)*"$'){throw 'unsupported-config'}
        return [string]($text|ConvertFrom-Json -ErrorAction Stop)
    }
    if($text.StartsWith("'")){
        if($text -notmatch "^'(?:[^']|'')*'$"){throw 'unsupported-config'}
        return $text.Substring(1,$text.Length-2).Replace("''","'")
    }
    if($text -match '[\s#\[\]{}&*!|>"''`]' -or $text -match '^(null|~)$'){throw 'unsupported-config'}
    $text
}
function Read-ExternalMihomoController {
    $path=Get-ExternalMihomoConfigPath
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return [pscustomobject]@{State='not-configured'}}
    try{
        $file=Get-Item -LiteralPath $path -ErrorAction Stop
        if($file.Length -gt 2097152){throw 'unsupported-config'}
        # Bounded read also protects against a configuration growing during the read.
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        try{
            $buffer=New-Object byte[] 2097153;$length=0
            while($length -lt $buffer.Length){$read=$stream.Read($buffer,$length,$buffer.Length-$length);if($read -eq 0){break};$length+=$read}
            if($length -gt 2097152){throw 'unsupported-config'}
            $text=[Text.Encoding]::UTF8.GetString($buffer,0,$length).TrimStart([char]0xfeff)
        }finally{$stream.Dispose()}
        $controller='';$secret='';$seen=@{}
        foreach($line in ($text -split '\r?\n')){
            if($line -notmatch '^(external-controller|secret):\s*(.*?)\s*$'){continue}
            $name=$Matches[1];$value=$Matches[2]
            if($seen.ContainsKey($name)){throw 'unsupported-config'};$seen[$name]=$true
            $value=ConvertFrom-ExternalMihomoScalar $value
            if($name -eq 'external-controller'){$controller=$value}else{$secret=$value}
        }
        if(-not $controller){return [pscustomobject]@{State='not-configured'}}
        # No DNS, userinfo, paths, remote controllers, or HTTPS fallback.
        if($controller -notmatch '^(?:http://)?(127\.0\.0\.1|localhost|\[::1\]):([0-9]{1,5})$'){return [pscustomobject]@{State='controller-rejected'}}
        $address=$Matches[1];$port=[int]$Matches[2]
        if($port -lt 1 -or $port -gt 65535){return [pscustomobject]@{State='controller-rejected'}}
        if($address -eq 'localhost'){$address='127.0.0.1'}
        if($secret.Length -gt 1024 -or $secret -match '[\r\n\x00-\x1f\x7f]'){throw 'unsupported-config'}
        # Secret is confined to this in-process object and the request header.
        [pscustomobject]@{State='configured';Uri=('http://'+$address+':'+$port+'/connections');Secret=$secret}
    }catch{[pscustomobject]@{State='config-unknown'}}
}
function Invoke-ExternalMihomoConnections($Controller,[int]$TimeoutMilliseconds=2000,[int]$MaxBytes=2097152) {
    $request=$null;$response=$null;$stream=$null;$memory=$null
    try{
        if($TimeoutMilliseconds -lt 1 -or $TimeoutMilliseconds -gt 3000 -or $MaxBytes -lt 1 -or $MaxBytes -gt 2097152){return [pscustomobject]@{State='response-rejected'}}
        # Validate again at the transport boundary. Only this one GET endpoint is allowed.
        if($Controller.Uri -notmatch '^http://(127\.0\.0\.1|\[::1\]):([0-9]{1,5})/connections$'){return [pscustomobject]@{State='controller-rejected'}}
        $port=[int]$Matches[2];if($port -lt 1 -or $port -gt 65535){return [pscustomobject]@{State='controller-rejected'}}
        $request=[Net.HttpWebRequest]::Create([string]$Controller.Uri)
        $request.Method='GET';$request.Proxy=$null;$request.AllowAutoRedirect=$false
        $request.Timeout=$TimeoutMilliseconds;$request.ReadWriteTimeout=$TimeoutMilliseconds;$request.KeepAlive=$false
        if($Controller.Secret){$request.Headers['Authorization']='Bearer '+$Controller.Secret}
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $response=$request.GetResponse()
        if([int]$response.StatusCode -ne 200){return [pscustomobject]@{State='response-rejected'}}
        if($response.ContentLength -gt $MaxBytes){return [pscustomobject]@{State='response-too-large'}}
        $stream=$response.GetResponseStream();$memory=New-Object IO.MemoryStream;$buffer=New-Object byte[] 8192
        while($true){
            $remaining=$TimeoutMilliseconds-[int]$clock.ElapsedMilliseconds
            if($remaining -le 0){return [pscustomobject]@{State='timeout'}}
            if($stream.CanTimeout){$stream.ReadTimeout=$remaining}
            $read=$stream.Read($buffer,0,$buffer.Length);if($read -eq 0){break}
            if($memory.Length+$read -gt $MaxBytes){return [pscustomobject]@{State='response-too-large'}}
            $memory.Write($buffer,0,$read)
        }
        if($clock.ElapsedMilliseconds -gt $TimeoutMilliseconds){return [pscustomobject]@{State='timeout'}}
        $data=[Text.Encoding]::UTF8.GetString($memory.ToArray())|ConvertFrom-Json -ErrorAction Stop
        if(-not $data -or -not $data.PSObject.Properties['connections'] -or $data.connections -isnot [Array]){return [pscustomobject]@{State='response-rejected'}}
        [pscustomobject]@{State='observed';Data=$data}
    }catch [Net.WebException]{
        $errorResponse=$_.Exception.Response
        try{
            $status=if($errorResponse){[int]$errorResponse.StatusCode}else{0}
            $state=if($status -in @(401,403)){'authentication-failed'}elseif($_.Exception.Status -eq [Net.WebExceptionStatus]::Timeout){'timeout'}else{'unavailable'}
            [pscustomobject]@{State=$state}
        }finally{if($errorResponse){$errorResponse.Dispose()}}
    }catch{[pscustomobject]@{State='unavailable'}}
    finally{if($stream){$stream.Dispose()};if($memory){$memory.Dispose()};if($response){$response.Dispose()};if($request){$request.Abort()}}
}
function Protect-ExternalMihomoLabel([string]$Value,[string]$Secret='') {
    # Route names are the only external free text shown. Hide URLs, credentials,
    # controls, oversized text, and unsupported characters instead of echoing them.
    if(-not $Value -or $Value.Length -gt 64 -or $Value -notmatch '^(?:[\p{L}\p{N}\p{M}\p{So} ._()\[\]+/|\-]|[\uD83C-\uD83E][\uDC00-\uDFFF])+$' -or $Value -match '(?i)(token|secret|password|authorization|bearer)' -or ($Secret -and $Value.Contains($Secret))){return '已隐藏'}
    $Value
}
function Get-ExternalMihomoSource($Metadata,$Tcp) {
    if(-not $Tcp.Available){return '来源未知'}
    $address=$null;$port=0
    if(-not [Net.IPAddress]::TryParse([string]$Metadata.sourceIP,[ref]$address) -or -not [int]::TryParse([string]$Metadata.sourcePort,[ref]$port) -or $port -lt 1 -or $port -gt 65535){return '来源未知'}
    $rows=@($Tcp.Rows|Where-Object { $_.State -eq 'Established' -and [string]$_.LocalAddress -ceq $address.ToString() -and $_.LocalPort -eq $port })
    # The endpoint must identify exactly one current socket, not merely one PID.
    if($rows.Count -ne 1){return '来源未知'}
    try{
        $owner=@(Get-ProcessInventory -Id ([int]$rows[0].OwningProcess))
        if($owner.Count -eq 1 -and $owner[0].Path -and $owner[0].ProcessName -ieq 'ChatGPT' -and [IO.Path]::GetFileName($owner[0].Path) -ieq 'ChatGPT.exe' -and $owner[0].StartTime -gt [DateTime]::MinValue){return 'ChatGPT（本机 TCP 对应）'}
    }catch{}
    '来源未知'
}
function ConvertTo-ExternalMihomoObservation($Data,$Tcp,[string]$Secret='') {
    $allowed=@('chatgpt.com','ws.chatgpt.com','api.openai.com','chat.openai.com','auth.openai.com')
    $types=@('Tun','HTTP','HTTPS','Socks4','Socks5','Mixed','Redir','TProxy','Inner')
    $rules=@('Domain','DomainSuffix','DomainKeyword','IPCIDR','SrcIPCIDR','ProcessName','ProcessPath','RuleSet','Match','GEOIP','GEOSITE','DST-PORT','SRC-PORT','DOMAIN','DOMAIN-SUFFIX','DOMAIN-KEYWORD','IP-CIDR','IP-CIDR6','PROCESS-NAME','PROCESS-PATH','RULE-SET','MATCH','AND','OR','NOT')
    $groups=@{};$count=0;$sources=@{};$sourceQueries=0;$examined=0
    foreach($connection in @($Data.connections)){
        if($examined -ge 4096){break};$examined++
        $metadata=$connection.metadata;$domain=([string]$metadata.host).ToLowerInvariant()
        if($domain -notin $allowed){continue};$count++
        $type=if([string]$metadata.type -in $types){[string]$metadata.type}else{'未知'}
        $rule=if([string]$connection.rule -in $rules){[string]$connection.rule}else{'未知'}
        $chains=@();$rawChains=@($connection.chains)
        foreach($name in @($rawChains|Select-Object -First 6)){$chains+=Protect-ExternalMihomoLabel ([string]$name) $Secret}
        if($rawChains.Count -gt 6){$chains+='…'}
        # Mihomo returns exit first, then enclosing selectors. Present policy -> exit.
        [array]::Reverse($chains)
        # One snapshot-local cache and at most 32 process identity lookups.
        # Unseen endpoints above that bound remain unknown.
        $sourceKey=([string]$metadata.sourceIP)+'|'+([string]$metadata.sourcePort)
        $source='来源未知'
        if($sources.ContainsKey($sourceKey)){$source=$sources[$sourceKey]}
        elseif($sourceQueries -lt 32){$sourceQueries++;$source=Get-ExternalMihomoSource $metadata $Tcp;$sources[$sourceKey]=$source}
        # No connection ID, URL, IP, port, process path, payload, or raw object escapes.
        $key=@($domain,$type,$rule,$source,($chains -join ' → '))|ConvertTo-Json -Compress
        if($groups.ContainsKey($key)){$groups[$key].Count++}
        elseif($groups.Count -lt 6){$groups[$key]=[pscustomobject]@{Host=$domain;Type=$type;Rule=$rule;Chains=$chains;Source=$source;Count=1}}
    }
    [pscustomobject]@{State=$(if($count){'observed'}else{'no-connections'});ConnectionCount=$count;Rows=@($groups.Values|Sort-Object Host,Type,Rule,Source);Truncated=(@($Data.connections).Count -gt $examined);AuthenticationVerified=$false}
}
function Get-ExternalMihomoObservation($Tcp) {
    $controller=Read-ExternalMihomoController
    if($controller.State -ne 'configured'){return [pscustomobject]@{State=$controller.State;ConnectionCount=0;Rows=@();AuthenticationVerified=$false}}
    try{
        $response=Invoke-ExternalMihomoConnections $controller
        if($response.State -ne 'observed'){return [pscustomobject]@{State=$response.State;ConnectionCount=0;Rows=@();AuthenticationVerified=$false}}
        ConvertTo-ExternalMihomoObservation $response.Data $Tcp $controller.Secret
    }catch{[pscustomobject]@{State='unavailable';ConnectionCount=0;Rows=@();AuthenticationVerified=$false}}
    finally{$controller.Secret=''}
}
function Format-ExternalMihomoObservation($Observation) {
    $lines=@('外部 Mihomo 连接证据（本次手动读取，最多 6 组）：')
    $notes=@{'not-configured'='未找到已有的本地控制接口配置；请在原代理客户端查看连接。';'controller-rejected'='控制地址不是允许的回环入口，未请求。';'config-unknown'='现有配置无法安全读取，状态未知。';'authentication-failed'='现有控制接口认证失败；请在原代理客户端检查，不自动修改凭据。';'timeout'='读取超时，连接与节点未知。';'response-too-large'='响应超过安全大小限制，连接与节点未知。';'response-rejected'='控制接口响应无法核验，连接与节点未知。';'unavailable'='现有控制接口无法读取，连接与节点未知。';'no-connections'='未观察到固定 OpenAI 域名连接；短连接、其他域名或采样间隙仍可能遗漏。'}
    if($Observation.State -eq 'observed'){
        foreach($row in $Observation.Rows){$lines+=($row.Host+' · 入口 '+$row.Type+' · 规则 '+$row.Rule+' · 链（策略→出口） '+($row.Chains -join ' → ')+' · '+$row.Source+' ×'+$row.Count)}
        if($Observation.ConnectionCount -gt (($Observation.Rows|Measure-Object Count -Sum).Sum)){$lines+='其他匹配连接已省略。'}
    }elseif($notes.ContainsKey([string]$Observation.State)){$lines+=$notes[[string]$Observation.State]}else{$lines+='连接与节点未知。'}
    if($Observation.Truncated){$lines+='响应连接较多，本次仅检查前 4096 条；计数与未观察结论均不涵盖省略部分。'}
    $lines+='连接链是该快照的转发证据，不能证明登录、认证或持续对话成功；来源不唯一时保持未知。'
    $lines -join "`r`n"
}
