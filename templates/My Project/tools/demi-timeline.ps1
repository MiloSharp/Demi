[CmdletBinding()]
param(
    [ValidateSet('import','preview','status','export')][string]$Command='status',
    [string]$Workbook,
    [string]$ProjectRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=if($ProjectRoot){(Resolve-Path -LiteralPath $ProjectRoot).Path}else{[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))}
. (Join-Path $PSScriptRoot 'demi-agent-memory.ps1')
. (Join-Path $PSScriptRoot 'demi-db-auth.ps1')
$database=Get-Content -Raw -LiteralPath (Join-Path $root 'config\database.json') -Encoding UTF8|ConvertFrom-Json
$storage=Get-Content -Raw -LiteralPath (Join-Path $root 'config\storage.json') -Encoding UTF8|ConvertFrom-Json
$projectSlug="$($storage.projectSlug)";$schema="$($database.schema)"
foreach($value in @($projectSlug,$schema,"$($database.database)","$($database.applicationUser)")){if($value-notmatch'^[a-z][a-z0-9_-]{0,62}$'){throw 'Unsafe database configuration value.'}}
$credentialPath=Join-Path $env:LOCALAPPDATA 'Demiurge\database-credential.clixml'

function Get-DefaultTimelineWorkbook {
    $files=@(Get-ChildItem -LiteralPath (Join-Path $root 'outputs') -Recurse -File -Filter 'Demiurge_Master_Chronology_Communications_Ledger_v*.xlsx' -ErrorAction SilentlyContinue)
    if(-not$files.Count){throw 'No master chronology workbook was found. Supply -Workbook.'}
    $ranked=$files|ForEach-Object{[pscustomobject]@{File=$_;Version=$(if($_.BaseName-match'_v(\d+)$'){[int]$Matches[1]}else{0})}}|Sort-Object Version,@{Expression={$_.File.LastWriteTimeUtc};Descending=$true} -Descending
    return $ranked[0].File.FullName
}

function ConvertFrom-XlsxCell([System.Xml.XmlElement]$Cell,[string[]]$SharedStrings){
    $type=$Cell.GetAttribute('t');$valueNode=$Cell.SelectSingleNode("./*[local-name()='v']");$value=if($valueNode){$valueNode.InnerText}else{''}
    if($type-eq's'){$index=[int]$value;if($index-ge0-and$index-lt$SharedStrings.Count){return $SharedStrings[$index]};return $value}
    if($type-eq'inlineStr'){return (@($Cell.SelectNodes(".//*[local-name()='t']")|ForEach-Object{$_.InnerText})-join'')}
    if($type-eq'b'){return $value-eq'1'}
    if($value-match'^[-+]?(?:\d+(?:\.\d*)?|\.\d+)$'){return [decimal]::Parse($value,[Globalization.CultureInfo]::InvariantCulture)}
    return $value
}

function Read-XlsxSheet([string]$Path,[string]$SheetName){
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($Path)
    try{
        function Read-Entry([string]$Name){$entry=$archive.GetEntry($Name);if(-not$entry){throw "Missing workbook part: $Name"};$reader=[IO.StreamReader]::new($entry.Open());try{return $reader.ReadToEnd()}finally{$reader.Dispose()}}
        [xml]$sharedXml=if($archive.GetEntry('xl/sharedStrings.xml')){Read-Entry 'xl/sharedStrings.xml'}else{'<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" />'}
        $shared=@($sharedXml.SelectNodes("//*[local-name()='si']")|ForEach-Object{(@($_.SelectNodes(".//*[local-name()='t']")|ForEach-Object{$_.InnerText})-join'')})
        [xml]$workbookXml=Read-Entry 'xl/workbook.xml';[xml]$relsXml=Read-Entry 'xl/_rels/workbook.xml.rels'
        $sheet=@($workbookXml.SelectNodes("//*[local-name()='sheet']")|Where-Object{"$($_.name)"-eq$SheetName})|Select-Object -First 1
        if(-not$sheet){throw "Worksheet '$SheetName' was not found."}
        $relationshipId=$sheet.GetAttribute('id','http://schemas.openxmlformats.org/officeDocument/2006/relationships')
        $relationship=@($relsXml.SelectNodes("//*[local-name()='Relationship']")|Where-Object{"$($_.Id)"-eq$relationshipId})|Select-Object -First 1
        $target="$($relationship.Target)".Replace('\','/').TrimStart('/')
        if($target-notlike'xl/*'){$target="xl/$target"}
        [xml]$sheetXml=Read-Entry $target
        $rows=[Collections.Generic.List[object]]::new()
        foreach($row in @($sheetXml.SelectNodes("//*[local-name()='sheetData']/*[local-name()='row']"))){
            $values=@{}
            foreach($cell in @($row.SelectNodes("./*[local-name()='c']"))){
                $reference="$($cell.r)";if($reference-notmatch'^([A-Z]+)'){continue};$letters=$Matches[1];$column=0
                foreach($character in $letters.ToCharArray()){$column=($column*26)+([int][char]$character-[int][char]'A'+1)}
                $values[$column]=ConvertFrom-XlsxCell $cell $shared
            }
            $rows.Add([pscustomobject]@{number=[int]$row.r;values=$values})
        }
        return @($rows)
    }finally{$archive.Dispose()}
}

function ConvertTo-Records([object[]]$Rows,[string[]]$RequiredHeaders){
    $headerRow=$Rows|Where-Object{$texts=@($_.values.Values|ForEach-Object{"$_"});@($RequiredHeaders|Where-Object{$_-notin$texts}).Count-eq0}|Select-Object -First 1
    if(-not$headerRow){throw "Required headers were not found: $($RequiredHeaders-join', ')"}
    $headers=@{};foreach($entry in $headerRow.values.GetEnumerator()){$headers[[int]$entry.Key]="$($entry.Value)"}
    foreach($row in $Rows|Where-Object{$_.number-gt$headerRow.number}){
        $record=[ordered]@{_row=$row.number};$hasValue=$false
        foreach($column in $headers.Keys){$value=if($row.values.ContainsKey($column)){$row.values[$column]}else{$null};$record[$headers[$column]]=$value;if($null-ne$value-and"$value"-ne''){$hasValue=$true}}
        if($hasValue){[pscustomobject]$record}
    }
}

function Get-AdoptionStatus([object]$SourceStatus){if("$SourceStatus"-match'(?i)confirmed|canon'){'canon'}else{'suggested'}}
function Get-NullableNumber([object]$Value){if($null-eq$Value-or"$Value"-notmatch'^[-+]?(?:\d+(?:\.\d*)?|\.\d+)$'){return $null};return $Value}
$crossingYearZero=2115
$demeterDeathEarthYear=$crossingYearZero+100
function Get-NormalizedEarthRange([object]$Row){
    $start=Get-NullableNumber $Row.'Earth Year Start';$end=Get-NullableNumber $Row.'Earth Year End';$display="$($Row.'Display Date')";$basis=$null
    if($null-eq$start-and$display-match'(?i)Crossing Year\s+(\d+)'){$start=$crossingYearZero+[int]$Matches[1];$basis="Crossing Year $($Matches[1]) + Earth-year epoch $crossingYearZero"}
    if($null-eq$start-and"$($Row.'Event ID')"-eq'T015'){$start=$crossingYearZero;$basis="Crossing Year 0 anchored approximately to $crossingYearZero by Milo"}
    if($null-eq$start-and$display-match'(?i)^After Demeter death'){$start=$demeterDeathEarthYear;$basis="Demeter death at Crossing Year 100 (approximately $demeterDeathEarthYear)"}
    if($null-eq$start-and$display-match'(?i)^After death'){$start=$demeterDeathEarthYear;$basis="Demeter death at Crossing Year 100 (approximately $demeterDeathEarthYear)";if($display-match'(?i)Tau Ceti approach'){$end=2481}}
    [pscustomobject]@{Start=$start;End=$end;Basis=$basis}
}
function Get-SiloSlugs([string]$Scope){
    $slugs=[Collections.Generic.List[string]]::new()
    if($Scope-match'(?i)series|global|all books'){$slugs.Add('global')}
    $map=@{}
    foreach($number in 1..6){if($Scope-match"(?i)book(?:s)?\s*(?:[a-z]+\s*/\s*)?$number|book\s+$(@('One','Two','Three','Four','Five','Six')[$number-1])"){$slugs.Add($map[$number])}}
    if(-not$slugs.Count){$slugs.Add('global')};return @($slugs|Select-Object -Unique)
}
function ConvertTo-Base64Json([object]$Value){[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 30 -Compress)))}
function Invoke-TimelinePsql([string[]]$Extra){
    $password=Get-DemiDatabasePassword;$psql=Get-DemiAgentMemoryPsql;$old=$env:PGPASSWORD
    try{$env:PGPASSWORD=$password;$output=&$psql -X -v ON_ERROR_STOP=1 -h "$($database.host)" -p "$($database.port)" -U "$($database.applicationUser)" -d "$($database.database)" @Extra 2>&1;if($LASTEXITCODE-ne0){throw($output-join[Environment]::NewLine)};,$output}
    finally{if($null-ne$old){$env:PGPASSWORD=$old}else{Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue}}
}

if($Command-eq'status'){
    $sql="SELECT json_build_object('events',(SELECT count(*) FROM $schema.timeline_events),'communications',(SELECT count(*) FROM $schema.timeline_communications),'conflicts',(SELECT count(*) FROM $schema.timeline_conflicts),'lastImport',(SELECT to_jsonb(r) FROM $schema.timeline_import_runs r ORDER BY started_at DESC LIMIT 1));"
    (Invoke-TimelinePsql @('-A','-t','-c',$sql)|Out-String).Trim();exit
}
if($Command-eq'export'){
    $sql=@"
SELECT json_build_object(
  'project',json_build_object('slug',p.slug,'name',p.name),
  'silos',COALESCE((SELECT jsonb_agg(jsonb_build_object('slug',s.slug,'name',s.name,'kind',s.kind) ORDER BY CASE WHEN s.slug='global' THEN 0 ELSE 1 END,s.name) FROM $schema.silos s WHERE s.project_id=p.id),'[]'::jsonb),
  'events',COALESCE((SELECT jsonb_agg(to_jsonb(row_data) ORDER BY row_data.earth_year_start NULLS LAST,row_data.chronology_order,row_data.external_id) FROM (
    SELECT e.external_id,e.title,e.summary,e.earth_year_start,e.earth_year_end,e.display_date,
      e.years_since_launch,e.landfall_year,e.date_system,e.adoption_status,e.verification_status,
      e.source_status,e.confidence,e.cross_book_impact,e.chronology_order,e.metadata->>'earthYearBasis' AS earth_year_basis,
      COALESCE((SELECT jsonb_agg(jsonb_build_object('slug',s.slug,'name',s.name,'role',es.role) ORDER BY CASE WHEN es.role='focus' THEN 0 ELSE 1 END,s.name)
        FROM $schema.timeline_event_silos es JOIN $schema.silos s ON s.id=es.silo_id WHERE es.event_id=e.id),'[]'::jsonb) AS silos,
      COALESCE((SELECT jsonb_agg(jsonb_build_object('path',src.source_path,'sheet',src.sheet_name,'row',src.source_row,'label',src.source_label,'claim',src.source_claim) ORDER BY src.source_path,src.source_row)
        FROM $schema.timeline_event_sources src WHERE src.event_id=e.id),'[]'::jsonb) AS sources
    FROM $schema.timeline_events e WHERE e.project_id=p.id
  ) row_data),'[]'::jsonb)
) FROM $schema.projects p WHERE p.slug='$projectSlug';
"@
    (Invoke-TimelinePsql @('-A','-t','-c',$sql)|Out-String).Trim();exit
}

$workbookPath=if($Workbook){(Resolve-Path -LiteralPath $Workbook).Path}else{Get-DefaultTimelineWorkbook}
$rootPrefix=$root.TrimEnd('\')+'\'
$relativePath=if($workbookPath.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)){$workbookPath.Substring($rootPrefix.Length).Replace('\','/')}else{$workbookPath}
$hash=(Get-FileHash -LiteralPath $workbookPath -Algorithm SHA256).Hash.ToLowerInvariant()
$events=@(ConvertTo-Records (Read-XlsxSheet $workbookPath 'Master Timeline') @('Event ID','Event','Earth Year Start'))
$communications=@(ConvertTo-Records (Read-XlsxSheet $workbookPath 'Communications') @('Comm ID','Sender','Recipient','Message / Beat'))
$conflicts=@(ConvertTo-Records (Read-XlsxSheet $workbookPath 'Conflicts') @('Conflict ID','Topic','Claim A','Claim B'))
$preview=[pscustomobject]@{source=$relativePath;sha256=$hash;events=$events.Count;communications=$communications.Count;conflicts=$conflicts.Count}
if($Command-eq'preview'){$preview|ConvertTo-Json;exit}

$payload=[ordered]@{projectSlug=$projectSlug;sourcePath=$relativePath;sourceHash=$hash;events=@();communications=@();conflicts=@()}
$order=0
foreach($row in $events){$order++;$scope="$($row.'Book/Scope')";$slugs=@(Get-SiloSlugs "$scope $($row.'Cross-Book Impact')");$earth=Get-NormalizedEarthRange $row;$payload.events+=@{externalId="$($row.'Event ID')";title="$($row.Event)";summary="$($row.'Source Claim / Notes')";earthYearStart=$earth.Start;earthYearEnd=$earth.End;displayDate="$($row.'Display Date')";yearsSinceLaunch=Get-NullableNumber $row.'Years Since Launch';landfallYear=Get-NullableNumber $row.'Landfall Year';dateSystem="$($row.'Date System / Context')";dateBasis=$earth.Basis;adoptionStatus=Get-AdoptionStatus $row.'Canon Status';sourceStatus="$($row.'Canon Status')";confidence="$($row.Confidence)";crossBookImpact="$($row.'Cross-Book Impact')";chronologyOrder=$order;sourceLabel="$($row.'Primary Source')";sourceClaim="$($row.'Source Claim / Notes')";sourceRow=$row._row;silos=[object[]]$slugs;scope=$scope}}
foreach($row in $communications){$payload.communications+=@{externalId="$($row.'Comm ID')";sender="$($row.Sender)";recipient="$($row.Recipient)";message="$($row.'Message / Beat')";compositionContext="$($row.'Composition / Send Context')";sendYear=Get-NullableNumber $row.'Send Year';expectedReceiveYear=Get-NullableNumber $row.'Expected Receive Year';actualReceiveYear=Get-NullableNumber $row.'Actual Receive / Result Year';sendYearText="$($row.'Send Year')";expectedReceiveYearText="$($row.'Expected Receive Year')";actualReceiveYearText="$($row.'Actual Receive / Result Year')";route="$($row.'Route / Medium')";senderState="$($row.'Sender TX State')";recipientState="$($row.'Recipient RX State')";outcome="$($row.Outcome)";adoptionStatus=Get-AdoptionStatus $row.'Canon Status';sourceStatus="$($row.'Canon Status')";sourceLabel="$($row.'Primary Source')";notes="$($row.'Notes / Dependency')";parentExternalId="$($row.'Reply / Parent Comm ID')";relatedIds="$($row.'Related Event / Conflict IDs')";sourceRow=$row._row}}
foreach($row in $conflicts){$payload.conflicts+=@{externalId="$($row.'Conflict ID')";topic="$($row.Topic)";sourceA="$($row.'Source A')";claimA="$($row.'Claim A')";sourceB="$($row.'Source B')";claimB="$($row.'Claim B')";currentDirection="$($row.'Latest Author / Current Direction')";smallestCorrection="$($row.'Smallest Effective Correction')";status="$($row.Status)";priority="$($row.Priority)";sourceRow=$row._row}}
$encoded=ConvertTo-Base64Json $payload;$temp=[IO.Path]::GetTempFileName()
try{
    $sql=@"
BEGIN;
CREATE TEMP TABLE timeline_payload(data jsonb) ON COMMIT DROP;
INSERT INTO timeline_payload(data) VALUES(convert_from(decode('$encoded','base64'),'UTF8')::jsonb);
INSERT INTO $schema.timeline_events(project_id,external_id,title,summary,earth_year_start,earth_year_end,display_date,years_since_launch,landfall_year,date_system,adoption_status,source_status,confidence,cross_book_impact,chronology_order,metadata,updated_at)
SELECT p.id,x."externalId",x.title,nullif(x.summary,''),x."earthYearStart",x."earthYearEnd",nullif(x."displayDate",''),x."yearsSinceLaunch",x."landfallYear",nullif(x."dateSystem",''),x."adoptionStatus",nullif(x."sourceStatus",''),nullif(x.confidence,''),nullif(x."crossBookImpact",''),x."chronologyOrder",jsonb_strip_nulls(jsonb_build_object('workbookScope',x.scope,'earthYearBasis',x."dateBasis")),now()
FROM $schema.projects p CROSS JOIN LATERAL jsonb_to_recordset((SELECT data->'events' FROM timeline_payload)) x("externalId" text,title text,summary text,"earthYearStart" numeric,"earthYearEnd" numeric,"displayDate" text,"yearsSinceLaunch" numeric,"landfallYear" numeric,"dateSystem" text,"dateBasis" text,"adoptionStatus" text,"sourceStatus" text,confidence text,"crossBookImpact" text,"chronologyOrder" numeric,"sourceLabel" text,"sourceClaim" text,"sourceRow" integer,silos jsonb,scope text)
WHERE p.slug=(SELECT data->>'projectSlug' FROM timeline_payload)
ON CONFLICT(project_id,external_id) DO UPDATE SET title=excluded.title,summary=excluded.summary,earth_year_start=excluded.earth_year_start,earth_year_end=excluded.earth_year_end,display_date=excluded.display_date,years_since_launch=excluded.years_since_launch,landfall_year=excluded.landfall_year,date_system=excluded.date_system,adoption_status=excluded.adoption_status,source_status=excluded.source_status,confidence=excluded.confidence,cross_book_impact=excluded.cross_book_impact,chronology_order=excluded.chronology_order,metadata=excluded.metadata,updated_at=now();
DELETE FROM $schema.timeline_event_silos es USING $schema.timeline_events e WHERE es.event_id=e.id AND e.project_id=(SELECT id FROM $schema.projects WHERE slug=(SELECT data->>'projectSlug' FROM timeline_payload)) AND e.external_id IN(SELECT x->>'externalId' FROM jsonb_array_elements((SELECT data->'events' FROM timeline_payload))x);
INSERT INTO $schema.timeline_event_silos(event_id,silo_id,role,reason)
SELECT e.id,s.id,CASE WHEN z.ordinality=1 THEN 'focus' ELSE 'reference' END,'Imported workbook scope' FROM jsonb_array_elements((SELECT data->'events' FROM timeline_payload))x JOIN $schema.timeline_events e ON e.external_id=x->>'externalId' AND e.project_id=(SELECT id FROM $schema.projects WHERE slug=(SELECT data->>'projectSlug' FROM timeline_payload)) CROSS JOIN LATERAL jsonb_array_elements_text(x->'silos')WITH ORDINALITY z(slug,ordinality) JOIN $schema.silos s ON s.project_id=e.project_id AND s.slug=z.slug ON CONFLICT(event_id,silo_id)DO UPDATE SET role=excluded.role,reason=excluded.reason;
INSERT INTO $schema.timeline_event_sources(event_id,source_path,source_sha256,sheet_name,source_row,source_label,source_claim,locator)
SELECT e.id,(SELECT data->>'sourcePath' FROM timeline_payload),(SELECT data->>'sourceHash' FROM timeline_payload),'Master Timeline',(x->>'sourceRow')::integer,nullif(x->>'sourceLabel',''),nullif(x->>'sourceClaim',''),jsonb_build_object('eventId',x->>'externalId') FROM jsonb_array_elements((SELECT data->'events' FROM timeline_payload))x JOIN $schema.timeline_events e ON e.external_id=x->>'externalId' AND e.project_id=(SELECT id FROM $schema.projects WHERE slug=(SELECT data->>'projectSlug' FROM timeline_payload)) ON CONFLICT(event_id,source_path,sheet_name,source_row)DO UPDATE SET source_sha256=excluded.source_sha256,source_label=excluded.source_label,source_claim=excluded.source_claim,locator=excluded.locator;
INSERT INTO $schema.timeline_communications(project_id,external_id,sender,recipient,message,composition_context,send_year,expected_receive_year,actual_receive_year,route,sender_state,recipient_state,outcome,adoption_status,source_status,source_label,notes,parent_external_id,related_ids,source_path,source_sha256,source_row,metadata,updated_at)
SELECT p.id,x."externalId",x.sender,x.recipient,x.message,x."compositionContext",x."sendYear",x."expectedReceiveYear",x."actualReceiveYear",x.route,x."senderState",x."recipientState",x.outcome,x."adoptionStatus",x."sourceStatus",x."sourceLabel",x.notes,x."parentExternalId",x."relatedIds",d->>'sourcePath',d->>'sourceHash',x."sourceRow",jsonb_build_object('sendYearText',x."sendYearText",'expectedReceiveYearText',x."expectedReceiveYearText",'actualReceiveYearText',x."actualReceiveYearText"),now() FROM $schema.projects p,(SELECT data d FROM timeline_payload)q CROSS JOIN LATERAL jsonb_to_recordset(d->'communications')x("externalId" text,sender text,recipient text,message text,"compositionContext" text,"sendYear" numeric,"expectedReceiveYear" numeric,"actualReceiveYear" numeric,"sendYearText" text,"expectedReceiveYearText" text,"actualReceiveYearText" text,route text,"senderState" text,"recipientState" text,outcome text,"adoptionStatus" text,"sourceStatus" text,"sourceLabel" text,notes text,"parentExternalId" text,"relatedIds" text,"sourceRow" integer)WHERE p.slug=d->>'projectSlug' ON CONFLICT(project_id,external_id)DO UPDATE SET sender=excluded.sender,recipient=excluded.recipient,message=excluded.message,composition_context=excluded.composition_context,send_year=excluded.send_year,expected_receive_year=excluded.expected_receive_year,actual_receive_year=excluded.actual_receive_year,route=excluded.route,sender_state=excluded.sender_state,recipient_state=excluded.recipient_state,outcome=excluded.outcome,adoption_status=excluded.adoption_status,source_status=excluded.source_status,source_label=excluded.source_label,notes=excluded.notes,parent_external_id=excluded.parent_external_id,related_ids=excluded.related_ids,source_sha256=excluded.source_sha256,source_row=excluded.source_row,metadata=excluded.metadata,updated_at=now();
INSERT INTO $schema.timeline_conflicts(project_id,external_id,topic,source_a,claim_a,source_b,claim_b,current_direction,smallest_correction,status,priority,source_path,source_sha256,source_row,updated_at)
SELECT p.id,x."externalId",x.topic,x."sourceA",x."claimA",x."sourceB",x."claimB",x."currentDirection",x."smallestCorrection",x.status,x.priority,d->>'sourcePath',d->>'sourceHash',x."sourceRow",now() FROM $schema.projects p,(SELECT data d FROM timeline_payload)q CROSS JOIN LATERAL jsonb_to_recordset(d->'conflicts')x("externalId" text,topic text,"sourceA" text,"claimA" text,"sourceB" text,"claimB" text,"currentDirection" text,"smallestCorrection" text,status text,priority text,"sourceRow" integer)WHERE p.slug=d->>'projectSlug' ON CONFLICT(project_id,external_id)DO UPDATE SET topic=excluded.topic,source_a=excluded.source_a,claim_a=excluded.claim_a,source_b=excluded.source_b,claim_b=excluded.claim_b,current_direction=excluded.current_direction,smallest_correction=excluded.smallest_correction,status=excluded.status,priority=excluded.priority,source_sha256=excluded.source_sha256,source_row=excluded.source_row,updated_at=now();
INSERT INTO $schema.timeline_import_runs(project_id,source_path,source_sha256,status,events_imported,communications_imported,conflicts_imported,details,completed_at)SELECT p.id,d->>'sourcePath',d->>'sourceHash','completed',jsonb_array_length(d->'events'),jsonb_array_length(d->'communications'),jsonb_array_length(d->'conflicts'),jsonb_build_object('confirmedRowsPromotedToCanon',true,'otherRowsImportedAs','suggested'),now() FROM $schema.projects p,(SELECT data d FROM timeline_payload)q WHERE p.slug=d->>'projectSlug';
COMMIT;
"@
    [IO.File]::WriteAllText($temp,$sql,[Text.UTF8Encoding]::new($false));[void](Invoke-TimelinePsql @('-f',$temp))
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
$preview|ConvertTo-Json
