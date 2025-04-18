<#
.SYNOPSIS
  Build the terraform-provider-vmworkstation plugin from source.

.DESCRIPTION
  1. Navigates to the provider source directory.
  2. Removes any old build of terraform-provider-vmworkstation.exe.
  3. Runs `go build` to compile the plugin.
  4. Verifies the binary exists.
  5. Runs the binary with `-help` to check it’s valid.

.PARAMETER ProjectDir
  Path to the cloned terraform-provider-vmworkstation repo.
  Defaults to $env:GOPATH\src\github.com\elsudano\terraform-provider-vmworkstation.

.EXAMPLE
  .\BuildProvider.ps1
#>

param(
    [string]$ProjectDir = (Join-Path $env:GOPATH "src\github.com\elsudano\terraform-provider-vmworkstation")
)

# 1. Ensure project directory exists
if (-not (Test-Path $ProjectDir -PathType Container)) {
    Write-Error "Project directory '$ProjectDir' not found."
    exit 1
}

# Remember current location, switch to project
Push-Location $ProjectDir

# 2. Remove old binary if present
$exe = "terraform-provider-vmworkstation.exe"
if (Test-Path $exe) {
    Write-Host "Removing existing $exe..." -ForegroundColor Yellow
    Remove-Item $exe -Force
}

# 3. Build the provider
Write-Host "Running: go build -o $exe" -ForegroundColor Cyan
go build -o $exe
if ($LASTEXITCODE -ne 0) {
    Write-Error "go build failed (exit code $LASTEXITCODE)."
    Pop-Location
    exit 1
}

# 4. Verify the binary exists
if (-not (Test-Path $exe)) {
    Write-Error "Build succeeded but $exe not found."
    Pop-Location
    exit 1
}

Write-Host "Build succeeded: $exe" -ForegroundColor Green

# 5. Sanity check the binary
Write-Host "`nVerifying with '$exe -help'..." -ForegroundColor Cyan
& .\terraform-provider-vmworkstation.exe -help

# Return to original folder
Pop-Location

Write-Host "`nDone. The provider binary is ready in $ProjectDir." -ForegroundColor Green
