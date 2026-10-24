[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DemiArguments)
$settingsPath = Join-Path $env:LOCALAPPDATA 'Demi\settings.json'
if (-not (Test-Path -LiteralPath $settingsPath)) { throw "Demi settings were not found at $settingsPath." }
$settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
$project = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$settings.defaultProject))
$node = Join-Path $PSScriptRoot '..\runtime\node.exe'
if (-not (Test-Path -LiteralPath $node)) { $node = (Get-Command node -ErrorAction Stop).Source }
$entry = Join-Path $project 'tools\demi.js'
if (-not (Test-Path -LiteralPath $entry)) { throw "Demi project tools were not found at $entry." }
& $node $entry @DemiArguments
exit $LASTEXITCODE