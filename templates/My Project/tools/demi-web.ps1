[CmdletBinding()]
param(
    [ValidateSet('start','status','stop','lan','local','firewall','pair','devices','revoke')]
    [string]$Action = 'start',
    [string]$Device,
    [int]$Port = 0,
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'demi-root.ps1')
$root = Assert-DemiProjectRoot $(if ($ProjectRoot) { $ProjectRoot } else { Get-DemiProjectRootFromToolsDirectory $PSScriptRoot })
$webRoot = Join-Path $root 'state\web'
$stateFile = Join-Path $webRoot 'server.json'
$serverScript = Join-Path $root 'tools\web\server.js'
foreach ($path in @($webRoot, $stateFile)) { Assert-DemiWritePath $path 'Demi web state' | Out-Null }

function Get-DemiWebState {
    if (-not (Test-Path -LiteralPath $stateFile)) { return $null }
    try { return Get-Content -Raw -LiteralPath $stateFile -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Test-DemiWebServer {
    param([object]$State)
    if (-not $State -or "$($State.host)" -notin @('127.0.0.1','0.0.0.0') -or -not $State.port -or -not $State.pid) { return $false }
    try {
        $process = Get-Process -Id ([int]$State.pid) -ErrorAction Stop
        if ($process.ProcessName -notmatch '^node') { return $false }
        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$($State.port)/api/bootstrap" -TimeoutSec 2
        return $response.StatusCode -eq 200
    } catch { return $false }
}

$existing = Get-DemiWebState
$healthy = Test-DemiWebServer $existing
if ($existing -and -not $healthy) {
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    $existing = $null
}

$requestedOperation = $Action
$requestedMode = if ($Action -in @('lan','pair')) { 'lan' } elseif ($Action -eq 'local') { 'local' } else { $null }
if ($Port -lt 0 -or $Port -gt 65535) { throw 'Port must be an integer from 1 through 65535, or omitted for the default.' }
$requestedPort = if ($Port -gt 0) { $Port } else { 51567 }
if ($requestedMode) {
    $currentMode = if ($existing -and $existing.PSObject.Properties['mode']) { "$($existing.mode)" } else { 'local' }
    $portChanged = $healthy -and $requestedPort -gt 0 -and [int]$existing.port -ne $requestedPort
    if ($healthy -and ($currentMode -ne $requestedMode -or $portChanged)) {
        Stop-Process -Id ([int]$existing.pid) -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ((Get-Process -Id ([int]$existing.pid) -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
        if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force }
        $existing = $null
        $healthy = $false
    }
    $Action = 'start'
}

switch ($Action) {
    'status' {
        if ($healthy) {
            $mode = if ($existing.PSObject.Properties['mode']) { "$($existing.mode)" } else { 'local' }
            Write-Output "Demi web is running in $mode mode at http://127.0.0.1:$($existing.port)/ (PID $($existing.pid))."
            foreach ($lanUrl in @($existing.lanUrls)) { Write-Output "Phone: $lanUrl" }
            if ($existing.PSObject.Properties['friendlyUrl'] -and $existing.friendlyUrl) { Write-Output "Phone name (when supported by the network): $($existing.friendlyUrl)" }
            if ($mode -eq 'lan') { Write-Output 'Previously paired devices can connect directly. Run demi web pair to authorize a new device.' }
        }
        else { Write-Output 'Demi web is not running.' }
    }
    'devices' {
        if ($healthy) {
            $origin = "http://127.0.0.1:$($existing.port)"
            $headers = @{ 'X-Demi-Token' = "$($existing.token)"; Origin = $origin }
            $result = Invoke-RestMethod -Method Get -Uri "$origin/api/admin/devices" -Headers $headers -TimeoutSec 5
            $devices = @($result.devices)
        } else {
            $deviceFile = Join-Path $webRoot 'devices.json'
            $devices = if (Test-Path -LiteralPath $deviceFile) { @((Get-Content -Raw -LiteralPath $deviceFile -Encoding UTF8 | ConvertFrom-Json).devices) } else { @() }
        }
        if (-not $devices.Count) { Write-Output 'No phones or other LAN devices are paired with Demi.'; return }
        foreach ($item in $devices) {
            Write-Output ("{0}  {1}  last seen {2}  expires {3}" -f $item.id,$item.name,$item.lastSeenAt,$item.expiresAt)
        }
    }
    'revoke' {
        if (-not $Device) { throw 'Usage: demi web revoke <device-id>' }
        if (-not $healthy) { throw 'Start Demi web before revoking a paired device.' }
        $origin = "http://127.0.0.1:$($existing.port)"
        $headers = @{ 'X-Demi-Token' = "$($existing.token)"; Origin = $origin }
        $body = @{ id = $Device } | ConvertTo-Json -Compress
        $result = Invoke-RestMethod -Method Post -Uri "$origin/api/admin/revoke" -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 5
        Write-Output "Revoked $($result.revoked.name) ($($result.revoked.id)). That device must pair again before it can use Demi."
    }
    'firewall' {
        $firewallPort = if ($Port -gt 0) { $Port } else { 51567 }
        $ruleName = 'Demi Web (Private LAN)'
        $nodePath = (Get-Command node -ErrorAction Stop).Source
        $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if ($existingRule) {
            $existingRule | Remove-NetFirewallRule -ErrorAction Stop
        }
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $firewallPort -Program $nodePath -Profile Private -RemoteAddress LocalSubnet -ErrorAction Stop | Out-Null
        Write-Output "Configured Windows Firewall rule '$ruleName' for the local subnet on private networks, TCP port $firewallPort, Node.js only."
    }
    'stop' {
        if (-not $healthy) { Write-Output 'Demi web is not running.'; return }
        Stop-Process -Id ([int]$existing.pid) -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ((Get-Process -Id ([int]$existing.pid) -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
        if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force }
        Write-Output 'Demi web stopped. Collaboration and dispatcher state were not changed.'
    }
    'start' {
        if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Node.js is required for demi web but was not found on PATH.' }
        if (-not $healthy) {
            if (-not (Test-Path -LiteralPath $webRoot)) { New-Item -ItemType Directory -Path $webRoot | Out-Null }
            $nodePath = (Get-Command node).Source
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $nodePath
            $startInfo.Arguments = '"' + ($serverScript -replace '"', '\"') + '"'
            $startInfo.WorkingDirectory = $root
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
            $modeToStart = if ($requestedMode) { $requestedMode } else { 'local' }
            $startInfo.EnvironmentVariables['DEMI_WEB_MODE'] = $modeToStart
            $startInfo.EnvironmentVariables['DEMI_WEB_PORT'] = "$requestedPort"
            $serverProcess = [System.Diagnostics.Process]::Start($startInfo)
            if (-not $serverProcess) { throw 'Node.js did not start.' }
            $serverProcess.Dispose()
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            do {
                Start-Sleep -Milliseconds 100
                $existing = Get-DemiWebState
                $healthy = Test-DemiWebServer $existing
            } while (-not $healthy -and [DateTime]::UtcNow -lt $deadline)
            if (-not $healthy) {
                throw 'Demi web did not start. Run node tools\web\server.js in a console for diagnostic output.'
            }
        }
        if ($requestedOperation -eq 'pair') {
            $origin = "http://127.0.0.1:$($existing.port)"
            $headers = @{ 'X-Demi-Token' = "$($existing.token)"; Origin = $origin }
            $pairing = Invoke-RestMethod -Method Post -Uri "$origin/api/admin/pairing" -Headers $headers -ContentType 'application/json' -Body '{}' -TimeoutSec 5
            Write-Output ''
            Write-Output "Demi phone pairing code: $($pairing.code)"
            Write-Output 'The code expires in ten minutes and works once.'
            foreach ($phoneUrl in @($pairing.phoneUrls)) { Write-Output "On the phone, open: $phoneUrl" }
            if ($pairing.friendlyUrl) { Write-Output "Or, when supported by the network: $($pairing.friendlyUrl)" }
            Write-Output 'Enter the code, optionally name the phone, and then bookmark the plain address. Future server restarts will not require another code for that paired browser.'
            return
        }
        # Use the literal IPv4 loopback address. Some browsers prefer ::1 for
        # localhost even though Demi's local listener is intentionally IPv4.
        $url = "http://127.0.0.1:$($existing.port)/"
        $browserInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $browserInfo.FileName = $url
        $browserInfo.UseShellExecute = $true
        $browserProcess = [System.Diagnostics.Process]::Start($browserInfo)
        if ($browserProcess) { $browserProcess.Dispose() }
        $mode = if ($existing.PSObject.Properties['mode']) { "$($existing.mode)" } else { 'local' }
        Write-Output "Opened Demi web in $mode mode at $url"
        foreach ($lanUrl in @($existing.lanUrls)) { Write-Output "Phone: $lanUrl" }
        if ($existing.PSObject.Properties['friendlyUrl'] -and $existing.friendlyUrl) { Write-Output "Phone name (when supported by the network): $($existing.friendlyUrl)" }
        if ($mode -eq 'lan') {
            Write-Output 'Previously paired devices can connect directly. Run demi web pair to authorize a new device.'
            Write-Output 'If the phone cannot connect, run demi web firewall once from an Administrator PowerShell window.'
        }
    }
}
