function Get-DemiAgentConfigurationPath { param([string]$Root);if(-not$Root){$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))};Join-Path $Root 'config\agents.json' }

function Get-DemiAgentRegistry {
    param([string]$Root,[switch]$IncludeDisabled)
    $path=Get-DemiAgentConfigurationPath $Root;if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return @()}
    $configuration=Get-Content -Raw -LiteralPath $path -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop;$seen=@{};$result=@()
    foreach($item in @($configuration.agents)){
        $handle="$($item.handle)".Trim().ToLowerInvariant();if($handle-notmatch'^[a-z][a-z0-9_-]{0,31}$'){throw "Invalid Demi agent handle '$handle'."};if($seen[$handle]){throw "Duplicate Demi agent handle '$handle'."};$seen[$handle]=$true
        $aliases=@($item.aliases|ForEach-Object{"$_".Trim().ToLowerInvariant()}|Where-Object{$_});foreach($alias in $aliases){if($alias-notmatch'^[a-z][a-z0-9_-]{0,31}$'){throw "Invalid alias '$alias' for Demi agent '$handle'."};if($seen[$alias]){throw "Duplicate Demi agent handle or alias '$alias'."};$seen[$alias]=$true}
        $enabled=-not$item.PSObject.Properties['enabled']-or[bool]$item.enabled;if(-not$enabled-and-not$IncludeDisabled){continue}
        $result+=[pscustomobject]@{Name="$($item.name)".Trim();Handle=$handle;Aliases=$aliases;Icon=$(if($item.icon){"$($item.icon)"}else{'●'});Color=$(if($item.color){"$($item.color)"}else{'#8fa3b8'});Role="$($item.role)";InstructionFile="$($item.instructionFile)";Kind="$($item.kind)";Model="$($item.model)";DirectEnabled=(-not$item.PSObject.Properties['directEnabled']-or[bool]$item.directEnabled);ParticipationMode=$(if($item.participationMode){"$($item.participationMode)"}else{'invited'});SynthesisEnabled=($item.PSObject.Properties['synthesisEnabled']-and[bool]$item.synthesisEnabled);Enabled=$enabled}
    };return @($result)
}

function Get-DemiAgent { param([string]$Name,[string]$Root);$token="$Name".Trim();$agent=Get-DemiAgentRegistry -Root $Root|Where-Object{$_.Name-ieq$token-or$_.Handle-ieq$token-or@($_.Aliases)-icontains$token}|Select-Object -First 1;if(-not$agent){throw "Unknown Demi agent '$Name'."};$agent }
function Resolve-DemiAgentToken { param([string]$Token,[string]$Root);try{Get-DemiAgent $Token $Root}catch{return $null} }
function Resolve-DemiAgentDirectAddress { param([string]$Token,[string]$Root);try{$agent=Get-DemiAgent $Token $Root;if(-not$agent.DirectEnabled){return $null};$agent}catch{return $null} }
function Get-DemiAutomaticAgentSequence { param([string]$Root);$agents=@(Get-DemiAgentRegistry -Root $Root);$ordinary=@($agents|Where-Object ParticipationMode -eq 'automatic'|ForEach-Object Name);$synthesis=@($agents|Where-Object SynthesisEnabled|ForEach-Object Name);return @($ordinary+$synthesis) }
function Get-DemiSynthesisAgents { param([string]$Root);return @(Get-DemiAgentRegistry -Root $Root|Where-Object SynthesisEnabled|ForEach-Object Name) }
function Save-DemiAgentConfiguration { param([string]$Root,[object]$Configuration);$path=Get-DemiAgentConfigurationPath $Root;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path));$temp="$path.$PID.tmp";try{[IO.File]::WriteAllText($temp,($Configuration|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force};[IO.File]::Move($temp,$path)}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}} }
function Add-DemiConfiguredAgent {
    param([string]$Root,[string]$Handle,[string]$Name,[ValidateSet('Claude','Codex','Antigravity','Ollama','HTTP')][string]$Kind,[string]$Model,[string]$Icon='●',[string]$Color='#8fa3b8')
    $handle=$Handle.Trim().ToLowerInvariant();$reserved=@('help','stop','status','review','note','continue','dispatch','run','retry','new-session','draft','fable','alice','all')
    if($handle-notmatch'^[a-z][a-z0-9_-]{0,31}$'-or$handle-in$reserved){throw "Agent handle '$handle' is invalid or reserved."};if([string]::IsNullOrWhiteSpace($Name)){throw 'Agent display name is required.'};if($Color-notmatch'^#[0-9a-fA-F]{6}$'){throw 'Agent color must be a six-digit hexadecimal color.'}
    $path=Get-DemiAgentConfigurationPath $Root;$configuration=if(Test-Path -LiteralPath $path){Get-Content -Raw -LiteralPath $path|ConvertFrom-Json}else{[pscustomobject]@{schemaVersion=1;agents=@()}}
    if(Resolve-DemiAgentToken $handle $Root){throw "Agent handle '$handle' already exists."}
    $new=[pscustomobject]@{name=$Name.Trim();handle=$handle;aliases=@();icon=$Icon;color=$Color;kind=$Kind;model=$Model;role='';instructionFile="agents\$handle.md";directEnabled=$true;participationMode='invited';enabled=$true}
    $configuration.agents=@($configuration.agents)+$new;Save-DemiAgentConfiguration $Root $configuration
    $instructionPath=Join-Path $Root "agents\$handle.md";if(-not(Test-Path -LiteralPath $instructionPath)){[void][IO.Directory]::CreateDirectory((Split-Path -Parent $instructionPath));[IO.File]::WriteAllText($instructionPath,"# $($Name.Trim())`r`n`r`nDescribe this agent's role, voice, and project responsibilities here.`r`n",[Text.UTF8Encoding]::new($false))}
    Get-DemiAgent $handle $Root
}
function Disable-DemiConfiguredAgent { param([string]$Root,[string]$Token);$path=Get-DemiAgentConfigurationPath $Root;$configuration=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json;$target=Get-DemiAgent $Token $Root;$match=@($configuration.agents|Where-Object{"$($_.handle)"-ieq$target.Handle})[0];$match.enabled=$false;Save-DemiAgentConfiguration $Root $configuration;$target }
function ConvertTo-DemiAntigravityStreamInput { param([string]$Prompt);([ordered]@{event='user';message=[ordered]@{role='user';content=@([ordered]@{type='text';text=$Prompt})}}|ConvertTo-Json -Compress -Depth 8)+"`n" }
function ConvertFrom-DemiAntigravityStreamOutput { param([string]$Output);$response=$null;foreach($line in($Output-split"`r?`n")){if([string]::IsNullOrWhiteSpace($line)-or-not$line.TrimStart().StartsWith('{')){continue};try{$item=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue};if($item.event-eq'result'-and$item.result.status-eq'SUCCESS'){$response=[string]$item.result.response}};if([string]::IsNullOrWhiteSpace($response)){throw 'Antigravity stream output did not contain a successful result response.'};$response }

function Get-DemiOllamaExecutable {
    $command=Get-Command ollama -ErrorAction SilentlyContinue
    if($command){return $command.Source}
    $candidates=@(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        (Join-Path $env:LOCALAPPDATA 'Ollama\ollama.exe'),
        (Join-Path $env:ProgramFiles 'Ollama\ollama.exe')
    )
    $found=$candidates|Where-Object{$_-and(Test-Path -LiteralPath $_ -PathType Leaf)}|Select-Object -First 1
    if(-not$found){throw 'Ollama was not found. Install Ollama, then restart Demi or verify the standard Windows installation path.'}
    return $found
}

function Get-DemiWindowsCaBundle {
    param([string]$Root);$certificateRoot=Join-Path $Root 'state\certificates';$bundlePath=Join-Path $certificateRoot 'windows-roots.pem';$refresh=-not(Test-Path -LiteralPath $bundlePath);if(-not$refresh){$refresh=(Get-Item -LiteralPath $bundlePath).LastWriteTimeUtc-lt[DateTime]::UtcNow.AddDays(-7)}
    if($refresh){[void][IO.Directory]::CreateDirectory($certificateRoot);$seen=@{};$blocks=[Collections.Generic.List[string]]::new();foreach($location in @('CurrentUser','LocalMachine')){$store=[Security.Cryptography.X509Certificates.X509Store]::new('Root',$location);try{$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly);foreach($certificate in $store.Certificates){if($seen[$certificate.Thumbprint]-or$certificate.NotAfter.ToUniversalTime()-le[DateTime]::UtcNow){continue};$seen[$certificate.Thumbprint]=$true;$base64=[Convert]::ToBase64String($certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert),[Base64FormattingOptions]::InsertLineBreaks);$blocks.Add("-----BEGIN CERTIFICATE-----`r`n$base64`r`n-----END CERTIFICATE-----")}}finally{$store.Dispose()}};[IO.File]::WriteAllText($bundlePath,($blocks-join"`r`n")+"`r`n",[Text.UTF8Encoding]::new($false))};$bundlePath
}

function New-DemiAgentInvocation {
    param([object]$Agent,[string]$Root,[string]$Prompt,[string]$ResponsePath,[int]$MaxTurns=10)
    switch($Agent.Kind){
        'Claude'{[pscustomobject]@{Executable=(Get-Command claude -ErrorAction Stop).Source;Arguments=@('-p','--model',$(if($Agent.Model){$Agent.Model}else{'sonnet'}),'--output-format','text','--max-turns',"$MaxTurns",'--tools','Read','--permission-mode','dontAsk','--no-session-persistence');StandardInput=$Prompt;ReadsStdout=$true}}
        'Codex'{$env:SSL_CERT_FILE=Get-DemiWindowsCaBundle $Root;if(-not$env:CODEX_HOME){$env:CODEX_HOME=Join-Path $env:USERPROFILE '.codex'};$desktopCli=$null;$configPath=Join-Path $env:USERPROFILE '.codex\config.toml';if(Test-Path -LiteralPath $configPath){$configText=Get-Content -Raw -LiteralPath $configPath -ErrorAction SilentlyContinue;$cliMatch=[regex]::Match($configText,'(?m)^\s*CODEX_CLI_PATH\s*=\s*[''"](?<Path>[^''"]+)[''"]');if($cliMatch.Success-and(Test-Path -LiteralPath $cliMatch.Groups['Path'].Value)){$desktopCli=$cliMatch.Groups['Path'].Value}};$cmd=Get-Command codex.cmd -ErrorAction SilentlyContinue;$nodeScript=if($cmd){Join-Path(Split-Path -Parent $cmd.Source)'node_modules\@openai\codex\bin\codex.js'}else{$null};if($desktopCli){$exe=$desktopCli;$prefix=@()}elseif($nodeScript-and(Test-Path -LiteralPath $nodeScript)){$exe=(Get-Command node -ErrorAction Stop).Source;$prefix=@($nodeScript)}elseif($cmd){$exe=$cmd.Source;$prefix=@()}else{$exe=Join-Path $PSHOME 'powershell.exe';$prefix=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Get-Command codex -ErrorAction Stop).Source)};[pscustomobject]@{Executable=$exe;Arguments=$prefix+@('--ask-for-approval','never','exec','--sandbox','read-only','--cd',$Root,'--output-last-message',$ResponsePath,'--ephemeral','-');StandardInput=$Prompt;ReadsStdout=$false}}
        'Antigravity'{$cmd=Get-Command agy -ErrorAction SilentlyContinue;$exe=if($cmd){$cmd.Source}else{Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'};if(-not(Test-Path -LiteralPath $exe)){throw 'Antigravity CLI (agy) was not found.'};[pscustomobject]@{Executable=$exe;Arguments=@('--input-format','stream-json','--output-format','stream-json','--mode','plan','--sandbox','--disable-slash-commands','--print=');StandardInput=(ConvertTo-DemiAntigravityStreamInput $Prompt);ReadsStdout=$true;StreamJson=$true}}
        'Ollama'{if(-not$Agent.Model){throw "Agent '$($Agent.Name)' needs an Ollama model."};[pscustomobject]@{Executable=(Get-DemiOllamaExecutable);Arguments=@('run',$Agent.Model,'--think=false','--hidethinking','--nowordwrap');StandardInput=$Prompt;ReadsStdout=$true}}
        'HTTP'{$usagePath="$ResponsePath.usage.json";[pscustomobject]@{Executable=(Get-Command node -ErrorAction Stop).Source;Arguments=@((Join-Path $PSScriptRoot 'runtime\http-agent-cli.js'),$Root,$Agent.Handle,$usagePath);StandardInput=$Prompt;ReadsStdout=$true;UsagePath=$usagePath}}
        default{throw "Agent adapter '$($Agent.Kind)' is not implemented."}
    }
}
