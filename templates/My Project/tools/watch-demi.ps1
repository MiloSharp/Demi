[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [int]$PollSeconds = 5,
    [switch]$NoBeep,
    [switch]$NoToast
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'demi-root.ps1')
$installedProjectRoot = Get-DemiProjectRootFromToolsDirectory $PSScriptRoot

function Get-Context {
    $root = if ($ProjectRoot) {
        Assert-DemiProjectRoot (Resolve-Path -LiteralPath $ProjectRoot).Path
    } else {
        $installedProjectRoot
    }
    $pointer = Join-Path $root '.demi-runtime-path'
    if (Test-Path -LiteralPath $pointer) {
        $runtime = (Get-Content -Raw -LiteralPath $pointer -Encoding UTF8).Trim()
        return [pscustomobject]@{ ProjectRoot = $root; RuntimeRoot = $runtime }
    }
    if (Test-Path -LiteralPath (Join-Path $root 'state\collaboration.json')) {
        return [pscustomobject]@{ ProjectRoot = $root; RuntimeRoot = $root }
    }
    throw 'Pass -ProjectRoot or run this watcher from an installed Demiurge toolkit.'
}

function Get-State([object]$Context) {
    $path = if ($Context.RuntimeRoot -eq $Context.ProjectRoot) {
        Join-Path $Context.ProjectRoot 'state\collaboration.json'
    } else {
        Join-Path $Context.RuntimeRoot 'collaboration.json'
    }
    Get-Content -Raw -LiteralPath $path -Encoding UTF8 |
        ConvertFrom-Json
}

function Get-LastEntry([string]$Path) {
    $match = Select-String -LiteralPath $Path -Pattern '^## (S\d{3}-([MCRS])\d{4}) - (.+)$' |
        Select-Object -Last 1
    if (-not $match) { return $null }
    [pscustomobject]@{
        Id = $match.Matches[0].Groups[1].Value
        Code = $match.Matches[0].Groups[2].Value
        Author = $match.Matches[0].Groups[3].Value
    }
}

function Show-DeliveryToast([string]$Title, [string]$Message) {
    if ($NoToast) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $icon = [System.Windows.Forms.NotifyIcon]::new()
        $icon.Icon = [System.Drawing.SystemIcons]::Information
        $icon.Visible = $true
        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText = $Message
        $icon.ShowBalloonTip(4000)
        Start-Sleep -Milliseconds 4500
        $icon.Dispose()
    } catch {
        # Console notification remains available when Windows notifications are unavailable.
    }
}

$context = Get-Context
$root = $context.ProjectRoot
$state = Get-State $context
$sessionPath = Join-Path $root $state.currentSession
$last = Get-LastEntry $sessionPath
$lastSeen = if ($last) { $last.Id } else { '' }
$lastWrite = (Get-Item -LiteralPath $sessionPath).LastWriteTimeUtc
$logPath = if ($context.RuntimeRoot -eq $root) {
    Join-Path $root 'state\notifications.log'
} else {
    Join-Path $context.RuntimeRoot 'notifications.log'
}
Assert-DemiWritePath $logPath 'collaboration notification log' | Out-Null

Write-Host "Watching $sessionPath"
Write-Host 'Press Ctrl+C to stop.'

while ($true) {
    Start-Sleep -Seconds $PollSeconds
    $state = Get-State $context
    $currentPath = Join-Path $root $state.currentSession
    if ($currentPath -ne $sessionPath) {
        $sessionPath = $currentPath
        $lastWrite = [DateTime]::MinValue
        $lastSeen = ''
        Write-Host "Now watching $sessionPath"
    }
    $item = Get-Item -LiteralPath $sessionPath
    if ($item.LastWriteTimeUtc -le $lastWrite) { continue }
    $lastWrite = $item.LastWriteTimeUtc
    $entry = Get-LastEntry $sessionPath
    if (-not $entry -or $entry.Id -eq $lastSeen) { continue }
    $lastSeen = $entry.Id
    if ($entry.Code -eq 'M') { continue }
    $message = "$($entry.Author) added $($entry.Id). Round $($state.round.id): $($state.round.remainingResponses) responses remain."
    $line = '[{0}] {1}' -f [DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss'), $message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Host $line -ForegroundColor Cyan
    if (-not $NoBeep) {
        try { [Console]::Beep(880, 180) } catch {}
    }
    Show-DeliveryToast 'Demiurge collaboration update' $message
}
