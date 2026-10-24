Set-StrictMode -Version Latest

$script:DemiDocumentAllowedExtensions = @('.md','.txt','.docx')
$script:DemiDocumentAllowedRoots = @(
    '^books\\[^\\]+\\drafts\\',
    '^canon\\proposals\\',
    '^research\\reports\\',
    '^collaboration\\handoff\\',
    '^exports\\handoff\\'
)
$script:DemiDocumentForbiddenSegments = @('state','tools','.git','archive')
$script:DemiReservedNames = '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'

function Get-DemiDocumentPolicy {
    param([string]$Root)
    $policyPath = Join-Path $Root 'config\document-authoring-policy.json'
    if (-not (Test-Path -LiteralPath $policyPath)) {
        return [pscustomobject]@{
            allowedRoots=@('books\*\drafts\','canon\proposals\','research\reports\','collaboration\handoff\','exports\handoff\')
            allowedExtensions=$script:DemiDocumentAllowedExtensions
            forbiddenSegments=$script:DemiDocumentForbiddenSegments
            canonStatus='proposed'
        }
    }
    $policy = Get-Content -Raw -LiteralPath $policyPath -Encoding UTF8 | ConvertFrom-Json
    if ($policy.canonStatus -ne 'proposed') { throw 'Document policy canonStatus must remain proposed.' }
    return $policy
}

function Assert-DemiDocumentRelativePath {
    param([string]$Root, [string]$RelativePath)
    $policy = Get-DemiDocumentPolicy $Root
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { throw 'A project-relative destination is required.' }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) { throw 'Document destinations must be project-relative, not absolute.' }
    if ($RelativePath -match ':') { throw 'Document destinations may not contain alternate data streams or drive specifiers.' }
    $normalized = $RelativePath.Replace('/','\').TrimStart('\')
    $segments = @($normalized -split '\\')
    if ($segments -contains '..' -or $segments -contains '.') { throw 'Document destinations may not contain path traversal.' }
    if ($segments.Count -lt 2 -or $segments | Where-Object { [string]::IsNullOrWhiteSpace($_) }) { throw 'Document destination is malformed.' }
    foreach ($segment in $segments) {
        if ($segment.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "Invalid filename component '$segment'." }
        if ($segment -match $script:DemiReservedNames -or $segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            throw "Unsafe or reserved filename component '$segment'."
        }
    }
    if ($segments | Where-Object { $_ -in @($policy.forbiddenSegments) }) {
        throw 'Generated documents may not be written under state, tools, .git, or archive.'
    }
    $extension = [System.IO.Path]::GetExtension($normalized).ToLowerInvariant()
    if ($extension -notin @($policy.allowedExtensions)) {
        throw "Document extension '$extension' is not allowed. Allowed: .md, .txt, .docx."
    }
    $allowed = $false
    foreach ($allowedRoot in @($policy.allowedRoots)) {
        $regex = '^' + [regex]::Escape("$allowedRoot").Replace('\*','[^\\]+')
        if ($normalized -match $regex) { $allowed = $true; break }
    }
    if (-not $allowed) {
        throw "Destination '$normalized' is not under an approved document-authoring location."
    }
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $Root $normalized))
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not $fullPath.StartsWith($rootPath + '\',[System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Document destination resolves outside the authoritative project root.'
    }
    return [pscustomobject]@{ RelativePath = $normalized; FullPath = $fullPath; Extension = $extension }
}

function Assert-DemiNoReparseParents {
    param([string]$Root, [string]$Destination)
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $parent = Split-Path -Parent $Destination
    while ($parent -and $parent.StartsWith($rootPath,[System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $parent) {
            $item = Get-Item -LiteralPath $parent -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Document authoring rejects reparse-point parent '$parent'."
            }
        }
        if ([string]::Equals($parent,$rootPath,[System.StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = Split-Path -Parent $parent
    }
}

function New-DemiApprovedDirectory {
    param([string]$Root, [string]$Destination)
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $relativeParent = (Split-Path -Parent $Destination).Substring($rootPath.Length).TrimStart('\')
    $cursor = $rootPath
    foreach ($segment in @($relativeParent -split '\\')) {
        if (-not $segment) { continue }
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (-not $item.PSIsContainer) { throw "Document parent '$cursor' is not a directory." }
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Document authoring rejects reparse-point parent '$cursor'." }
        } else {
            [void][System.IO.Directory]::CreateDirectory($cursor)
        }
    }
}

function ConvertTo-DemiWordParagraphXml {
    param([string]$Content)
    $escaped = {
        param([string]$Value)
        [System.Security.SecurityElement]::Escape($Value)
    }
    $output = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Content -replace '\r\n?',"`n" -split "`n")) {
        $style = $null
        $text = $line
        if ($line -match '^(#{1,6})\s+(.+)$') {
            $style = "Heading$($Matches[1].Length)"
            $text = $Matches[2]
        } elseif ($line -match '^\s*[-+*]\s+(.+)$') {
            $style = 'ListParagraph'
            $text = "$([char]0x2022) $($Matches[1])"
        } elseif ($line -match '^\s*\d+[.)]\s+(.+)$') {
            $style = 'ListParagraph'
            $text = $line.Trim()
        }
        $property = if ($style) { "<w:pPr><w:pStyle w:val=`"$style`"/></w:pPr>" } else { '' }
        $value = & $escaped $text
        $output.Add("<w:p>$property<w:r><w:t xml:space=`"preserve`">$value</w:t></w:r></w:p>")
    }
    return $output -join ''
}

function New-DemiDocxBytes {
    param([string]$Content)
    Add-Type -AssemblyName System.IO.Compression
    $memory = [System.IO.MemoryStream]::new()
    $archive = [System.IO.Compression.ZipArchive]::new($memory,[System.IO.Compression.ZipArchiveMode]::Create,$true)
    try {
        $parts = [ordered]@{
            '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>'
            '_rels/.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
            'word/styles.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/></w:style><w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/></w:style><w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/></w:style></w:styles>'
            'word/document.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' + (ConvertTo-DemiWordParagraphXml $Content) + '<w:sectPr/></w:body></w:document>'
        }
        foreach ($part in $parts.GetEnumerator()) {
            $entry = $archive.CreateEntry($part.Key,[System.IO.Compression.CompressionLevel]::Optimal)
            $writer = [System.IO.StreamWriter]::new($entry.Open(),[System.Text.UTF8Encoding]::new($false))
            try { $writer.Write($part.Value) } finally { $writer.Dispose() }
        }
    } finally {
        $archive.Dispose()
    }
    return $memory.ToArray()
}

function Get-DemiDocumentBytes {
    param([string]$Extension, [string]$Content)
    if ($Extension -eq '.docx') { return New-DemiDocxBytes $Content }
    return [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
}

function Invoke-DemiCreateNewFile {
    param([string]$Path, [byte[]]$Bytes)
    $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
    try {
        $stream.Write($Bytes,0,$Bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Get-DemiVersionedRelativePath {
    param([string]$RelativePath, [int]$Version)
    $directory = Split-Path -Parent $RelativePath
    $extension = [System.IO.Path]::GetExtension($RelativePath)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($RelativePath) -replace '_v\d{3}$',''
    Join-Path $directory ('{0}_v{1:D3}{2}' -f $stem,$Version,$extension)
}

function Add-DemiDocumentAudit {
    param([string]$Root, [object]$Record)
    $auditDirectory = Join-Path $Root 'state\documents'
    [void][System.IO.Directory]::CreateDirectory($auditDirectory)
    $auditPath = Join-Path $auditDirectory 'creation-audit.jsonl'
    [System.IO.File]::AppendAllText($auditPath,($Record | ConvertTo-Json -Compress) + [Environment]::NewLine,[System.Text.UTF8Encoding]::new($false))
}

function Invoke-DemiCreateDocumentUnlocked {
    param(
        [string]$Root,
        [string]$RelativePath,
        [string]$Content,
        [string]$RequestEntry,
        [string]$Agent,
        [string]$Model,
        [string]$Source,
        [switch]$VersionIfExists
    )
    $candidate = $RelativePath
    $initialStem = [System.IO.Path]::GetFileNameWithoutExtension($RelativePath)
    $version = if ($initialStem -match '_v(\d{3})$') { [int]$Matches[1] } else { 0 }
    while ($true) {
        $validated = Assert-DemiDocumentRelativePath $Root $candidate
        Assert-DemiNoReparseParents $Root $validated.FullPath
        New-DemiApprovedDirectory $Root $validated.FullPath
        $bytes = Get-DemiDocumentBytes $validated.Extension $Content
        try {
            Invoke-DemiCreateNewFile $validated.FullPath $bytes
            break
        } catch [System.IO.IOException] {
            if (-not $VersionIfExists) {
                $suggestedVersion = $version + 1
                do {
                    $alternative = Get-DemiVersionedRelativePath $RelativePath $suggestedVersion
                    $alternativeFullPath = [System.IO.Path]::GetFullPath((Join-Path $Root $alternative))
                    $suggestedVersion++
                } while ((Test-Path -LiteralPath $alternativeFullPath) -and $suggestedVersion -le 1000)
                throw "Document already exists; nothing was overwritten: $candidate. Try the new version '$alternative'."
            }
            $version++
            if ($version -gt 999) { throw 'No available numbered document version was found.' }
            $candidate = Get-DemiVersionedRelativePath $RelativePath $version
        }
    }
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try { $sha256 = ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
    $record = [ordered]@{
        timestamp = [DateTimeOffset]::Now.ToString('o')
        requestingMiloEntry = $RequestEntry
        authoringAgent = $Agent
        model = $Model
        destination = $validated.RelativePath
        fileSize = $bytes.Length
        sha256 = $sha256
        source = $Source
        canonStatus = 'proposed'
    }
    Add-DemiDocumentAudit $Root $record
    return [pscustomobject]$record
}

function Invoke-DemiCreateDocument {
    param(
        [string]$Root,
        [string]$RelativePath,
        [string]$Content,
        [string]$RequestEntry,
        [string]$Agent,
        [string]$Model,
        [string]$Source,
        [switch]$VersionIfExists
    )
    $lockDirectory = Join-Path $Root 'state\documents'
    [void][System.IO.Directory]::CreateDirectory($lockDirectory)
    $lockPath = Join-Path $lockDirectory 'document.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $stream = $null
    while (-not $stream) {
        try {
            $stream = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Timed out waiting for the document-authoring lock.' }
            Start-Sleep -Milliseconds 100
        }
    }
    try {
        return Invoke-DemiCreateDocumentUnlocked $Root $RelativePath $Content $RequestEntry $Agent $Model $Source -VersionIfExists:$VersionIfExists
    } finally { $stream.Dispose() }
}

function Read-DemiZipEntryText {
    param([System.IO.Compression.ZipArchive]$Archive, [string]$Name)
    $entry = $Archive.GetEntry($Name)
    if (-not $entry) { return $null }
    $reader = [System.IO.StreamReader]::new($entry.Open(),[System.Text.Encoding]::UTF8,$true)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function ConvertFrom-DemiWordXml {
    param([string]$Xml, [string]$Label = 'Document')
    if ([string]::IsNullOrWhiteSpace($Xml)) { return '' }
    if ($Xml -match '(?i)<!DOCTYPE|<!ENTITY') { throw 'DOCX XML with external entity declarations is not supported.' }
    [xml]$document = $Xml
    $manager = [System.Xml.XmlNamespaceManager]::new($document.NameTable)
    $manager.AddNamespace('w','http://schemas.openxmlformats.org/wordprocessingml/2006/main')
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($node in $document.SelectNodes('//w:body/w:p|//w:body/w:tbl',$manager)) {
        if ($node.LocalName -eq 'tbl') {
            foreach ($row in $node.SelectNodes('.//w:tr',$manager)) {
                $cells = @($row.SelectNodes('./w:tc',$manager) | ForEach-Object { (@($_.SelectNodes('.//w:t',$manager) | ForEach-Object InnerText) -join '') })
                $lines.Add('| ' + ($cells -join ' | ') + ' |')
            }
            $lines.Add('')
            continue
        }
        $text = @($node.SelectNodes('.//w:t|.//w:delText',$manager) | ForEach-Object {
            if ($_.LocalName -eq 'delText') { "~~$($_.InnerText)~~" } else { $_.InnerText }
        }) -join ''
        $styleNode = $node.SelectSingleNode('./w:pPr/w:pStyle',$manager)
        $style = if ($styleNode) { $styleNode.GetAttribute('val','http://schemas.openxmlformats.org/wordprocessingml/2006/main') } else { '' }
        if ($style -match '^Heading([1-6])$') { $text = ('#' * [int]$Matches[1]) + ' ' + $text }
        elseif ($style -eq 'ListParagraph') { $text = '- ' + ($text -replace ('^' + [char]0x2022 + '\s*'),'') }
        $lines.Add($text)
        $lines.Add('')
    }
    return ($lines -join [Environment]::NewLine).Trim()
}

function ConvertFrom-DemiDocx {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $parts = [System.Collections.Generic.List[string]]::new()
        $parts.Add("Representation: normalized DOCX text; layout may not be preserved.")
        $parts.Add('')
        $parts.Add((ConvertFrom-DemiWordXml (Read-DemiZipEntryText $archive 'word/document.xml')))
        $documentXml = Read-DemiZipEntryText $archive 'word/document.xml'
        if ($documentXml -match '<w:(?:ins|del)\b') { $parts.Add("`n> Warning: tracked insertions/deletions were normalized; deletions are labeled with strikethrough markers.") }
        if ($documentXml -match '<m:oMath\b') { $parts.Add("`n> Warning: unsupported equation objects are present.") }
        if ($documentXml -match '<w:drawing\b|<w:pict\b') { $parts.Add("`n> Warning: image or drawing content is referenced but not visually interpreted.") }
        foreach ($extra in @(
            @{ Name='word/footnotes.xml'; Label='Footnotes' },
            @{ Name='word/endnotes.xml'; Label='Endnotes' },
            @{ Name='word/comments.xml'; Label='Comments' },
            @{ Name='word/header1.xml'; Label='Header' },
            @{ Name='word/footer1.xml'; Label='Footer' }
        )) {
            $xml = Read-DemiZipEntryText $archive $extra.Name
            if ($xml) {
                $parts.Add('')
                $parts.Add("## $($extra.Label)")
                $parts.Add((($xml -replace '<[^>]+>',' ' -replace '\s+',' ').Trim()))
            }
        }
        if (@($archive.Entries | Where-Object FullName -match '^word/embeddings/').Count) {
            $parts.Add("`n> Warning: unreadable embedded objects are present.")
        }
        return ($parts -join [Environment]::NewLine)
    } finally { $archive.Dispose() }
}

function ConvertFrom-DemiEpub {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $containerText = Read-DemiZipEntryText $archive 'META-INF/container.xml'
        if ($containerText -match '(?i)<!DOCTYPE|<!ENTITY') { throw 'EPUB XML with external entity declarations is not supported.' }
        [xml]$container = $containerText
        if ($archive.GetEntry('META-INF/encryption.xml')) { throw 'Encrypted or password-protected EPUB content is not supported.' }
        $packagePath = $container.container.rootfiles.rootfile.'full-path'
        if (-not $packagePath) { throw 'Malformed EPUB: package document not found.' }
        $packageText = Read-DemiZipEntryText $archive $packagePath
        if ($packageText -match '(?i)<!DOCTYPE|<!ENTITY') { throw 'EPUB package XML with external entity declarations is not supported.' }
        [xml]$package = $packageText
        $packageDirectory = Split-Path -Parent $packagePath
        $manifest = @{}
        foreach ($item in $package.package.manifest.item) { $manifest["$($item.id)"] = "$($item.href)" }
        $output = [System.Collections.Generic.List[string]]::new()
        $output.Add('Representation: normalized EPUB spine text; layout, active content, and remote resources are omitted.')
        foreach ($reference in $package.package.spine.itemref) {
            $href = $manifest["$($reference.idref)"]
            if (-not $href) { continue }
            $entryPath = if ($packageDirectory) { ($packageDirectory.TrimEnd('/','\') + '/' + $href).Replace('\','/') } else { $href }
            $xhtml = Read-DemiZipEntryText $archive $entryPath
            if (-not $xhtml) { $output.Add("`n> Warning: missing spine item $href."); continue }
            $safe = $xhtml -replace '(?is)<script\b.*?</script>','' -replace '(?is)<style\b.*?</style>',''
            $safe = $safe -replace '(?is)<img\b[^>]*alt=["'']([^"'']*)["''][^>]*>','[Image: $1]'
            $safe = $safe -replace '(?is)<a\b[^>]*href=["'']https?://[^"'']*["''][^>]*>(.*?)</a>','$1 [remote link omitted]'
            $text = $safe -replace '(?i)</?(?:h1|h2|h3|p|div|li|blockquote|br)\b[^>]*>',"`n" -replace '<[^>]+>',''
            $text = [System.Net.WebUtility]::HtmlDecode($text) -replace '\n\s*\n\s*\n+',"`n`n"
            $output.Add("`n## EPUB chapter: $href`n")
            $output.Add($text.Trim())
        }
        return ($output -join [Environment]::NewLine)
    } finally { $archive.Dispose() }
}

function Get-DemiDocumentRepresentation {
    param([string]$Root, [string]$RelativePath)
    if ([System.IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)|:') { throw 'Document source must be a safe project-relative path.' }
    $source = [System.IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    if (-not $source.StartsWith(([System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'),[System.StringComparison]::OrdinalIgnoreCase)) { throw 'Document source resolves outside the project root.' }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Document source does not exist: $RelativePath" }
    Assert-DemiNoReparseParents $Root $source
    $sourceItem = Get-Item -LiteralPath $source -Force
    if (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Document ingestion rejects reparse-point source files.' }
    $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    $cacheDirectory = Join-Path $Root 'state\document-cache'
    [void][System.IO.Directory]::CreateDirectory($cacheDirectory)
    $pathHasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $pathHash = ([BitConverter]::ToString($pathHasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($RelativePath.ToLowerInvariant())))).Replace('-','').ToLowerInvariant().Substring(0,16)
    } finally { $pathHasher.Dispose() }
    $cachePath = Join-Path $cacheDirectory "$pathHash-$hash.md"
    if (Test-Path -LiteralPath $cachePath) { return [pscustomobject]@{ Path=$cachePath; Hash=$hash; Cached=$true } }
    $extension = [System.IO.Path]::GetExtension($source).ToLowerInvariant()
    $representation = switch ($extension) {
        '.md' { "Representation: source Markdown (UTF-8).`n`n" + [System.IO.File]::ReadAllText($source,[System.Text.Encoding]::UTF8) }
        '.txt' { "Representation: source plain text (UTF-8).`n`n" + [System.IO.File]::ReadAllText($source,[System.Text.Encoding]::UTF8) }
        '.docx' { ConvertFrom-DemiDocx $source }
        '.epub' { ConvertFrom-DemiEpub $source }
        '.pdf' {
            $python = @($env:DEMI_PYTHON,(Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'),(Get-Command python -ErrorAction SilentlyContinue).Source) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
            if(-not $python){throw 'PDF ingestion requires Python with pypdf; no compatible local runtime was found.'}
            $output = & $python (Join-Path $Root 'tools\extract_pdf.py') $source 2>&1
            if($LASTEXITCODE -ne 0){throw "PDF extraction failed: $($output -join [Environment]::NewLine)"}
            $output -join [Environment]::NewLine
        }
        default { throw "Unsupported document source extension '$extension'." }
    }
    try { Invoke-DemiCreateNewFile $cachePath ([System.Text.UTF8Encoding]::new($false).GetBytes($representation)) }
    catch [System.IO.IOException] {
        if (-not (Test-Path -LiteralPath $cachePath)) { throw }
    }
    return [pscustomobject]@{ Path=$cachePath; Hash=$hash; Cached=$false; Representation=$representation }
}
