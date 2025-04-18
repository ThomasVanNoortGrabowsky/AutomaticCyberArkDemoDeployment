<#
.SYNOPSIS
  Build the terraform-provider-vmworkstation plugin from source.

.DESCRIPTION
  1. Detects the provider source directory (from -ProjectDir or defaults).
  2. Removes any old build of terraform-provider-vmworkstation.exe.
  3. Runs `go build` to compile the plugin.
  4. Verifies the binary exists.
  5. Runs the binary with `-help` to check it’s valid.

.PARAMETER ProjectDir
  Optional: explicitly specify the provider source directory.
  If omitted, the script will look in:
    A) $env:GOPATH\src\github.com\elsudano\terraform-provider-vmworkstation
    B) A subfolder named "terraform-provider-vmworkstation" under $PSScriptRoot
  and pick the first containing go.mod.

.EXAMPLE
  .\BuildProvider.ps1
  (Detects and builds from your GOPATH or subfolder.)

.EXAMPLE
  .\BuildProvider.ps1 -ProjectDir "D:\Code\terraform-provider-vmworkstation"
  (Forces use of that folder.)
#>

param(
    [string]$ProjectDir = ''
)

# Auto‑detect if none provided
if (-not $ProjectDir) {
    $gopathRepo = Join-Path $env:GOPATH 'src\github.com\elsudano\terraform-provider-vmworkstation'
    $subfolderRepo = Join-Path $PSScriptRoot 'terraform-provider-vmworkstation'

    if ($env:GOPATH -and (Test-Path (Join-Path $gopathRepo 'go.mod'))) {
        $ProjectDir = $gopathRepo
    }
    elseif (Test-Path (Join-Path $subfolderRepo 'go.mod')) {
        $ProjectDir = $subfolderRepo
    }
    else {
        Write-Error "Cannot locate terraform-provider-vmworkstation source. Use -ProjectDir to specify it."
        exit 1
    }
}

Write-Host "Building provider from: $ProjectDir" -ForegroundColor Cyan

# Validate
if (-not (Test-Path $ProjectDir -PathType Container)) {
    Write-Error "Directory not found: $ProjectDir"
    exit 1
}
if (-not (Test-Path (Join-Path $ProjectDir 'go.mod'))) {
    Write-Warning "No go.mod in $
