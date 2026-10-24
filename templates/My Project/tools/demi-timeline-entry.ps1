[CmdletBinding(DefaultParameterSetName='Legacy')]
param(
    [Parameter(Mandatory,ParameterSetName='Legacy')][string]$Date,
    [Parameter(Mandatory,ParameterSetName='Legacy')][string]$Title,
    [Parameter(ParameterSetName='Legacy')][string]$Summary='',
    [Parameter(Mandatory,ParameterSetName='Payload')][string]$PayloadBase64,
    [Parameter(Mandatory,ParameterSetName='Delete')][string]$DeleteExternalId
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'demi-session-store.ps1')
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Write-TimelineJson([object]$Value) {
    $file=Join-Path $root 'state\timeline.json';$temp="$file.$PID.tmp"
    try{
        [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        if(Test-Path -LiteralPath $file -PathType Leaf){
            $backup="$file.$PID.$([guid]::NewGuid().ToString('N')).replace-backup"
            try{[IO.File]::Replace($temp,$file,$backup,$true)}
            finally{if(Test-Path -LiteralPath $backup -PathType Leaf){Remove-Item -LiteralPath $backup -Force}}
        }else{[IO.File]::Move($temp,$file)}
    }
    finally{if(Test-Path -LiteralPath $temp -PathType Leaf){Remove-Item -LiteralPath $temp -Force}}
}
function Clean-Text([object]$Value,[int]$Maximum,[string]$Label,[switch]$Required){
    $clean="$Value".Normalize([Text.NormalizationForm]::FormKC).Trim()
    if($Required-and-not$clean){throw "$Label is required."}
    if($clean.Length-gt$Maximum){throw "$Label may contain at most $Maximum characters."}
    return $clean
}
function Nullable-Number([object]$Value,[string]$Label){
    if($null-eq$Value-or"$Value".Trim()-eq''){return $null}
    $number=0d
    if(-not[decimal]::TryParse("$Value",[Globalization.NumberStyles]::Number,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)){throw "$Label must be a number."}
    return $number
}

if($PSCmdlet.ParameterSetName-eq'Delete'){
    $externalId=Clean-Text $DeleteExternalId 80 'Timeline ID' -Required
    if($externalId-notmatch'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$'){throw 'Timeline ID contains unsupported characters.'}
    $storage=Get-Content -Raw -LiteralPath (Join-Path $root 'config\storage.json') -Encoding UTF8|ConvertFrom-Json
    if("$($storage.backend)"-eq'postgresql'){
        $context=Get-DemiSessionDatabaseContext -Root $root;$schema="$($context.Database.schema)"
        $safeId=$externalId.Replace("'","''")
        $result=Invoke-DemiSessionDatabaseSql -Context $context -Sql "DELETE FROM $schema.timeline_events WHERE project_id=(SELECT id FROM $schema.projects WHERE slug='$($storage.projectSlug)') AND external_id='$safeId' RETURNING external_id;"
        if(-not(($result|Out-String).Trim())){throw 'Timeline event was not found.'}
        $export=(& (Join-Path $PSScriptRoot 'demi-timeline.ps1') export -ProjectRoot $root|Out-String).Trim()|ConvertFrom-Json
        Write-TimelineJson $export
    }else{
        $file=Join-Path $root 'state\timeline.json'
        if(-not(Test-Path -LiteralPath $file)){throw 'Timeline data is unavailable.'}
        $timeline=Get-Content -Raw -LiteralPath $file -Encoding UTF8|ConvertFrom-Json
        $before=@($timeline.events).Count;$timeline.events=@($timeline.events|Where-Object{$_.external_id-ne$externalId})
        if(@($timeline.events).Count-eq$before){throw 'Timeline event was not found.'}
        Write-TimelineJson $timeline
    }
    [pscustomobject]@{accepted=$true;deleted=$true;eventId=$externalId}|ConvertTo-Json -Compress
    return
}

if($PSCmdlet.ParameterSetName-eq'Payload'){
    try{$request=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PayloadBase64))|ConvertFrom-Json}
    catch{throw 'Timeline event data is invalid.'}
}else{
    $request=[pscustomobject]@{date=$Date;title=$Title;summary=$Summary;earthYearStart=$null;earthYearEnd=$null;dateSystem='';dateBasis='';adoptionStatus='suggested';verificationStatus='not_required';confidence='author supplied';crossBookImpact='';sourceLabel='';sourceClaim='';externalId='';siloSlugs=@('global')}
}

$cleanTitle=Clean-Text $request.title 200 'Timeline title' -Required
$cleanSummary=Clean-Text $request.summary 4000 'Timeline summary'
$displayDate=Clean-Text $request.date 120 'Timeline date' -Required
$dateSystem=Clean-Text $request.dateSystem 120 'Date system'
$dateBasis=Clean-Text $request.dateBasis 1000 'Date basis'
$confidence=Clean-Text $request.confidence 80 'Confidence'
$crossBookImpact=Clean-Text $request.crossBookImpact 1000 'Cross-book impact'
$sourceLabel=Clean-Text $request.sourceLabel 240 'Source label'
$sourceClaim=Clean-Text $request.sourceClaim 2000 'Source claim'
$start=Nullable-Number $request.earthYearStart 'Earth year start'
$end=Nullable-Number $request.earthYearEnd 'Earth year end'
if($null-ne$start-and$null-ne$end-and$end-lt$start){throw 'Earth year end cannot precede the start.'}
if($null-eq$start-and$displayDate-match'^[-+]?\d+(?:\.\d+)?$'){$start=[decimal]::Parse($displayDate,[Globalization.CultureInfo]::InvariantCulture)}
$status=Clean-Text $request.adoptionStatus 20 'Status'
if($status-notin@('suggested','proposed','verified','canon')){throw 'Choose suggested, proposed, verified, or canon.'}
$verification=Clean-Text $request.verificationStatus 30 'Verification status'
if(-not$verification){$verification=if($status-eq'verified'){'verified'}else{'not_required'}}
if($verification-notin@('not_required','needs_verification','verified','failed','disputed')){throw 'Choose a valid verification status.'}
$externalId=Clean-Text $request.externalId 80 'Timeline ID'
if($externalId-and$externalId-notmatch'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$'){throw 'Timeline ID contains unsupported characters.'}
if(-not$externalId){$externalId='MANUAL-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)}
$siloSlugs=@($request.siloSlugs|ForEach-Object{"$_".Trim().ToLowerInvariant()}|Where-Object{$_}|Select-Object -Unique)
if(-not$siloSlugs.Count){$siloSlugs=@('global')}
if(@($siloSlugs|Where-Object{$_-notmatch'^[a-z][a-z0-9-]{0,62}$'}).Count){throw 'One or more silo names are invalid.'}
$event=[ordered]@{external_id=$externalId;title=$cleanTitle;summary=$(if($cleanSummary){$cleanSummary}else{$null});earth_year_start=$start;earth_year_end=$end;display_date=$displayDate;years_since_launch=$null;landfall_year=$null;date_system=$(if($dateSystem){$dateSystem}else{'Earth calendar'});earth_year_basis=$(if($dateBasis){$dateBasis}else{$null});adoption_status=$status;verification_status=$verification;source_status='Milo-added';confidence=$(if($confidence){$confidence}else{'Author supplied'});cross_book_impact=$(if($crossBookImpact){$crossBookImpact}else{$null});chronology_order=$null;silos=@($siloSlugs|ForEach-Object{[ordered]@{slug=$_;name=$_;role=$(if($_-eq$siloSlugs[0]){'focus'}else{'reference'})}});sources=@([ordered]@{path='state/timeline.json';sheet=$null;row=$null;label=$(if($sourceLabel){$sourceLabel}else{'Added with /timeline'});claim=$(if($sourceClaim){$sourceClaim}else{$cleanSummary})})}
$storage=Get-Content -Raw -LiteralPath (Join-Path $root 'config\storage.json') -Encoding UTF8|ConvertFrom-Json
if("$($storage.backend)"-eq'postgresql'){
    $context=Get-DemiSessionDatabaseContext -Root $root;$schema="$($context.Database.schema)";$payload=ConvertTo-DemiBase64Json $event
    $sql=@"
BEGIN;
CREATE TEMP TABLE demi_timeline_entry(data jsonb) ON COMMIT DROP;
INSERT INTO demi_timeline_entry VALUES(convert_from(decode('$payload','base64'),'UTF8')::jsonb);
INSERT INTO $schema.timeline_events(project_id,external_id,title,summary,earth_year_start,earth_year_end,display_date,date_system,adoption_status,verification_status,source_status,confidence,cross_book_impact,metadata,updated_at)
SELECT p.id,d.data->>'external_id',d.data->>'title',nullif(d.data->>'summary',''),(d.data->>'earth_year_start')::numeric,(d.data->>'earth_year_end')::numeric,nullif(d.data->>'display_date',''),nullif(d.data->>'date_system',''),d.data->>'adoption_status',d.data->>'verification_status',d.data->>'source_status',d.data->>'confidence',nullif(d.data->>'cross_book_impact',''),jsonb_strip_nulls(jsonb_build_object('createdBy','/timeline','earthYearBasis',d.data->>'earth_year_basis')),now() FROM $schema.projects p,demi_timeline_entry d WHERE p.slug='$($storage.projectSlug)'
ON CONFLICT(project_id,external_id)DO UPDATE SET title=excluded.title,summary=excluded.summary,earth_year_start=excluded.earth_year_start,earth_year_end=excluded.earth_year_end,display_date=excluded.display_date,date_system=excluded.date_system,adoption_status=excluded.adoption_status,verification_status=excluded.verification_status,source_status=excluded.source_status,confidence=excluded.confidence,cross_book_impact=excluded.cross_book_impact,metadata=$schema.timeline_events.metadata||excluded.metadata,updated_at=now();
DELETE FROM $schema.timeline_event_silos es USING $schema.timeline_events e,demi_timeline_entry d WHERE es.event_id=e.id AND e.project_id=(SELECT id FROM $schema.projects WHERE slug='$($storage.projectSlug)') AND e.external_id=d.data->>'external_id';
INSERT INTO $schema.timeline_event_silos(event_id,silo_id,role,reason)
SELECT e.id,s.id,CASE WHEN x.ordinality=1 THEN'focus'ELSE'reference'END,'Selected in timeline editor' FROM demi_timeline_entry d JOIN $schema.timeline_events e ON e.external_id=d.data->>'external_id' AND e.project_id=(SELECT id FROM $schema.projects WHERE slug='$($storage.projectSlug)') CROSS JOIN LATERAL jsonb_array_elements(d.data->'silos')WITH ORDINALITY x(item,ordinality) JOIN $schema.silos s ON s.project_id=e.project_id AND s.slug=x.item->>'slug';
DELETE FROM $schema.timeline_event_sources src USING $schema.timeline_events e,demi_timeline_entry d WHERE src.event_id=e.id AND src.source_path='state/timeline.json' AND e.external_id=d.data->>'external_id' AND e.project_id=(SELECT id FROM $schema.projects WHERE slug='$($storage.projectSlug)');
INSERT INTO $schema.timeline_event_sources(event_id,source_path,sheet_name,source_row,source_label,source_claim,locator)
SELECT e.id,'state/timeline.json','Manual timeline editor',0,nullif(d.data->'sources'->0->>'label',''),nullif(d.data->'sources'->0->>'claim',''),jsonb_build_object('createdBy','/timeline') FROM demi_timeline_entry d JOIN $schema.timeline_events e ON e.external_id=d.data->>'external_id' AND e.project_id=(SELECT id FROM $schema.projects WHERE slug='$($storage.projectSlug)');
COMMIT;
"@
    [void](Invoke-DemiSessionDatabaseSql -Context $context -Sql $sql)
    $export=(& (Join-Path $PSScriptRoot 'demi-timeline.ps1') export -ProjectRoot $root|Out-String).Trim()|ConvertFrom-Json
    Write-TimelineJson $export
}else{
    $file=Join-Path $root 'state\timeline.json'
    $timeline=if(Test-Path -LiteralPath $file){Get-Content -Raw -LiteralPath $file -Encoding UTF8|ConvertFrom-Json}else{[pscustomobject]@{schemaVersion=1;project=[pscustomobject]@{slug="$($storage.projectSlug)";name='Demi'};events=@()}}
    $timeline.events=@($timeline.events|Where-Object{$_.external_id-ne$externalId})+@([pscustomobject]$event);Write-TimelineJson $timeline
}
[pscustomobject]@{accepted=$true;eventId=$externalId;title=$cleanTitle;status=$status}|ConvertTo-Json -Compress
