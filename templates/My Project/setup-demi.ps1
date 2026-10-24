[CmdletBinding()]
param([string]$ProjectRoot,[string]$RuntimeRoot,[string]$OwnerName='Owner',[string]$ProjectName='Demi project',[switch]$InstallProfileCommand,[switch]$Force)
$a=@{};foreach($key in $PSBoundParameters.Keys){$a[$key]=$PSBoundParameters[$key]};if(-not$a.ContainsKey('ProjectRoot')){$a.ProjectRoot=$PSScriptRoot}
& (Join-Path $PSScriptRoot 'tools\setup-demi.ps1') @a