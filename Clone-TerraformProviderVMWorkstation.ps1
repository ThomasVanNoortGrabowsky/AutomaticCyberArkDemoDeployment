<#
.SYNOPSIS
  Clones or updates the terraform-provider-vmworkstation repo and builds the provider plugin.

.DESCRIPTION
  1. Ensures Git is installed (installs via winget if missing).
  2. Clones or updates the terraform-provider-vmworkstation repo under the script folder.
  3. Detects that repo folder and runs `go build` to produce terraform-provider-vmworkstation.exe.
  4. Verifies the build succeeded.

.PARAMETER Force
  If specified, will delete & reclone the repo even if it already exists.

.EXAMPLE
  .\Setup-TFWsProvider.ps1
  (Clones/pulls, then builds.)

.EXAMPLE
  .\Setup-TFWsProvider.ps1 -Force
  (Deletes the existing clone, then re-clones and builds.)
#>

[CmdletBinding()]
param(
    [switch]$Force
)

# 1) Ensure Git is available
Write-Host "==> Checking for Git..."
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Git not found. Installing via winget..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Start-Process winget `
          -ArgumentList 'install','--id','Git.Git','-e','--source','winget',`
                        '--accept-package-agreements','--accept-source-agreements' `
          -Wait -NoNewWindow
        # Refresh PATH for this session
        $env:PATH = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path','User')
    }
    else {
        Write-Error "winget not available; please install Git manually."
        exit 1
    }
}
Write-Host "Git version: $(git --version)" -ForegroundColor Green

# 2) Clone or update the provider repo
$repoUrl   = 'https://github.com/elsudano/terraform-provider-vmworkstation.git'
$targetDir = Join-Path $PSScriptRoot 'terraform-provider-vmworkstation'

if (Test-Path $targetDir) {
    if ($Force) {
        Write-Host "Removing existing folder for fresh clone..." -ForegroundColor Yellow
        Remove-Item -Recurse -Force $targetDir
    }
}

if (-not (Test-Path $targetDir)) {
    Write-Host "Cloning $repoUrl into '$targetDir'..." -ForegroundColor Cyan
    git clone $repoUrl $targetDir
}
else {
    Write-Host "Updating existing repo in '$targetDir'..." -ForegroundColor Cyan
    Push-Location $targetDir
    git pull
    Pop-Location
}

# 3) Build the provider plugin
Write-Host "`n==> Building terraform-provider-vmworkstation..." -ForegroundColor Cyan

if (-not (Test-Path $targetDir)) {
    Write-Error "Provider source folder '$targetDir' not found."
    exit 1
}

Push-Location $targetDir

# Clean up any old binary
$exe = 'terraform-provider-vmworkstation.exe'
if (Test-Path $exe) {
    Write-Host "Removing old binary $exe..." -ForegroundColor Yellow
    Remove-Item $exe -Force
}

# Run the Go build
Write-Host "Running: go build -o $exe"
go build -o $exe
if ($LASTEXITCODE -ne 0) {
    Write-Error "go build failed (exit code $LASTEXITCODE)."
    Pop-Location
    exit 1
}

# Verify the binary exists
if (-not (Test-Path $exe)) {
    Write-Error "Build reported success but $exe was not produced."
    Pop-Location
    exit 1
}

Write-Host "Build succeeded: $targetDir\$exe" -ForegroundColor Green

# Optional: run '-help' to sanity‑check
Write-Host "`nVerifying plugin help output..." -ForegroundColor Cyan
& .\terraform-provider-vmworkstation.exe -help

Pop-Location

Write-Host "`n✅ All done! The provider binary lives in:" -ForegroundColor Green
Write-Host "   $targetDir\$exe`n"
