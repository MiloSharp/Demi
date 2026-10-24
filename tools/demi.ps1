[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('say','alice','checkin','respond','continue','stop','status','note','direct','review','manuscript','new-session','session','usage','watch','validate','dispatch','run','draft','fable','draft-save','entry-save','chat','web','database','storage','timeline','timeline-save','timeline-delete','agent','inventory','help')]
    [string]$Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Arguments,

    [string]$ProjectRoot,
    [string]$To = 'Both',
    [switch]$Each,
    [switch]$NoAck,
    [switch]$NoDispatch,
    [string]$File,
    [ValidateSet('md','txt','docx')]
    [string]$Format = 'md',
    [switch]$ResponsesOnly,
    [switch]$Json,
    [switch]$DryRun,
    [ValidateRange(1,12)]
    [int]$MaxResponses = 12,
    [ValidateRange(1024,1048576)]
    [int]$MaxOutputBytes = 65536,
    [ValidateRange(1,20)]
    [int]$AgentMaxTurns = 10,
    [ValidateRange(30,1800)]
    [int]$AgentTimeoutSeconds = 900,
    [ValidateRange(1,100)]
    [int]$UsageLimitPercent = 90,
    [ValidateRange(4096,10485760)]
    [int]$MaxSessionBytes = 1048576
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'demi-root.ps1')
. (Join-Path $PSScriptRoot 'demi-documents.ps1')
. (Join-Path $PSScriptRoot 'demi-agents.ps1')
. (Join-Path $PSScriptRoot 'demi-storage.ps1')
. (Join-Path $PSScriptRoot 'demi-session-store.ps1')
. (Join-Path $PSScriptRoot 'demi-agent-memory.ps1')
$installedProjectRoot = Get-DemiProjectRootFromToolsDirectory $PSScriptRoot

function Get-DemiContext {
    param([string]$ExplicitRoot)
    $candidate = if ($ExplicitRoot) {
        (Resolve-Path -LiteralPath $ExplicitRoot).Path
    } else {
        $installedProjectRoot
    }
    $candidate = Assert-DemiProjectRoot $candidate
    $pointer = Join-Path $candidate '.demi-runtime-path'
    if (Test-Path -LiteralPath $pointer) {
        $runtime = (Get-Content -Raw -LiteralPath $pointer -Encoding UTF8).Trim()
        if (-not [System.IO.Path]::IsPathRooted($runtime)) {
            $runtime = [System.IO.Path]::GetFullPath((Join-Path $candidate $runtime))
        }
        if (-not (Test-Path -LiteralPath (Join-Path $runtime 'collaboration.json'))) {
            throw "Runtime state is missing at $runtime. Rerun setup-demi.ps1."
        }
        return [pscustomobject]@{ ProjectRoot = $candidate; RuntimeRoot = $runtime }
    }
    if (Test-Path -LiteralPath (Join-Path $candidate 'state\collaboration.json')) {
        return [pscustomobject]@{ ProjectRoot = $candidate; RuntimeRoot = $candidate }
    }
    throw 'Could not locate a Demiurge collaboration project. Run setup-demi.ps1 first or pass -ProjectRoot.'
}

function Read-JsonFile {
    param([string]$Path)
    $lastError = $null
    foreach ($attempt in 1..8) {
        try {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw [IO.FileNotFoundException]::new("Missing state file: $Path",$Path) }
            return Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        } catch [IO.IOException], [System.Management.Automation.ItemNotFoundException], [System.Management.Automation.RuntimeException] {
            $lastError = $_
            if ($attempt -lt 8) { Start-Sleep -Milliseconds (15 * $attempt); continue }
        }
    }
    throw $lastError
}

function Set-Utf8NoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $directory = Split-Path -Parent $Path
    if ($directory) { [void][IO.Directory]::CreateDirectory($directory) }
    $temp = "$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Set-Utf8NoBom -Path $temp -Content ($Value | ConvertTo-Json -Depth 12)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backup = "$Path.$PID.$([guid]::NewGuid().ToString('N')).replace-backup"
            try { [IO.File]::Replace($temp,$Path,$backup,$true) }
            finally { if(Test-Path -LiteralPath $backup -PathType Leaf){Remove-Item -LiteralPath $backup -Force} }
        } else {
            [IO.File]::Move($temp,$Path)
        }
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Invoke-WithLock {
    param([string]$LockPath, [scriptblock]$Action, [int]$TimeoutSeconds = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $exclusiveLock = "$LockPath.exclusive-lock"
    $lockStream = $null
    $acquired = $false
    while (-not $acquired) {
        try {
            $lockStream = [IO.File]::Open($exclusiveLock,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $owner = [Text.Encoding]::UTF8.GetBytes(([ordered]@{pid=$PID;acquiredAt=[DateTimeOffset]::Now.ToString('o')} | ConvertTo-Json -Compress))
            $lockStream.Write($owner,0,$owner.Length); $lockStream.Flush($true)
            $acquired = $true
        } catch [System.IO.IOException] {
            if (Test-Path -LiteralPath $exclusiveLock -PathType Leaf) {
                $age = [DateTime]::UtcNow - (Get-Item -LiteralPath $exclusiveLock).LastWriteTimeUtc
                if ($age.TotalMinutes -gt 10) { Remove-Item -LiteralPath $exclusiveLock -Force -ErrorAction SilentlyContinue; continue }
            }
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "Timed out waiting for collaboration lock: $LockPath"
            }
            Start-Sleep -Milliseconds 150
        }
    }
    try { & $Action } finally { if($lockStream){$lockStream.Dispose()}; Remove-Item -LiteralPath $exclusiveLock -Force -ErrorAction SilentlyContinue }
}

function Get-SessionPath {
    param([string]$Root, [object]$State)
    return Join-Path $Root $State.currentSession
}

function Get-DemiSessionFocusMetadata {
    param([string]$Root, [string]$SessionName)
    $metadataPath = Join-Path $Root 'state\session-metadata.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return $null }
    $metadata = Read-JsonFile $metadataPath
    if (-not $metadata.sessions) { return $null }
    $property = $metadata.sessions.PSObject.Properties[$SessionName]
    if (-not $property -or -not $property.Value.PSObject.Properties['focus']) { return $null }
    return Copy-DemiValue $property.Value.focus
}

function Get-DemiFocus {
    param([object]$State)
    if ($State.PSObject.Properties['round'] -and $State.round -and $State.round.PSObject.Properties['focus'] -and $State.round.focus) { return $State.round.focus }
    if ($State.PSObject.Properties['focus'] -and $State.focus) { return $State.focus }
    return $null
}

function Test-DemiDatabaseSessionMode {
    param([string]$Root)
    $storagePath = Join-Path $Root 'config\storage.json'
    $policyPath = Join-Path $Root 'config\session-context.json'
    if (-not (Test-Path -LiteralPath $storagePath -PathType Leaf)) { return $false }
    try {
        $storage = Read-JsonFile $storagePath
        $policy = if (Test-Path -LiteralPath $policyPath -PathType Leaf) { Read-JsonFile $policyPath } else { $null }
        return "$($storage.backend)" -eq 'postgresql' -and (-not $policy -or -not $policy.PSObject.Properties['databaseSessionsUnlimited'] -or [bool]$policy.databaseSessionsUnlimited)
    } catch { return $false }
}

function Get-DemiDatabaseSessionContext {
    param([string]$Root,[string]$SessionPath,[string]$Agent)
    if (-not (Test-DemiDatabaseSessionMode $Root)) { return '' }
    try {
        $node = (Get-Command node -ErrorAction Stop).Source
        $renderer = Join-Path $Root 'tools\runtime\context-runtime.js'
        $context = & $node $renderer '--render' $Root $SessionPath $Agent 2>&1
        if ($LASTEXITCODE -ne 0) { throw (($context | Out-String).Trim()) }
        return ($context | Out-String).Trim()
    } catch {
        Write-Warning "Database context window could not be prepared; Demi will use its normal file context for this dispatch: $($_.Exception.Message)"
        return ''
    }
}

function Format-DemiFocusPrompt {
    param([object]$State)
    $focus = Get-DemiFocus $State
    if (-not $focus) { return 'ACTIVE WORK CONTEXT: Not set. Infer cautiously from the active request; do not default to a prior book.' }
    $book = if ($focus.PSObject.Properties['book'] -and $focus.book) { "$($focus.book)" } else { 'Unassigned' }
    $story = if ($focus.PSObject.Properties['story'] -and $focus.story) { "$($focus.story)" } else { 'Unassigned' }
    $characters = if ($focus.PSObject.Properties['characters']) { @($focus.characters) -join ', ' } else { '' }
    $keywords = if ($focus.PSObject.Properties['keywords']) { @($focus.keywords) -join ', ' } else { '' }
@"
ACTIVE WORK CONTEXT (authoritative routing metadata)
Book: $book
Story: $story
Focus characters/designers: $(if($characters){$characters}else{'Unassigned'})
Keywords: $(if($keywords){$keywords}else{'None'})
Apply domain- or subject-specific guidance only when it matches this context. Do not substitute an unrelated earlier subject merely because its guidance is globally available.
"@
}

function Get-DemiBoundedText {
    param([string]$Text,[int]$MaximumCharacters)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $clean = $Text.Trim()
    if ($clean.Length -le $MaximumCharacters) { return $clean }
    return $clean.Substring(0,$MaximumCharacters).TrimEnd() + "`n[…context shortened by Demi…]"
}

function Get-DemiLocalContextTokens {
    param([string]$Text)
    $stop = @('about','after','again','agent','also','because','being','book','colony','could','current','demi','demiurge','diaspora','discussion','does','exact','first','from','have','into','just','more','needs','only','other','project','series','session','should','still','summary','that','their','them','then','there','these','they','this','through','what','when','where','which','with','world','would','your')
    return @([regex]::Matches("$Text",'(?i)[\p{L}\p{N}][\p{L}\p{N}_-]{3,}') |
        ForEach-Object { $_.Value.ToLowerInvariant() } |
        Where-Object { $_ -notin $stop } |
        Select-Object -Unique -First 36)
}

function Resolve-DemiFocusSilo {
    param([object]$Focus)
    if(-not$Focus){return $null}
    foreach($candidate in @($Focus.book,$Focus.story)){
        $value="$candidate".Trim().ToLowerInvariant()
        if($value-match'^[a-z0-9][a-z0-9._-]*$'){return $value}
    }
    return $null
}
function Get-DemiRelevantSourceExcerpts {
    param([string]$Root,[string]$Query,[object]$Focus,[int]$MaximumCharacters=2500)
    $inventoryPath=Join-Path $Root 'state\database\source-inventory.json'
    if(-not(Test-Path -LiteralPath $inventoryPath -PathType Leaf)){return ''}
    try{$inventory=Read-JsonFile $inventoryPath}catch{return ''}
    $tokens=@(Get-DemiLocalContextTokens $Query)
    $focusSilo=Resolve-DemiFocusSilo $Focus
    $scored=foreach($source in @($inventory.sources)){
        $path="$($source.relativePath)";if(-not$path-or$path-match'(?i)(^|/)(archive|drafting|sessions|inbox)(/|$)'){continue}
        if("$($source.sourceKind)"-in@('instructions','session','archive')){continue}
        if("$($source.suggestedSilo)"-in@('unassigned','web')){continue}
        $score=0;$relevant=$false
        if("$($source.suggestedSilo)"-eq'global'){$score+=2}
        if($focusSilo-and"$($source.suggestedSilo)"-eq$focusSilo){$score+=12;$relevant=$true}
        if($path-match'(?i)(^|/)current/'){$score+=4}
        if("$($source.sourceKind)"-eq'bible'){$score+=3}
        foreach($token in $tokens){if($path-match("(?i)(^|[^a-z0-9])"+[regex]::Escape($token)+"([^a-z0-9]|$)")){$score+=5;$relevant=$true}}
        if($relevant){[pscustomobject]@{Source=$source;Score=$score}}
    }
    $selected=[Collections.Generic.List[object]]::new();$seenFamilies=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($item in @($scored|Sort-Object -Property @{Expression='Score';Descending=$true},@{Expression={"$($_.Source.relativePath)"};Descending=$false})){
        $family=if($item.Source.versionFamily){"$($item.Source.versionFamily)"}elseif($item.Source.artifactStem){"$($item.Source.artifactStem)"}else{"$($item.Source.relativePath)"}
        if($seenFamilies.Add($family)){$selected.Add($item)}
        if($selected.Count-ge4){break}
    }
    $parts=[Collections.Generic.List[string]]::new()
    foreach($item in $selected){
        $relative="$($item.Source.relativePath)";$absolute=Join-Path $Root $relative.Replace('/','\')
        if(-not(Test-Path -LiteralPath $absolute -PathType Leaf)){continue}
        try{
            $representation=Get-DemiDocumentRepresentation $Root $relative
            $content=Get-Content -Raw -LiteralPath $representation.Path -Encoding UTF8
            $position=-1
            foreach($token in $tokens){$candidate=$content.IndexOf($token,[StringComparison]::OrdinalIgnoreCase);if($candidate-ge0-and($position-lt0-or$candidate-lt$position)){$position=$candidate}}
            $start=if($position-gt350){$position-350}else{0};$length=[Math]::Min(1500,$content.Length-$start)
            if($length-le0){continue};$excerpt=$content.Substring($start,$length).Trim()
            $parts.Add("SOURCE: $relative`n$excerpt")
            if(($parts-join"`n`n").Length-ge$MaximumCharacters){break}
        }catch{continue}
    }
    return Get-DemiBoundedText ($parts-join"`n`n") $MaximumCharacters
}

function Get-DemiProjectCatalogContext {
    param([string]$Root)
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add('PROJECT CONTENT AREAS')
    foreach($folder in @('books','canon','agents','inbox')){
        $path=Join-Path $Root $folder
        if(Test-Path -LiteralPath $path){$count=@(Get-ChildItem -LiteralPath $path -File -Recurse -ErrorAction SilentlyContinue).Count;$lines.Add("- ${folder}: $count files")}
    }
    $lines.Add('Treat file presence as project evidence, not as publication or approval status.')
    return ($lines-join"`n")
}
function Get-DemiPreparedAgentContext {
    param([string]$Agent,[object]$State,[string]$SessionPath,[string]$ActiveText)
    $agentDefinition=Get-DemiAgent $Agent
    if($agentDefinition.Kind-ne'Ollama'){return ''}
    $sessionName=[IO.Path]::GetFileNameWithoutExtension($SessionPath)
    $metadataFocus=Get-DemiSessionFocusMetadata $root $sessionName
    $focus=if((Get-DemiFocus $State)){Get-DemiFocus $State}elseif($metadataFocus){$metadataFocus}else{$null}
    $metadataPath=Join-Path $root 'state\session-metadata.json';$sessionSummary=''
    if(Test-Path -LiteralPath $metadataPath -PathType Leaf){
        $metadata=Read-JsonFile $metadataPath;$property=if($metadata.sessions){$metadata.sessions.PSObject.Properties[$sessionName]}else{$null}
        if($property-and$property.Value.PSObject.Properties['summary']){$sessionSummary="$($property.Value.summary)"}
    }
    $instructionPath=Join-Path $root $agentDefinition.InstructionFile
    $instructions=if(Test-Path -LiteralPath $instructionPath){Get-DemiBoundedText (Get-Content -Raw -LiteralPath $instructionPath -Encoding UTF8) 2600}else{''}
    $collaborationPath=Join-Path $root 'COLLABORATION.md'
    $collaboration=if(Test-Path -LiteralPath $collaborationPath){Get-DemiBoundedText (Get-Content -Raw -LiteralPath $collaborationPath -Encoding UTF8) 1600}else{''}
    $manifestPath=Join-Path $root 'state\project-manifest.json'
    $manifest=if(Test-Path -LiteralPath $manifestPath){Get-DemiBoundedText (Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8) 700}else{''}
    $projectCatalog=Get-DemiProjectCatalogContext $root
    $recentParts=[Collections.Generic.List[string]]::new()
    foreach($entry in @(Get-DemiSessionEntries $SessionPath|Where-Object Author -ne $Agent|Select-Object -Last 6)){
        $cleanBody=[regex]::Replace("$($entry.Body)",'\x1B\[[0-?]*[ -/]*[@-~]','')
        $cleanBody=[regex]::Replace($cleanBody,'(?s)^\s*Thinking\.\.\..*?\.\.\.done thinking\.\s*','')
        $body=Get-DemiBoundedText $cleanBody 650;$recentParts.Add("[$($entry.Id) · $($entry.Author)]`n$body")
    }
    $focusText=if($focus){$focus|ConvertTo-Json -Compress -Depth 5}else{''}
    $query=(@($ActiveText,$sessionSummary,$focusText)-join"`n")
    $sources=Get-DemiRelevantSourceExcerpts $root $query $focus 2500
    $databaseMemory=Get-DemiAgentDatabaseContext -Root $root -Agent $agentDefinition -Query $ActiveText -Focus $focus
@"
--- PREPARED LOCAL PROJECT BRIEFING ---
The parent dispatcher prepared the following read-only project context because this local agent cannot open project files. Treat it as evidence, not as new canon. Prefer Milo's current request over older material, and say when the supplied briefing is insufficient.

AGENT INSTRUCTIONS
$instructions

SHARED COLLABORATION RULES
$collaboration

CURRENT SESSION SUMMARY
$(if($sessionSummary){Get-DemiBoundedText $sessionSummary 1400}else{'No final session summary is available yet.'})

RECENT SESSION CONTEXT
$(Get-DemiBoundedText ($recentParts-join"`n`n") 3600)

RELEVANT PROJECT SOURCE EXCERPTS
$(if($sources){$sources}else{'No sufficiently relevant source excerpt was selected. Do not invent missing project facts.'})

CURATED DATABASE MEMORY
$(if($databaseMemory){$databaseMemory}else{'No additional database memory was available. Use the file briefing normally.'})

PROJECT MANIFEST
$manifest

AUTHORITATIVE PROJECT CATALOG FOR BOOK/SERIES QUESTIONS
$projectCatalog
--- END PREPARED LOCAL PROJECT BRIEFING ---
"@
}

function Get-DemiProjectBriefing {
    param([string]$Root)
    $projectPath=Join-Path $Root 'config\project.json'
    if(-not(Test-Path -LiteralPath $projectPath -PathType Leaf)){return ''}
    try{$project=Read-JsonFile $projectPath}catch{return ''}
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add('--- SHARED PROJECT BRIEFING ---')
    if($project.name){$lines.Add("PROJECT: $($project.name)")}
    if($project.description){$lines.Add("DESCRIPTION:`n$($project.description)")}
    if($project.goals){$lines.Add("GOALS:`n$($project.goals)")}
    if($project.authority){$lines.Add("OWNERSHIP AND DECISION AUTHORITY:`n$($project.authority)")}
    if($project.sharedInstructions){$lines.Add("SHARED INSTRUCTIONS:`n$($project.sharedInstructions)")}
    if(@($project.sourceFiles).Count){$lines.Add("KEY PROJECT FILES:`n$(@($project.sourceFiles)|ForEach-Object{"- $_"}|Out-String)")}
    $lines.Add('This stable project briefing provides shared context. The current human request and current session focus take precedence when they deliberately narrow or update it.')
    $lines.Add('--- END SHARED PROJECT BRIEFING ---')
    return Get-DemiBoundedText ($lines-join"`n`n") 12000
}

function New-EntryId {
    param([object]$State, [ValidatePattern('^[A-Z]$')] [string]$AuthorCode)
    $State.entryCounter = [int]$State.entryCounter + 1
    return ('S{0:D3}-{1}{2:D4}' -f [int]$State.sessionNumber, $AuthorCode, [int]$State.entryCounter)
}

function Add-SessionEntry {
    param(
        [string]$Root,
        [object]$State,
        [string]$Author,
        [string]$Type,
        [string]$Body,
        [hashtable]$Metadata
    )
    $codes = @{ Milo = 'M'; Alice = 'A'; Claude = 'C'; Rowan = 'R'; Gem = 'G'; System = 'S' }
    $authorCode = if($codes.ContainsKey($Author)){$codes[$Author]}else{'G'}
    $id = New-EntryId -State $State -AuthorCode $authorCode
    $timestamp = [DateTimeOffset]::Now.ToString('o')
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("## $id - $Author")
    $lines.Add("Timestamp: $timestamp")
    $lines.Add("Type: $Type")
    foreach ($key in $Metadata.Keys) {
        if ($null -ne $Metadata[$key] -and "$($Metadata[$key])" -ne '') {
            $lines.Add("${key}: $($Metadata[$key])")
        }
    }
    $lines.Add('')
    $normalizedBody = $Body -replace '\r\n|\r|\n', [Environment]::NewLine
    $lines.Add($normalizedBody)
    $lines.Add('')
    $entry = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    $sessionPath = Get-SessionPath -Root $Root -State $State
    if (Test-DemiDatabaseSessionMode $Root) {
        $sessionName = [IO.Path]::GetFileNameWithoutExtension($sessionPath)
        [void](Write-DemiDatabaseSessionEntry -Root $Root -SessionName $sessionName -EntryId $id -Sequence ([int64]$State.entryCounter) -Author $Author -Type $Type -Body $normalizedBody -Metadata $Metadata -Timestamp $timestamp)
    }
    [System.IO.File]::AppendAllText($sessionPath, $entry, [System.Text.UTF8Encoding]::new($false))
    $State.lastEntry = $id
    $State.lastAuthor = $Author
    $State.lastUpdated = $timestamp
    return $id
}

function Get-DemiNextSessionNumber {
    param([string]$Root)
    $numbers = @(Get-ChildItem -LiteralPath (Join-Path $Root 'sessions') -Filter 'session-*.md' -File -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.BaseName -match '^session-(\d+)$') { [int]$Matches[1] } })
    if (-not $numbers.Count) { return 1 }
    return (($numbers | Measure-Object -Maximum).Maximum + 1)
}

function Get-DemiSessionHandoff {
    param([string]$SessionPath,[int]$MaximumCharacters = 24000)
    $entries = @(Get-DemiSessionEntries $SessionPath | Select-Object -Last 14)
    $parts = [System.Collections.Generic.List[string]]::new()
    $sourceName = [IO.Path]::GetFileNameWithoutExtension($SessionPath)
    $sourceFile = [IO.Path]::GetFileName($SessionPath)
    $root = Split-Path (Split-Path $SessionPath -Parent) -Parent
    $summary = $null
    $metadataPath = Join-Path $root 'state\session-metadata.json'
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        $metadata = Read-JsonFile $metadataPath
        $property = if ($metadata.sessions) { $metadata.sessions.PSObject.Properties[$sourceName] } else { $null }
        if ($property -and $property.Value.PSObject.Properties['summary']) { $summary = "$($property.Value.summary)".Trim() }
    }
    $parts.Add("Linked continuation of $sourceFile. The complete predecessor is available at sessions/archive/$sourceFile and may be consulted when a model needs details beyond this handoff.")
    if ($summary) { $parts.Add("FINAL SESSION SUMMARY`n$summary") }
    $parts.Add('RECENT CONTEXT')
    foreach ($entry in $entries) {
        $type = if ($entry.Metadata.Contains('Type')) { $entry.Metadata.Type } else { 'ENTRY' }
        $body = $entry.Body.Trim()
        if ($body.Length -gt 1600) { $body = $body.Substring(0,1600) + ' …' }
        $candidate = "`n[$($entry.Id) · $($entry.Author) · $type]`n$body"
        if ((($parts -join "`n").Length + $candidate.Length) -gt $MaximumCharacters) { break }
        $parts.Add($candidate)
    }
    return ($parts -join "`n").Trim()
}

function Update-DemiSessionCardMetadata {
    param([string]$Root,[string]$SessionPath)
    try {
        $node = (Get-Command node -ErrorAction Stop).Source
        $server = Join-Path $Root 'tools\web\server.js'
        $output = & $node $server '--refresh-session-metadata' $SessionPath 2>&1
        if ($LASTEXITCODE -ne 0) { throw (($output | Out-String).Trim()) }
        return $true
    } catch {
        Write-Warning "Session deactivated, but its card summary could not be refreshed: $($_.Exception.Message) The previous summary was preserved and refresh will be retried when the Sessions catalog is next loaded."
        return $false
    }
}

function Start-DemiSessionContinuation {
    param([string]$Root,[object]$State,[string]$SourcePath,[switch]$PreserveActiveWork)
    [void](Update-DemiSessionCardMetadata $Root $SourcePath)
    $sourceSessionName = [IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $sourceFocus = Get-DemiSessionFocusMetadata $Root $sourceSessionName
    if ($sourceFocus) {
        if ($State.PSObject.Properties['focus']) { $State.focus = Copy-DemiValue $sourceFocus }
        else { $State | Add-Member -NotePropertyName focus -NotePropertyValue (Copy-DemiValue $sourceFocus) }
    }
    $archiveDir = Join-Path $Root 'sessions\archive'
    [void][IO.Directory]::CreateDirectory($archiveDir)
    $archiveName = [IO.Path]::GetFileName($SourcePath)
    Copy-Item -LiteralPath $SourcePath -Destination (Join-Path $archiveDir $archiveName) -Force
    $oldRound = Copy-DemiValue $State.round
    $oldDirect = Copy-DemiValue $State.directTurn
    $activeId = if ($oldDirect -and $oldDirect.active) { "$($oldDirect.openedBy)" } elseif ($oldRound -and $oldRound.status -eq 'open') { "$($oldRound.openedBy)" } else { $null }
    $activeEntry = if ($activeId) { Get-DemiSessionEntries $SourcePath | Where-Object Id -eq $activeId | Select-Object -First 1 } else { $null }
    $handoff = Get-DemiSessionHandoff $SourcePath
    $State.sessionNumber = Get-DemiNextSessionNumber $Root
    $State.entryCounter = 0
    $State.roundCounter = 0
    $State.currentSession = 'sessions\session-{0:D3}.md' -f [int]$State.sessionNumber
    $State.round = [pscustomobject]@{ id=$null;status='waiting_for_milo';remainingResponses=0;nextSpeaker='Milo';target='Both';openedBy=$null;focus=$(if($State.PSObject.Properties['focus']){Copy-DemiValue $State.focus}else{$null}) }
    $State.directTurn = $null
    $newPath = Get-SessionPath $Root $State
    Set-Utf8NoBom -Path $newPath -Content "# Session $('{0:D3}' -f [int]$State.sessionNumber)`r`n`r`n"
    [void](Add-SessionEntry $Root $State 'System' 'SESSION CONTINUATION' $handoff @{ 'Continues from'=$archiveName; 'Predecessor entry'=$activeId })
    if ($PreserveActiveWork -and $activeEntry) {
        $newRequest = Add-SessionEntry $Root $State 'Milo' 'CONTINUED REQUEST' $activeEntry.Body.TrimEnd() @{ 'Continued from'=$activeEntry.Id }
        if ($oldDirect -and $oldDirect.active) {
            $oldDirect.openedBy = $newRequest
            $oldDirect.suspendedRound = Copy-DemiValue $State.round
            $State.directTurn = $oldDirect
        } else {
            $State.roundCounter = 1
            $oldRound.id = 'R{0:D3}-001' -f [int]$State.sessionNumber
            $oldRound.openedBy = $newRequest
            $State.round = $oldRound
        }
    }
    return $newPath
}

function Test-DemiUsageLimitFailure {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return $Text -match '(?i)(?:usage|rate|session|weekly|daily|model|token|request)\s+(?:limit|quota)\s+(?:reached|exceeded|exhausted|used)|(?:quota|credits?)\s+(?:exceeded|exhausted|depleted|insufficient)|resource[_ ]exhausted|too many requests|\b429\b|insufficient_quota|you(?:''ve| have) (?:hit|reached) (?:your|the) (?:usage |rate |session )?limit|limit resets?\s+(?:(?:at|in|on)\s+)?|no (?:usage|AI )?credits? remaining'
}

function Get-DemiUsageResetHint {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $patterns = @(
        '(?i)\bresets?\s+(?:(?:at|in|on)\s+)?[^\r\n.;]+',
        '(?i)(?:limit|quota|usage|credits?|session)\s+(?:will\s+)?resets?\s+(?:at|in|on)\s+[^\r\n.;]+',
        '(?i)(?:try again|available again|next session (?:begins|starts))\s+(?:at|in|on|after)\s+[^\r\n.;]+'
    )
    foreach ($pattern in $patterns) {
        $match = [regex]::Match($Text, $pattern)
        if ($match.Success) { return $match.Value.Trim() }
    }
    return $null
}

function Get-DemiNextGroupAgent {
    param([string]$Agent)
    switch ($Agent) {
        'Claude' { return 'Rowan' }
        'Rowan' { return 'Gem' }
        default { return 'Claude' }
    }
}

function Test-DemiRoundSynthesisStage {
    param([object]$Round)
    if (-not $Round -or -not $Round.PSObject.Properties['sequence'] -or -not $Round.PSObject.Properties['synthesisAgents']) { return $false }
    $sequence = @($Round.sequence)
    $synthesisAgents = @($Round.synthesisAgents)
    $index = if ($Round.PSObject.Properties['sequenceIndex']) { [int]$Round.sequenceIndex } else { -1 }
    return $synthesisAgents.Count -gt 0 -and $index -ge ($sequence.Count - $synthesisAgents.Count)
}

function Move-DemiRoundPastAgent {
    param([object]$State, [string]$Agent)
    $State.round.remainingResponses = [int]$State.round.remainingResponses - 1
    if ([int]$State.round.remainingResponses -le 0) {
        $State.round.status = 'waiting_for_milo'
        $State.round.nextSpeaker = 'Milo'
    } elseif ($State.round.target -eq 'Both' -and $State.round.PSObject.Properties['sequence']) {
        $State.round.sequenceIndex = [int]$State.round.sequenceIndex + 1
        $sequence = @($State.round.sequence)
        if ([int]$State.round.sequenceIndex -ge $sequence.Count) {
            $sequence += (Get-DemiNextGroupAgent $Agent)
            $State.round.sequence = $sequence
        }
        $State.round.nextSpeaker = $sequence[[int]$State.round.sequenceIndex]
    } elseif ($State.round.target -eq 'Both') {
        $State.round.nextSpeaker = if ($Agent -eq 'Claude') { 'Rowan' } else { 'Claude' }
    } else {
        $State.round.nextSpeaker = $Agent
    }
}

function Complete-DemiStopAfterCurrent {
    param([object]$State)
    if ($State.round.PSObject.Properties['stopAfterCurrent'] -and [bool]$State.round.stopAfterCurrent) {
        $State.round.status = 'waiting_for_milo'
        $State.round.remainingResponses = 0
        $State.round.nextSpeaker = 'Milo'
        $State.round.stopAfterCurrent = $false
        return $true
    }
    return $false
}

function Invoke-DemiUsageSkipLocked {
    param([string]$Root,[string]$StatePath,[string]$Agent,[string]$DispatchType,[string]$ExpectedOpenedBy,[string]$ResetHint)
    $state = Read-JsonFile $StatePath
    $body = "$Agent was skipped because its provider refused the request after its usage limit was reached. No model response was produced; the remaining participants will continue."
    if ($ResetHint) { $body += " Provider report: $ResetHint." }
    if ($DispatchType -eq 'DIRECT') {
        if (-not $state.directTurn -or -not $state.directTurn.active -or $state.directTurn.agent -ne $Agent) { throw 'The direct turn changed before the usage-limit skip could be recorded.' }
        if ($ExpectedOpenedBy -and $state.directTurn.openedBy -ne $ExpectedOpenedBy) { throw 'The direct question changed before the usage-limit skip could be recorded.' }
        $id = Add-SessionEntry $Root $state 'System' 'AGENT SKIPPED' $body @{ Agent=$Agent; Reason='usage limit'; 'Responding to'=$state.directTurn.openedBy }
        $state.directTurn = $null
    } elseif ($DispatchType -eq 'RESPONSE') {
        if ($state.round.status -ne 'open' -or $state.round.nextSpeaker -ne $Agent) { throw 'The round changed before the usage-limit skip could be recorded.' }
        if ($ExpectedOpenedBy -and $state.round.openedBy -ne $ExpectedOpenedBy) { throw 'The active request changed before the usage-limit skip could be recorded.' }
        Move-DemiRoundPastAgent $state $Agent
        [void](Complete-DemiStopAfterCurrent $state)
        $id = Add-SessionEntry $Root $state 'System' 'AGENT SKIPPED' $body @{ Agent=$Agent; Reason='usage limit'; Round=$state.round.id; 'Responding to'=$state.round.openedBy }
    } else {
        throw "Automatic usage-limit skipping is not supported for dispatch type $DispatchType."
    }
    Write-JsonAtomic $StatePath $state
    return [pscustomobject]@{ Id=$id; State=$state; Agent=$Agent; Skipped=$true }
}

function Invoke-DemiResponseLocked {
    param(
        [string]$Root,
        [string]$StatePath,
        [string]$Agent,
        [string]$Body,
        [string]$ExpectedRound,
        [string]$ExpectedOpenedBy,
        [object]$DocumentCreation,
        [hashtable]$UsageMetadata
    )

    $state = Read-JsonFile $StatePath
    if ($state.round.status -ne 'open' -or [int]$state.round.remainingResponses -lt 1) {
        throw 'No agent responses are currently authorized. Milo must open or continue a round.'
    }
    if ($ExpectedRound -and $state.round.id -ne $ExpectedRound) {
        throw "Active round changed from $ExpectedRound to $($state.round.id) while the agent was running."
    }
    if ($ExpectedOpenedBy -and $state.round.openedBy -ne $ExpectedOpenedBy) {
        throw "Milo added a newer round entry while the agent was running. Dispatch again for $($state.round.openedBy)."
    }
    if ($state.round.nextSpeaker -and $state.round.nextSpeaker -notin @($Agent,'Either')) {
        throw "The next speaker is $($state.round.nextSpeaker), not $Agent."
    }
    if ($state.round.target -ne 'Both' -and $state.round.target -ne $Agent) {
        throw "This round targets $($state.round.target), not $Agent."
    }
    $isSynthesis = Test-DemiRoundSynthesisStage $state.round
    Move-DemiRoundPastAgent $state $Agent
    [void](Complete-DemiStopAfterCurrent $state)
    $metadata = @{
        Round = $state.round.id
        'Responding to' = $state.round.openedBy
    }
    if ($isSynthesis) { $metadata.Synthesis = 'true' }
    if ($UsageMetadata) { foreach ($key in $UsageMetadata.Keys) { $metadata[$key] = $UsageMetadata[$key] } }
    if ($DocumentCreation) {
        $metadata.Destination = $DocumentCreation.destination
        $metadata.'File size' = $DocumentCreation.fileSize
        $metadata.'SHA-256' = $DocumentCreation.sha256
        $metadata.'Canon status' = 'proposed'
    }
    $id = Add-SessionEntry $Root $state $Agent 'RESPONSE' $Body $metadata
    Write-JsonAtomic $StatePath $state
    return [pscustomobject]@{ Id = $id; State = $state }
}

function Copy-DemiValue {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    return $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json
}

function Ensure-DemiAcknowledgementState {
    param([object]$State)
    if (-not $State.PSObject.Properties['acknowledgements']) {
        $State | Add-Member -NotePropertyName acknowledgements -NotePropertyValue @()
    }
    if ($null -eq $State.acknowledgements) { $State.acknowledgements = @() }
}

function Clear-DemiReviewPause {
    param([object]$State)
    if ($State.PSObject.Properties['miloReviewPause'] -and $State.miloReviewPause) {
        $State.miloReviewPause = $null
    }
}

function Add-DemiNoteLocked {
    param(
        [string]$Root,
        [string]$StatePath,
        [string]$Body,
        [bool]$QueueAcknowledgements
    )
    $state = Read-JsonFile $StatePath
    Ensure-DemiAcknowledgementState $state
    $pauseSnapshot = if ($state.PSObject.Properties['miloReviewPause']) {
        Copy-DemiValue $state.miloReviewPause
    } else { $null }
    $id = Add-SessionEntry $Root $state 'Milo' 'NOTE' $Body @{}
    if ($QueueAcknowledgements) {
        $item = [pscustomobject]@{
            noteEntryId = $id
            pending = @('Claude','Rowan')
            completed = @()
            resumeState = [pscustomobject]@{
                round = Copy-DemiValue $state.round
                miloReviewPause = $pauseSnapshot
            }
            createdAt = [DateTimeOffset]::Now.ToString('o')
        }
        $state.acknowledgements = @($state.acknowledgements) + @($item)
    }
    Write-JsonAtomic $StatePath $state
    return [pscustomobject]@{ Id = $id; State = $state; Queued = $QueueAcknowledgements }
}

function Get-NextDemiAcknowledgement {
    param([object]$State)
    Ensure-DemiAcknowledgementState $State
    foreach ($item in @($State.acknowledgements)) {
        if (@($item.pending).Count -gt 0) {
            return [pscustomobject]@{
                Item = $item
                NoteEntryId = "$($item.noteEntryId)"
                Agent = "$(@($item.pending)[0])"
            }
        }
    }
    return $null
}

function Get-DemiPendingAcknowledgementCount {
    param([object]$State)
    Ensure-DemiAcknowledgementState $State
    $count = 0
    foreach ($item in @($State.acknowledgements)) { $count += @($item.pending).Count }
    return $count
}

function Get-DemiDispatchWorkCount {
    param([object]$State)
    $count = Get-DemiPendingAcknowledgementCount $State
    if ($State.PSObject.Properties['directTurn'] -and $State.directTurn -and $State.directTurn.active) {
        $count += [Math]::Max(0, [int]$State.directTurn.remainingResponses)
    }
    $paused = $State.PSObject.Properties['miloReviewPause'] -and
        $State.miloReviewPause -and $State.miloReviewPause.active
    if (-not $paused -and $State.round.status -eq 'open') {
        $count += [Math]::Max(0, [int]$State.round.remainingResponses)
    }
    return $count
}

function Add-DemiDirectTurnLocked {
    param([string]$Root, [string]$StatePath, [string]$Agent, [string]$Body)
    $state = Read-JsonFile $StatePath
    if ($state.PSObject.Properties['directTurn'] -and $state.directTurn -and $state.directTurn.active) {
        throw "A direct turn for $($state.directTurn.agent) is already active."
    }
    $participants=@()
    if($state.round.status-eq'open'){
        if($state.round.PSObject.Properties['sequence']-and@($state.round.sequence).Count){$participants=@($state.round.sequence|Select-Object -Unique)}
        else{$participants=@(Get-DemiAgentRegistry -Root $Root|Where-Object{$_.Enabled-and($_.ParticipationMode-eq'automatic'-or$_.SynthesisEnabled)}|ForEach-Object{$_.Name})}
    }
    if($Agent-in$participants){throw "$Agent is participating in the active collaboration round. Wait for the round to finish before addressing $Agent directly."}
    $id = Add-SessionEntry $Root $state 'Milo' 'DIRECT QUESTION' $Body @{
        Agent = $Agent
        'Response allowance' = 1
        'Suspended round' = $state.round.id
    }
    $directTurn = [pscustomobject]@{
        active = $true
        agent = $Agent
        openedBy = $id
        remainingResponses = 1
        suspendedRound = Copy-DemiValue $state.round
        createdAt = [DateTimeOffset]::Now.ToString('o')
    }
    if ($state.PSObject.Properties['directTurn']) { $state.directTurn = $directTurn }
    else { $state | Add-Member -NotePropertyName directTurn -NotePropertyValue $directTurn }
    Write-JsonAtomic $StatePath $state
    return [pscustomobject]@{ Id = $id; State = $state }
}

function Invoke-DemiDirectResponseLocked {
    param(
        [string]$Root, [string]$StatePath, [string]$Agent, [string]$Body,
        [string]$ExpectedOpenedBy,
        [object]$DocumentCreation,
        [hashtable]$UsageMetadata
    )
    $state = Read-JsonFile $StatePath
    if (-not $state.PSObject.Properties['directTurn'] -or -not $state.directTurn -or -not $state.directTurn.active) {
        throw 'No direct turn is active.'
    }
    if ($state.directTurn.agent -ne $Agent) { throw "The direct turn targets $($state.directTurn.agent), not $Agent." }
    if ($ExpectedOpenedBy -and $state.directTurn.openedBy -ne $ExpectedOpenedBy) {
        throw "Direct turn changed from $ExpectedOpenedBy while the agent was running."
    }
    if ([int]$state.directTurn.remainingResponses -ne 1) { throw 'Direct turn allowance is not exactly one.' }
    # A later normal message may advance the round while a slower local agent
    # is answering. The response remains linked to its direct-question entry;
    # clearing directTurn does not restore or otherwise overwrite state.round.
    $metadata = @{
        'Responding to' = $state.directTurn.openedBy
        'Direct turn' = $Agent
    }
    if ($UsageMetadata) { foreach ($key in $UsageMetadata.Keys) { $metadata[$key] = $UsageMetadata[$key] } }
    if ($DocumentCreation) {
        $metadata.Destination = $DocumentCreation.destination
        $metadata.'File size' = $DocumentCreation.fileSize
        $metadata.'SHA-256' = $DocumentCreation.sha256
        $metadata.'Canon status' = 'proposed'
    }
    $id = Add-SessionEntry $Root $state $Agent 'DIRECT RESPONSE' $Body $metadata
    $state.directTurn = $null
    Write-JsonAtomic $StatePath $state
    return [pscustomobject]@{ Id = $id; State = $state }
}

function Get-DemiDirectPrompt {
    param([string]$Agent, [object]$State, [string]$SessionPath)
    $instructionFile = (Get-DemiAgent $Agent).InstructionFile
    $stateFile = Join-Path $root 'state\collaboration.json'
    $activeEntry = Get-DemiSessionEntries $SessionPath |
        Where-Object Id -eq "$($State.directTurn.openedBy)" |
        Select-Object -First 1
    if (-not $activeEntry) { throw "Could not find direct human entry $($State.directTurn.openedBy) in the current session." }
    $requestAuthor = "$($activeEntry.Author)"
    if ($requestAuthor -in @('System',$Agent) -or (Resolve-DemiAgentToken -Token $requestAuthor -Root $root)) {
        throw "Direct entry $($State.directTurn.openedBy) was not authored by a human participant."
    }
    $databaseContext = Get-DemiDatabaseSessionContext $root $SessionPath $Agent
    $projectBriefing = Get-DemiProjectBriefing $root
    $preparedContext = Get-DemiPreparedAgentContext $Agent $State $SessionPath $activeEntry.Body
    if ($databaseContext) { $preparedContext = "$databaseContext`n`n$preparedContext".Trim() }
@"
Agent: $Agent
Direct $requestAuthor entry: $($State.directTurn.openedBy)

$(Format-DemiFocusPrompt $State)

$projectBriefing

$(if($preparedContext){$preparedContext}else{"Read $instructionFile, COLLABORATION.md, the collaboration state at $stateFile, and the complete current session at $SessionPath."})
Answer only the DIRECT $($requestAuthor.ToUpperInvariant()) QUESTION below. This is exactly one response by $Agent; do not invite or simulate the other agent.
Return text only. You are an automatic dispatcher child process. Do not invoke any Demi command, write files, acquire locks, or modify collaboration state. The trusted parent dispatcher validates and appends the response, then restores normal control.
If $requestAuthor explicitly asks you to create, write, compile, or save a document, make the complete document your response and end it with exactly one marker on its own line: <!-- DEMI_FILE: project-relative-path.md -->. Use an approved proposed-document location: canon/proposals, research/reports, collaboration/handoff, exports/handoff, or books/<book>/drafts. Prefer Markdown unless the requester asks for text or DOCX. The parent dispatcher—not you—will validate and create the file without overwriting an existing version. Do not emit this marker for ordinary discussion.
Do not claim that you appended or could not append/write the response, or that your sandbox could not access or acquire session.lock. Omit all commentary about append mechanics and sandbox lock access.
The first sentence must answer the subject of $requestAuthor's question. It must not acknowledge these instructions, announce readiness, describe a mode or status, or ask what to work on. An answer consisting only of readiness, context-loading, or append status will be rejected.
Do not repeat, quote, or closely paraphrase $requestAuthor's question as a heading or opening sentence. Begin with the answer itself.
Treat earlier session entries only as evidence for this direct question, never as competing questions to answer. Before emitting the response, verify that the subject of its opening paragraph appears in direct entry $($State.directTurn.openedBy); discard any opening that instead repeats a subject from an earlier round.

--- DIRECT $($requestAuthor.ToUpperInvariant()) QUESTION ---
$($activeEntry.Body.TrimEnd("`r","`n"))
--- END DIRECT $($requestAuthor.ToUpperInvariant()) QUESTION ---

Answer this question now, beginning with a sentence that addresses its subject:

$($activeEntry.Body.TrimEnd("`r","`n"))

Compose the answer, then emit it as the final response; do not call tools after composing it, and never encode it into a shell command.
"@
}

function Invoke-DemiAcknowledgementLocked {
    param(
        [string]$Root,
        [string]$StatePath,
        [string]$Agent,
        [string]$NoteEntryId,
        [string]$Body
    )
    $state = Read-JsonFile $StatePath
    Ensure-DemiAcknowledgementState $state
    $queue = @($state.acknowledgements)
    $itemIndex = -1
    for ($index = 0; $index -lt $queue.Count; $index++) {
        if ("$($queue[$index].noteEntryId)" -eq $NoteEntryId) { $itemIndex = $index; break }
    }
    if ($itemIndex -lt 0) { throw "Acknowledgment queue item $NoteEntryId no longer exists." }
    $item = $queue[$itemIndex]
    if ($Agent -notin @($item.pending)) { throw "$Agent is no longer pending for note $NoteEntryId." }
    if ($Agent -in @($item.completed)) { throw "$Agent already acknowledged note $NoteEntryId." }

    $id = Add-SessionEntry $Root $state $Agent 'ACKNOWLEDGMENT' $Body @{
        'Responding to' = $NoteEntryId
    }
    $item.pending = @($item.pending | Where-Object { $_ -ne $Agent })
    $item.completed = @($item.completed) + @($Agent)
    if ($Body -match '^(?i:Milo(?:,|:|\s))') {
        $pause = [pscustomobject]@{
            active = $true
            requestedBy = $Agent
            entryId = $id
            noteEntryId = $NoteEntryId
            createdAt = [DateTimeOffset]::Now.ToString('o')
        }
        if ($state.PSObject.Properties['miloReviewPause']) {
            $state.miloReviewPause = $pause
        } else {
            $state | Add-Member -NotePropertyName miloReviewPause -NotePropertyValue $pause
        }
    }
    if (@($item.pending).Count -eq 0) {
        $state.acknowledgements = @(
            for ($index = 0; $index -lt $queue.Count; $index++) {
                if ($index -ne $itemIndex) { $queue[$index] }
            }
        )
    } else {
        $queue[$itemIndex] = $item
        $state.acknowledgements = $queue
    }
    Write-JsonAtomic $StatePath $state
    return [pscustomobject]@{ Id = $id; State = $state; NoteEntryId = $NoteEntryId }
}

function Get-DemiAcknowledgementPrompt {
    param([string]$Agent, [string]$NoteEntryId, [string]$SessionPath)
    $instructionFile = if ($Agent -eq 'Claude') { 'CLAUDE.md' } else { 'ROWAN.md' }
    $databaseContext = Get-DemiDatabaseSessionContext $root $SessionPath $Agent
    $projectBriefing = Get-DemiProjectBriefing $root
@"
DEMI_DISPATCH_MODE=ACKNOWLEDGMENT_ONLY
You are the read-only $Agent acknowledgment generator.
Read $instructionFile, COLLABORATION.md, and collaboration state at $statePath.
$projectBriefing
$(if($databaseContext){$databaseContext}else{"Read the complete current session at $SessionPath."})
Acknowledge Milos note in no more than two sentences. Do not analyze, debate, extend, or substantially restate it. You may flag a direct conflict or ambiguity that Milo needs to know about. Return only the acknowledgment text. Do not invoke demi or write any file.
Respond only to note $NoteEntryId. Do not acquire a lock or modify collaboration state. The parent dispatcher will append your final text.
"@
}

function Test-DemiAcknowledgementText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text.Length -gt 1200) { return $false }
    $sentenceCount = [regex]::Matches($Text.Trim(), '[.!?](?=\s|$)').Count
    if ($sentenceCount -eq 0) { $sentenceCount = 1 }
    return $sentenceCount -le 2
}

function Get-DispatchPrompt {
    param([string]$Agent, [object]$State, [string]$SessionPath)
    $instructionFile = (Get-DemiAgent $Agent).InstructionFile
    $stateFile = Join-Path $root 'state\collaboration.json'
    $activeEntry = Get-DemiSessionEntries $SessionPath |
        Where-Object Id -eq "$($State.round.openedBy)" |
        Select-Object -First 1
    if (-not $activeEntry) {
        throw "Could not find active entry $($State.round.openedBy) in the current session."
    }
    $requestAuthor = "$($activeEntry.Author)"
    $sequence = @(if ($State.round.PSObject.Properties['sequence']) { @($State.round.sequence) })
    $synthesisAgents = @(if ($State.round.PSObject.Properties['synthesisAgents']) { @($State.round.synthesisAgents) })
    $sequenceIndex = if ($State.round.PSObject.Properties['sequenceIndex']) { [int]$State.round.sequenceIndex } else { -1 }
    $isSynthesis = $synthesisAgents.Count -gt 0 -and $sequenceIndex -ge ($sequence.Count - $synthesisAgents.Count)
    $roundResponses = @(
        Get-DemiSessionEntries $SessionPath |
            Where-Object {
                $_.Id -ne "$($State.round.openedBy)" -and
                $_.Metadata.PSObject.Properties['Round'] -and
                "$($_.Metadata.Round)" -eq "$($State.round.id)" -and
                (-not $isSynthesis -or -not ($_.Metadata.PSObject.Properties['Synthesis'] -and "$($_.Metadata.Synthesis)" -eq 'true'))
            }
    )
    $roundContext = if ($roundResponses.Count -gt 0) {
        ($roundResponses | ForEach-Object {
            "[$($_.Id) - $($_.Author)]`n$($_.Body.TrimEnd("`r","`n"))"
        }) -join "`n`n"
    } else {
        '(No earlier agent response exists in this round.)'
    }
    $documentContext = Get-DemiDispatchDocumentContext $activeEntry.Body
    $databaseContext = if ($isSynthesis) { '' } else { Get-DemiDatabaseSessionContext $root $SessionPath $Agent }
    $preparedContext = if ($isSynthesis) { '' } else { Get-DemiPreparedAgentContext $Agent $State $SessionPath $activeEntry.Body }
    $projectBriefing = Get-DemiProjectBriefing $root
    if ($databaseContext) { $preparedContext = "$databaseContext`n`n$preparedContext".Trim() }
@"
Agent: $Agent
Round: $($State.round.id)
Active $requestAuthor entry: $($State.round.openedBy)
Mode: $(if($isSynthesis){'INDEPENDENT SYNTHESIS'}else{'AGENT RESPONSE'})

$(Format-DemiFocusPrompt $State)

$projectBriefing

$(if($preparedContext){$preparedContext}else{"Read $instructionFile and COLLABORATION.md when available. The active request and eligible earlier agent responses in this round are supplied directly below.$(if($isSynthesis){' This is an independent synthesis pass: do not read the complete session or any other synthesizer response. Base the synthesis only on the active human request and the ordinary agent responses supplied here.'}else{" Consult the collaboration state at $stateFile and the complete session at $SessionPath only when the active request requires an older fact; do not reread it merely to announce that context is loaded."})"})
Read relevant project files referenced by the active discussion when needed. Preserve disagreements and distinguish proposals from canon.
$documentContext
For this dispatch, you are an automatic dispatcher child process: return text only and do not invoke any Demi command or append a response. Make no filesystem edits, acquire no lock, and do not modify collaboration state or the session. The trusted parent dispatcher validates and performs the locked append.
If the active request explicitly asks you to create, write, compile, or save a document, make the complete document your response and end it with exactly one marker on its own line: <!-- DEMI_FILE: project-relative-path.md -->. Use an approved proposed-document location: canon/proposals, research/reports, collaboration/handoff, exports/handoff, or books/<book>/drafts. Prefer Markdown unless a text or DOCX file is requested. The parent dispatcher—not you—will validate and create the file without overwriting an existing version. Do not emit this marker for ordinary discussion.
Do not claim that you appended or could not append/write the response, or that your sandbox could not access or acquire session.lock. Omit all commentary about append mechanics and sandbox lock access.

Respond substantively to the ACTIVE $($requestAuthor.ToUpperInvariant()) REQUEST below. Answer only this active request and do not carry unrelated topics forward unless the requester asks for them. Return only $Agent's proposed response.
The first sentence must answer the subject of $requestAuthor's request. It must not acknowledge these instructions, announce readiness, describe a mode or status, or ask what to work on. An answer consisting only of readiness, context-loading, or append status will be rejected.
Do not repeat, quote, or closely paraphrase $requestAuthor's request as a heading or opening sentence. Begin with the answer itself.
Treat earlier session entries only as evidence for the active request, never as competing questions to answer. Before emitting the response, verify that the subject of its opening paragraph appears in active entry $($State.round.openedBy); discard any opening that instead repeats a subject from an earlier round.

--- $(if($isSynthesis){'ORDINARY RESPONSES TO SYNTHESIZE'}else{'EARLIER RESPONSES IN THIS ROUND'}) ---
$roundContext
--- END $(if($isSynthesis){'ORDINARY RESPONSES TO SYNTHESIZE'}else{'EARLIER RESPONSES IN THIS ROUND'}) ---

--- ACTIVE $($requestAuthor.ToUpperInvariant()) REQUEST ---
$($activeEntry.Body.TrimEnd("`r","`n"))
--- END ACTIVE $($requestAuthor.ToUpperInvariant()) REQUEST ---

Answer this request now, beginning with a sentence that addresses its subject:

$($activeEntry.Body.TrimEnd("`r","`n"))

Compose the answer, then emit it as the final response; do not call tools after composing it, and never encode it into a shell command.
"@
}

function Get-DemiDispatchDocumentContext {
    param([string]$Text)
    $references = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($match in [regex]::Matches("$Text",'(?i)(?:`|"|'')(?<path>[^`"''\r\n]+\.(?:md|txt|pdf|docx|epub))(?:`|"|'')')) {
        [void]$references.Add($match.Groups['path'].Value)
    }
    foreach ($match in [regex]::Matches("$Text",'(?im)(?<path>(?:books|canon|research|collaboration|exports|manuscript|drafting|inbox[\\/]attachments)[\\/][^\r\n\)]+?\.(?:md|txt|pdf|docx|epub))')) {
        [void]$references.Add($match.Groups['path'].Value.Trim())
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($reference in $references) {
        $relative = $reference.Replace('/','\')
        if ([System.IO.Path]::IsPathRooted($relative) -or $relative -match '(^|\\)\.\.(\\|$)|:') { continue }
        $candidate = Join-Path $root $relative
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $representation = Get-DemiDocumentRepresentation $root $relative
            $cacheRelative = $representation.Path.Substring($root.Length).TrimStart('\')
            $lines.Add("Parent-prepared read-only representation for '$relative': '$cacheRelative'. Read that UTF-8 file. It is derived cache, not canon; its opening line states format/layout limitations.")
        } catch {
            $lines.Add("Warning: parent could not normalize referenced document '$relative': $($_.Exception.Message)")
        }
    }
    if ($lines.Count -eq 0) { return '' }
    return ($lines -join [Environment]::NewLine)
}

function ConvertFrom-DemiDraftOutput {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Claude produced no draft output.' }
    $jsonText = $Text.Trim()
    if (-not $jsonText.StartsWith('{') -or -not $jsonText.EndsWith('}')) {
        $firstBrace = $jsonText.IndexOf('{')
        $lastBrace = $jsonText.LastIndexOf('}')
        if ($firstBrace -lt 0 -or $lastBrace -le $firstBrace) {
            throw 'Claude draft output did not contain a JSON object.'
        }
        $jsonText = $jsonText.Substring($firstBrace, $lastBrace - $firstBrace + 1)
    }
    try { $draft = $jsonText | ConvertFrom-Json } catch { throw "Claude draft output was not valid JSON: $($_.Exception.Message)" }
    $required = @('title','suggestedFileName','format','canonStatus','content')
    foreach ($name in $required) {
        if (-not $draft.PSObject.Properties[$name]) { throw "Draft output is missing required field '$name'." }
        if ($draft.$name -isnot [string]) { throw "Draft field '$name' must be a string." }
    }
    $unknown = @($draft.PSObject.Properties.Name | Where-Object { $_ -notin $required })
    if ($unknown.Count) { throw "Draft output contains unsupported field(s): $($unknown -join ', ')." }
    if ([string]::IsNullOrWhiteSpace("$($draft.title)") -or "$($draft.title)".Length -gt 300) { throw 'Draft title is invalid.' }
    if ([string]::IsNullOrWhiteSpace("$($draft.content)") -or "$($draft.content)".Length -gt 2000000) { throw 'Draft content is empty or too large.' }
    if ("$($draft.canonStatus)" -ne 'proposed') { throw 'Draft canonStatus must be proposed.' }
    if ("$($draft.format)" -notin @('markdown','text','docx')) { throw 'Draft format must be markdown, text, or docx.' }
    $suggested = "$($draft.suggestedFileName)"
    if ([System.IO.Path]::IsPathRooted($suggested) -or $suggested -match '[\\/:]' -or $suggested -ne [System.IO.Path]::GetFileName($suggested)) {
        throw 'Draft suggestedFileName must be a safe filename only, never a path.'
    }
    $extension = [System.IO.Path]::GetExtension($suggested).ToLowerInvariant()
    if ($extension -notin @('.md','.txt','.docx')) { throw 'Draft suggestedFileName has an unsupported extension.' }
    $expectedSuggestedExtension = @{ markdown='.md'; text='.txt'; docx='.docx' }["$($draft.format)"]
    if ($extension -ne $expectedSuggestedExtension) { throw 'Draft suggestedFileName extension does not match its format.' }
    return $draft
}

function Get-DemiDraftPrompt {
    param([string]$Request, [string]$RequestedFormat, [string]$ModelName)
    $documentContext = Get-DemiDispatchDocumentContext $Request
@"
Mode: document_draft
Agent: Claude
Model: $ModelName
Canon status: proposed

Read CLAUDE.md, COLLABORATION.md, the collaboration state, the complete current session, and relevant referenced project documents. You are a read-only authoring process. Do not invoke demi, use shell commands, write or edit files, acquire locks, or select a project path. The trusted parent will validate and optionally create a new file.
$documentContext

Return exactly one JSON object and nothing else with this schema:
{
  "title": "short title",
  "suggestedFileName": "safe-leaf-name_v001.$RequestedFormat",
  "format": "$(if ($RequestedFormat -eq 'md') { 'markdown' } elseif ($RequestedFormat -eq 'txt') { 'text' } else { 'docx' })",
  "canonStatus": "proposed",
  "content": "complete document content"
}

The content must be the complete proposed document. Do not wrap the JSON in a code fence.

--- MILO DRAFT REQUEST ---
$Request
--- END MILO DRAFT REQUEST ---
"@
}

function Invoke-DemiDraft {
    param(
        [string]$Request,
        [string]$Destination,
        [string]$RequestedFormat,
        [ValidateSet('Sonnet','Fable')]
        [string]$ModelName,
        [switch]$OnlyResponse
    )
    if ([string]::IsNullOrWhiteSpace($Request)) { throw 'Usage: demi draft "request" [-File project-relative-new-file] [-Format md|txt|docx] [-ResponsesOnly]' }
    if ($Destination) {
        $validatedDestination = Assert-DemiDocumentRelativePath $root $Destination
        $expectedExtension = '.' + $RequestedFormat
        if ($validatedDestination.Extension -ne $expectedExtension) {
            throw "Requested format '$RequestedFormat' does not match destination extension '$($validatedDestination.Extension)'."
        }
    }
    $roundSnapshot = Copy-DemiValue (Read-JsonFile $statePath).round
    $requestResult = Invoke-WithLock $lockPath {
        $draftState = Read-JsonFile $statePath
        $requestId = Add-SessionEntry $root $draftState 'Milo' 'DRAFT REQUEST' $Request @{
            Model = "Claude $ModelName"
            Format = $RequestedFormat
            Destination = $(if ($Destination) { $Destination } else { 'preview only' })
            'Canon status' = 'proposed'
        }
        Write-JsonAtomic $statePath $draftState
        [pscustomobject]@{ Id=$requestId; State=$draftState }
    }
    $draftRoot = Join-Path $root 'state\drafts'
    $errorRoot = Join-Path $draftRoot 'errors'
    [void][System.IO.Directory]::CreateDirectory($draftRoot)
    [void][System.IO.Directory]::CreateDirectory($errorRoot)
    $token = [guid]::NewGuid().ToString('N')
    $responsePath = Join-Path $draftRoot "$token-response.json"
    $stderrPath = Join-Path $draftRoot "$token-stderr.txt"
    $prompt = Get-DemiDraftPrompt $Request $RequestedFormat $ModelName
    $claude = (Get-Command claude -ErrorAction Stop).Source
    $arguments = @(
        '-p',$prompt,
        '--model',$ModelName.ToLowerInvariant(),
        '--output-format','text',
        '--max-turns',"$([Math]::Max($AgentMaxTurns,20))",
        '--tools','Read',
        '--permission-mode','dontAsk',
        '--no-session-persistence'
    )
    try {
        $exitCode = Invoke-DispatchProcess $claude $arguments $root $responsePath $stderrPath $AgentTimeoutSeconds
        if ($exitCode -ne 0) { throw "Claude $ModelName exited with code $exitCode." }
        if (-not (Test-Path -LiteralPath $responsePath)) { throw "Claude $ModelName produced no response file." }
        if ((Get-Item -LiteralPath $responsePath).Length -gt 4194304) { throw "Claude $ModelName structured output exceeds the 4 MiB safety limit." }
        $raw = Get-Content -Raw -LiteralPath $responsePath -Encoding UTF8
        try {
            $draft = ConvertFrom-DemiDraftOutput $raw
        } catch {
            $firstValidationError = $_.Exception.Message
            Set-Utf8NoBom -Path (Join-Path $errorRoot "$token-invalid-first-output.txt") -Content $raw
            foreach ($path in @($responsePath,$stderrPath)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
            }
            $correctivePrompt = @"
$prompt

CORRECTIVE RETRY: Your previous answer was rejected because it did not satisfy the required JSON-only protocol:
$firstValidationError

Return the requested complete document again as exactly one valid JSON object using the schema above. Begin with { and end with }. Do not add an introduction, conclusion, status message, or Markdown fence outside the JSON.
"@
            $arguments[1] = $correctivePrompt
            $retryExitCode = Invoke-DispatchProcess $claude $arguments $root $responsePath $stderrPath $AgentTimeoutSeconds
            if ($retryExitCode -ne 0) { throw "Claude $ModelName corrective draft retry exited with code $retryExitCode." }
            if (-not (Test-Path -LiteralPath $responsePath)) { throw "Claude $ModelName corrective draft retry produced no response file." }
            if ((Get-Item -LiteralPath $responsePath).Length -gt 4194304) { throw "Claude $ModelName corrective structured output exceeds the 4 MiB safety limit." }
            $raw = Get-Content -Raw -LiteralPath $responsePath -Encoding UTF8
            $draft = ConvertFrom-DemiDraftOutput $raw
        }
        $expectedProtocolFormat = if ($RequestedFormat -eq 'md') { 'markdown' } elseif ($RequestedFormat -eq 'txt') { 'text' } else { 'docx' }
        if ("$($draft.format)" -ne $expectedProtocolFormat) { throw "Claude returned format '$($draft.format)' instead of '$expectedProtocolFormat'." }
        $creation = $null
        if ($Destination -and -not $OnlyResponse) {
            $creation = Invoke-DemiCreateDocument $root $Destination "$($draft.content)" $requestResult.Id 'Claude' $ModelName "draft request $($requestResult.Id)"
        }
        $pendingPath = $null
        if (-not $creation) {
            $pendingPath = Join-Path $draftRoot "$token-pending.json"
            $pending = [ordered]@{
                id=$token; requestEntry=$requestResult.Id; round=$roundSnapshot.id
                title="$($draft.title)"; suggestedFileName="$($draft.suggestedFileName)"
                format="$($draft.format)"; canonStatus='proposed'; content="$($draft.content)"
                model=$ModelName; createdAt=[DateTimeOffset]::Now.ToString('o')
            } | ConvertTo-Json -Depth 5
            Invoke-DemiCreateNewFile $pendingPath ([System.Text.UTF8Encoding]::new($false).GetBytes($pending))
        }
        $entryResult = Invoke-WithLock $lockPath {
            $draftState = Read-JsonFile $statePath
            $metadata = @{
                Model=$ModelName; 'Responding to'=$requestResult.Id; 'Canon status'='proposed'
                Format=$draft.format; Title=$draft.title
                Destination=$(if ($creation) { $creation.destination } else { 'preview only' })
                'Draft token'=$(if ($pendingPath) { $token } else { $null })
            }
            $entryId = Add-SessionEntry $root $draftState 'Claude' 'DRAFT PROPOSAL' "$($draft.content)" $metadata
            Write-JsonAtomic $statePath $draftState
            [pscustomobject]@{ Id=$entryId; State=$draftState }
        }
        $result = [ordered]@{
            ok=$true; requestEntry=$requestResult.Id; entry=$entryResult.Id; draftToken=$(if ($pendingPath) { $token } else { $null })
            title="$($draft.title)"; suggestedFileName="$($draft.suggestedFileName)"; format="$($draft.format)"
            canonStatus='proposed'; content="$($draft.content)"; model=$ModelName; creation=$creation
        }
        if ($Json) { return $result | ConvertTo-Json -Depth 8 }
        Write-Output "Claude $ModelName`n`n$($draft.content)"
        if ($creation) {
            Write-Output "`nCreated $($creation.destination) ($($creation.fileSize) bytes; SHA-256 $($creation.sha256)). Proposed - not canon. No existing file was overwritten."
        } else {
            Write-Output "`nPreview only. Draft token: $token. Nothing was written outside transient state."
            Write-Output "Options: save with demi draft-save $token <new-project-relative-path>; revise with another /draft; ask Rowan to review; or discard it in demi web."
        }
    } catch {
        $stderrDetail = if (Test-Path -LiteralPath $stderrPath) {
            "$((Get-Content -Raw -LiteralPath $stderrPath -Encoding UTF8))".Trim()
        } else { '' }
        $stdoutDetail = if (Test-Path -LiteralPath $responsePath) {
            "$((Get-Content -Raw -LiteralPath $responsePath -Encoding UTF8))".Trim()
        } else { '' }
        $diagnostic = [ordered]@{
            timestamp=[DateTimeOffset]::Now.ToString('o')
            requestEntry=$requestResult.Id
            error=$_.Exception.Message
            stderr=$stderrDetail
            stdout=$stdoutDetail
        }
        [System.IO.File]::WriteAllText((Join-Path $errorRoot "$token-error.json"),($diagnostic|ConvertTo-Json),[System.Text.UTF8Encoding]::new($false))
        throw
    } finally {
        foreach ($path in @($responsePath,$stderrPath)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    }
}

function Save-DemiPendingDraft {
    param([string]$Token, [string]$Destination)
    if ($Token -notmatch '^[a-f0-9]{32}$') { throw 'Invalid draft token.' }
    $pendingPath = Join-Path $root "state\drafts\$Token-pending.json"
    if (-not (Test-Path -LiteralPath $pendingPath)) { throw 'Pending draft was not found.' }
    $pending = Read-JsonFile $pendingPath
    $modelName = if ($pending.PSObject.Properties['model'] -and $pending.model) { "$($pending.model)" } else { 'Sonnet' }
    $agentName = if ($pending.PSObject.Properties['agent'] -and $pending.agent) { "$($pending.agent)" } else { 'Claude' }
    $creation = Invoke-DemiCreateDocument $root $Destination "$($pending.content)" "$($pending.requestEntry)" $agentName $modelName "draft request $($pending.requestEntry)"
    $savedFormat = [System.IO.Path]::GetExtension("$($creation.destination)").TrimStart('.').ToLowerInvariant()
    Invoke-WithLock $lockPath {
        $draftState = Read-JsonFile $statePath
        [void](Add-SessionEntry $root $draftState 'System' 'DOCUMENT CREATED' "Created proposed document $($creation.destination). No existing file was overwritten." @{
            'Responding to'=$pending.requestEntry; Agent=$agentName; Model=$modelName; Format=$savedFormat
            Destination=$creation.destination; 'File size'=$creation.fileSize; 'SHA-256'=$creation.sha256
            'Canon status'='proposed'
        })
        Write-JsonAtomic $statePath $draftState
    }
    Remove-Item -LiteralPath $pendingPath -Force
    return $creation
}

function Resolve-DemiDraftArguments {
    param([string[]]$Values,[string]$NamedFile,[string]$NamedFormat,[bool]$NamedResponsesOnly)
    $destination = $NamedFile
    $requestedFormat = if ($NamedFormat) { $NamedFormat } else { 'md' }
    $onlyResponse = $NamedResponsesOnly
    $requestParts = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt @($Values).Count; $index++) {
        $value = $Values[$index]
        if ($value -eq '--file') {
            if ($index + 1 -ge @($Values).Count) { throw '--file requires a project-relative destination.' }
            $destination = $Values[++$index]
        } elseif ($value -eq '--format') {
            if ($index + 1 -ge @($Values).Count) { throw '--format requires md, txt, or docx.' }
            $requestedFormat = $Values[++$index].ToLowerInvariant()
            if ($requestedFormat -notin @('md','txt','docx')) { throw '--format requires md, txt, or docx.' }
        } elseif ($value -eq '--responses-only') {
            $onlyResponse = $true
        } elseif ($value.StartsWith('--')) {
            throw "Unknown draft option '$value'."
        } else {
            $requestParts.Add($value)
        }
    }
    return [pscustomobject]@{
        Request=($requestParts -join ' ')
        Destination=$destination
        Format=$requestedFormat
        ResponsesOnly=$onlyResponse
    }
}

function Test-DemiGenericModeAcknowledgement {
    param([string]$Response)
    if ([string]::IsNullOrWhiteSpace($Response)) { return $false }
    $normalized = ($Response.Trim() -replace '[`*#]', '' -replace '\s+', ' ').Trim()
    if ($normalized.Length -gt 500) { return $false }
    return $normalized -match '(?is)^(?:' +
        '(?:acknowledged|understood|confirmed)[,:.! -]*(?:demi\s+)?dispatch\s+mode\b.{0,80}\bresponse[- _]?only' +
        '|' +
        '(?:(?:acknowledged|understood|confirmed)[,:.! -]*)?(?:(?:demi\s+)?dispatch\s+)?(?:direct(?:[- ]response)?|substantive(?:[- ]response)?|response[- ]only)(?:\s+mode)?\s+(?:is\s+)?(?:enabled|active|ready|confirmed|acknowledged)' +
        '|(?:(?:acknowledged|understood|confirmed)[,:.! -]*)?(?:mode|status)\s*:\s*(?:direct[- _]response|substantive[- _]response|response[- _]only)' +
        '|(?:ready(?:\s+to\s+(?:help|begin|proceed|respond))?[.!]?\s*)?(?:what|which)\s+(?:would|do)\s+you\s+like\s+me\s+to\s+(?:work\s+on|do|address|answer)\??' +
        ')\s*[.!]?\s*$'
}

function Test-DispatchOperationalFailure {
    param([string]$Response)
    if ([string]::IsNullOrWhiteSpace($Response)) { return $false }
    $historicalContext = '(?i)\b(?:earlier|previously|historically|formerly|last time|in (?:entry |round )?S?\d{3}-[MCR]\d{3,4}|during (?:an? )?(?:earlier|previous|prior|past) (?:dispatch|round|response)|used to)\b'
    if ($Response -match $historicalContext) { return $false }

    $normalized = ($Response.Trim() -replace '[`*#]', '' -replace '\s+', ' ').Trim()
    if ($normalized.Length -gt 1200) { return $false }
    $appendFailure = $normalized -match '(?i)\b(?:could not|couldn''t|cannot|can''t|unable to|failed to)\b.{0,100}\b(?:append(?:ed)?|write|written|record(?:ed)?)\b|\b(?:append(?:ed)?|write|written|record(?:ed)?)\b.{0,100}\b(?:could not|couldn''t|cannot|can''t|failed|denied)\b'
    $prepared = $normalized -match '(?i)\b(?:(?:the )?(?:review|response|answer)\s+is\s+(?:prepared|ready)|prepared (?:review|response|answer))\b'
    $denial = $normalized -match '(?i)\b(?:workspace|sandbox|filesystem|file system)\b.{0,100}\b(?:read-only|denied|denying|refused|permission)\b|\b(?:read-only|denied|denying|refused|permission)\b.{0,100}\b(?:workspace|sandbox|filesystem|file system)\b'
    $lock = $normalized -match '(?i)\b(?:state[\\/])?session\.lock\b'
    $noFiles = $normalized -match '(?i)\bno (?:project )?files? (?:was|were|have been|has been) (?:modified|changed|written|created)\b'
    $operationalSignals = @($prepared, $denial, $lock, $noFiles) | Where-Object { $_ }
    return $appendFailure -and $operationalSignals.Count -ge 2
}

function Test-DemiNonSubstantiveReadiness {
    param([string]$Agent, [string]$Response)
    if ([string]::IsNullOrWhiteSpace($Response)) { return $false }
    $historicalContext = '(?i)\b(?:earlier|previously|historically|formerly|last time|in (?:entry |round )?S?\d{3}-[MCR]\d{3,4}|during (?:an? )?(?:earlier|previous|prior|past) (?:dispatch|round|response)|used to)\b'
    if ($Response -match $historicalContext) { return $false }

    $normalized = ($Response.Trim() -replace '[`*#]', '' -replace '[’‘]', "'" -replace '\s+', ' ').Trim()
    if ($normalized.Length -gt 700) { return $false }
    $escapedAgent = [regex]::Escape($Agent)
    if ($normalized -match "(?i)^(?:(?:$escapedAgent|the (?:$escapedAgent )?agent)\s+(?:is\s+)?ready|ready)[.!]?$") {
        return $true
    }
    if ($normalized -match "(?i)^(?:$escapedAgent|the (?:$escapedAgent )?agent)\s+(?:is\s+)?active\b.{0,300}\b(?:project\s+)?context\s+(?:is\s+)?loaded\b.{0,160}\bready\b") {
        return $true
    }
    $initialized = $normalized -match "(?i)^(?:$escapedAgent|the (?:$escapedAgent )?agent)\s+initialized[.!]?"
    $agentActive = $initialized -or $normalized -match "(?i)^(?:$escapedAgent|the (?:$escapedAgent )?agent)\s+(?:is\s+)?active[.!]?"
    $contextLoaded = $normalized -match "(?i)\bI.{0,8}\b(?:loaded|read|reviewed)\b.{0,300}\b(?:protocol|session|manifest|decision|file|context)\w*\b"
    $ready = $normalized -match '(?i)\b(?:I am|I''m|we are|the (?:review|response|answer) is)\s+(?:now\s+)?(?:ready|prepared)\b|\bready\s+(?:for|to)\b'
    if (-not ($agentActive -or $contextLoaded -or $ready)) { return $false }
    if (($agentActive -or $contextLoaded) -and $ready) { return $true }
    if ($initialized -and $contextLoaded -and $ready) { return $true }

    $residual = $normalized
    $residual = $residual -replace "(?i)^(?:$escapedAgent|the (?:$escapedAgent )?agent)\s+(?:(?:is\s+)?active|initialized)[.!]?\s*", ''
    $residual = $residual -replace "(?i)\bI\s*(?:have|'ve)?\s*(?:loaded|read|reviewed)\b.{0,300}\b(?:protocol|session|manifest|decision|file|context)\w*(?:\s*(?:,|and)\s*(?:the\s+)?(?:protocol|session|manifest|decision|file|context)\w*)*[.!]?", ''
    $residual = $residual -replace '(?i)\b(?:I am|I''m|we are|the (?:review|response|answer) is)\s+(?:now\s+)?(?:ready|prepared)\b(?:\s+(?:for|to)\b[^.!?]*)?[.!]?', ''
    return [string]::IsNullOrWhiteSpace(($residual -replace '[\s,;:.!-]+', ''))
}

function Test-DemiCurrentSelfAppendFailureClaim {
    param([string]$Response)
    if ([string]::IsNullOrWhiteSpace($Response)) { return $false }

    $historicalContext = '(?i)\b(?:earlier|previously|historically|formerly|last time|in (?:entry |round )?S?\d{3}-[MCR]\d{3,4}|during (?:an? )?(?:earlier|previous|prior|past) (?:dispatch|round|response)|used to|had (?:earlier |previously )?(?:been )?(?:unable|failed))\b'
    $claimPattern = '(?i)\b(?:I|my (?:read-only )?sandbox|this agent)\b.{0,160}\b(?:could not|couldn''t|cannot|can''t|am unable to|was unable to|failed to|denied (?:me )?(?:access|permission))\b.{0,160}\b(?:append|write|record|acquire|access|session\.lock)\b'
    $reverseClaimPattern = '(?i)\b(?:append|write|record|acquire|access|session\.lock)\b.{0,160}\b(?:could not|couldn''t|cannot|can''t|am unable to|was unable to|failed|denied)\b.{0,160}\b(?:I|me|my (?:read-only )?sandbox|this agent)\b'

    foreach ($paragraph in ($Response -split '(?:\r?\n){2,}')) {
        if ($paragraph -match $historicalContext) { continue }
        if ($paragraph -match $claimPattern -or $paragraph -match $reverseClaimPattern) { return $true }
    }
    return $false
}

function Test-DemiStaleMoonBrightnessResponse {
    param([string]$ActiveRequest, [string]$Response)
    if ([string]::IsNullOrWhiteSpace($ActiveRequest) -or [string]::IsNullOrWhiteSpace($Response)) { return $false }
    $activeIsMoonTopic = $ActiveRequest -match '(?i)\b(?:moon|lunar|tau ceti|moonlight|brightness|bright|phase|wax(?:ing|ed)?|new moon|full moon)\b'
    if ($activeIsMoonTopic) { return $false }
    $opening = $Response.Substring(0, [Math]::Min(1800, $Response.Length))
    $moonTerms = [regex]::Matches($opening, '(?i)\b(?:moon|moonlight|lunar|tau ceti|luminosity|stellar flux|sunlight)\b').Count
    $brightnessTerms = [regex]::Matches($opening, '(?i)\b(?:bright|brighter|brightness|dimmer|weaker|incident light|reflected light)\b').Count
    return $moonTerms -ge 2 -and $brightnessTerms -ge 1
}

function Remove-DemiObsoleteSelfAppendWrapper {
    param([string]$Agent, [string]$DispatchType, [string]$Response)
    if ($DispatchType -notin @('RESPONSE','DIRECT') -or [string]::IsNullOrWhiteSpace($Response)) {
        return $Response
    }

    $escapedAgent = [regex]::Escape($Agent)
<#
    $wrapper = "(?i)$escapedAgent(?:'|’|â€™)s response is ready, but I could not append it through[^\r\n]{0,400}session\.lock[.!]?"
#>
    $paragraphs = @([regex]::Split($Response.Trim(), '(?:\r?\n){2,}'))
    $first = 0
    $last = $paragraphs.Count - 1
    while ($first -le $last -and
        ((Test-DispatchOperationalFailure $paragraphs[$first]) -or
         (Test-DemiNonSubstantiveReadiness $Agent $paragraphs[$first]))) {
        $first++
    }
    while ($last -ge $first -and
        ((Test-DispatchOperationalFailure $paragraphs[$last]) -or
         (Test-DemiNonSubstantiveReadiness $Agent $paragraphs[$last]))) {
        $last--
    }
    if ($first -eq 0 -and $last -eq ($paragraphs.Count - 1)) { return $Response }
    if ($first -gt $last) { return '' }

    $cleaned = ($paragraphs[$first..$last] -join ([Environment]::NewLine + [Environment]::NewLine)).Trim()
    if ($cleaned.Length -lt 40 -or
        (Test-DemiGenericModeAcknowledgement $cleaned) -or
        (Test-DemiNonSubstantiveReadiness $Agent $cleaned) -or
        (Test-DemiCurrentSelfAppendFailureClaim $cleaned) -or
        (Test-DispatchOperationalFailure $cleaned)) {
        return $Response
    }
    return $cleaned
}

function Remove-DemiEchoedActiveRequest {
    param([string]$Response,[string]$ActiveRequest)
    if([string]::IsNullOrWhiteSpace($Response)-or[string]::IsNullOrWhiteSpace($ActiveRequest)){return $Response}
    $answer=$Response.Trim();$request=$ActiveRequest.Trim()
    if($answer.StartsWith($request,[StringComparison]::OrdinalIgnoreCase)){
        # Use the numeric em-dash value so Windows PowerShell 5.1 cannot
        # misdecode that character when reading a UTF-8 source file.
        $remainder=$answer.Substring($request.Length).TrimStart([char[]]@(13,10,32,0x2014,45,58))
        if($remainder.Length-ge20){return $remainder}
    }
    $answerLines=@($answer-split'\r?\n');$requestLine=($request-split'\r?\n'|Select-Object -First 1).Trim()
    if($answerLines.Count-gt1-and$answerLines[0].Trim().TrimEnd()-ieq$requestLine.TrimEnd()){
        $remainder=($answerLines[1..($answerLines.Count-1)]-join[Environment]::NewLine).Trim()
        if($remainder.Length-ge20){return $remainder}
    }
    return $Response
}

function Assert-DemiDispatchResponse {
    param([string]$Agent, [string]$DispatchType, [string]$Response, [string]$ActiveRequest = '')
    if ([string]::IsNullOrWhiteSpace($Response)) {
        throw "$Agent returned no substantive response."
    }
    if ($DispatchType -eq 'ACKNOWLEDGMENT' -and -not (Test-DemiAcknowledgementText $Response)) {
        throw "$Agent acknowledgment exceeds the two-sentence brief."
    }
    if ($DispatchType -in @('RESPONSE','DIRECT') -and (Test-DemiGenericModeAcknowledgement $Response)) {
        throw "$Agent returned a generic dispatch-mode acknowledgment instead of answering Milo's active request."
    }
    if ($DispatchType -in @('RESPONSE','DIRECT') -and (Test-DemiNonSubstantiveReadiness $Agent $Response)) {
        throw "$Agent returned only readiness or context-loading status instead of answering Milo's active request."
    }
    if ($DispatchType -in @('RESPONSE','DIRECT') -and (Test-DemiCurrentSelfAppendFailureClaim $Response)) {
        throw "$Agent returned a current self-referential claim about inability to append/write or access session.lock. The response was not appended and may be retried."
    }
    if (Test-DispatchOperationalFailure $Response) {
        throw "$Agent output is primarily an operational failure, not a substantive response."
    }
    if ($DispatchType -in @('RESPONSE','DIRECT') -and (Test-DemiStaleMoonBrightnessResponse $ActiveRequest $Response)) {
        throw "$Agent returned a recycled moon-brightness answer that does not address Milo's active request. The response was not appended and may be retried."
    }
    if ($Response -match '(?mi)^\s*#\s*Session\b|^\s*##\s+S\d{3}-[MACRGS]\d{4}\b|^\s*##\s+.+\s+-\s+(?:Milo|Alice)\s*$') {
        throw "$Agent output contains an attempted session heading or forged Milo entry."
    }
}

function ConvertFrom-DemiAgentFileOutput {
    param([string]$Response)
    $result = [pscustomobject]@{ Body=$Response; Destination=$null }
    if ([string]::IsNullOrWhiteSpace($Response)) { return $result }
    $match = [regex]::Match($Response,'(?is)\r?\n\s*<!--\s*DEMI_FILE:\s*(?<Path>[^\r\n<>]+?)\s*-->\s*$')
    if (-not $match.Success) {
        if ($Response -match '(?i)DEMI_FILE\s*:') { throw 'Agent returned a malformed proposed-file marker.' }
        return $result
    }
    $body = $Response.Substring(0,$match.Index).TrimEnd()
    if ([string]::IsNullOrWhiteSpace($body)) { throw 'Agent proposed a file without document content.' }
    $destination = $match.Groups['Path'].Value.Trim()
    [void](Assert-DemiDocumentRelativePath $root $destination)
    return [pscustomobject]@{ Body=$body; Destination=$destination }
}

function Invoke-DispatchProcess {
    param(
        [string]$Executable,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [string]$StandardOutputPath,
        [string]$StandardErrorPath,
        [int]$TimeoutSeconds,
        [string]$StandardInputText
    )
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($info.PSObject.Properties.Name -contains 'StandardOutputEncoding') {
        $info.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $info.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    }
    $quotedArguments = foreach ($argument in $ArgumentList) {
        if ($argument -notmatch '[\s"]') {
            $argument
            continue
        }
        $escaped = [regex]::Replace($argument, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        '"' + $escaped + '"'
    }
    $info.Arguments = $quotedArguments -join ' '
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    $stdoutTask = $null
    $stderrTask = $null
    $timedOut = $false
    try {
        [void]$process.Start()
        $started = $true
        if ($null -ne $StandardInputText) {
            $inputBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($StandardInputText)
            $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
            $process.StandardInput.BaseStream.Flush()
        }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $process.WaitForExit(250)) {
            if ([DateTime]::UtcNow -ge $deadline) {
                $timedOut = $true
                break
            }
        }
        if ($timedOut) {
            $killedTree = $false
            try {
                $killTreeMethod = $process.GetType().GetMethod('Kill', [type[]]@([bool]))
                if ($killTreeMethod) {
                    [void]$killTreeMethod.Invoke($process, @($true))
                    $killedTree = $true
                }
            } catch {}
            if (-not $killedTree -and $env:OS -eq 'Windows_NT') {
                try {
                    & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null
                    $killedTree = $true
                } catch {}
            }
            if (-not $process.HasExited) {
                try { $process.Kill() } catch {}
            }
            try { [void]$process.WaitForExit(5000) } catch {}
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [System.IO.File]::WriteAllText($StandardOutputPath, $stdout, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($StandardErrorPath, $stderr, [System.Text.UTF8Encoding]::new($false))
        if ($timedOut) {
            throw "Agent process exceeded the $TimeoutSeconds-second timeout. Partial stdout and stderr were retained."
        }
        return $process.ExitCode
    } finally {
        if ($started -and -not $process.HasExited) {
            try { $process.Kill() } catch {}
            try { $process.WaitForExit() } catch {}
        }
        if ($process) { $process.Dispose() }
    }
}

function Convert-DemiInvocationOutputFile {
    param([object]$Invocation,[string]$Path)
    if($Invocation.PSObject.Properties.Name -contains 'StreamJson' -and $Invocation.StreamJson -and (Test-Path -LiteralPath $Path)){
        $plain = ConvertFrom-DemiAntigravityStreamOutput ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8))
        Set-Utf8NoBom $Path $plain
    }
}

function Invoke-DemiCheckIn {
    param([string]$Agent)
    $checkRoot = Join-Path $root 'state\checkins'
    Assert-DemiWritePath $checkRoot 'agent check-in output' | Out-Null
    [void][System.IO.Directory]::CreateDirectory($checkRoot)
    $token = '{0}-{1}' -f $Agent.ToLowerInvariant(),([guid]::NewGuid().ToString('N'))
    $responsePath = Join-Path $checkRoot "$token-response.txt"
    $stdoutPath = Join-Path $checkRoot "$token-stdout.txt"
    $stderrPath = Join-Path $checkRoot "$token-stderr.txt"
    $started = [DateTimeOffset]::Now
    $keepDiagnostics = $false
    try {
        $registered = Get-DemiAgent $Agent $root
        $expected = "DEMI_CHECKIN_OK $Agent"
        $prompt = "This is a private availability check from Demi. Do not read project files, use tools, or discuss the manuscript. Reply with exactly: $expected"
        $invocation = New-DemiAgentInvocation $registered $root $prompt $responsePath 1
        $timeout = [Math]::Min($AgentTimeoutSeconds,60)
        $exitCode = Invoke-DispatchProcess $invocation.Executable $invocation.Arguments $root $stdoutPath $stderrPath $timeout $invocation.StandardInput
        $stdout = if(Test-Path -LiteralPath $stdoutPath){Get-Content -Raw -LiteralPath $stdoutPath -Encoding UTF8}else{''}
        if($invocation.ReadsStdout -and -not [string]::IsNullOrWhiteSpace($stdout)){Set-Utf8NoBom $responsePath $stdout}
        Convert-DemiInvocationOutputFile $invocation $responsePath
        $response = if(Test-Path -LiteralPath $responsePath){Get-Content -Raw -LiteralPath $responsePath -Encoding UTF8}else{''}
        $stderr = if(Test-Path -LiteralPath $stderrPath){Get-Content -Raw -LiteralPath $stderrPath -Encoding UTF8}else{''}
        $evidence = "$stdout`n$stderr`n$response"
        $online = $exitCode -eq 0 -and $response.Trim() -eq $expected
        $limited = -not $online -and (Test-DemiUsageLimitFailure $evidence)
        $resetHint = if($limited){Get-DemiUsageResetHint $evidence}else{$null}
        $detail = ($stderr+"`n"+$stdout).Trim()
        if($detail -match '(?i)invalid peer certificate:\s*UnknownIssuer'){
            $detail = 'TLS certificate rejected (UnknownIssuer) while connecting to api.openai.com. Check the VPN, HTTPS inspection, antivirus web filtering, or the trusted root certificate store.'
        }elseif($detail.Length -gt 600){$detail=$detail.Substring([Math]::Max(0,$detail.Length-600))}
        $reason = if($online){$null}elseif($limited){'usage limit'}elseif($exitCode -ne 0){if($detail){$detail}else{"process exited with code $exitCode"}}else{'did not return the check-in confirmation'}
        $keepDiagnostics = -not $online
        [pscustomobject]@{agent=$Agent;online=$online;checkedAt=[DateTimeOffset]::Now.ToString('o');elapsedMs=[int]([DateTimeOffset]::Now-$started).TotalMilliseconds;reason=$reason;resetHint=$resetHint;diagnostics=$(if($keepDiagnostics){$stderrPath}else{$null})} | ConvertTo-Json -Compress
    } catch {
        $failureText=$_.Exception.Message;$limited=Test-DemiUsageLimitFailure $failureText
        $keepDiagnostics = $true
        [pscustomobject]@{agent=$Agent;online=$false;checkedAt=[DateTimeOffset]::Now.ToString('o');elapsedMs=[int]([DateTimeOffset]::Now-$started).TotalMilliseconds;reason=$(if($limited){'usage limit'}else{$failureText});resetHint=$(if($limited){Get-DemiUsageResetHint $failureText}else{$null});diagnostics=$stderrPath} | ConvertTo-Json -Compress
    } finally {
        if(-not $keepDiagnostics){foreach($path in @($responsePath,$stdoutPath,$stderrPath)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}}}
    }
}

function Get-DemiClaudeMaxTurns {
    param([string]$DispatchType, [int]$RequestedMaxTurns)
    if ($DispatchType -eq 'ACKNOWLEDGMENT') {
        return [Math]::Min($RequestedMaxTurns, 4)
    }
    return $RequestedMaxTurns
}

function Remove-DemiStaleDispatcherLock {
    param([string]$LockPath)
    if (-not (Test-Path -LiteralPath $LockPath)) { return $false }

    try {
        $lockText = Get-Content -Raw -LiteralPath $LockPath -Encoding UTF8
    } catch {
        throw "Cannot inspect Demi dispatcher lock at ${LockPath}: $($_.Exception.Message) The lock was preserved."
    }
    $match = [regex]::Match($lockText, '^\s*(?<Pid>\d+)(?:\s+|$)')
    if (-not $match.Success) {
        throw "Malformed Demi dispatcher lock at $LockPath (expected a leading numeric PID). The lock was preserved for manual inspection."
    }
    $lockPid = 0
    if (-not [int]::TryParse($match.Groups['Pid'].Value, [ref]$lockPid) -or $lockPid -le 0) {
        throw "Malformed Demi dispatcher lock at $LockPath (invalid PID '$($match.Groups['Pid'].Value)'). The lock was preserved for manual inspection."
    }

    $owner = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
    if ($owner) {
        throw "A live Demi dispatcher lock is active at $LockPath (PID $lockPid, process '$($owner.ProcessName)'). The lock was preserved."
    }

    try {
        $stream = [System.IO.File]::Open(
            $LockPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        try {
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false), $true, 1024, $true)
            try { $currentText = $reader.ReadToEnd() } finally { $reader.Dispose() }
            if ($currentText -ne $lockText) {
                throw "Demi dispatcher lock changed while stale recovery was checking it. The lock was preserved."
            }
        } finally {
            $stream.Dispose()
        }
        Remove-Item -LiteralPath $LockPath -Force
    } catch {
        throw "Could not safely recover orphaned Demi dispatcher lock at ${LockPath}: $($_.Exception.Message)"
    }
    Write-Warning "Recovered orphaned Demi dispatcher lock at $LockPath (dead PID $lockPid)."
    return $true
}

function Test-DemiLiveDispatcherLock {
    param([string]$LockPath)
    if (-not (Test-Path -LiteralPath $LockPath)) { return $false }
    $lockText = Get-Content -Raw -LiteralPath $LockPath -Encoding UTF8
    $match = [regex]::Match($lockText, '^\s*(?<Pid>\d+)(?:\s+|$)')
    if (-not $match.Success) { throw "Malformed Demi dispatcher lock at $LockPath." }
    $lockPid = 0
    if (-not [int]::TryParse($match.Groups['Pid'].Value, [ref]$lockPid) -or $lockPid -le 0) {
        throw "Malformed Demi dispatcher lock at $LockPath."
    }
    if (Get-Process -Id $lockPid -ErrorAction SilentlyContinue) { return $true }
    [void](Remove-DemiStaleDispatcherLock $LockPath)
    return $false
}

function Get-TextArgument {
    param([string[]]$Values, [string]$Prompt)
    $text = $Values -join ' '
    if ([string]::IsNullOrWhiteSpace($text)) { throw $Prompt }
    return $text
}

function Get-UsageStatus {
    param([object]$Usage)
    if ($null -eq $Usage.percentConsumed) { return 'unknown' }
    $age = [DateTimeOffset]::Now - [DateTimeOffset]::Parse($Usage.reportedAt)
    $stale = if ($age.TotalHours -ge 6) { ' (stale)' } else { '' }
    return "$($Usage.percentConsumed)% consumed$stale"
}

function Format-DemiDuration {
    param([TimeSpan]$Duration)
    if ($Duration.TotalSeconds -lt 0) { $Duration = [TimeSpan]::Zero }
    if ($Duration.TotalDays -ge 1) {
        return '{0}d {1}h' -f [Math]::Floor($Duration.TotalDays), $Duration.Hours
    }
    if ($Duration.TotalHours -ge 1) {
        return '{0}h {1}m' -f [Math]::Floor($Duration.TotalHours), $Duration.Minutes
    }
    if ($Duration.TotalMinutes -ge 1) {
        return '{0}m {1}s' -f [Math]::Floor($Duration.TotalMinutes), $Duration.Seconds
    }
    return '{0}s' -f [Math]::Floor($Duration.TotalSeconds)
}

function Get-DemiPendingStatus {
    param([string]$Root, [string]$RuntimeRoot, [object]$State, [object[]]$Entries)
    $now = [DateTimeOffset]::Now
    $direct = if ($State.PSObject.Properties['directTurn']) { $State.directTurn } else { $null }
    $isDirect = $direct -and $direct.active
    $speaker = if ($isDirect) {
        "$($direct.agent)"
    } elseif ($State.round.status -eq 'open' -and (Resolve-DemiAgentToken -Token "$($State.round.nextSpeaker)" -Root $root)) {
        (Get-DemiAgent "$($State.round.nextSpeaker)" $root).Name
    } else { $null }

    $pendingSince = $null
    if ($speaker) {
        if ($isDirect) {
            $pendingSince = @($Entries | Where-Object Id -eq "$($direct.openedBy)" | Select-Object -Last 1).Timestamp
        } else {
            $roundId = "$($State.round.id)"
            $openedBy = "$($State.round.openedBy)"
            $candidate = $Entries | Where-Object {
                ($_.Id -eq $openedBy) -or
                ($_.Metadata.Contains('Round') -and "$($_.Metadata.Round)" -eq $roundId -and
                    "$($_.Metadata.Type)" -in @('RESPONSE','CONTINUE'))
            } | Where-Object Timestamp | Select-Object -Last 1
            if ($candidate) { $pendingSince = $candidate.Timestamp }
        }
        if (-not $pendingSince -and $State.lastUpdated) {
            $parsedFallback = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse("$($State.lastUpdated)", [ref]$parsedFallback)) {
                $pendingSince = $parsedFallback
            }
        }
    }

    $dispatchRoot = if ($RuntimeRoot -eq $Root) { Join-Path $Root 'state\dispatch' } else { Join-Path $RuntimeRoot 'dispatch' }
    $lockPath = Join-Path $dispatchRoot 'dispatcher.lock'
    $dispatcher = [ordered]@{ state = 'inactive'; agent = $null; since = $null; elapsed = $null; failure = $null }
    if (Test-Path -LiteralPath $lockPath) {
        try {
            $lockText = Get-Content -Raw -LiteralPath $lockPath -Encoding UTF8
            $match = [regex]::Match($lockText, '^\s*(?<Pid>\d+)\s+(?<Timestamp>\S+)\s+(?<Agent>\S+)(?:\s+(?<Round>\S+))?')
            if ($match.Success -and (Get-Process -Id ([int]$match.Groups['Pid'].Value) -ErrorAction SilentlyContinue)) {
                $lockSince = [DateTimeOffset]::Parse($match.Groups['Timestamp'].Value)
                $dispatcher.state = 'running'
                $dispatcher.agent = $match.Groups['Agent'].Value
                $dispatcher.since = $lockSince.ToString('o')
                $dispatcher.elapsed = Format-DemiDuration ($now - $lockSince)
            }
        } catch {}
    }

    if ($speaker -and $pendingSince) {
        $expectedType = if ($isDirect) { 'DIRECT' } else { 'RESPONSE' }
        $errorRoot = Join-Path $dispatchRoot 'errors'
        $newestFailure = $null
        if (Test-Path -LiteralPath $errorRoot) {
            foreach ($file in Get-ChildItem -LiteralPath $errorRoot -Filter '*-error.json' -File -ErrorAction SilentlyContinue) {
                try {
                    $failure = Read-JsonFile $file.FullName
                    $failureAt = [DateTimeOffset]::Parse("$($failure.timestamp)")
                    if ($failure.agent -eq $speaker -and $failure.round -eq $State.round.id -and
                        $failure.dispatchType -eq $expectedType -and $failureAt -ge $pendingSince -and
                        (-not $newestFailure -or $failureAt -gt $newestFailure.At)) {
                        $newestFailure = [pscustomobject]@{ At = $failureAt; Error = "$($failure.error)" }
                    }
                } catch {}
            }
        }
        if ($newestFailure) {
            $dispatcher.state = 'failed/retryable'
            $dispatcher.agent = $speaker
            $dispatcher.since = $newestFailure.At.ToString('o')
            $dispatcher.elapsed = Format-DemiDuration ($now - $newestFailure.At)
            $dispatcher.failure = $newestFailure.Error
        }
    }

    return [pscustomobject]@{
        Speaker = $speaker
        Since = $pendingSince
        Duration = $(if ($pendingSince) { Format-DemiDuration ($now - $pendingSince) } else { $null })
        Dispatcher = [pscustomobject]$dispatcher
    }
}

function Show-Status {
    param([string]$Root, [string]$RuntimeRoot, [object]$State, [switch]$AsJson)
    $sessionPath = Get-SessionPath -Root $Root -State $State
    $sessionText = Get-Content -Raw -LiteralPath $sessionPath -Encoding UTF8
    $entries = @(ConvertFrom-DemiSessionText $sessionText)
    $pending = Get-DemiPendingStatus $Root $RuntimeRoot $State $entries
    $words = ([regex]::Matches($sessionText, '\S+')).Count
    $estimatedTokens = [Math]::Ceiling($sessionText.Length / 3.7)
    $sessionBytes = (Get-Item -LiteralPath $sessionPath).Length
    $statusSequence = @(if ($State.round.PSObject.Properties['sequence']) { @($State.round.sequence) })
    $statusIndex = if ($State.round.PSObject.Properties['sequenceIndex']) { [int]$State.round.sequenceIndex } else { -1 }
    $statusSynthesis = Test-DemiRoundSynthesisStage $State.round
    $statusRole = if ($statusSynthesis) { 'synthesis' } else { switch ("$($State.round.nextSpeaker)") { 'Claude' { 'writing proposal' }; 'Rowan' { 'editorial and continuity review' }; 'Gem' { 'independent prose and technical review' }; default { if ($State.round.nextSpeaker -and $State.round.nextSpeaker -ne 'Milo') { 'agent response' } else { $null } } } }
    $payload = [ordered]@{
        projectRoot = $Root
        session = $State.sessionNumber
        sessionFile = $State.currentSession
        roundId = $State.round.id
        roundStatus = $State.round.status
        remainingResponses = $State.round.remainingResponses
        nextSpeaker = $State.round.nextSpeaker
        sequence = $(if ($State.round.PSObject.Properties['sequence']) { @($State.round.sequence) } else { @() })
        sequenceStage = $(if ($State.round.PSObject.Properties['sequenceIndex']) { [int]$State.round.sequenceIndex + 1 } else { $null })
        nextRole = $statusRole
        pendingSpeaker = $pending.Speaker
        pendingSince = $(if ($pending.Since) { $pending.Since.ToString('o') } else { $null })
        pendingFor = $pending.Duration
        dispatcher = $pending.Dispatcher
        lastEntry = $State.lastEntry
        sessionWords = $words
        estimatedSessionTokens = $estimatedTokens
        sessionBytes = $sessionBytes
        sessionByteLimit = $MaxSessionBytes
        sessionPercent = [Math]::Min(100,[Math]::Round(($sessionBytes / $MaxSessionBytes) * 100,1))
        sessionReadOnly = $sessionBytes -ge $MaxSessionBytes
        claudeUsage = Get-UsageStatus $State.usage.claude
        rowanUsage = Get-UsageStatus $State.usage.rowan
    }
    if ($AsJson) {
        $payload | ConvertTo-Json -Depth 5
        return
    }
    @"
DEMI STATUS

Project:              $Root
Session:              $($State.sessionNumber) ($($State.currentSession))
Round:                $($State.round.id)
Round status:         $($State.round.status)
Responses remaining: $($State.round.remainingResponses)
Next speaker:         $($State.round.nextSpeaker)
Round sequence:       $(if ($State.round.PSObject.Properties['sequence']) { @($State.round.sequence) -join ' -> ' } else { 'legacy round' })
Current stage:        $(if ($State.round.PSObject.Properties['sequenceIndex'] -and $State.round.status -eq 'open') { "$(1 + [int]$State.round.sequenceIndex) of $(@($State.round.sequence).Count)" } else { 'n/a' })
Pending speaker:      $(if ($pending.Speaker) { $pending.Speaker } else { 'none' })
Pending since:        $(if ($pending.Since) { $pending.Since.ToLocalTime().ToString('g', [System.Globalization.CultureInfo]::CurrentCulture) } else { 'n/a' })
Pending for:          $(if ($pending.Duration) { $pending.Duration } else { 'n/a' })
Dispatcher state:     $($pending.Dispatcher.state)$(if ($pending.Dispatcher.agent) { " - $($pending.Dispatcher.agent)$(if ($pending.Dispatcher.elapsed) { " ($($pending.Dispatcher.elapsed))" })" })
Last entry:           $($State.lastEntry)

Session size:         $words words / ~$estimatedTokens tokens
Session capacity:     $sessionBytes / $MaxSessionBytes bytes ($([Math]::Round(($sessionBytes / $MaxSessionBytes) * 100,1))%)
Claude usage:         $(Get-UsageStatus $State.usage.claude)
Rowan usage:          $(Get-UsageStatus $State.usage.rowan)
"@
}

$context = Get-DemiContext -ExplicitRoot $ProjectRoot
$root = $context.ProjectRoot
$runtimeRoot = $context.RuntimeRoot
$statePath = if ($runtimeRoot -eq $root) {
    Join-Path $root 'state\collaboration.json'
} else {
    Join-Path $runtimeRoot 'collaboration.json'
}
$lockPath = if ($runtimeRoot -eq $root) {
    Join-Path $root 'state\session.lock'
} else {
    Join-Path $runtimeRoot 'session.lock'
}

$mutatingCommands = @('say','alice','respond','continue','stop','note','direct','review','manuscript','new-session','session','usage','dispatch','run','draft','fable','draft-save','entry-save','chat','web')
if ($Command -in $mutatingCommands) {
    $preflightState = Read-JsonFile $statePath
    Assert-DemiWritePath $statePath 'collaboration state' | Out-Null
    Assert-DemiWritePath $lockPath 'collaboration lock' | Out-Null
    Assert-DemiWritePath (Get-SessionPath $root $preflightState) 'collaboration session' | Out-Null
    if ($Command -eq 'new-session') {
        Assert-DemiWritePath (Join-Path $root 'sessions\archive') 'session archive' | Out-Null
        $nextSession = Join-Path $root ('sessions\session-{0:D3}.md' -f ([int]$preflightState.sessionNumber + 1))
        Assert-DemiWritePath $nextSession 'new collaboration session' | Out-Null
    }
}

function Invoke-OneDispatch {
    param([switch]$AsDryRun, [switch]$Quiet)

    $dispatchRoot = Join-Path $root 'state\dispatch'
    $errorRoot = Join-Path $dispatchRoot 'errors'
    $dispatcherLock = Join-Path $dispatchRoot 'dispatcher.lock'
    $historyPath = Join-Path $dispatchRoot 'history.jsonl'
    foreach ($path in @($dispatchRoot,$errorRoot,$dispatcherLock,$historyPath)) {
        Assert-DemiWritePath $path 'dispatcher' | Out-Null
    }
    [void](Remove-DemiStaleDispatcherLock $dispatcherLock)

    $state = Read-JsonFile $statePath
    $directTurn = if ($state.PSObject.Properties['directTurn']) { $state.directTurn } else { $null }
    $acknowledgement = Get-NextDemiAcknowledgement $state
    if ($directTurn -and $directTurn.active) {
        $dispatchType = 'DIRECT'
        $agent = "$($directTurn.agent)"
        $noteEntryId = $null
    } elseif ($acknowledgement) {
        $dispatchType = 'ACKNOWLEDGMENT'
        $agent = $acknowledgement.Agent
        $noteEntryId = $acknowledgement.NoteEntryId
    } else {
        $dispatchType = 'RESPONSE'
        $noteEntryId = $null
        if ($state.PSObject.Properties['miloReviewPause'] -and $state.miloReviewPause -and $state.miloReviewPause.active) {
            throw "Dispatch is paused for Milo review requested by $($state.miloReviewPause.requestedBy) in $($state.miloReviewPause.entryId)."
        }
        if ($state.round.status -ne 'open') { throw 'Dispatch requires an open round or pending acknowledgment.' }
        if ([int]$state.round.remainingResponses -le 0) { throw 'Dispatch requires a positive response allowance.' }
        $agent = "$($state.round.nextSpeaker)"
        if (-not (Resolve-DemiAgentToken -Token $agent -Root $root)) { throw "Dispatch cannot select unknown or disabled agent '$agent'." }
    }
    $usageProperty = $state.usage.PSObject.Properties[$agent.ToLowerInvariant()]
    $agentUsage = if ($usageProperty) { $usageProperty.Value } else { $null }
    if ($agentUsage -and $null -ne $agentUsage.percentConsumed -and [int]$agentUsage.percentConsumed -ge $UsageLimitPercent) {
        throw "$agent usage is $($agentUsage.percentConsumed)%, meeting the $UsageLimitPercent% dispatch limit."
    }
    $sessionPath = Get-SessionPath $root $state
    if (-not (Test-DemiDatabaseSessionMode $root) -and (Get-Item -LiteralPath $sessionPath).Length -ge $MaxSessionBytes) {
        Invoke-WithLock $lockPath {
            $rollState = Read-JsonFile $statePath
            $rollPath = Get-SessionPath $root $rollState
            if ((Get-Item -LiteralPath $rollPath).Length -ge $MaxSessionBytes) {
                [void](Start-DemiSessionContinuation $root $rollState $rollPath -PreserveActiveWork)
                Write-JsonAtomic $statePath $rollState
            }
        }
        $state = Read-JsonFile $statePath
        $sessionPath = Get-SessionPath $root $state
        $agent = if ($state.directTurn -and $state.directTurn.active) { "$($state.directTurn.agent)" } else { "$($state.round.nextSpeaker)" }
    }

    $prompt = if ($dispatchType -eq 'DIRECT') {
        Get-DemiDirectPrompt $agent $state $sessionPath
    } elseif ($dispatchType -eq 'ACKNOWLEDGMENT') {
        Get-DemiAcknowledgementPrompt $agent $noteEntryId $sessionPath
    } else {
        Get-DispatchPrompt $agent $state $sessionPath
    }
    $token = '{0}-{1}' -f [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff'), ([guid]::NewGuid().ToString('N'))
    $responsePath = Join-Path $dispatchRoot "$token-response.txt"
    $stdoutPath = Join-Path $dispatchRoot "$token-stdout.txt"
    $stderrPath = Join-Path $dispatchRoot "$token-stderr.txt"
    $registeredAgent = Get-DemiAgent $agent $root
    $agentInstructionFile = $registeredAgent.InstructionFile
    $promptFiles = @(
        (Join-Path $root $agentInstructionFile),
        (Join-Path $root 'COLLABORATION.md'),
        $sessionPath
    )
    $resolvedMaxTurns = if ($agent -eq 'Claude') { Get-DemiClaudeMaxTurns $dispatchType $AgentMaxTurns } else { $AgentMaxTurns }
    $invocation = New-DemiAgentInvocation $registeredAgent $root $prompt $responsePath $resolvedMaxTurns
    $usagePath = if ($invocation.PSObject.Properties['UsagePath']) { "$($invocation.UsagePath)" } else { $null }
    $displayExecutable = [System.IO.Path]::GetFileName($invocation.Executable)
    $executable = $invocation.Executable
    $agentArguments = $invocation.Arguments

    if ($AsDryRun) {
        Write-Host "Agent:              $agent"
        Write-Host "Executable:         $displayExecutable"
        Write-Host "Arguments:          $($agentArguments -join ' ')"
        Write-Host "Prompt files:       $($promptFiles -join '; ')"
        Write-Host "Round:              $($state.round.id)"
        Write-Host "Response allowance: $($state.round.remainingResponses)"
        Write-Host "Dispatch type:      $dispatchType"
        if ($noteEntryId) { Write-Host "Responding to note: $noteEntryId" }
        return [pscustomobject]@{ DryRun = $true; State = $state; DispatchType = $dispatchType }
    }

    if (-not (Test-Path -LiteralPath $dispatchRoot)) {
        New-Item -ItemType Directory -Path $dispatchRoot -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $errorRoot)) {
        New-Item -ItemType Directory -Path $errorRoot -Force | Out-Null
    }

    $lockStream = $null
    try {
        try {
            $lockStream = [System.IO.File]::Open(
                $dispatcherLock,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read
            )
        } catch [System.IO.IOException] {
            throw "A Demi dispatcher lock is already active at $dispatcherLock."
        }
        $lockText = "$PID $([DateTimeOffset]::Now.ToString('o')) $agent $($state.round.id)"
        $lockBytes = [System.Text.Encoding]::UTF8.GetBytes($lockText)
        $lockStream.Write($lockBytes, 0, $lockBytes.Length)
        $lockStream.Flush()

        $processOutputPath = if ($invocation.ReadsStdout) { $responsePath } else { $stdoutPath }
        $exitCode = Invoke-DispatchProcess $executable $agentArguments $root $processOutputPath $stderrPath $AgentTimeoutSeconds $invocation.StandardInput
        if ($exitCode -ne 0) {
            $processDiagnostic=@($responsePath,$stdoutPath,$stderrPath)|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|ForEach-Object{[IO.File]::ReadAllText($_)}
            $processDiagnostic=($processDiagnostic -join "`n").Trim()
            if($processDiagnostic.Length -gt 1200){$processDiagnostic=$processDiagnostic.Substring($processDiagnostic.Length-1200)}
            throw "$agent exited with code $exitCode.$(if($processDiagnostic){" Provider diagnostic: $processDiagnostic"})"
        }
        Convert-DemiInvocationOutputFile $invocation $responsePath
        if (-not (Test-Path -LiteralPath $responsePath)) { throw "$agent produced no response file." }
        $responseItem = Get-Item -LiteralPath $responsePath
        if ($responseItem.Length -le 0) {
            $diagnostic = if (Test-Path -LiteralPath $stderrPath) { (Get-Content -Raw -LiteralPath $stderrPath -Encoding UTF8).Trim() } else { '' }
            if ($diagnostic.Length -gt 1200) { $diagnostic = $diagnostic.Substring($diagnostic.Length - 1200) }
            throw "$agent produced an empty response.$(if ($diagnostic) { " Agent diagnostic: $diagnostic" })"
        }
        if ($responseItem.Length -gt $MaxOutputBytes) {
            throw "$agent response is $($responseItem.Length) bytes; limit is $MaxOutputBytes."
        }
        [string]$rawResponse = [System.IO.File]::ReadAllText($responsePath, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($rawResponse)) { throw "$agent produced only whitespace." }
        $response = Remove-DemiObsoleteSelfAppendWrapper $agent $dispatchType $rawResponse
        if ($response -ne $rawResponse) {
            $sanitizerDiagnosticPath = Join-Path $errorRoot "$token-sanitizer.json"
            $sanitizerDiagnostic = [ordered]@{
                timestamp = [DateTimeOffset]::Now.ToString('o')
                round = $state.round.id
                agent = $agent
                dispatchType = $dispatchType
                recovery = 'obsolete-self-append-wrapper-removed'
                rawOutput = $rawResponse
            } | ConvertTo-Json
            Set-Utf8NoBom -Path $sanitizerDiagnosticPath -Content $sanitizerDiagnostic
        }
        $activeRequestId = if ($dispatchType -eq 'DIRECT') {
            "$($state.directTurn.openedBy)"
        } elseif ($dispatchType -eq 'RESPONSE') {
            "$($state.round.openedBy)"
        } else {
            ''
        }
        $activeRequestEntry = if ($activeRequestId) {
            Get-DemiSessionEntries $sessionPath | Where-Object Id -eq $activeRequestId | Select-Object -First 1
        } else {
            $null
        }
        $activeRequestBody = if ($null -ne $activeRequestEntry) { "$($activeRequestEntry.Body)" } else { '' }
        $response = Remove-DemiEchoedActiveRequest $response $activeRequestBody
        try {
            Assert-DemiDispatchResponse $agent $dispatchType $response $activeRequestBody
        } catch {
            $validationMessage = $_.Exception.Message
            $correctableNonResponse = $dispatchType -in @('RESPONSE','DIRECT') -and
                $validationMessage -match '(?i)readiness|context-loading|generic dispatch-mode acknowledgment|recycled moon-brightness'
            if (-not $correctableNonResponse) { throw }

            $rejectedDiagnosticPath = Join-Path $errorRoot "$token-rejected-first-attempt.json"
            $rejectedDiagnostic = [ordered]@{
                timestamp = [DateTimeOffset]::Now.ToString('o')
                round = $state.round.id
                agent = $agent
                dispatchType = $dispatchType
                recovery = 'automatic-corrective-retry'
                validationError = $validationMessage
                rejectedOutput = $rawResponse
            } | ConvertTo-Json
            Set-Utf8NoBom -Path $rejectedDiagnosticPath -Content $rejectedDiagnostic

            foreach ($path in @($responsePath,$stdoutPath,$stderrPath,$usagePath)) {
                if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force }
            }
            $retryPrompt = @"
$prompt

CORRECTIVE RETRY: Your previous output was rejected because it contained only readiness/status or recycled an unrelated topic. Do not announce that you are ready, active, initialized, or that context is loaded. Answer only the active Milo request below with substantive analysis in the first sentence:

$activeRequestBody
"@
            $retryInvocation = New-DemiAgentInvocation $registeredAgent $root $retryPrompt $responsePath $resolvedMaxTurns
            $retryOutputPath = if ($retryInvocation.ReadsStdout) { $responsePath } else { $stdoutPath }
            $retryExitCode = Invoke-DispatchProcess $retryInvocation.Executable $retryInvocation.Arguments $root $retryOutputPath $stderrPath $AgentTimeoutSeconds $retryInvocation.StandardInput
            if ($retryExitCode -ne 0) { throw "$agent corrective retry exited with code $retryExitCode." }
            Convert-DemiInvocationOutputFile $retryInvocation $responsePath
            if (-not (Test-Path -LiteralPath $responsePath)) { throw "$agent corrective retry produced no response file." }
            $retryItem = Get-Item -LiteralPath $responsePath
            if ($retryItem.Length -le 0 -or $retryItem.Length -gt $MaxOutputBytes) {
                throw "$agent corrective retry produced an invalid response size of $($retryItem.Length) bytes."
            }
            [string]$retryRawResponse = [System.IO.File]::ReadAllText($responsePath, [System.Text.Encoding]::UTF8)
            $response = Remove-DemiObsoleteSelfAppendWrapper $agent $dispatchType $retryRawResponse
            $response = Remove-DemiEchoedActiveRequest $response $activeRequestBody
            Assert-DemiDispatchResponse $agent $dispatchType $response $activeRequestBody
        }

        $fileOutput = if ($dispatchType -in @('RESPONSE','DIRECT')) { ConvertFrom-DemiAgentFileOutput $response } else { [pscustomobject]@{ Body=$response; Destination=$null } }
        $response = $fileOutput.Body
        $usageMetadata = @{}
        if ($usagePath -and (Test-Path -LiteralPath $usagePath)) {
            $usage = Get-Content -Raw -LiteralPath $usagePath -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $usage.inputTokens) { $usageMetadata['Input tokens'] = [int64]$usage.inputTokens }
            if ($null -ne $usage.outputTokens) { $usageMetadata['Output tokens'] = [int64]$usage.outputTokens }
            if ($null -ne $usage.totalTokens) { $usageMetadata['Total tokens'] = [int64]$usage.totalTokens }
            if ($null -ne $usage.costUsd) {
                $usageMetadata['Credits consumed (estimated)'] = '$' + ([double]$usage.costUsd).ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture)
            }
            if ($usage.pricing -and $usage.pricing.source) { $usageMetadata['Pricing basis'] = "$($usage.pricing.source)" }
        }
        $appendResult = Invoke-WithLock $lockPath {
            $documentCreation = $null
            if ($fileOutput.Destination) {
                $documentCreation = Invoke-DemiCreateDocument $root $fileOutput.Destination $response $activeRequestId $agent "$($registeredAgent.Model)" "agent response to $activeRequestId" -VersionIfExists
            }
            if ($dispatchType -eq 'DIRECT') {
                Invoke-DemiDirectResponseLocked $root $statePath $agent $response $state.directTurn.openedBy $documentCreation $usageMetadata
            } elseif ($dispatchType -eq 'ACKNOWLEDGMENT') {
                Invoke-DemiAcknowledgementLocked $root $statePath $agent $noteEntryId $response
            } else {
                Invoke-DemiResponseLocked $root $statePath $agent $response $state.round.id $state.round.openedBy $documentCreation $usageMetadata
            }
        }
        $history = [ordered]@{
            timestamp = [DateTimeOffset]::Now.ToString('o')
            round = $appendResult.State.round.id
            agent = $agent
            entry = $appendResult.Id
            respondingTo = $(if ($dispatchType -eq 'DIRECT') { $state.directTurn.openedBy } else { $state.round.openedBy })
            status = $appendResult.State.round.status
            remainingResponses = [int]$appendResult.State.round.remainingResponses
            dispatchType = $dispatchType
            noteEntryId = $noteEntryId
        } | ConvertTo-Json -Compress
        [System.IO.File]::AppendAllText($historyPath, $history + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        foreach ($path in @($responsePath,$stdoutPath,$stderrPath,$usagePath)) {
            if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force }
        }
        if (-not $Quiet) {
            Write-Host "Added $($appendResult.Id). Round $($appendResult.State.round.id) is $($appendResult.State.round.status); $($appendResult.State.round.remainingResponses) responses remain."
        }
        return [pscustomobject]@{
            DryRun = $false
            Id = $appendResult.Id
            Agent = $agent
            Response = $response
            State = $appendResult.State
            DispatchType = $dispatchType
            NoteEntryId = $noteEntryId
        }
    } catch {
        $failure = $_
        $failureEvidence = [System.Collections.Generic.List[string]]::new()
        $failureEvidence.Add($failure.Exception.Message)
        foreach ($path in @($responsePath,$stdoutPath,$stderrPath,$usagePath)) {
            if ($path -and (Test-Path -LiteralPath $path)) {
                $failureEvidence.Add([System.IO.File]::ReadAllText($path))
            }
        }
        $failureText = $failureEvidence -join "`n"
        $usageLimited = Test-DemiUsageLimitFailure $failureText
        $resetHint = Get-DemiUsageResetHint $failureText
        foreach ($path in @($responsePath,$stdoutPath,$stderrPath,$usagePath)) {
            if ($path -and (Test-Path -LiteralPath $path)) {
                Move-Item -LiteralPath $path -Destination (Join-Path $errorRoot ([System.IO.Path]::GetFileName($path))) -Force
            }
        }
        $diagnosticPath = Join-Path $errorRoot "$token-error.json"
        $diagnosticJson = [ordered]@{
            timestamp = [DateTimeOffset]::Now.ToString('o')
            round = $state.round.id
            agent = $agent
            dispatchType = $dispatchType
            noteEntryId = $noteEntryId
            error = $failure.Exception.Message
            usageLimit = $usageLimited
        } | ConvertTo-Json
        Set-Utf8NoBom -Path $diagnosticPath -Content $diagnosticJson
        if ($usageLimited -and $dispatchType -in @('RESPONSE','DIRECT')) {
            $expectedOpenedBy = if ($dispatchType -eq 'DIRECT') { $state.directTurn.openedBy } else { $state.round.openedBy }
            $skipResult = Invoke-WithLock $lockPath {
                Invoke-DemiUsageSkipLocked $root $statePath $agent $dispatchType $expectedOpenedBy $resetHint
            }
            $history = [ordered]@{
                timestamp = [DateTimeOffset]::Now.ToString('o'); round = $skipResult.State.round.id
                agent = $agent; entry = $skipResult.Id; respondingTo = $expectedOpenedBy
                status = 'skipped-usage-limit'; remainingResponses = [int]$skipResult.State.round.remainingResponses
                dispatchType = $dispatchType; noteEntryId = $noteEntryId; diagnostic = $diagnosticPath
            } | ConvertTo-Json -Compress
            [System.IO.File]::AppendAllText($historyPath, $history + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
            if (-not $Quiet) { Write-Warning "$agent was skipped because its provider reported a usage limit. The remaining participants will continue." }
            return [pscustomobject]@{ DryRun=$false; Id=$skipResult.Id; Agent=$agent; Response=$null; State=$skipResult.State; DispatchType=$dispatchType; Skipped=$true; Reason='usage limit' }
        }
        throw "Dispatch failed for ${agent}: $($failure.Exception.Message) Diagnostics: $diagnosticPath"
    } finally {
        if ($lockStream) {
            $lockStream.Dispose()
            if (Test-Path -LiteralPath $dispatcherLock) { Remove-Item -LiteralPath $dispatcherLock -Force }
        }
    }
}

function ConvertFrom-DemiSessionText {
    param([string]$Text)
    $heading = '## (?<Id>S\d{3}-[A-Z]\d{4}) - (?<Author>[^\r\n]+)'
    $pattern = "(?ms)^$heading\r?\n(?<Content>.*?)(?=^## S\d{3}-[A-Z]\d{4} - [^\r\n]+\r?$|\z)"
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        $content = $match.Groups['Content'].Value
        $separator = [regex]::Match($content, '\r?\n\r?\n')
        if ($separator.Success) {
            $metadataText = $content.Substring(0, $separator.Index).TrimEnd("`r","`n")
            $body = $content.Substring($separator.Index + $separator.Length)
        } else {
            $metadataText = $content.TrimEnd("`r","`n")
            $body = ''
        }
        $metadata = [ordered]@{}
        foreach ($line in ($metadataText -split '\r?\n')) {
            if ($line -match '^(?<Key>[^:]+):\s*(?<Value>.*)$') {
                $metadata[$Matches.Key] = $Matches.Value
            }
        }
        $timestamp = $null
        if ($metadata.Contains('Timestamp')) {
            $parsedTimestamp = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($metadata.Timestamp, [ref]$parsedTimestamp)) {
                $timestamp = $parsedTimestamp
            }
        }
        [pscustomobject]@{
            Id = $match.Groups['Id'].Value
            Author = $match.Groups['Author'].Value
            Timestamp = $timestamp
            Metadata = $metadata
            Body = $body
            Raw = $match.Value
        }
    }
}

function Get-DemiSessionEntries {
    param([string]$SessionPath)
    $text = Get-Content -Raw -LiteralPath $SessionPath -Encoding UTF8
    return @(ConvertFrom-DemiSessionText $text)
}

function Save-DemiSessionEntry {
    param([string]$EntryId)
    if ($EntryId -notmatch '^S\d{3}-[A-Z]\d{4}$') { throw 'Invalid session entry ID.' }
    $state = Read-JsonFile $statePath
    $entry = Get-DemiSessionEntries (Get-SessionPath $root $state) |
        Where-Object Id -eq $EntryId | Select-Object -First 1
    if (-not $entry) { throw "Session entry $EntryId was not found in the current session." }
    $author = "$($entry.Author)".ToLowerInvariant() -replace '[^a-z0-9]+','-'
    $directory = Join-Path $root 'downloads\comments'
    Assert-DemiWritePath $directory 'comment download directory' | Out-Null
    [void][System.IO.Directory]::CreateDirectory($directory)
    $timestamp = if ($entry.Timestamp) { $entry.Timestamp.ToString('o') } else { "$($entry.Metadata.Timestamp)" }
    $type = if ($entry.Metadata.Contains('Type')) { "$($entry.Metadata.Type)" } else { '' }
    $content = @(
        "# $($entry.Author) ($($entry.Id))"
        $(if ($timestamp) { "Timestamp: $timestamp" })
        $(if ($type) { "Type: $type" })
        ''
        $entry.Body.TrimEnd()
        ''
    ) -join [Environment]::NewLine
    $baseName = "$EntryId-$author"
    $candidate = Join-Path $directory "$baseName.md"
    $version = 1
    while (Test-Path -LiteralPath $candidate) {
        if ((Get-Content -Raw -LiteralPath $candidate -Encoding UTF8) -eq $content) {
            return [pscustomobject]@{ path="downloads\comments\$([System.IO.Path]::GetFileName($candidate))"; existing=$true }
        }
        $version++
        $candidate = Join-Path $directory ('{0}_v{1:D3}.md' -f $baseName,$version)
    }
    Invoke-DemiCreateNewFile $candidate ([System.Text.UTF8Encoding]::new($false).GetBytes($content))
    return [pscustomobject]@{ path="downloads\comments\$([System.IO.Path]::GetFileName($candidate))"; existing=$false }
}

function Test-DemiTerminalStyling {
    if ([Console]::IsOutputRedirected) { return $false }
    if ($env:TERM -eq 'dumb' -or $env:NO_COLOR) { return $false }
    $supportsVirtualTerminal = $Host.UI.PSObject.Properties['SupportsVirtualTerminal']
    if ($supportsVirtualTerminal) { return [bool]$Host.UI.SupportsVirtualTerminal }
    return $false
}

function Get-DemiChatPreferences {
    param(
        [string]$Path,
        [bool]$StylingSupported = (Test-DemiTerminalStyling)
    )
    $defaults = [ordered]@{
        view = 'compact'
        color = $true
        bodyColor = 'white'
        markdown = $true
        statusline = $false
    }
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]$defaults }
    $saved = Read-JsonFile $Path
    if ($saved.view -in @('compact','full','raw')) { $defaults.view = $saved.view }
    if ($null -ne $saved.color) { $defaults.color = [bool]$saved.color }
    if ($saved.PSObject.Properties['bodyColor'] -and $saved.bodyColor -in @('white','gray','default')) {
        $defaults.bodyColor = $saved.bodyColor
    }
    if ($null -ne $saved.statusline) { $defaults.statusline = [bool]$saved.statusline }
    if ($saved.PSObject.Properties['markdown']) { $defaults.markdown = [bool]$saved.markdown }
    return [pscustomobject]$defaults
}

function Save-DemiChatPreferences {
    param([string]$Path, [object]$Preferences)
    Assert-DemiWritePath $Path 'chat preferences' | Out-Null
    Write-JsonAtomic $Path ([ordered]@{
        view = $Preferences.view
        color = [bool]$Preferences.color
        bodyColor = $Preferences.bodyColor
        statusline = [bool]$Preferences.statusline
        markdown = [bool]$Preferences.markdown
    })
}

function Get-DemiChatColor {
    param([string]$Author)
    switch ($Author) {
        'Milo' { 'Yellow' }
        'Claude' { 'Cyan' }
        'Rowan' { 'Green' }
        'Gem' { 'Magenta' }
        'Gemini' { 'Magenta' }
        default { 'DarkGray' }
    }
}

function Get-DemiChatBodyColor {
    param([object]$Preferences, [string]$Author)
    if ($Author -eq 'System') { return 'DarkGray' }
    switch ($Preferences.bodyColor) {
        'gray' { 'Gray' }
        'default' { 'Default' }
        default { 'White' }
    }
}

function Get-DemiAnsiColorCode {
    param([string]$Color)
    switch ($Color) {
        'Yellow' { '33' }
        'Cyan' { '36' }
        'Green' { '32' }
        'Magenta' { '35' }
        'DarkGray' { '90' }
        'DarkYellow' { '33' }
        'Red' { '31' }
        'White' { '97' }
        'Default' { '39' }
        default { '37' }
    }
}

function ConvertTo-DemiAnsiMarkdown {
    param([string]$Text, [string]$BaseColor = 'Gray', [bool]$UseColor = $true)
    $escape = [char]27
    $reset = "$escape[0m"
    $base = if ($UseColor) { "$escape[$(Get-DemiAnsiColorCode $BaseColor)m" } else { '' }
    $pattern = '`(?<Code>[^`\r\n]+)`|\*\*(?<Bold>[^*\r\n]+)\*\*|\*(?<StarItalic>[^*\r\n]+)\*|_(?<UnderItalic>[^_\r\n]+)_'
    $renderedLines = foreach ($line in [regex]::Split($Text, '\r?\n')) {
        $builder = [System.Text.StringBuilder]::new()
        [void]$builder.Append($base)
        $position = 0
        foreach ($match in [regex]::Matches($line, $pattern)) {
            [void]$builder.Append($line.Substring($position, $match.Index - $position))
            $style = if ($match.Groups['Bold'].Success) {
                '1'
            } elseif ($match.Groups['Code'].Success) {
                '7'
            } else {
                '3'
            }
            $content = if ($match.Groups['Bold'].Success) {
                $match.Groups['Bold'].Value
            } elseif ($match.Groups['Code'].Success) {
                $match.Groups['Code'].Value
            } elseif ($match.Groups['StarItalic'].Success) {
                $match.Groups['StarItalic'].Value
            } else {
                $match.Groups['UnderItalic'].Value
            }
            [void]$builder.Append("$escape[${style}m")
            [void]$builder.Append($content)
            [void]$builder.Append($reset)
            [void]$builder.Append($base)
            $position = $match.Index + $match.Length
        }
        [void]$builder.Append($line.Substring($position))
        [void]$builder.Append($reset)
        $builder.ToString()
    }
    return $renderedLines -join [Environment]::NewLine
}

function Format-DemiChatMarkdown {
    param(
        [string]$Text,
        [object]$Preferences,
        [string]$Color,
        [bool]$StylingSupported = (Test-DemiTerminalStyling)
    )
    if ($Preferences.markdown -and $StylingSupported) {
        return ConvertTo-DemiAnsiMarkdown $Text $Color ([bool]$Preferences.color)
    }
    return $Text
}

function Write-DemiChatText {
    param(
        [string]$Text,
        [object]$Preferences,
        [string]$Color = 'Gray',
        [switch]$RenderMarkdown
    )
    if ($RenderMarkdown -and $Preferences.markdown -and (Test-DemiTerminalStyling)) {
        Write-Host (Format-DemiChatMarkdown $Text $Preferences $Color $true)
        return
    }
    if ($Preferences.color -and $Color -ne 'Default') {
        Write-Host $Text -ForegroundColor $Color
    } else {
        Write-Host $Text
    }
}

function Write-DemiChatSubdued {
    param([string]$Text, [object]$Preferences)
    if ($Preferences.color -and (Test-DemiTerminalStyling)) {
        $escape = [char]27
        Write-Host "$escape[2;37m$Text$escape[0m"
    } else {
        Write-DemiChatText $Text $Preferences 'DarkGray'
    }
}

function Show-DemiChatEntry {
    param([object]$Entry, [object]$Preferences)
    $headingColor = Get-DemiChatColor $Entry.Author
    $bodyColor = Get-DemiChatBodyColor $Preferences $Entry.Author
    $localTime = if ($Entry.Timestamp) {
        $Entry.Timestamp.ToLocalTime().ToString('t', [System.Globalization.CultureInfo]::CurrentCulture)
    } else { '?' }
    $displayAuthor = if ($Entry.Author -eq 'Claude') {
        if ($Entry.Metadata.Contains('Model') -and "$($Entry.Metadata.Model)" -eq 'Fable') { 'Claude  Fable' } else { 'Claude  Sonnet' }
    } else { $Entry.Author }
    Write-Host ''
    switch ($Preferences.view) {
        'raw' {
            $rawLines = [regex]::Split($Entry.Raw, '\r?\n')
            Write-DemiChatText $rawLines[0] $Preferences $headingColor
            if ($rawLines.Count -gt 1) {
                Write-DemiChatText ($rawLines[1..($rawLines.Count - 1)] -join [Environment]::NewLine) $Preferences $bodyColor
            }
        }
        'full' {
            Write-DemiChatText "$displayAuthor ($($Entry.Id)), ${localTime}:" $Preferences $headingColor
            foreach ($item in $Entry.Metadata.GetEnumerator()) {
                Write-DemiChatText "$($item.Key): $($item.Value)" $Preferences 'DarkGray'
            }
            Write-Host ''
            Write-DemiChatText $Entry.Body $Preferences $bodyColor -RenderMarkdown
        }
        default {
            Write-DemiChatText "$displayAuthor ($($Entry.Id)), ${localTime}:" $Preferences $headingColor
            Write-DemiChatText $Entry.Body $Preferences $bodyColor -RenderMarkdown
        }
    }
}

function Show-DemiChatStatus {
    param([object]$State, [bool]$AutoEnabled, [object]$Preferences, [switch]$Force)
    if (-not $Force -and -not $Preferences.statusline) { return }
    $roundId = if ($State.round.id) { $State.round.id } else { '(none)' }
    $next = if ($State.round.nextSpeaker) { $State.round.nextSpeaker } else { 'Milo' }
    $autoLabel = if ($AutoEnabled) { 'ON' } else { 'OFF' }
    Write-DemiChatSubdued "Round $roundId | Next: $next | $($State.round.remainingResponses) responses remain | Auto: $autoLabel" $Preferences
}

function Invoke-DemiChatDispatch {
    param([bool]$AutoEnabled, [object]$Preferences)
    $before = Read-JsonFile $statePath
    $directTurn = if ($before.PSObject.Properties['directTurn']) { $before.directTurn } else { $null }
    $acknowledgement = Get-NextDemiAcknowledgement $before
    $selectedAgent = if ($directTurn -and $directTurn.active) {
        "$($directTurn.agent)"
    } elseif ($acknowledgement) {
        $acknowledgement.Agent
    } else {
        "$($before.round.nextSpeaker)"
    }
    if (-not (Resolve-DemiAgentToken -Token $selectedAgent -Root $root)) {
        throw "No dispatchable agent is next; current next speaker is $($before.round.nextSpeaker)."
    }
    $chatSequence = if ($before.round.PSObject.Properties['sequence']) { @($before.round.sequence) } else { @() }
    $chatIndex = if ($before.round.PSObject.Properties['sequenceIndex']) { [int]$before.round.sequenceIndex } else { -1 }
    $chatSynthesis = Test-DemiRoundSynthesisStage $before.round
    $role = if ($chatSynthesis) { 'final synthesis' } else { switch ($selectedAgent) { 'Claude' { 'writing proposal' }; 'Rowan' { 'editorial review' }; 'Gem' { 'independent prose and technical review' }; default { 'agent response' } } }
    $stage = if ($before.round.PSObject.Properties['sequence'] -and -not ($directTurn -and $directTurn.active) -and -not $acknowledgement) { " · stage $(1 + [int]$before.round.sequenceIndex)/$(@($before.round.sequence).Count)" } else { '' }
    Write-DemiChatSubdued "Dispatching $selectedAgent · $role$stage..." $Preferences
    $result = Invoke-OneDispatch -Quiet
    $entry = Get-DemiSessionEntries (Get-SessionPath $root $result.State) |
        Where-Object Id -eq $result.Id | Select-Object -First 1
    if (-not $entry) { throw "Appended entry $($result.Id) could not be parsed for display." }
    Show-DemiChatEntry $entry $Preferences
    Show-DemiChatStatus $result.State $AutoEnabled $Preferences
    return $result
}

function Invoke-DemiChatRun {
    param([bool]$AutoEnabled, [object]$Preferences)
    $initial = Read-JsonFile $statePath
    $available = Get-DemiDispatchWorkCount $initial
    if ($available -le 0) { throw 'Run requires an open round or pending acknowledgment.' }
    $limit = [Math]::Min([Math]::Min($available, $MaxResponses), 12)
    $completed = 0
    while ($completed -lt $limit) {
        $current = Read-JsonFile $statePath
        if ((Get-DemiDispatchWorkCount $current) -le 0) { break }
        [void](Invoke-DemiChatDispatch $AutoEnabled $Preferences)
        $completed++
    }
    return $completed
}

function Get-DemiLatestManuscript {
    param([string]$Root)
    $candidates = @(Get-ChildItem -LiteralPath $Root -File -Filter 'Diaspora_Book_One_v*.docx' | ForEach-Object {
        if ($_.Name -match '^Diaspora_Book_One_v(?<Version>\d+).*\.docx$') {
            [pscustomobject]@{ Path=$_.FullName; RelativePath=$_.Name; Version=[int]$Matches.Version }
        }
    })
    if (-not $candidates.Count) { throw 'No top-level Diaspora_Book_One_v*.docx manuscript was found.' }
    $highest = ($candidates | Measure-Object Version -Maximum).Maximum
    $selected = @($candidates | Where-Object Version -eq $highest)
    if ($selected.Count -ne 1) { throw "More than one Book One manuscript has highest version v$highest. Pin one with: demi manuscript set <project-relative-docx>" }
    return $selected[0]
}

function Get-DemiReviewManuscript {
    param([string]$Root)
    $configPath = Join-Path $Root 'config\review-manuscript.json'
    if (-not (Test-Path -LiteralPath $configPath)) { return Get-DemiLatestManuscript $Root }
    $config = Read-JsonFile $configPath
    $relative = "$($config.path)"
    if ([string]::IsNullOrWhiteSpace($relative) -or [System.IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)|:') { throw 'Configured review manuscript path is unsafe.' }
    $full = [System.IO.Path]::GetFullPath((Join-Path $Root $relative))
    if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or [System.IO.Path]::GetExtension($full) -ne '.docx') { throw "Configured review manuscript does not exist or is not DOCX: $relative" }
    return [pscustomobject]@{ Path=$full; RelativePath=$relative; Version=$(if([System.IO.Path]::GetFileName($relative)-match '_v(\d+)'){[int]$Matches[1]}else{$null}) }
}

function Get-DemiChapterExcerpt {
    param([string]$Text,[int]$FirstChapter,[int]$LastChapter)
    $headings = [regex]::Matches($Text,'(?im)^\s*#?\s*Chapter\s+[^\r\n]+\s*$')
    if ($FirstChapter -lt 1 -or $LastChapter -lt $FirstChapter -or $LastChapter -gt $headings.Count) { throw "Requested chapter range $FirstChapter-$LastChapter is outside the manuscript's 1-$($headings.Count) chapters." }
    $start = $headings[$FirstChapter-1].Index
    $end = if ($LastChapter -lt $headings.Count) { $headings[$LastChapter].Index } else { $Text.Length }
    return $Text.Substring($start,$end-$start).Trim()
}

function Get-DemiScopedReviewMaterial {
    param([string]$Root,[string]$Request)
    $match = [regex]::Match($Request,'(?i)\bChapters?\s+(?<First>\d+)(?:\s*(?:-|–|—|through|to)\s*(?<Last>\d+))?\b')
    if (-not $match.Success) { return $null }
    $first = [int]$match.Groups['First'].Value
    $last = if ($match.Groups['Last'].Success) { [int]$match.Groups['Last'].Value } else { $first }
    $manuscript = Get-DemiReviewManuscript $Root
    try { $text = ConvertFrom-DemiDocx $manuscript.Path }
    catch { throw "The authoritative manuscript cannot be prepared for review: $($manuscript.RelativePath). Close it in Word if it is open, then retry. Detail: $($_.Exception.Message)" }
    $excerpt = Get-DemiChapterExcerpt $text $first $last
    return [pscustomobject]@{ Manuscript=$manuscript; First=$first; Last=$last; Text=$excerpt; Words=[regex]::Matches($excerpt,'\S+').Count }
}

function Invoke-DemiBlindReview {
    param([string]$Request)
    if ([string]::IsNullOrWhiteSpace($Request)) { throw 'Usage: demi review "request"' }
    $reviewRoot = Join-Path $root 'state\reviews'
    Assert-DemiWritePath $reviewRoot 'review output' | Out-Null
    [void][System.IO.Directory]::CreateDirectory($reviewRoot)
    $reviewId = 'REV-{0}-{1}' -f [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss'),([guid]::NewGuid().ToString('N').Substring(0,8))
    $requestEntry = Invoke-WithLock $lockPath {
        $locked = Read-JsonFile $statePath
        $id = Add-SessionEntry $root $locked 'Milo' 'BLIND REVIEW REQUEST' "/review $Request" @{Review=$reviewId}
        Write-JsonAtomic $statePath $locked
        return $id
    }
    $scopedMaterial = Get-DemiScopedReviewMaterial $root $Request
    $materialInstruction = ''
    if ($scopedMaterial) {
        $materialPath = Join-Path $reviewRoot "$reviewId-material.md"
        $materialHeader = "# Blind review material`n`nSource: $($scopedMaterial.Manuscript.RelativePath)`nScope: Chapters $($scopedMaterial.First)-$($scopedMaterial.Last)`nWords: $($scopedMaterial.Words)`n`n"
        Set-Utf8NoBom $materialPath ($materialHeader + $scopedMaterial.Text)
        $materialInstruction = @"
The exact primary manuscript material has already been extracted to:
$materialPath

Read that file completely and review only that supplied chapter scope. Do not search for, select, or critique alternate manuscript versions, chapter drafts, packets, or archives. Consult later chapters or canon sources only when the request requires a specific continuity check.
"@
    }
    $state = Read-JsonFile $statePath
    $sessionPath = Get-SessionPath $root $state
    $jobs = @()
    foreach ($agent in Get-DemiAgentRegistry) {
        $responsePath = Join-Path $reviewRoot "$reviewId-$($agent.Name.ToLowerInvariant()).txt"
        $prompt = @"
Agent: $($agent.Name)
Role: $($agent.Role)
Blind review: $reviewId

Read $($agent.InstructionFile), COLLABORATION.md, state/collaboration.json, and the current session at $sessionPath. Read relevant project sources when needed. Preserve the existing Demiurge canon-status and role architecture.
$materialInstruction
Review only the request below. This is a blind independent review: do not read or seek any other agent's output for this review. Return text only; do not edit files, invoke Demi, or modify collaboration state.

Use strict editorial candor. Do not provide morale-building praise, a complimentary preamble, or inflated superlatives. Calibrate favorable language to specific textual evidence and distinguish competent, effective, strong, unusually successful, and exceptional. Identify strengths only to make the diagnosis accurate and to protect them during revision. State weaknesses, mixed judgments, and uncertainty plainly.

--- REVIEW REQUEST ---
$Request
--- END REVIEW REQUEST ---
"@
        $reviewMaxTurns = if($agent.Name -eq 'Claude'){[Math]::Max($AgentMaxTurns,25)}else{$AgentMaxTurns}
        $invocation = New-DemiAgentInvocation $agent $root $prompt $responsePath $reviewMaxTurns
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$invocation.Executable;$info.WorkingDirectory=$root;$info.UseShellExecute=$false;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        if($info.PSObject.Properties.Name -contains 'StandardOutputEncoding'){$utf8=[Text.UTF8Encoding]::new($false);$info.StandardOutputEncoding=$utf8;$info.StandardErrorEncoding=$utf8}
        $quoted=foreach($arg in $invocation.Arguments){if($arg-notmatch '[\s"]'){$arg}else{$escaped=[regex]::Replace($arg,'(\\*)"','$1$1\"');$escaped=[regex]::Replace($escaped,'(\\+)$','$1$1');'"'+$escaped+'"'}};$info.Arguments=$quoted-join ' '
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info;[void]$process.Start()
        if($null-ne $invocation.StandardInput){$inputBytes=[Text.UTF8Encoding]::new($false).GetBytes($invocation.StandardInput);$process.StandardInput.BaseStream.Write($inputBytes,0,$inputBytes.Length);$process.StandardInput.BaseStream.Flush()};$process.StandardInput.Close()
        $jobs += [pscustomobject]@{Agent=$agent;Process=$process;Stdout=$process.StandardOutput.ReadToEndAsync();Stderr=$process.StandardError.ReadToEndAsync();ResponsePath=$responsePath;ReadsStdout=$invocation.ReadsStdout;Invocation=$invocation;Published=$false}
    }
    $deadline=[DateTime]::UtcNow.AddSeconds($AgentTimeoutSeconds)
    while(@($jobs|Where-Object{-not $_.Process.HasExited}).Count){
        foreach($j in $jobs|Where-Object{$_.Process.HasExited-and-not$_.Published}){
            if($j.ReadsStdout-and$j.Stdout.IsCompleted){$early=$j.Stdout.GetAwaiter().GetResult();if(-not[string]::IsNullOrWhiteSpace($early)){Set-Utf8NoBom $j.ResponsePath $early}}
            $j.Published=$true
        }
        if([DateTime]::UtcNow-ge$deadline){foreach($j in $jobs|Where-Object{-not $_.Process.HasExited}){try{$j.Process.Kill($true)}catch{}};throw "Blind review exceeded the $AgentTimeoutSeconds-second timeout."};Start-Sleep -Milliseconds 200
    }
    foreach($j in $jobs|Where-Object{-not$_.Published}){if($j.ReadsStdout-and$j.Stdout.IsCompleted){$early=$j.Stdout.GetAwaiter().GetResult();if(-not[string]::IsNullOrWhiteSpace($early)){Set-Utf8NoBom $j.ResponsePath $early}};$j.Published=$true}
    $reviews=[ordered]@{}
    $skipped=[ordered]@{}
    $reviewFailures=[System.Collections.Generic.List[string]]::new()
    foreach($job in $jobs){
        $stdout=$job.Stdout.GetAwaiter().GetResult();$stderr=$job.Stderr.GetAwaiter().GetResult()
        $exitCode=$job.Process.ExitCode
        if($job.ReadsStdout -and -not [string]::IsNullOrWhiteSpace($stdout)){Set-Utf8NoBom $job.ResponsePath $stdout}
        Convert-DemiInvocationOutputFile $job.Invocation $job.ResponsePath
        $text=if(Test-Path -LiteralPath $job.ResponsePath){Get-Content -Raw -LiteralPath $job.ResponsePath -Encoding UTF8}else{''}
        $evidence="$stdout`n$stderr`n$text"
        if(($exitCode-ne 0)-or[string]::IsNullOrWhiteSpace($text)){
            if(Test-DemiUsageLimitFailure $evidence){
                $resetHint=Get-DemiUsageResetHint $evidence
                $reviews[$job.Agent.Name]="$($job.Agent.Name) was skipped because its provider refused the review after its usage limit was reached."
                if($resetHint){$reviews[$job.Agent.Name]+=" Provider report: $resetHint."}
                $skipped[$job.Agent.Name]=$true
                $job.Process.Dispose();continue
            }
            $job.Process.Dispose()
            $detail=($stderr+"`n"+$text).Trim()
            if($exitCode-ne 0){$reviewFailures.Add("$($job.Agent.Name) review failed: $(if($detail){$detail}else{'no diagnostic output'})");continue}
            $reviewFailures.Add("$($job.Agent.Name) produced no review.");continue
        }
        $reviews[$job.Agent.Name]=$text.Trim();$skipped[$job.Agent.Name]=$false;$job.Process.Dispose()
    }
    if($reviewFailures.Count){throw ($reviewFailures -join "`n")}
    Invoke-WithLock $lockPath {
        $locked=Read-JsonFile $statePath
        foreach($name in @('Claude','Rowan','Gem')){
            if($skipped[$name]){[void](Add-SessionEntry $root $locked 'System' 'AGENT SKIPPED' $reviews[$name] @{Agent=$name;Reason='usage limit';Review=$reviewId;'Responding to'=$requestEntry})}
            else{[void](Add-SessionEntry $root $locked $name 'INDEPENDENT REVIEW' $reviews[$name] @{Review=$reviewId;'Responding to'=$requestEntry;Blind='true'})}
        }
        $comparison=@("# Review comparison",'')+(@('Claude','Rowan','Gem')|ForEach-Object{"## $_`n`n$($reviews[$_])"})
        [void](Add-SessionEntry $root $locked 'System' 'REVIEW COMPARISON' ($comparison-join "`n`n") @{Review=$reviewId;'Responding to'=$requestEntry})
        Write-JsonAtomic $statePath $locked
    }
    Write-Output (($reviews.GetEnumerator()|ForEach-Object{"=== $($_.Key) ===`n$($_.Value)"})-join "`n`n")
}

function Invoke-DemiChatAcknowledgements {
    param([bool]$AutoEnabled, [object]$Preferences)
    $completed = 0
    while ($completed -lt 12) {
        $current = Read-JsonFile $statePath
        if ((Get-DemiPendingAcknowledgementCount $current) -le 0) { break }
        [void](Invoke-DemiChatDispatch $AutoEnabled $Preferences)
        $completed++
    }
    return $completed
}

function Show-DemiChatExternalUpdates {
    param(
        [string]$SessionPath,
        [string]$LastDisplayedId,
        [object]$Preferences,
        [bool]$AutoEnabled
    )
    $entries = @(Get-DemiSessionEntries $SessionPath)
    if (-not $entries.Count) { return $LastDisplayedId }
    $startIndex = 0
    if ($LastDisplayedId) {
        $known = -1
        for ($index = 0; $index -lt $entries.Count; $index++) {
            if ($entries[$index].Id -eq $LastDisplayedId) { $known = $index; break }
        }
        if ($known -ge 0) { $startIndex = $known + 1 }
    }
    for ($index = $startIndex; $index -lt $entries.Count; $index++) {
        Show-DemiChatEntry $entries[$index] $Preferences
        Show-DemiChatStatus (Read-JsonFile $statePath) $AutoEnabled $Preferences
        $LastDisplayedId = $entries[$index].Id
    }
    return $LastDisplayedId
}

function Write-DemiChatPrompt {
    param([string]$Buffer, [object]$Preferences)
    if ($Preferences.color) {
        Write-Host 'Milo> ' -NoNewline -ForegroundColor Yellow
    } else {
        Write-Host 'Milo> ' -NoNewline
    }
    if ($Buffer) { Write-Host $Buffer -NoNewline }
}

function Read-DemiChatLine {
    param(
        [string]$SessionPath,
        [ref]$LastDisplayedId,
        [object]$Preferences,
        [bool]$AutoEnabled
    )
    if ([Console]::IsInputRedirected) {
        Write-DemiChatPrompt '' $Preferences
        return [Console]::In.ReadLine()
    }
    try { $null = [Console]::KeyAvailable } catch { return Read-Host 'Milo' }
    $buffer = [System.Text.StringBuilder]::new()
    $lastWrite = (Get-Item -LiteralPath $SessionPath).LastWriteTimeUtc
    Write-DemiChatPrompt '' $Preferences
    while ($true) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) {
                Write-Host ''
                return $buffer.ToString()
            }
            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($buffer.Length -gt 0) {
                    [void]$buffer.Remove($buffer.Length - 1, 1)
                    Write-Host "`b `b" -NoNewline
                }
                continue
            }
            if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq [ConsoleKey]::C) {
                throw [System.OperationCanceledException]::new('Chat input interrupted.')
            }
            if (-not [char]::IsControl($key.KeyChar)) {
                [void]$buffer.Append($key.KeyChar)
                Write-Host $key.KeyChar -NoNewline
            }
            continue
        }
        Start-Sleep -Milliseconds 100
        $item = Get-Item -LiteralPath $SessionPath
        if ($item.LastWriteTimeUtc -gt $lastWrite) {
            $lastWrite = $item.LastWriteTimeUtc
            Write-Host ''
            $LastDisplayedId.Value = Show-DemiChatExternalUpdates $SessionPath $LastDisplayedId.Value $Preferences $AutoEnabled
            Write-DemiChatPrompt $buffer.ToString() $Preferences
        }
    }
}

switch ($Command) {
    'checkin' {
        if($Arguments.Count -ne 1){throw 'Usage: demi checkin <agent-name-or-handle>'}
        $agent = Get-DemiAgent -Name $Arguments[0] -Root $root
        Invoke-DemiCheckIn $agent.Name
    }
    'say' {
        $body = Get-TextArgument $Arguments 'Usage: demi say "message"'
        $targetName = if($To -ieq 'Both'){'Both'}else{(Get-DemiAgent -Name $To -Root $root).Name}
        Invoke-WithLock $lockPath {
            $state = Read-JsonFile $statePath
            Clear-DemiReviewPause $state
            if ($state.round.status -eq 'open') {
                $roundId = $state.round.id
                $remainingResponses = [int]$state.round.remainingResponses
                $id = Add-SessionEntry $root $state 'Milo' 'INTERJECTION' $body @{
                    Round = $roundId
                }
                $state.round.openedBy = $id
                Write-JsonAtomic $statePath $state
                Write-Output "Added $id to $roundId. Response allowance unchanged at $remainingResponses."
                return
            }
            $roundNumber = [int]$state.roundCounter + 1
            $state.roundCounter = $roundNumber
            $roundId = 'R{0:D3}-{1:D3}' -f [int]$state.sessionNumber, $roundNumber
            $sequence = if ($targetName -eq 'Both') { @(Get-DemiAutomaticAgentSequence -Root $root) } else { @($targetName,$targetName,$targetName) }
            if(-not$sequence.Count){$id=Add-SessionEntry $root $state 'Milo' 'HUMAN ENTRY' $body @{};Write-JsonAtomic $statePath $state;Write-Output "Added $id. No automatic agents are configured.";return}
            $state.round = [pscustomobject]@{
                id = $roundId
                status = 'open'
                remainingResponses = $sequence.Count
                nextSpeaker = $sequence[0]
                target = $targetName
                openedBy = $null
                sequence = $sequence
                sequenceIndex = 0
                synthesisAgents = $(if($targetName -eq 'Both'){@(Get-DemiSynthesisAgents -Root $root)}else{@()})
                focus = $(if($state.PSObject.Properties['focus']){Copy-DemiValue $state.focus}else{$null})
            }
            $id = Add-SessionEntry $root $state 'Milo' 'PROPOSAL ROUND' $body @{
                Round = $roundId
                Target = $targetName
                'Default agent responses' = $sequence.Count
                'Response sequence' = ($sequence -join ' -> ')
            }
            $state.round.openedBy = $id
            Write-JsonAtomic $statePath $state
            Write-Output "Added $id. Opened ${roundId}: $($sequence -join ' -> ') ($($sequence.Count) responses)."
        }
    }
    'alice' {
        $body = Get-TextArgument $Arguments 'Usage: demi alice "message"'
        Invoke-WithLock $lockPath {
            $state = Read-JsonFile $statePath
            Clear-DemiReviewPause $state
            if ($state.round.status -eq 'open') {
                $roundId = $state.round.id
                $remainingResponses = [int]$state.round.remainingResponses
                $id = Add-SessionEntry $root $state 'Alice' 'GUEST CONTRIBUTION' $body @{ Round = $roundId }
                $state.round.openedBy = $id
                Write-JsonAtomic $statePath $state
                Write-Output "Added Alice contribution $id to $roundId. Response allowance unchanged at $remainingResponses."
                return
            }
            $roundNumber = [int]$state.roundCounter + 1
            $state.roundCounter = $roundNumber
            $roundId = 'R{0:D3}-{1:D3}' -f [int]$state.sessionNumber, $roundNumber
            $sequence = @(Get-DemiAutomaticAgentSequence -Root $root)
            if(-not$sequence.Count){$id=Add-SessionEntry $root $state 'Alice' 'GUEST CONTRIBUTION' $body @{};Write-JsonAtomic $statePath $state;Write-Output "Added Alice contribution $id. No automatic agents are configured.";return}
            $state.round = [pscustomobject]@{
                id = $roundId; status = 'open'; remainingResponses = $sequence.Count
                nextSpeaker = $sequence[0]; target = 'Both'; openedBy = $null
                sequence = $sequence; sequenceIndex = 0
                synthesisAgents = @(Get-DemiSynthesisAgents -Root $root)
                focus = $(if($state.PSObject.Properties['focus']){Copy-DemiValue $state.focus}else{$null})
            }
            $id = Add-SessionEntry $root $state 'Alice' 'GUEST CONTRIBUTION' $body @{
                Round = $roundId
                Target = 'Both'
                'Default agent responses' = $sequence.Count
                'Response sequence' = ($sequence -join ' -> ')
            }
            $state.round.openedBy = $id
            Write-JsonAtomic $statePath $state
            Write-Output "Added Alice contribution $id. Opened ${roundId}: $($sequence -join ' -> ') ($($sequence.Count) responses)."
        }
    }
    'respond' {
        if ($Arguments.Count -lt 2) { throw 'Usage: demi respond <agent-name-or-handle> "response text"' }
        $agent = (Get-DemiAgent -Name $Arguments[0] -Root $root).Name
        $body = Get-TextArgument $Arguments[1..($Arguments.Count - 1)] 'Response text is required.'
        Invoke-WithLock $lockPath {
            $result = Invoke-DemiResponseLocked $root $statePath $agent $body
            Write-Output "Added $($result.Id). $($result.State.round.remainingResponses) agent responses remain."
        }
    }
    'continue' {
        $parsedCount = 0
        if (-not $Arguments -or -not [int]::TryParse($Arguments[0], [ref]$parsedCount)) {
            throw 'Usage: demi continue <number> [-Each]'
        }
        $count = $parsedCount
        if ($count -lt 1 -or $count -gt 50) { throw 'Continuation count must be between 1 and 50.' }
        if ($Each) { $count *= 2 }
        Invoke-WithLock $lockPath {
            $state = Read-JsonFile $statePath
            Clear-DemiReviewPause $state
            if (-not $state.round.id) { throw 'There is no current round to continue.' }
            $previousSequenceCount = 0
            if ($state.round.target -eq 'Both' -and $state.round.PSObject.Properties['sequence']) {
                $extendedSequence = @($state.round.sequence)
                $previousSequenceCount = $extendedSequence.Count
                $lastScheduledAgent = if ($extendedSequence.Count) { "$($extendedSequence[-1])" } else { 'Gem' }
                for ($index = 0; $index -lt $count; $index++) {
                    $lastScheduledAgent = Get-DemiNextGroupAgent $lastScheduledAgent
                    $extendedSequence += $lastScheduledAgent
                }
                $state.round.sequence = $extendedSequence
            }
            $state.round.remainingResponses = [int]$state.round.remainingResponses + $count
            $state.round.status = 'open'
            if (-not $state.round.nextSpeaker -or $state.round.nextSpeaker -eq 'Milo') {
                if ($state.round.target -eq 'Both' -and $state.round.PSObject.Properties['sequence']) {
                    $nextIndex = $previousSequenceCount
                    $state.round.sequenceIndex = $nextIndex
                    $state.round.nextSpeaker = @($state.round.sequence)[$nextIndex]
                } else {
                    $state.round.nextSpeaker = if ($state.lastAuthor -eq 'Claude') { 'Rowan' } else { 'Claude' }
                }
            }
            $id = Add-SessionEntry $root $state 'Milo' 'CONTINUE' "Continue the current discussion for $count additional agent responses." @{
                Round = $state.round.id
                'Additional agent responses' = $count
            }
            Write-JsonAtomic $statePath $state
            Write-Output "Added $id. $($state.round.id) now permits $($state.round.remainingResponses) responses; next: $($state.round.nextSpeaker)."
        }
    }
    'stop' {
        Invoke-WithLock $lockPath {
            $state = Read-JsonFile $statePath
            $dispatcherLock = Join-Path $runtimeRoot 'dispatch\dispatcher.lock'
            if ($state.PSObject.Properties['directTurn'] -and $state.directTurn -and $state.directTurn.active) {
                if (Test-DemiLiveDispatcherLock $dispatcherLock) {
                    throw "The direct $($state.directTurn.agent) response is currently running. Wait for it to finish before closing the turn."
                }
                $direct = Copy-DemiValue $state.directTurn
                $state.directTurn = $null
                $id = Add-SessionEntry $root $state 'System' 'DIRECT TURN CLOSED' "Closed the unanswered direct $($direct.agent) turn after its dispatch failed. The original question remains in the transcript and may be asked again later." @{
                    Agent = $direct.agent
                    'Responding to' = $direct.openedBy
                    Reason = 'stopped after failed dispatch'
                }
                Write-JsonAtomic $statePath $state
                Write-Output "Added $id. Closed the unanswered direct $($direct.agent) turn; the normal round remains unchanged."
                return
            }
            $graceful = $state.round.status -eq 'open' -and (Test-DemiLiveDispatcherLock $dispatcherLock)
            if ($graceful) {
                if ($state.round.PSObject.Properties['stopAfterCurrent']) { $state.round.stopAfterCurrent = $true }
                else { $state.round | Add-Member -NotePropertyName stopAfterCurrent -NotePropertyValue $true }
                $body = 'Stop after the currently running agent response is written, then wait for Milo.'
            } else {
                $state.round.status = 'waiting_for_milo'
                $state.round.remainingResponses = 0
                $state.round.nextSpeaker = 'Milo'
                if ($state.round.PSObject.Properties['stopAfterCurrent']) { $state.round.stopAfterCurrent = $false }
                $body = 'Stop the current agent discussion and wait for Milo.'
            }
            $id = Add-SessionEntry $root $state 'Milo' 'STOP' $body @{
                Round = $state.round.id
                'After current response' = $graceful
            }
            Write-JsonAtomic $statePath $state
            Write-Output $(if ($graceful) { "Added $id. The current response will be written before discussion stops." } else { "Added $id. Discussion stopped." })
        }
    }
    'note' {
        $body = Get-TextArgument $Arguments 'Usage: demi note "text" [-NoAck]'
        Invoke-WithLock $lockPath {
            $result = Add-DemiNoteLocked $root $statePath $body (-not $NoAck)
            if ($result.Queued) {
                Write-Output "Added $($result.Id). Queued acknowledgments from Claude and Rowan."
            } else {
                Write-Output "Added $($result.Id). No acknowledgments requested."
            }
        }
    }
    'direct' {
        if (-not $Arguments -or $Arguments.Count -lt 2) { throw 'Usage: demi direct <agent-name-or-handle> "question"' }
        $registeredDirectAgent = Get-DemiAgent -Name $Arguments[0] -Root $root
        if(-not $registeredDirectAgent.DirectEnabled){throw "Direct addressing is disabled for $($registeredDirectAgent.Name)."}
        $agent = $registeredDirectAgent.Name
        $body = Get-TextArgument $Arguments[1..($Arguments.Count - 1)] 'Direct question text is required.'
        $direct = Invoke-WithLock $lockPath { Add-DemiDirectTurnLocked $root $statePath $agent $body }
        Write-Output "Added $($direct.Id). Direct $agent allowance is exactly one; normal round suspended unchanged."
        if (-not $NoDispatch) { [void](Invoke-OneDispatch) }
    }
    'review' {
        $body = Get-TextArgument $Arguments 'Usage: demi review "request"'
        Invoke-DemiBlindReview $body
    }
    'manuscript' {
        $action = if($Arguments -and $Arguments.Count){$Arguments[0].ToLowerInvariant()}else{'status'}
        $configPath = Join-Path $root 'config\review-manuscript.json'
        switch($action){
            'latest' {
                $latest=Get-DemiLatestManuscript $root
                Write-Output "Latest Book One manuscript: $($latest.RelativePath) (v$($latest.Version))"
            }
            'status' {
                $selected=Get-DemiReviewManuscript $root
                $mode=if(Test-Path -LiteralPath $configPath){'pinned'}else{'automatic highest-version'}
                Write-Output "Review manuscript: $($selected.RelativePath) ($mode)"
            }
            'set' {
                if(-not $Arguments -or $Arguments.Count-lt 2){throw 'Usage: demi manuscript set <project-relative-docx>'}
                $relative=($Arguments[1..($Arguments.Count-1)]-join ' ').Trim('"').Replace('/','\')
                if([System.IO.Path]::IsPathRooted($relative)-or$relative-match '(^|[\\/])\.\.([\\/]|$)|:'){throw 'Manuscript path must be safe and project-relative.'}
                $full=[System.IO.Path]::GetFullPath((Join-Path $root $relative))
                if(-not $full.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)-or-not(Test-Path -LiteralPath $full -PathType Leaf)-or[IO.Path]::GetExtension($full)-ne'.docx'){throw 'Pinned manuscript must be an existing project DOCX.'}
                Write-JsonAtomic $configPath ([pscustomobject]@{path=$relative;setAt=[DateTimeOffset]::Now.ToString('o')})
                Write-Output "Pinned review manuscript: $relative"
            }
            default {throw 'Usage: demi manuscript [status|latest|set <project-relative-docx>]'}
        }
    }
    'new-session' {
        Invoke-WithLock $lockPath {
            $state = Read-JsonFile $statePath
            $dispatcherLock = Join-Path $runtimeRoot 'dispatch\dispatcher.lock'
            [void](Remove-DemiStaleDispatcherLock $dispatcherLock)
            if (Test-Path -LiteralPath $dispatcherLock) {
                throw 'Cannot open a new session while a Claude/Rowan dispatch or run is active. No work was cancelled.'
            }
            if ($state.PSObject.Properties['directTurn'] -and $state.directTurn -and $state.directTurn.active) {
                throw "Cannot open a new session while the direct $($state.directTurn.agent) turn is active. No work was cancelled."
            }
            $sourcePath = Get-SessionPath $root $state
            if ($Arguments -and $Arguments.Count) {
                $sourceName = "$($Arguments[0])"
                if ($sourceName -notmatch '^session-(\d{3})$|^sessions[\\/]session-(\d{3})\.md$') { throw 'Continuation source must be a Demi session number or session-NNN.' }
                $number = [int]($Matches[1] + $Matches[2])
                $sourcePath = Join-Path $root ('sessions\session-{0:D3}.md' -f $number)
                if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Session $number does not exist." }
            }
            [void](Start-DemiSessionContinuation $root $state $sourcePath)
            Write-JsonAtomic $statePath $state
            Write-Output "Opened $($state.currentSession), continuing $([IO.Path]::GetFileName($sourcePath))."
        }
    }
    'session' {
        $verb = if ($Arguments -and $Arguments.Count) { "$($Arguments[0])".ToLowerInvariant() } else { 'list' }
        if ($verb -eq 'list') {
            Get-ChildItem -LiteralPath (Join-Path $root 'sessions') -Filter 'session-*.md' -File | Sort-Object Name | ForEach-Object {
                [pscustomobject]@{ session=$_.BaseName; bytes=$_.Length; percent=[Math]::Round(($_.Length/$MaxSessionBytes)*100,1); full=$_.Length-ge$MaxSessionBytes; active=$_.FullName-eq(Get-SessionPath $root (Read-JsonFile $statePath)) }
            } | ConvertTo-Json -Depth 3
            return
        }
        if ($verb -ne 'activate' -or $Arguments.Count -lt 2) { throw 'Usage: demi session [list|activate session-NNN]' }
        Invoke-WithLock $lockPath {
            $state = Read-JsonFile $statePath
            $name = "$($Arguments[1])"
            if ($name -notmatch '^session-(\d{3})$|^sessions[\\/]session-(\d{3})\.md$') { throw 'Session must be named session-NNN.' }
            $number = [int]($Matches[1] + $Matches[2])
            $path = Join-Path $root ('sessions\session-{0:D3}.md' -f $number)
            if (-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Session $number does not exist."}
            if ((Get-Item -LiteralPath $path).Length -ge $MaxSessionBytes){throw 'That session is full and can only be read. Use Continue in new session.'}
            $deactivatedPath = Get-SessionPath $root $state
            if (-not [string]::Equals($deactivatedPath,$path,[StringComparison]::OrdinalIgnoreCase)) {
                [void](Update-DemiSessionCardMetadata $root $deactivatedPath)
            }
            $entries=@(Get-DemiSessionEntries $path);$last=$entries|Select-Object -Last 1
            $state.sessionNumber=$number;$state.currentSession='sessions\session-{0:D3}.md'-f$number
            $state.entryCounter=if($last-and$last.Id-match '(\d{4})$'){[int]$Matches[1]}else{0}
            $sessionName = 'session-{0:D3}' -f $number
            $sessionFocus = Get-DemiSessionFocusMetadata $root $sessionName
            if ($state.PSObject.Properties['focus']) { $state.focus = $sessionFocus } else { $state | Add-Member -NotePropertyName focus -NotePropertyValue $sessionFocus }
            $state.roundCounter=0;$state.round=[pscustomobject]@{id=$null;status='waiting_for_milo';remainingResponses=0;nextSpeaker='Milo';target='Both';openedBy=$null;focus=$(if($sessionFocus){Copy-DemiValue $sessionFocus}else{$null})};$state.directTurn=$null
            if($last){$state.lastEntry=$last.Id;$state.lastAuthor=$last.Author;$state.lastUpdated=if($last.Timestamp){$last.Timestamp.ToString('o')}else{$state.lastUpdated}}
            Write-JsonAtomic $statePath $state
            Write-Output "Activated $($state.currentSession)."
        }
    }
    'usage' {
        if ($Arguments.Count -lt 2) { throw 'Usage: demi usage <claude|rowan> <percent-consumed>' }
        $agent = $Arguments[0].ToLowerInvariant()
        if ($agent -notin @('claude','rowan')) { throw 'Agent must be claude or rowan.' }
        $percent = 0
        if (-not [int]::TryParse($Arguments[1], [ref]$percent) -or $percent -lt 0 -or $percent -gt 100) {
            throw 'Percent consumed must be an integer from 0 through 100.'
        }
        Invoke-WithLock $lockPath {
            $state = Read-JsonFile $statePath
            $state.usage.$agent.percentConsumed = $percent
            $state.usage.$agent.reportedAt = [DateTimeOffset]::Now.ToString('o')
            $state.usage.$agent.source = 'manual'
            Write-JsonAtomic $statePath $state
            Write-Output "Recorded $agent usage as $percent% consumed."
        }
    }
    'watch' {
        & (Join-Path $PSScriptRoot 'watch-demi.ps1') -ProjectRoot $root
    }
    'web' {
        $webAction = if ($Arguments -and $Arguments.Count -gt 0 -and $Arguments[0]) { $Arguments[0].ToLowerInvariant() } else { 'start' }
        if ($webAction -notin @('start','status','stop','lan','local','firewall','pair','devices','revoke')) {
            throw 'Usage: demi web [lan|local|status|stop|firewall|pair|devices|revoke <device-id>]'
        }
        $second = if ($Arguments -and $Arguments.Count -gt 1) { $Arguments[1] } else { $null }
        $device = if ($webAction -eq 'revoke') { $second } else { $null }
        $port = 0
        if ($second -and $webAction -ne 'revoke' -and (-not [int]::TryParse($second,[ref]$port) -or $port -lt 1 -or $port -gt 65535)) {
            throw 'Port must be an integer from 1 through 65535.'
        }
        & (Join-Path $PSScriptRoot 'demi-web.ps1') -Action $webAction -Device $device -Port $port -ProjectRoot $root
    }
    'dispatch' {
        [void](Invoke-OneDispatch -AsDryRun:$DryRun)
    }
    'run' {
        $initialState = Read-JsonFile $statePath
        $available = Get-DemiDispatchWorkCount $initialState
        if ($available -le 0) { throw 'Run requires an open round or pending acknowledgment.' }
        $limit = [Math]::Min([Math]::Min($available, $MaxResponses), 12)
        if ($DryRun) {
            Write-Output "DRY RUN: at most $limit sequential dispatches (available work: $available; safety ceiling: 12)."
            [void](Invoke-OneDispatch -AsDryRun)
            return
        }
        $completed = 0
        while ($completed -lt $limit) {
            $current = Read-JsonFile $statePath
            if ((Get-DemiDispatchWorkCount $current) -le 0) { break }
            try {
                [void](Invoke-OneDispatch)
                $completed++
            } catch {
                Write-Error $_
                break
            }
        }
        $finalState = Read-JsonFile $statePath
        Write-Output "Run completed $completed response(s). Round $($finalState.round.id) is $($finalState.round.status); $($finalState.round.remainingResponses) responses remain."
    }
    'draft' {
        $draftOptions = Resolve-DemiDraftArguments $Arguments $File $Format ([bool]$ResponsesOnly)
        if ([string]::IsNullOrWhiteSpace($draftOptions.Request)) { throw 'Usage: demi draft [--file path] [--format md|txt|docx] [--responses-only] "request"' }
        Invoke-DemiDraft $draftOptions.Request $draftOptions.Destination $draftOptions.Format 'Sonnet' -OnlyResponse:$draftOptions.ResponsesOnly
    }
    'fable' {
        $draftOptions = Resolve-DemiDraftArguments $Arguments $File $Format ([bool]$ResponsesOnly)
        if ([string]::IsNullOrWhiteSpace($draftOptions.Request)) { throw 'Usage: demi fable [--file path] [--format md|txt|docx] [--responses-only] "request"' }
        Invoke-DemiDraft $draftOptions.Request $draftOptions.Destination $draftOptions.Format 'Fable' -OnlyResponse:$draftOptions.ResponsesOnly
    }
    'draft-save' {
        if (-not $Arguments -or $Arguments.Count -lt 2) { throw 'Usage: demi draft-save <token> <project-relative-new-file>' }
        $creation = Save-DemiPendingDraft $Arguments[0] $Arguments[1]
        if ($Json) { $creation | ConvertTo-Json -Depth 5 }
        else { Write-Output "Created $($creation.destination) ($($creation.fileSize) bytes; SHA-256 $($creation.sha256)). Proposed - not canon. No existing file was overwritten." }
    }
    'entry-save' {
        if (-not $Arguments -or $Arguments.Count -lt 1) { throw 'Usage: demi entry-save <session-entry-id>' }
        $savedEntry = Save-DemiSessionEntry $Arguments[0]
        if ($Json) { $savedEntry | ConvertTo-Json -Compress }
        elseif ($savedEntry.existing) { Write-Output "Already saved at $($savedEntry.path)." }
        else { Write-Output "Saved $($savedEntry.path)." }
    }
    'chat' {
        $auto = $false
        $preferencePath = Join-Path $root 'state\chat-preferences.json'
        Assert-DemiWritePath $preferencePath 'chat preferences' | Out-Null
        $preferences = Get-DemiChatPreferences $preferencePath
        Save-DemiChatPreferences $preferencePath $preferences
        $chatState = Read-JsonFile $statePath
        $chatSessionPath = Get-SessionPath $root $chatState
        $lastDisplayedId = "$($chatState.lastEntry)"
        $previousInputEncoding = [Console]::InputEncoding
        $previousConsoleEncoding = [Console]::OutputEncoding
        $previousOutputEncoding = $OutputEncoding
        [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        try {
            Write-DemiChatText 'Demi chat. Type /help for commands.' $preferences 'DarkGray'
            Show-DemiChatStatus $chatState $auto $preferences -Force
            while ($true) {
                try {
                    $line = Read-DemiChatLine $chatSessionPath ([ref]$lastDisplayedId) $preferences $auto
                } catch [System.OperationCanceledException] {
                    Write-DemiChatText 'Input cancelled.' $preferences 'Yellow'
                    continue
                }
                if ($null -eq $line) { break }
                $trimmed = $line.Trim()
                switch -Regex ($trimmed) {
                    '^/quit$' { return }
                    '^/help$' {
                        $builtIn='/help | /draft request | /fable request | /note [-noack] text | /auto on|off | /dispatch | /run | /continue N | /view compact|full|raw | /color on|off | /bodycolor white|gray|default | /markdown on|off | /statusline on|off | /font small|medium|large | /status | /stop | /quit'
                        $agentHelp=@(Get-DemiAgentRegistry -Root $root|Where-Object DirectEnabled|ForEach-Object{"/$($_.Handle) question - $($_.Icon) $($_.Name)$(if($_.Aliases.Count){' (aliases: '+(($_.Aliases|ForEach-Object{'/'+$_})-join', ')+')'}else{''})"})
                        Write-DemiChatText ($builtIn+$(if($agentHelp.Count){"`nConfigured agents:`n"+($agentHelp-join"`n")}else{"`nNo directly addressable agents are configured."})) $preferences 'DarkGray'
                        continue
                    }
                    '^/([a-z][a-z0-9_-]{0,31})\s+(.+)$' {
                        try {
                            $directAgent = Resolve-DemiAgentDirectAddress -Token $Matches[1] -Root $root
                            if(-not $directAgent){throw "Unknown or unavailable direct agent '/$($Matches[1])'."}
                            $agent = $directAgent.Name
                            $beforeDirect = (Read-JsonFile $statePath).lastEntry
                            $null = & $PSCommandPath direct $agent $Matches[2]
                            $directState = Read-JsonFile $statePath
                            $lastDisplayedId = Show-DemiChatExternalUpdates (Get-SessionPath $root $directState) "$beforeDirect" $preferences $auto
                        } catch {
                            Write-DemiChatText $_.Exception.Message $preferences 'Red'
                        }
                        continue
                    }
                    '^/retry$' {
                        Write-DemiChatText 'No retryable failed terminal action exists. /retry is available in Demi web for failed web actions.' $preferences 'Yellow'
                        continue
                    }
                    '^/(draft|fable)\s+(.+)$' {
                        try {
                            $draftCommand = $Matches[1].ToLowerInvariant()
                            $draftLine = $Matches[2]
                            $draftFile = $null
                            $draftFormat = 'md'
                            $draftResponsesOnly = $false
                            if ($draftLine -match '(?i)(?:^|\s)--file\s+("[^"]+"|\S+)') {
                                $draftFile = $Matches[1].Trim('"')
                                $draftLine = ($draftLine -replace '(?i)(?:^|\s)--file\s+("[^"]+"|\S+)',' ').Trim()
                            }
                            if ($draftLine -match '(?i)(?:^|\s)--format\s+(md|txt|docx)') {
                                $draftFormat = $Matches[1].ToLowerInvariant()
                                $draftLine = ($draftLine -replace '(?i)(?:^|\s)--format\s+(?:md|txt|docx)',' ').Trim()
                            }
                            if ($draftLine -match '(?i)(?:^|\s)--responses-only(?:\s|$)') {
                                $draftResponsesOnly = $true
                                $draftLine = ($draftLine -replace '(?i)(?:^|\s)--responses-only(?:\s|$)',' ').Trim()
                            }
                            $invokeArguments = @($draftCommand,$draftLine,'-Format',$draftFormat,'-Json')
                            if ($draftFile) { $invokeArguments += @('-File',$draftFile) }
                            if ($draftResponsesOnly) { $invokeArguments += '-ResponsesOnly' }
                            $null = & $PSCommandPath @invokeArguments
                            $draftState = Read-JsonFile $statePath
                            $draftEntry = Get-DemiSessionEntries (Get-SessionPath $root $draftState) | Where-Object Id -eq $draftState.lastEntry | Select-Object -First 1
                            if ($draftEntry) { Show-DemiChatEntry $draftEntry $preferences }
                            $lastDisplayedId = "$($draftState.lastEntry)"
                        } catch {
                            Write-DemiChatText $_.Exception.Message $preferences 'Red'
                        }
                        continue
                    }
                    '^/note(?:\s+(-noack))?(?:\s+(.+))?$' {
                        $withoutAcknowledgement = $Matches[1] -eq '-noack'
                        $noteText = $Matches[2]
                        if ([string]::IsNullOrWhiteSpace($noteText)) {
                            Write-DemiChatText 'Usage: /note [-noack] <text>' $preferences 'Yellow'
                            continue
                        }
                        try {
                            $noteResult = Invoke-WithLock $lockPath {
                                Add-DemiNoteLocked $root $statePath $noteText (-not $withoutAcknowledgement)
                            }
                            $entry = Get-DemiSessionEntries (Get-SessionPath $root $noteResult.State) |
                                Where-Object Id -eq $noteResult.Id | Select-Object -First 1
                            if ($entry) { Show-DemiChatEntry $entry $preferences }
                            $lastDisplayedId = "$($noteResult.Id)"
                            Show-DemiChatStatus $noteResult.State $auto $preferences
                            if ($auto -and $noteResult.Queued) {
                                [void](Invoke-DemiChatAcknowledgements $auto $preferences)
                                $lastDisplayedId = "$((Read-JsonFile $statePath).lastEntry)"
                            }
                        } catch {
                            $auto = $false
                            Write-DemiChatText $_.Exception.Message $preferences 'Red'
                            Show-DemiChatStatus (Read-JsonFile $statePath) $auto $preferences -Force
                        }
                        continue
                    }
                    '^/view(?:\s+(compact|full|raw))?$' {
                        if ($Matches[1]) {
                            $preferences.view = $Matches[1]
                            Save-DemiChatPreferences $preferencePath $preferences
                        }
                        Write-DemiChatText "View: $($preferences.view)" $preferences 'DarkGray'
                        continue
                    }
                    '^/color(?:\s+(on|off))?$' {
                        if ($Matches[1]) {
                            $preferences.color = $Matches[1] -eq 'on'
                            Save-DemiChatPreferences $preferencePath $preferences
                        }
                        Write-DemiChatText "Color: $(if ($preferences.color) { 'ON' } else { 'OFF' })" $preferences 'DarkGray'
                        continue
                    }
                    '^/bodycolor(?:\s+(white|gray|default))?$' {
                        if ($Matches[1]) {
                            $preferences.bodyColor = $Matches[1]
                            Save-DemiChatPreferences $preferencePath $preferences
                        }
                        Write-DemiChatText "Body color: $($preferences.bodyColor)" $preferences 'DarkGray'
                        continue
                    }
                    '^/font(?:\s+(small|medium|large))?$' {
                        if (-not $Matches[1]) {
                            Write-DemiChatText 'Usage: /font small|medium|large' $preferences 'Yellow'
                        } else {
                            Write-DemiChatText 'Font size is controlled by Windows Terminal settings; no change was made.' $preferences 'Yellow'
                        }
                        continue
                    }
                    '^/markdown(?:\s+(on|off))?$' {
                        if ($Matches[1]) {
                            $preferences.markdown = $Matches[1] -eq 'on'
                            Save-DemiChatPreferences $preferencePath $preferences
                        }
                        $fallback = if ($preferences.markdown -and -not (Test-DemiTerminalStyling)) {
                            ' (literal fallback: terminal styling unsupported)'
                        } else { '' }
                        Write-DemiChatText "Markdown: $(if ($preferences.markdown) { 'ON' } else { 'OFF' })$fallback" $preferences 'DarkGray'
                        continue
                    }
                    '^/statusline(?:\s+(on|off))?$' {
                        if ($Matches[1]) {
                            $preferences.statusline = $Matches[1] -eq 'on'
                            Save-DemiChatPreferences $preferencePath $preferences
                        }
                        Write-DemiChatText "Status line: $(if ($preferences.statusline) { 'ON' } else { 'OFF' })" $preferences 'DarkGray'
                        continue
                    }
                    '^/auto\s+on$' {
                        $auto = $true
                        Write-DemiChatText 'Automatic dispatch is ON.' $preferences 'DarkGray'
                        Show-DemiChatStatus (Read-JsonFile $statePath) $auto $preferences -Force
                        continue
                    }
                    '^/auto\s+off$' {
                        $auto = $false
                        Write-DemiChatText 'Automatic dispatch is OFF.' $preferences 'DarkGray'
                        Show-DemiChatStatus (Read-JsonFile $statePath) $auto $preferences -Force
                        continue
                    }
                    '^/auto$' {
                        Write-DemiChatText "Automatic dispatch is $(if ($auto) { 'ON' } else { 'OFF' })." $preferences 'DarkGray'
                        Show-DemiChatStatus (Read-JsonFile $statePath) $auto $preferences -Force
                        continue
                    }
                    '^/dispatch$' {
                        try {
                            $dispatchResult = Invoke-DemiChatDispatch $auto $preferences
                            $lastDisplayedId = $dispatchResult.Id
                        } catch {
                            $auto = $false
                            Write-DemiChatText $_.Exception.Message $preferences 'Red'
                            Show-DemiChatStatus (Read-JsonFile $statePath) $auto $preferences -Force
                        }
                        continue
                    }
                    '^/review\s+(.+)$' {
                        try { Invoke-DemiBlindReview $Matches[1] | ForEach-Object { Write-DemiChatText $_ $preferences 'White' }; $lastDisplayedId="$((Read-JsonFile $statePath).lastEntry)" } catch { Write-DemiChatText $_.Exception.Message $preferences 'Red' }
                        continue
                    }
                    '^/run$' {
                        try {
                            [void](Invoke-DemiChatRun $auto $preferences)
                            $lastDisplayedId = "$((Read-JsonFile $statePath).lastEntry)"
                        } catch {
                            $auto = $false
                            Write-DemiChatText $_.Exception.Message $preferences 'Red'
                            Show-DemiChatStatus (Read-JsonFile $statePath) $auto $preferences -Force
                        }
                        continue
                    }
                    '^/continue\s+(\d+)$' {
                        $null = & $PSCommandPath continue $Matches[1]
                        $continued = Read-JsonFile $statePath
                        $entry = Get-DemiSessionEntries (Get-SessionPath $root $continued) | Where-Object Id -eq $continued.lastEntry | Select-Object -First 1
                        if ($entry) { Show-DemiChatEntry $entry $preferences }
                        $lastDisplayedId = "$($continued.lastEntry)"
                        Show-DemiChatStatus $continued $auto $preferences
                        continue
                    }
                    '^/status$' {
                        $chatState = Read-JsonFile $statePath
                        Show-Status -Root $root -RuntimeRoot $runtimeRoot -State $chatState | Write-Host
                        Show-DemiChatStatus $chatState $auto $preferences -Force
                        continue
                    }
                    '^/stop$' {
                        $auto = $false
                        $null = & $PSCommandPath stop
                        $stopped = Read-JsonFile $statePath
                        $entry = Get-DemiSessionEntries (Get-SessionPath $root $stopped) | Where-Object Id -eq $stopped.lastEntry | Select-Object -First 1
                        if ($entry) { Show-DemiChatEntry $entry $preferences }
                        $lastDisplayedId = "$($stopped.lastEntry)"
                        Show-DemiChatStatus $stopped $auto $preferences
                        continue
                    }
                    '^/' {
                        Write-DemiChatText "Unknown chat command: $line" $preferences 'Yellow'
                        continue
                    }
                    default {
                        try {
                            $null = & $PSCommandPath say $line
                            $committed = Read-JsonFile $statePath
                            $entry = Get-DemiSessionEntries (Get-SessionPath $root $committed) | Where-Object Id -eq $committed.lastEntry | Select-Object -First 1
                            if ($entry) { Show-DemiChatEntry $entry $preferences }
                            $lastDisplayedId = "$($committed.lastEntry)"
                            Show-DemiChatStatus $committed $auto $preferences
                            if ($auto) {
                                [void](Invoke-DemiChatRun $auto $preferences)
                                $lastDisplayedId = "$((Read-JsonFile $statePath).lastEntry)"
                            }
                        } catch {
                            $auto = $false
                            Write-DemiChatText $_.Exception.Message $preferences 'Red'
                            Show-DemiChatStatus (Read-JsonFile $statePath) $auto $preferences -Force
                        }
                    }
                }
            }
        } finally {
            [Console]::InputEncoding = $previousInputEncoding
            [Console]::OutputEncoding = $previousConsoleEncoding
            $OutputEncoding = $previousOutputEncoding
        }
    }
    'validate' {
        $state = Read-JsonFile $statePath
        $sessionPath = Get-SessionPath $root $state
        $ids = @(
            Select-String -LiteralPath $sessionPath -Pattern '^## (S\d{3}-[A-Z]\d{4}) - ' |
                ForEach-Object { $_.Matches[0].Groups[1].Value }
        )
        $duplicates = $ids | Group-Object | Where-Object Count -gt 1
        if ($duplicates) { throw "Duplicate entry IDs: $($duplicates.Name -join ', ')" }
        if ($ids.Count -and $ids[-1] -ne $state.lastEntry) {
            throw "State says last entry is $($state.lastEntry), but session ends with $($ids[-1])."
        }
        Write-Output "Session valid: $($ids.Count) entries, no duplicate IDs."
    }
    'status' {
        $state = Read-JsonFile $statePath
        Show-Status -Root $root -RuntimeRoot $runtimeRoot -State $state -AsJson:$Json
    }
    'database' {
        $databaseCommand = if($Arguments.Count){$Arguments[0]}else{'status'}
        if($databaseCommand -notin @('provision','migrate','status','import','timeline-import','timeline-status','timeline-export','backup')){throw 'Usage: demi database [status|provision|migrate|import|timeline-import|timeline-status|backup]'}
        & (Join-Path $PSScriptRoot 'demi-db.ps1') $databaseCommand
    }
    'storage' {
        $storageCommand = if($null -ne $Arguments -and $Arguments.Length -gt 0){$Arguments[0]}else{'status'}
        if($storageCommand -ne 'status'){throw 'Usage: demi storage status'}
        $storageStatus = Get-DemiStorageStatus -Root $root
        if($Json){$storageStatus | ConvertTo-Json -Depth 5}else{$storageStatus | Format-List}
    }
    'timeline' {
        if($null-eq$Arguments-or$Arguments.Count-lt2-or$Arguments.Count-gt3){throw 'Usage: demi timeline <date> <title> [summary]'}
        & (Join-Path $PSScriptRoot 'demi-timeline-entry.ps1') -Date $Arguments[0] -Title $Arguments[1] -Summary $(if($Arguments.Count-gt2){$Arguments[2]}else{''})
    }
    'timeline-save' {
        if($null-eq$Arguments-or$Arguments.Count-ne1){throw 'Timeline event data is required.'}
        & (Join-Path $PSScriptRoot 'demi-timeline-entry.ps1') -PayloadBase64 $Arguments[0]
    }
    'timeline-delete' {
        if($null-eq$Arguments-or$Arguments.Count-ne1){throw 'Timeline event ID is required.'}
        & (Join-Path $PSScriptRoot 'demi-timeline-entry.ps1') -DeleteExternalId $Arguments[0]
    }
    'agent' {
        $agentCommand=if($null-ne$Arguments-and$Arguments.Length){$Arguments[0].ToLowerInvariant()}else{'list'}
        switch($agentCommand){
            'list'{Get-DemiAgentRegistry -Root $root -IncludeDisabled|Select-Object Name,Handle,Kind,Model,Icon,Color,DirectEnabled,ParticipationMode,Enabled|Format-Table -AutoSize}
            'add'{if($Arguments.Count-lt4){throw 'Usage: demi agent add <handle> <display-name> <Claude|Codex|Antigravity|Ollama> [model] [icon] [#color]'};$added=Add-DemiConfiguredAgent -Root $root -Handle $Arguments[1] -Name $Arguments[2] -Kind $Arguments[3] -Model $(if($Arguments.Count-gt4){$Arguments[4]}else{''}) -Icon $(if($Arguments.Count-gt5){$Arguments[5]}else{'●'}) -Color $(if($Arguments.Count-gt6){$Arguments[6]}else{'#8fa3b8'});Write-Output "Added $($added.Name). Direct command: /$($added.Handle)"}
            'disable'{if($Arguments.Count-ne2){throw 'Usage: demi agent disable <name-or-handle>'};$disabled=Disable-DemiConfiguredAgent -Root $root -Token $Arguments[1];Write-Output "Disabled $($disabled.Name)."}
            default{throw 'Usage: demi agent [list|add|disable]'}
        }
    }
    'inventory' {
        & (Join-Path $PSScriptRoot 'demi-inventory.ps1') -ProjectRoot $root -Json:$Json
    }
    'help' {
@'
DEMI - Demiurge collaboration console

  demi say "message" [-To Claude|Rowan|Both]  Open a configured proposal/review/synthesis round
  demi alice "message"                        Add an Alice-authored contribution and open the normal round
  demi checkin Claude                         Privately verify that one agent is responding
  demi respond Claude "text"                    Append an authorized agent response
  demi respond Rowan "text"
  demi continue 4 [-Each]                       Allow more agent responses
  demi stop                                     Stop and wait for Milo
  demi note "text" [-NoAck]                     Append a note; acknowledgments default on
  demi direct Rowan "question"                  Ask exactly one named-agent response
  demi review "request"                        Run blind concurrent Claude, Rowan, and Gem reviews
  demi manuscript latest                       Show the highest-version Book One DOCX
  demi manuscript set <project-relative-docx>  Pin a different authoritative review manuscript
  demi status [-Json]                           Show session, round, context, usage
  demi usage claude 62                          Record percent of plan usage consumed
  demi usage rowan 41
  demi new-session                              Archive and open the next session
  demi dispatch [-DryRun]                       Run exactly one authorized agent response
  demi run [-DryRun] [-MaxResponses N]          Run sequentially (authorized allowance, max 12)
  demi draft "request" [-File new-path]          Generate proposed reference/backend material with Claude Sonnet
             [-Format md|txt|docx] [-ResponsesOnly]
  demi fable "request" [-File new-path]          Generate proposed scenes or prose with Claude Fable
             [-Format md|txt|docx] [-ResponsesOnly]
  demi chat                                     Interactive terminal chat (auto defaults OFF)
  demi web [lan|local|status|stop|firewall]     Control local or protected home-network web access
  demi web pair                                Pair a phone with one short-lived code
  demi web devices                             List paired phones and browsers
  demi web revoke <device-id>                  Revoke one paired device
  demi database status                         Check the isolated PostgreSQL foundation
  demi database backup                         Create a local PostgreSQL backup
  demi storage status                          Show the configured and active storage backend
  demi database import                        Index reviewed current project memory in PostgreSQL
  demi database timeline-import               Import the latest master chronology workbook
  demi database timeline-status               Show timeline, communication, and conflict counts
  demi timeline <date> <title> [summary]       Add a suggested event to the active timeline store
  demi agent list                              List configured agents
  demi agent add <handle> <name> <kind> [...] Add a directly addressable agent
  demi inventory [-Json]                       Build a read-only source classification report
    /auto on | /auto off | /auto                Set or report local automatic mode
    /help                                        Show built-in and configured-agent commands
    /review request                              Blind concurrent configured-agent review
    /timeline date | title | summary             Add a suggested event to the timeline
    /draft [options] request                     Preview or create proposed Sonnet reference material
    /fable [options] request                     Preview or create proposed Fable prose
    /note [-noack] text                          Note; queue Claude and Rowan unless disabled
    /<agent-handle> text                         One configured-agent response; preserve any open round
    /dispatch                                    Poke the authorized next speaker for one response
    /retry                                       Retry the latest failed web dispatch
    /run                                         Run the bounded authorized allowance
    /view compact|full|raw                       Select transcript display detail
    /color on|off | /markdown on|off             Configure color and lightweight Markdown
    /bodycolor white|gray|default                Select neutral response-body color
    /font small|medium|large                     Explain terminal-managed font sizing
    /statusline on|off                           Configure the compact status line
    /continue N | /status | /stop | /quit       Control the active discussion
  demi watch                                    Run the delivery watcher
  demi validate                                 Check session IDs and state
'@
    }
}
