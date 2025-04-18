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
  Path to the cloned terraform-provider-vmworkstation repository.
  Defaults to $env:GOPATH\src\github.com\elsudano\terraform-provider-vmworkstation.

.EXAMPLE
  .\build-provider.ps1
  Builds using the default GOPATH location.

.EXAMPLE
  .\build-provider.ps1 -ProjectDir "D:\Code\vmworkstation"
#>

param(
    [string]$ProjectDir = (Join-Path $env:GOPATH "src\github.com\elsudano\terraform-provider-vmworkstation")
)

# 1. Check the directory exists
if (!(Test-Path -Path $ProjectDir -PathType Container)) {
    Write-Error "Project directory '$ProjectDir' not found. Please clone the repo there first."
    exit 1
}

# 2. Build
Write-Host "Building Terraform VMware Workstation provider in `"$ProjectDir`"..." -ForegroundColor Cyan
Push-Location $ProjectDir

# 2a. Clean up old binary if present
$exe = "terraform-provider-vmworkstation.exe"
if (Test-Path $exe) {
    Write-Host "Removing existing binary $exe" -ForegroundColor Yellow
    Remove-Item $exe -Force
}

# 2b. Run go build
Write-Host "Running: go build -o $exe" -NoNewline
try {
    go build -o $exe
    Write-Host "  ✔"
} catch {
    Write-Error "Build failed. Please check for Go errors above."
    Pop-Location
    exit 1
}

# 3. Verify binary exists
if (!(Test-Path $exe)) {
    Write-Error "Expected binary '$exe' not found after build."
    Pop-Location
    exit 1
}

Write-Host "Build succeeded: $exe" -ForegroundColor Green

# 4. Quick sanity check with -help
Write-Host "`nVerifying with `$exe -help` ..." -ForegroundColor Cyan
& .\$exe -help

Pop-Location

Write-Host "`nDone. You can now move or reference `$exe` in your Terraform plugin path or terraform.rc override." -ForegroundColor Green
