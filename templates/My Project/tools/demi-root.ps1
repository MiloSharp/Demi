Set-StrictMode -Version Latest

$script:DemiAuthoritativeProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Get-DemiNormalizedPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Assert-DemiProjectRoot {
    param(
        [Parameter(Mandatory)]
        [string]$ActualRoot
    )

    $resolvedActual = Get-DemiNormalizedPath $ActualRoot
    $resolvedAuthoritative = Get-DemiNormalizedPath $script:DemiAuthoritativeProjectRoot
    if (-not [string]::Equals(
        $resolvedActual,
        $resolvedAuthoritative,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Demiurge project-root preflight failed. Resolved project root '$resolvedActual' is not the authoritative root '$resolvedAuthoritative'. No writes were performed."
    }

    return $resolvedAuthoritative
}

function Get-DemiProjectRootFromToolsDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$ToolsDirectory
    )

    $actualRoot = [System.IO.Path]::GetFullPath((Join-Path $ToolsDirectory '..'))
    return Assert-DemiProjectRoot $actualRoot
}

function Assert-DemiWritePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Purpose = 'project data'
    )

    $root = Get-DemiNormalizedPath $script:DemiAuthoritativeProjectRoot
    $resolvedPath = Get-DemiNormalizedPath $Path
    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    $insideRoot = [string]::Equals(
        $resolvedPath,
        $root,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or $resolvedPath.StartsWith(
        $rootPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )

    if (-not $insideRoot) {
        throw "Demiurge write preflight failed. $Purpose path '$resolvedPath' is outside the authoritative project root '$root'. No writes were performed."
    }

    return $resolvedPath
}
