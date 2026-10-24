[CmdletBinding()]
param([string]$ProjectRoot,[string]$RuntimeRoot,[string]$OwnerName='Owner',[string]$ProjectName='Demi project',[switch]$InstallProfileCommand,[switch]$Force)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Write-Utf8([string]$Path,[string]$Content){$parent=Split-Path -Parent $Path;if($parent-and-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory $parent -Force|Out-Null};[IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($false))}
function Write-JsonNew([string]$Path,$Value){if(-not(Test-Path -LiteralPath $Path)){Write-Utf8 $Path ($Value|ConvertTo-Json -Depth 12)}}
function Copy-Tree([string]$Source,[string]$Destination){$s=[IO.Path]::GetFullPath($Source).TrimEnd('\');$d=[IO.Path]::GetFullPath($Destination).TrimEnd('\');if([string]::Equals($s,$d,[StringComparison]::OrdinalIgnoreCase)){return};if((Test-Path $d)-and-not$Force){Write-Warning "Kept existing $d. Use -Force to replace it.";return};if(Test-Path $d){Remove-Item -LiteralPath $d -Recurse -Force};Copy-Item -LiteralPath $s -Destination $d -Recurse -Force}
$sourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$root=if($ProjectRoot){[IO.Path]::GetFullPath($ProjectRoot)}else{$sourceRoot}
$runtime=if($RuntimeRoot){[IO.Path]::GetFullPath($RuntimeRoot)}else{Join-Path $root state}
if(-not(($runtime.TrimEnd('\')+'\').StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'RuntimeRoot must be inside ProjectRoot.'}
foreach($relative in @('agents','books','canon\bibles\current','canon\research','canon\indexes','commands\owner','config','database','decisions','inbox','outbox','proposals\open','proposals\accepted','proposals\rejected','sessions\archive','state')){New-Item -ItemType Directory (Join-Path $root $relative)-Force|Out-Null}
New-Item -ItemType Directory $runtime -Force|Out-Null
Copy-Tree (Join-Path $sourceRoot tools)(Join-Path $root tools)
Copy-Tree (Join-Path $sourceRoot 'database\migrations')(Join-Path $root 'database\migrations')
if(Test-Path (Join-Path $sourceRoot templates)){Copy-Tree (Join-Path $sourceRoot templates)(Join-Path $root templates)}
if(-not([string]::Equals($sourceRoot,$root,[StringComparison]::OrdinalIgnoreCase))){Copy-Item -LiteralPath (Join-Path $sourceRoot README.md) -Destination (Join-Path $root README.md) -Force}
$wrapper=@'
[CmdletBinding()]
param([string]$ProjectRoot,[string]$RuntimeRoot,[string]$OwnerName='Owner',[string]$ProjectName='Demi project',[switch]$InstallProfileCommand,[switch]$Force)
$a=@{};foreach($key in $PSBoundParameters.Keys){$a[$key]=$PSBoundParameters[$key]};if(-not$a.ContainsKey('ProjectRoot')){$a.ProjectRoot=$PSScriptRoot}
& (Join-Path $PSScriptRoot 'tools\setup-demi.ps1') @a
'@
if(-not(Test-Path (Join-Path $root setup-demi.ps1))){Write-Utf8 (Join-Path $root setup-demi.ps1)$wrapper}
$now=[DateTimeOffset]::Now.ToString('o')
$session=Join-Path $root 'sessions\session-001.md'
if(-not(Test-Path $session)){Write-Utf8 $session "# Session 001`r`n`r`n## S001-S0001 - System`r`nTimestamp: $now`r`nType: SESSION OPENED`r`n`r`nCollaboration environment created. Waiting for the project owner.`r`n"}
Write-JsonNew (Join-Path $runtime collaboration.json)([ordered]@{schemaVersion=1;sessionNumber=1;currentSession='sessions\session-001.md';focus=[ordered]@{book=$null;story=$null;characters=@();keywords=@();updatedAt=$null};entryCounter=1;roundCounter=0;lastEntry='S001-S0001';lastAuthor='System';lastUpdated=$now;round=[ordered]@{id=$null;status='waiting_for_human';remainingResponses=0;nextSpeaker=$OwnerName;target='Both';openedBy=$null};usage=[ordered]@{claude=[ordered]@{percentConsumed=$null;reportedAt=$null;source=$null};rowan=[ordered]@{percentConsumed=$null;reportedAt=$null;source=$null}}})
Write-JsonNew (Join-Path $runtime project-manifest.json)([ordered]@{schemaVersion=2;projectName=$ProjectName;currentSession='sessions\session-001.md';currentBook=$null;currentStory=$null;focusCharacters=@();keywords=@();currentManuscript=$null;decisions='decisions\owner-decisions.md';openItems='decisions\open-items.md'})
Write-JsonNew (Join-Path $root config\storage.json)([ordered]@{schemaVersion=1;backend='files';fallback='files';projectSlug='demi-project';mirrorWrites=$false;allowAutomaticStartupFallback=$true;allowAutomaticMidSessionFallback=$false;exportMarkdownTranscripts=$true})
Write-JsonNew (Join-Path $root config\database.json)([ordered]@{host='127.0.0.1';port=5432;database='demi';adminUser='postgres';ownerRole='demi_owner';applicationUser='demi_app';schema='demi'})
Write-JsonNew (Join-Path $root config\agents.json)([ordered]@{schemaVersion=1;agents=@()})
Write-JsonNew (Join-Path $root config\humans.json)([ordered]@{schemaVersion=1;humans=@([ordered]@{id='owner';sourceAuthor=$OwnerName;displayName=$OwnerName;color='#e2a93b';role='owner';canSetCanon=$true;enabled=$true})})
Write-JsonNew (Join-Path $root config\project-links.json)([ordered]@{schemaVersion=1;menuLabel='Project links';links=@([ordered]@{label='Timeline';category='Project';target='timeline.html';description='Search, filter, and sort dated project events.'})})
Write-JsonNew (Join-Path $root config\project.json)([ordered]@{schemaVersion=1;name=$ProjectName;description='';goals='';authority="$OwnerName is the project owner and final decision authority.";sharedInstructions='';sourceFiles=@('COLLABORATION.md','state\project-manifest.json')})
Write-JsonNew (Join-Path $root config\agent-memory.json)([ordered]@{schemaVersion=1;enabled=$false;provider='postgresql';fallback='files';readCapabilities=@('session-summaries','claims','documents','entities','timeline');writeCapabilities=@();agents=@();maximumItemsPerKind=4;maximumContextCharacters=5000})
Write-JsonNew (Join-Path $root config\session-context.json)([ordered]@{schemaVersion=1;recentEntryCount=20;modelSizedRecentWindows=$true;modelWindowEntries=[ordered]@{under14B=8;'14BTo19B'=14;'20BAndAbove'=20;cloudOrUnknown=20};agentOverrides=[ordered]@{};recentContextMaximumCharacters=30000;earlierSummaryMaximumCharacters=6000;retrievedOlderEntryCount=6;databaseSessionsUnlimited=$true})
$starters=[ordered]@{'COLLABORATION.md'="# Shared collaboration rules`r`n`r`n- The project owner alone determines final canon.`r`n- Agents may suggest, review, and propose; an item becomes canon only when the owner confirms it.`r`n- Session entries are append-only.`r`n";'decisions\owner-decisions.md'="# Owner decisions`r`n";'decisions\open-items.md'="# Open items`r`n";'state\timeline.json'="{`r`n  `"schemaVersion`": 1,`r`n  `"events`": []`r`n}"}
foreach($relative in $starters.Keys){$path=Join-Path $root $relative;if(-not(Test-Path $path)){Write-Utf8 $path $starters[$relative]}}
if(-not(Test-Path (Join-Path $runtime notifications.log))){Write-Utf8 (Join-Path $runtime notifications.log)''}
Write-Utf8 (Join-Path $root .demi-runtime-path)$runtime
if($InstallProfileCommand){$profilePath=$PROFILE.CurrentUserAllHosts;$dir=Split-Path -Parent $profilePath;if(-not(Test-Path $dir)){New-Item -ItemType Directory $dir -Force|Out-Null};$existing=if(Test-Path $profilePath){Get-Content -Raw $profilePath}else{''};if($existing-notmatch'# BEGIN DEMI COMMAND'){$script=(Join-Path $root 'tools\demi.js').Replace("'","''");[IO.File]::AppendAllText($profilePath,"`r`n# BEGIN DEMI COMMAND`r`nfunction global:demi { & node '$script' @args }`r`n# END DEMI COMMAND`r`n",[Text.UTF8Encoding]::new($false))}}
Write-Output "Demi is ready at $root"
Write-Output "Run: node '$root\tools\demi.js' status"
