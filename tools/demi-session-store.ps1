[CmdletBinding()]
param([ValidateSet('library','append-file','sync-session')][string]$StoreCommand='library',[string]$Root,[string]$PayloadFile,[string]$SessionFile)
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'demi-db-auth.ps1')

function Get-DemiSessionDatabaseContext {
    param([Parameter(Mandatory)][string]$Root)
    $database = Get-Content -Raw -LiteralPath (Join-Path $Root 'config\database.json') -Encoding UTF8 | ConvertFrom-Json
    $storage = Get-Content -Raw -LiteralPath (Join-Path $Root 'config\storage.json') -Encoding UTF8 | ConvertFrom-Json
    if ("$($storage.backend)" -ne 'postgresql') { return $null }
    $psqlCommand = Get-Command psql.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    $bin = if ($psqlCommand) { Split-Path -Parent $psqlCommand.Source } else { Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin' -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName -First 1 }
    if (-not $bin) { throw 'PostgreSQL command-line tools were not found.' }
    [pscustomobject]@{ Database=$database;Storage=$storage;Psql=(Join-Path $bin 'psql.exe');Password=(Get-DemiDatabasePassword) }
}

function ConvertTo-DemiBase64Json {
    param([Parameter(Mandatory)][object]$Value)
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 30 -Compress)))
}

function Invoke-DemiSessionDatabaseSql {
    param([Parameter(Mandatory)][object]$Context,[Parameter(Mandatory)][string]$Sql)
    $old = $env:PGPASSWORD
    $sqlFile = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($sqlFile,$Sql,[Text.UTF8Encoding]::new($false))
        $env:PGPASSWORD = $Context.Password
        $database = $Context.Database
        $psql = "$($Context.Psql)"
        $output = & $psql -X -v ON_ERROR_STOP=1 -h "$($database.host)" -p "$($database.port)" -U "$($database.applicationUser)" -d "$($database.database)" -f $sqlFile 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($output -join [Environment]::NewLine) }
        return $output
    } finally {
        if(Test-Path -LiteralPath $sqlFile){Remove-Item -LiteralPath $sqlFile -Force}
        if ($null -ne $old) { $env:PGPASSWORD = $old } else { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
    }
}

function Write-DemiDatabaseSessionEntry {
    param(
        [Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$EntryId,[Parameter(Mandatory)][int64]$Sequence,
        [Parameter(Mandatory)][string]$Author,[Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Body,[Parameter(Mandatory)][object]$Metadata,
        [Parameter(Mandatory)][string]$Timestamp
    )
    $context = Get-DemiSessionDatabaseContext -Root $Root
    if (-not $context) { return $false }
    $payload = ConvertTo-DemiBase64Json ([ordered]@{projectSlug="$($context.Storage.projectSlug)";session=$SessionName;entryId=$EntryId;sequence=$Sequence;author=$Author;entryType=$Type;body=$Body;metadata=$Metadata;createdAt=$Timestamp})
    $schema = "$($context.Database.schema)"
    $sql = @"
BEGIN;
CREATE TEMP TABLE demi_live_entry(data jsonb) ON COMMIT DROP;
INSERT INTO demi_live_entry VALUES(convert_from(decode('$payload','base64'),'UTF8')::jsonb);
UPDATE $schema.sessions SET status='inactive',updated_at=now() WHERE project_id=(SELECT id FROM $schema.projects WHERE slug=(SELECT data->>'projectSlug' FROM demi_live_entry)) AND status='active' AND legacy_name<>(SELECT data->>'session' FROM demi_live_entry);
INSERT INTO $schema.sessions(project_id,legacy_name,status,updated_at)
SELECT p.id,d.data->>'session','active',now() FROM $schema.projects p,demi_live_entry d WHERE p.slug=d.data->>'projectSlug'
ON CONFLICT(legacy_name) DO UPDATE SET status='active',updated_at=now();
INSERT INTO $schema.messages(session_id,legacy_entry_id,sequence_number,author,entry_type,body,metadata,created_at,source_path)
SELECT s.id,d.data->>'entryId',(d.data->>'sequence')::bigint,d.data->>'author',d.data->>'entryType',d.data->>'body',d.data->'metadata',(d.data->>'createdAt')::timestamptz,'sessions/'||(d.data->>'session')||'.md'
FROM demi_live_entry d JOIN $schema.sessions s ON s.legacy_name=d.data->>'session'
ON CONFLICT(legacy_entry_id) DO NOTHING;
INSERT INTO $schema.project_runtime_state(project_id,active_session_id,state,revision)
SELECT p.id,s.id,jsonb_build_object('currentSession','sessions/'||s.legacy_name||'.md'),1 FROM $schema.projects p JOIN $schema.sessions s ON s.project_id=p.id,demi_live_entry d WHERE p.slug=d.data->>'projectSlug' AND s.legacy_name=d.data->>'session'
ON CONFLICT(project_id) DO UPDATE SET active_session_id=excluded.active_session_id,state=$schema.project_runtime_state.state||excluded.state,revision=$schema.project_runtime_state.revision+1,updated_at=now();
COMMIT;
"@
    [void](Invoke-DemiSessionDatabaseSql -Context $context -Sql $sql)
    return $true
}

function Sync-DemiDatabaseSessionFile {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Path)
    $context=Get-DemiSessionDatabaseContext -Root $Root
    if(-not$context){throw 'PostgreSQL must be selected before syncing a live session.'}
    $session=[IO.Path]::GetFileNameWithoutExtension($Path);$records=[Collections.Generic.List[object]]::new();$text=Get-Content -Raw -LiteralPath $Path -Encoding UTF8
    foreach($match in [regex]::Matches($text,'(?ms)^## (S\d{3}-[A-Z]\d{4}) - ([^\r\n]+)\r?\n(.*?)(?=^## S\d{3}-[A-Z]\d{4} - |\z)')){
        $block=$match.Groups[3].Value;$split=[regex]::Match($block,'\r?\n\r?\n');$header=if($split.Success){$block.Substring(0,$split.Index)}else{$block};$body=if($split.Success){$block.Substring($split.Index+$split.Length).Trim()}else{''};$metadata=[ordered]@{}
        foreach($line in $header -split'\r?\n'){if($line-match'^([^:]+):\s*(.*)$'){$metadata[$Matches[1].Trim()]=$Matches[2].Trim()}}
        $sequence=if($match.Groups[1].Value-match'(\d{4})$'){[int64]$Matches[1]}else{0}
        $records.Add([ordered]@{entryId=$match.Groups[1].Value;sequence=$sequence;author=$match.Groups[2].Value.Trim();entryType="$($metadata.Type)";body=$body;metadata=$metadata;createdAt="$($metadata.Timestamp)"})
    }
    $payload=ConvertTo-DemiBase64Json ([ordered]@{projectSlug="$($context.Storage.projectSlug)";session=$session;messages=$records})
    $schema="$($context.Database.schema)";$sql=@"
BEGIN;
CREATE TEMP TABLE demi_live_session(data jsonb) ON COMMIT DROP;
INSERT INTO demi_live_session VALUES(convert_from(decode('$payload','base64'),'UTF8')::jsonb);
UPDATE $schema.sessions SET status='inactive',updated_at=now() WHERE project_id=(SELECT id FROM $schema.projects WHERE slug=(SELECT data->>'projectSlug' FROM demi_live_session)) AND status='active' AND legacy_name<>(SELECT data->>'session' FROM demi_live_session);
INSERT INTO $schema.sessions(project_id,legacy_name,status,updated_at) SELECT p.id,d.data->>'session','active',now() FROM $schema.projects p,demi_live_session d WHERE p.slug=d.data->>'projectSlug' ON CONFLICT(legacy_name)DO UPDATE SET status='active',updated_at=now();
INSERT INTO $schema.messages(session_id,legacy_entry_id,sequence_number,author,entry_type,body,metadata,created_at,source_path)
SELECT s.id,x."entryId",x.sequence,x.author,x."entryType",x.body,x.metadata,x."createdAt",'sessions/'||(d.data->>'session')||'.md' FROM demi_live_session d CROSS JOIN LATERAL jsonb_to_recordset(d.data->'messages')x("entryId" text,sequence bigint,author text,"entryType" text,body text,metadata jsonb,"createdAt" timestamptz) JOIN $schema.sessions s ON s.legacy_name=d.data->>'session'
ON CONFLICT(legacy_entry_id)DO UPDATE SET body=excluded.body,metadata=excluded.metadata,entry_type=excluded.entry_type;
INSERT INTO $schema.project_runtime_state(project_id,active_session_id,state,revision) SELECT p.id,s.id,jsonb_build_object('currentSession','sessions/'||s.legacy_name||'.md'),1 FROM $schema.projects p JOIN $schema.sessions s ON s.project_id=p.id,demi_live_session d WHERE p.slug=d.data->>'projectSlug' AND s.legacy_name=d.data->>'session' ON CONFLICT(project_id)DO UPDATE SET active_session_id=excluded.active_session_id,state=$schema.project_runtime_state.state||excluded.state,revision=$schema.project_runtime_state.revision+1,updated_at=now();
COMMIT;
"@
    [void](Invoke-DemiSessionDatabaseSql -Context $context -Sql $sql)
    return $records.Count
}

if ($StoreCommand -eq 'append-file') {
    if (-not $Root -or -not $PayloadFile) { throw 'append-file requires -Root and -PayloadFile.' }
    $payload = Get-Content -Raw -LiteralPath $PayloadFile -Encoding UTF8 | ConvertFrom-Json
    [void](Write-DemiDatabaseSessionEntry -Root $Root -SessionName $payload.session -EntryId $payload.entryId -Sequence ([int64]$payload.sequence) -Author $payload.author -Type $payload.entryType -Body $payload.body -Metadata $payload.metadata -Timestamp $payload.createdAt)
}
if($StoreCommand-eq'sync-session'){
    if(-not$Root-or-not$SessionFile){throw 'sync-session requires -Root and -SessionFile.'}
    Sync-DemiDatabaseSessionFile -Root $Root -Path $SessionFile
}
