Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'demi-db-auth.ps1')

function Get-DemiAgentMemoryConfiguration {
    param([Parameter(Mandatory)][string]$Root)
    $path = Join-Path $Root 'config\agent-memory.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            schemaVersion = 1
            enabled = $false
            provider = 'postgresql'
            fallback = 'files'
            readCapabilities = @('session-summaries','claims','documents','entities','timeline')
            writeCapabilities = @()
            agents = @()
            maximumItemsPerKind = 4
            maximumContextCharacters = 5000
        }
    }
    $configuration = Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($configuration.provider -ne 'postgresql') { throw "Unsupported agent-memory provider '$($configuration.provider)'." }
    if ($configuration.fallback -notin @('none','files')) { throw "Unsupported agent-memory fallback '$($configuration.fallback)'." }
    return $configuration
}

function Test-DemiAgentMemoryEnabled {
    param([Parameter(Mandatory)][object]$Configuration,[Parameter(Mandatory)][object]$Agent)
    if (-not [bool]$Configuration.enabled) { return $false }
    $allowed = @($Configuration.agents | ForEach-Object { "$($_)".ToLowerInvariant() })
    if ($allowed.Count -eq 0) { return $false }
    $names = @("$($Agent.Handle)".ToLowerInvariant(),"$($Agent.Name)".ToLowerInvariant())
    if ($Agent.PSObject.Properties['Aliases']) { $names += @($Agent.Aliases | ForEach-Object { "$($_)".ToLowerInvariant() }) }
    return [bool](@($names | Where-Object { $_ -in $allowed }).Count)
}

function Get-DemiAgentMemoryPsql {
    $command = Get-Command psql.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    foreach ($candidate in @(Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) {
        return $candidate.FullName
    }
    throw 'PostgreSQL command-line tools were not found.'
}

function ConvertTo-DemiSqlUtf8Expression {
    param([AllowEmptyString()][string]$Text)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($(if($null -eq $Text){''}else{$Text})))
    return "convert_from(decode('$encoded','base64'),'UTF8')"
}

function Invoke-DemiAgentMemoryQuery {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Query,
        [string]$FocusSilo,
        [int]$MaximumItemsPerKind = 4
    )
    $databasePath = Join-Path $Root 'config\database.json'
    if (-not (Test-Path -LiteralPath $databasePath -PathType Leaf)) { throw 'Demi database configuration is absent.' }
    $database = Get-Content -Raw -LiteralPath $databasePath -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    foreach ($name in @('database','applicationUser','schema')) {
        if ("$($database.$name)" -notmatch '^[a-z][a-z0-9_]{0,62}$') { throw "Unsafe database configuration value: $name" }
    }
    $projectSlug = (Get-DemiStorageConfiguration -Root $Root).projectSlug
    if ("$projectSlug" -notmatch '^[a-z][a-z0-9_-]{0,62}$') { throw 'Unsafe project slug in storage configuration.' }
    if ($FocusSilo -and $FocusSilo -notmatch '^[a-z][a-z0-9_-]{0,62}$') { throw 'Unsafe focus silo.' }
    $limit = [Math]::Max(1,[Math]::Min(10,$MaximumItemsPerKind))
    $stopWords=@('about','after','again','also','been','being','could','does','from','have','into','just','more','should','that','their','there','these','they','this','what','when','where','which','with','would','your')
    $terms=[Collections.Generic.List[string]]::new()
    foreach($match in [regex]::Matches("$Query".ToLowerInvariant(),'[\p{L}\p{N}][\p{L}\p{N}_-]{2,}')){if($match.Value-notin$stopWords-and$match.Value-notin$terms){$terms.Add($match.Value)};if($terms.Count-ge10){break}}
    $searchQuery=if($terms.Count){$terms-join' OR '}else{"$Query"}
    $queryExpression = ConvertTo-DemiSqlUtf8Expression $searchQuery
    $projectExpression = ConvertTo-DemiSqlUtf8Expression $projectSlug
    $focusExpression = ConvertTo-DemiSqlUtf8Expression $(if($FocusSilo){$FocusSilo}else{''})
    $schema = "$($database.schema)"
    $sql = @"
WITH input AS (
    SELECT $queryExpression AS query_text, $projectExpression AS project_slug, $focusExpression AS focus_slug
), project AS (
    SELECT p.id FROM $schema.projects p, input i WHERE p.slug=i.project_slug
), visible_silos AS (
    SELECT s.id FROM $schema.silos s, project p, input i
    WHERE s.project_id=p.id AND (s.kind='global' OR (i.focus_slug<>'' AND s.slug=i.focus_slug))
), claim_rows AS (
    SELECT c.normalized_claim AS text,c.adoption_status,c.verification_status,s.slug AS silo
    FROM $schema.claims c JOIN project p ON p.id=c.project_id
    LEFT JOIN $schema.silos s ON s.id=c.scope_silo_id CROSS JOIN input i
    WHERE c.disposition='active' AND (c.scope_silo_id IS NULL OR c.scope_silo_id IN(SELECT id FROM visible_silos))
      AND (i.query_text='' OR to_tsvector('english',c.normalized_claim)@@websearch_to_tsquery('english',i.query_text))
    ORDER BY ts_rank_cd(to_tsvector('english',c.normalized_claim),websearch_to_tsquery('english',i.query_text)) DESC,c.updated_at DESC LIMIT $limit
), document_candidates AS (
    SELECT d.id AS document_id,d.title,ds.heading,left(ds.body,1200) AS text,s.slug AS silo,d.source_path,dv.imported_at,ds.ordinal,
      (25*ts_rank_cd(to_tsvector('english',translate(d.title,'_-','  ')),websearch_to_tsquery('english',i.query_text))+
       ts_rank_cd(to_tsvector('english',coalesce(ds.heading,'')||' '||ds.body),websearch_to_tsquery('english',i.query_text))) AS relevance
    FROM $schema.document_sections ds
    JOIN $schema.document_versions dv ON dv.id=ds.document_version_id
    JOIN $schema.documents d ON d.id=dv.document_id JOIN project p ON p.id=d.project_id
    LEFT JOIN $schema.silos s ON s.id=d.silo_id CROSS JOIN input i
    WHERE (d.silo_id IS NULL OR d.silo_id IN(SELECT id FROM visible_silos) OR EXISTS(
        SELECT 1 FROM $schema.document_silos dx WHERE dx.document_id=d.id AND dx.silo_id IN(SELECT id FROM visible_silos)))
      AND (i.query_text='' OR to_tsvector('english',translate(d.title,'_-','  ')||' '||coalesce(ds.heading,'')||' '||ds.body)@@websearch_to_tsquery('english',i.query_text))
), document_rows AS (
    SELECT title,heading,text,silo,source_path FROM (
      SELECT DISTINCT ON(document_id) document_id,title,heading,text,silo,source_path,relevance,imported_at,ordinal
      FROM document_candidates ORDER BY document_id,relevance DESC,ordinal
    ) best ORDER BY relevance DESC,imported_at DESC LIMIT $limit
), entity_rows AS (
    SELECT e.canonical_name,e.kind,s.slug AS silo,e.metadata
    FROM $schema.entities e JOIN project p ON p.id=e.project_id
    LEFT JOIN $schema.silos s ON s.id=e.home_silo_id CROSS JOIN input i
    WHERE (e.home_silo_id IS NULL OR e.home_silo_id IN(SELECT id FROM visible_silos))
      AND (i.query_text='' OR to_tsvector('simple',e.canonical_name)@@websearch_to_tsquery('simple',i.query_text) OR EXISTS(
        SELECT 1 FROM $schema.entity_aliases a WHERE a.entity_id=e.id AND to_tsvector('simple',a.alias)@@websearch_to_tsquery('simple',i.query_text)))
    ORDER BY e.canonical_name LIMIT $limit
), session_rows AS (
    SELECT se.legacy_name,se.title,se.summary,se.status
    FROM $schema.sessions se JOIN project p ON p.id=se.project_id
    WHERE se.summary IS NOT NULL AND EXISTS(
        SELECT 1 FROM $schema.session_silos ss WHERE ss.session_id=se.id AND ss.silo_id IN(SELECT id FROM visible_silos))
    ORDER BY se.updated_at DESC LIMIT $limit
), timeline_rows AS (
    SELECT e.external_id,e.title,e.summary,e.display_date,e.earth_year_start,e.earth_year_end,
      e.adoption_status,e.verification_status,
      COALESCE((SELECT string_agg(s.slug,', ' ORDER BY CASE WHEN es.role='focus' THEN 0 ELSE 1 END,s.slug)
        FROM $schema.timeline_event_silos es JOIN $schema.silos s ON s.id=es.silo_id WHERE es.event_id=e.id),'global') AS silos
    FROM $schema.timeline_events e JOIN project p ON p.id=e.project_id CROSS JOIN input i
    WHERE (NOT EXISTS(SELECT 1 FROM $schema.timeline_event_silos es WHERE es.event_id=e.id) OR EXISTS(
        SELECT 1 FROM $schema.timeline_event_silos es WHERE es.event_id=e.id AND es.silo_id IN(SELECT id FROM visible_silos)))
      AND (i.query_text='' OR to_tsvector('english',e.title||' '||coalesce(e.summary,''))@@websearch_to_tsquery('english',i.query_text))
    ORDER BY ts_rank_cd(to_tsvector('english',e.title||' '||coalesce(e.summary,'')),websearch_to_tsquery('english',i.query_text)) DESC,
      e.earth_year_start NULLS LAST,e.chronology_order LIMIT $limit
)
SELECT jsonb_build_object(
 'claims',COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM claim_rows x),'[]'::jsonb),
 'documents',COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM document_rows x),'[]'::jsonb),
 'entities',COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM entity_rows x),'[]'::jsonb),
 'sessions',COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM session_rows x),'[]'::jsonb),
 'timeline',COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM timeline_rows x),'[]'::jsonb)
);
"@
    $password = Get-DemiDatabasePassword
    $psql = Get-DemiAgentMemoryPsql
    $oldPassword = $env:PGPASSWORD
    try {
        $env:PGPASSWORD = $password
        $result = & $psql -X -A -t -v ON_ERROR_STOP=1 -h "$($database.host)" -p "$($database.port)" -U "$($database.applicationUser)" -d "$($database.database)" -c $sql 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($result -join [Environment]::NewLine) }
        return (($result -join [Environment]::NewLine).Trim() | ConvertFrom-Json -ErrorAction Stop)
    } finally {
        if ($null -ne $oldPassword) { $env:PGPASSWORD = $oldPassword } else { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
    }
}

function Get-DemiAgentDatabaseContext {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][object]$Agent,[AllowEmptyString()][string]$Query,[object]$Focus)
    $configuration = Get-DemiAgentMemoryConfiguration -Root $Root
    if (-not (Test-DemiAgentMemoryEnabled -Configuration $configuration -Agent $Agent)) { return '' }
    $focusSilo = Resolve-DemiFocusSilo $Focus
    try {
        $memory = Invoke-DemiAgentMemoryQuery -Root $Root -Query $Query -FocusSilo $focusSilo -MaximumItemsPerKind $configuration.maximumItemsPerKind
        $capabilities = @($configuration.readCapabilities)
        $lines = [Collections.Generic.List[string]]::new()
        if ('claims' -in $capabilities) { foreach ($item in @($memory.claims)) { $lines.Add("CLAIM [$($item.adoption_status); $($item.verification_status); $($item.silo)]: $($item.text)") } }
        if ('timeline' -in $capabilities) { foreach ($item in @($memory.timeline)) { $date=if($item.display_date){$item.display_date}elseif($item.earth_year_start){"Earth year $($item.earth_year_start)"}else{'date open'};$lines.Add("TIMELINE [$($item.external_id); $date; $($item.adoption_status); $($item.silos)]: $($item.title)$(if($item.summary){' - '+$item.summary})") } }
        if ('documents' -in $capabilities) { foreach ($item in @($memory.documents)) { $lines.Add("DOCUMENT [$($item.silo)] $($item.title)$(if($item.heading){' - '+$item.heading}): $($item.text)") } }
        if ('entities' -in $capabilities) { foreach ($item in @($memory.entities)) { $lines.Add("ENTITY [$($item.silo)] $($item.canonical_name) ($($item.kind))") } }
        if ('session-summaries' -in $capabilities) { foreach ($item in @($memory.sessions)) { $lines.Add("SESSION [$($item.legacy_name); $($item.status)]: $($item.title) - $($item.summary)") } }
        if ($lines.Count -eq 0) { return '' }
        $maximum = if($configuration.maximumContextCharacters){[int]$configuration.maximumContextCharacters}else{5000}
        return Get-DemiBoundedText ($lines -join "`n`n") $maximum
    } catch {
        if ($configuration.fallback -eq 'files') { return '' }
        throw
    }
}

