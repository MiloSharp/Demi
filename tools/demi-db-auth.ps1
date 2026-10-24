Set-StrictMode -Version Latest

function Get-DemiDatabasePassword {
    $localRoot=Join-Path $env:LOCALAPPDATA 'Demiurge'
    $credentialPath=Join-Path $localRoot 'database-credential.clixml'
    try {
        if(Test-Path -LiteralPath $credentialPath -PathType Leaf){return (Import-Clixml -LiteralPath $credentialPath).GetNetworkCredential().Password}
    } catch {}
    $passFile=Join-Path $localRoot 'database.pgpass'
    if(Test-Path -LiteralPath $passFile -PathType Leaf){
        $line=(Get-Content -LiteralPath $passFile -Encoding UTF8|Where-Object{$_-and-not$_.StartsWith('#')}|Select-Object -First 1)
        if($line){$parts=$line.Split(':');if($parts.Count-ge5){return ($parts[4..($parts.Count-1)]-join':')}}
    }
    throw "Demi's local database credential is unavailable. Run tools\demi-db.ps1 provision."
}

function Write-DemiDatabasePassFile {
    param([Parameter(Mandatory)][object]$Database,[Parameter(Mandatory)][string]$Password)
    $localRoot=Join-Path $env:LOCALAPPDATA 'Demiurge';[void][IO.Directory]::CreateDirectory($localRoot)
    $passFile=Join-Path $localRoot 'database.pgpass'
    $line="$($Database.host):$($Database.port):$($Database.database):$($Database.applicationUser):$Password"
    [IO.File]::WriteAllText($passFile,$line+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    try {
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls.exe $passFile '/inheritance:r' '/grant:r' "${identity}:(F)" '/grant:r' '*S-1-5-18:(F)' | Out-Null
        $profileIdentity="$env:COMPUTERNAME\$env:USERNAME"
        if($profileIdentity-ne$identity){& icacls.exe $passFile '/grant:r' "${profileIdentity}:(F)"|Out-Null}
        $sandboxGroup="$env:COMPUTERNAME\CodexSandboxUsers"
        if([Security.Principal.NTAccount]::new($sandboxGroup).Translate([Security.Principal.SecurityIdentifier])){
            & icacls.exe $passFile '/grant:r' "${sandboxGroup}:(R)" | Out-Null
        }
    } catch { Write-Warning "Could not tighten the PostgreSQL password-file ACL: $($_.Exception.Message)" }
    return $passFile
}
