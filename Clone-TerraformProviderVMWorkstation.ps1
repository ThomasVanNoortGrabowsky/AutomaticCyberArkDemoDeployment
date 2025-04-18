<#
.SYNOPSIS
  Clone/update and build the Terraform VMware Workstation provider, then install it.

.DESCRIPTION
  * Checks for Git and installs via winget if missing.
  * Clones (or pulls) https://github.com/elsudano/terraform-provider-vmworkstation 
    into a subfolder under the script location.
  * Runs `go build -o terraform-provider-vmworkstation.exe`.
  * Copies the resulting EXE into Terraform’s plugin directory under %APPDATA%,
    so Terraform will find it automatically.

.PARAMETER Force
  If specified, the script will delete any existing clone and re-clone fresh.

.PARAMETER PluginVersion
  The provider version folder under the plugin directory. Defaults to "1.1.6".
#>

[CmdletBinding()]
param(
  [switch]$Force,
  [string]$PluginVersion = '1.1.6'
)

# 1) Ensure Git is available
Write-Host "==> Checking for Git..."
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Git not found. Installing via winget..." -ForegroundColor Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Start-Process winget `
          -ArgumentList 'install','--id','Git.Git','-e','--source','winget',`
                        '--accept-package-agreements','--accept-source-agreements' `
          -Wait -NoNewWindow
        # Refresh PATH in this session
        $env:PATH = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path','User')
    }
    else {
        Write-Error "winget not available; please install Git manually."
        exit 1
    }
}
Write-Host "Git is available: $(git --version)" -ForegroundColor Green

# 2) Define where to clone the provider
$RepoDir   = Join-Path $PSScriptRoot 'terraform-provider-vmworkstation'
$RepoUrl   = 'https://github.com/elsudano/terraform-provider-vmworkstation.git'

# 3) Clone or update the repo
if (Test-Path $RepoDir) {
    if ($Force) {
        Write-Host "Removing existing repo for fresh clone..." -ForegroundColor Yellow
        Remove-Item -Recurse -Force $RepoDir
    }
}

if (-not (Test-Path $RepoDir)) {
    Write-Host "Cloning provider into '$RepoDir'..." -ForegroundColor Cyan
    git clone $RepoUrl $RepoDir
}
else {
    Write-Host "Updating existing provider clone..." -ForegroundColor Cyan
    Push-Location $RepoDir
    git pull
    Pop-Location
}

# 4) Build the provider plugin
Write-Host "`n==> Building terraform-provider-vmworkstation.exe" -ForegroundColor Cyan
Push-Location $RepoDir

# Remove any old build
$ExeName = 'terraform-provider-vmworkstation.exe'
if (Test-Path $ExeName) {
    Write-Host "Deleting old binary $ExeName" -ForegroundColor Yellow
    Remove-Item $ExeName -Force
}

# Run the build
go build -o $ExeName
if ($LASTEXITCODE -ne 0) {
    Write-Error "go build failed with exit code $LASTEXITCODE"
    Pop-Location
    exit 1
}

if (-not (Test-Path $ExeName)) {
    Write-Error "Build succeeded but $ExeName was not found."
    Pop-Location
    exit 1
}

Write-Host "Build succeeded: $RepoDir\$ExeName" -ForegroundColor Green

Pop-Location

# 5) Install into Terraform local plugin directory
$PluginDir = Join-Path $env:APPDATA "terraform.d\plugins\windows_amd64\elsudano\vmworkstation\$PluginVersion"
Write-Host "`n==> Installing provider plugin to:" -ForegroundColor Cyan
Write-Host "   $PluginDir" -ForegroundColor Cyan

if (-not (Test-Path $PluginDir)) {
    New-Item -ItemType Directory -Path $PluginDir -Force | Out-Null
}

Copy-Item -Path (Join-Path $RepoDir $ExeName) `
          -Destination (Join-Path $PluginDir $ExeName) -Force

Write-Host "`n✅ Done! The provider plugin is installed here:" -ForegroundColor Green
Write-Host "   $PluginDir\$ExeName`n"
