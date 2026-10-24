[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\Program Files\Demi',
    [string]$ProjectsRoot = "$env:USERPROFILE\Documents\Demi Projects",
    [string]$ProjectName = 'My Project',
    [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=[Security.Principal.WindowsPrincipal]::new($identity)
if(-not$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Run "Install Demi.cmd" to approve the Windows administrator prompt.'
}
$source=[IO.Path]::GetFullPath($PSScriptRoot)
$dataRoot=Join-Path $env:LOCALAPPDATA 'Demi'
$projectTarget=Join-Path $ProjectsRoot $ProjectName
New-Item -ItemType Directory -Path $InstallRoot,$dataRoot,$ProjectsRoot -Force|Out-Null
foreach($name in @('app','tools','database','runtime','templates','Demi.cmd','Start Demi.cmd','LICENSE','NOTICE','README.md','VERSION')){
    $item=Join-Path $source $name
    if(Test-Path -LiteralPath $item){Copy-Item -LiteralPath $item -Destination $InstallRoot -Recurse -Force}
}
foreach($folder in @('credentials','logs','backups')){New-Item -ItemType Directory -Path (Join-Path $dataRoot $folder)-Force|Out-Null}
if(-not(Test-Path -LiteralPath $projectTarget)){
    Copy-Item -LiteralPath (Join-Path $source 'templates\My Project') -Destination $projectTarget -Recurse -Force
}elseif($Force){
    throw 'For safety, the installer will not replace an existing project. Choose a different -ProjectName or back up and remove the existing folder yourself.'
}
$settings=[ordered]@{schemaVersion=1;version=(Get-Content -Raw -LiteralPath (Join-Path $source 'VERSION')).Trim();projectsRoot=$ProjectsRoot;defaultProject=$projectTarget}
$settings|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $dataRoot 'settings.json') -Encoding utf8
Write-Host "Demi installed at $InstallRoot"
Write-Host "Starter project: $projectTarget"
Write-Host "Run: & '$InstallRoot\Demi.cmd' web"