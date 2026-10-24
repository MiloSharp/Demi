Set-StrictMode -Version Latest

function Get-DemiStorageConfiguration {
    param([Parameter(Mandatory)][string]$Root)
    $path = Join-Path $Root 'config\storage.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            schemaVersion = 1
            backend = 'files'
            fallback = 'files'
            projectSlug = 'demiurge'
            mirrorWrites = $false
            allowAutomaticStartupFallback = $true
            allowAutomaticMidSessionFallback = $false
            exportMarkdownTranscripts = $true
        }
    }
    $configuration = Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($configuration.backend -notin @('files','postgresql')) { throw "Unsupported Demi storage backend '$($configuration.backend)'." }
    if ($configuration.fallback -notin @('none','files')) { throw "Unsupported Demi storage fallback '$($configuration.fallback)'." }
    if ($configuration.backend -eq 'files' -and [bool]$configuration.mirrorWrites) { throw 'Storage mirroring requires PostgreSQL to be the configured destination.' }
    return $configuration
}

function Get-DemiStorageCapabilities {
    param([Parameter(Mandatory)][string]$Root)
    $configuration = Get-DemiStorageConfiguration -Root $Root
    [pscustomobject]@{
        backend = $configuration.backend
        fallback = $configuration.fallback
        structuredMemory = ($configuration.backend -eq 'postgresql')
        concurrentUsers = ($configuration.backend -eq 'postgresql')
        binaryStorage = 'filesystem'
        markdownTranscriptExport = [bool]$configuration.exportMarkdownTranscripts
    }
}

function Resolve-DemiStorageBackend {
    param(
        [Parameter(Mandatory)][string]$Root,
        [scriptblock]$PostgreSqlHealthCheck,
        [switch]$Startup
    )
    $configuration = Get-DemiStorageConfiguration -Root $Root
    if ($configuration.backend -eq 'files') {
        return [pscustomobject]@{ requested='files'; active='files'; degraded=$false; reason=$null }
    }
    $healthy = $false
    $reason = $null
    try {
        if (-not $PostgreSqlHealthCheck) { throw 'No PostgreSQL health check was supplied.' }
        $healthy = [bool](& $PostgreSqlHealthCheck)
        if (-not $healthy) { $reason = 'PostgreSQL health check did not succeed.' }
    } catch { $reason = $_.Exception.Message }
    if ($healthy) { return [pscustomobject]@{ requested='postgresql'; active='postgresql'; degraded=$false; reason=$null } }
    $mayFallback = $configuration.fallback -eq 'files' -and $Startup -and [bool]$configuration.allowAutomaticStartupFallback
    if ($mayFallback) { return [pscustomobject]@{ requested='postgresql'; active='files'; degraded=$true; reason=$reason } }
    throw "PostgreSQL storage is unavailable. $reason File fallback was not activated because a live-session transition must be explicit."
}

function Test-DemiPostgreSqlStorage {
    param([Parameter(Mandatory)][string]$Root)
    $tool = Join-Path $Root 'tools\demi-db.ps1'
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { return $false }
    try {
        $raw = & $tool status 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        $status = ($raw -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
        return [bool]$status.healthy
    } catch { return $false }
}

function Get-DemiStorageStatus {
    param([Parameter(Mandatory)][string]$Root)
    $configuration = Get-DemiStorageConfiguration -Root $Root
    $postgresHealthy = Test-DemiPostgreSqlStorage -Root $Root
    $selection = if ($configuration.backend -eq 'files') {
        Resolve-DemiStorageBackend -Root $Root
    } else {
        Resolve-DemiStorageBackend -Root $Root -Startup -PostgreSqlHealthCheck { $postgresHealthy }
    }
    $pendingRoot = Join-Path $Root 'state\storage-recovery'
    $pending = if (Test-Path -LiteralPath $pendingRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $pendingRoot -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    } else { 0 }
    [pscustomobject]@{
        configuredBackend = $configuration.backend
        activeBackend = $selection.active
        fallback = $configuration.fallback
        degraded = [bool]$selection.degraded
        postgreSqlHealthy = $postgresHealthy
        binaryStorage = 'filesystem'
        pendingRecoveryOperations = $pending
        mirrorWrites = [bool]$configuration.mirrorWrites
        reason = $selection.reason
    }
}

function New-DemiStorageOperation {
    param(
        [Parameter(Mandatory)][ValidateSet('create-session','append-message','update-runtime-state','save-summary','assign-silo','record-claim')][string]$Kind,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][object]$Payload
    )
    [pscustomobject]@{
        schemaVersion = 1
        operationId = $OperationId
        kind = $Kind
        payload = $Payload
        createdAt = [DateTimeOffset]::Now.ToString('o')
    }
}

function Write-DemiRecoveryOperation {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][object]$Operation)
    $journalRoot = Join-Path $Root 'state\storage-recovery'
    [void][IO.Directory]::CreateDirectory($journalRoot)
    $safeId = "$($Operation.operationId)" -replace '[^A-Za-z0-9._-]','_'
    if (-not $safeId) { throw 'A recovery operation requires a safe operation ID.' }
    $path = Join-Path $journalRoot "$safeId.json"
    $temp = "$path.$PID.tmp"
    try {
        [IO.File]::WriteAllText($temp,($Operation | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp,$path,$true)
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force }
    }
    return $path
}
