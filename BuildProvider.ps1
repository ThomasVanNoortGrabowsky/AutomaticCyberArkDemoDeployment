<#
.SYNOPSIS
  Build the terraform-provider-vmworkstation plugin from source.

.DESCRIPTION
  1. Uses the script directory (or specified path) as the provider source directory.
  2. Removes any old build of terraform-provider-vmworkstation.exe.
  3. Runs `go build` to compile the plugin.
  4. Verifies the binary exists.
  5. Runs the binary with `-help` to check it’s valid.

.PARAMETER ProjectDir
  (Optional) Path to the cloned terraform-provider-vmworkstation repository.
  Defaults to the directory where this script resides.

.EXAMPLE
  .\BuildProvider.ps1
    Builds using the current script folder as source.

.EXAMPLE
  .\BuildProvider.ps1 -ProjectDir "D:\Code\vmworkstation"
    Builds using the given folder as source.
#>

param(
    [string]$ProjectDir = $PSScriptRoot
)

# 1. Ensure project directory exists
if (-not (Test-Path $ProjectDir -PathType Container)) {
    Write-Error "Project directory '$ProjectDir' not found. Please clone the repo there first or specify -ProjectDir."
    exit 1
}

# 2. Verify this looks like the provider source
if (-not (Test-Path (Join-Path $ProjectDir 'go.mod'))) {
    Write-Warning "No go.mod found in '$ProjectDir'. Are you sure this is the provider source folder?"
}

Push-Location $ProjectDir

# 3. Remove old binary if present
$exe = 'terraform-provider-vmworkstation.exe'
if (Test-Path $exe) {
    Write-Host "Removing existing $exe..." -ForegroundColor Yellow
    Remove-Item $exe -Force
}

# 4. Build the provider
Write-Host "Running: go build -o $exe" -ForegroundColor Cyan
go build -o $exe
if ($LASTEXITCODE -ne 0) {
    Write-Error "go build failed (exit code $LASTEXITCODE)."
    Pop-Location
    exit 1
}

# 5. Verify the binary exists
if (-not (Test-Path $exe)) {
    Write-Error "Build succeeded but $exe not found."
    Pop-Location
    exit 1
}

Write-Host "Build succeeded: $exe" -ForegroundColor Green

# 6. Sanity check the binary
Write-Host "`nVerifying with '$exe -help'..." -ForegroundColor Cyan
& .\$exe -help

Pop-Location

Write-Host "`nDone. The provider binary is ready in '$ProjectDir'." -ForegroundColor Green
