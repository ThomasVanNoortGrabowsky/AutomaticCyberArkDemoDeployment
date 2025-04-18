<#
.SYNOPSIS
  Clone/update and build the terraform-provider-vmworkstation plugin, including its API client, then install it for Terraform.

.DESCRIPTION
  1. Ensures Git is installed (via winget if missing).
  2. Clones or updates the terraform-provider-vmworkstation repo under a subfolder.
  3. Clones or updates the vmware-workstation-api-client repo into the parent directory (to satisfy go.mod replace directive).
  4. Builds the provider plugin (`terraform-provider-vmworkstation.exe`).
  5. Verifies the build succeeded.
  6. Copies the plugin binary into Terraform's plugin directory for usage.

.PARAMETER Force
  If specified, the script will delete and reclone both repos.

.PARAMETER PluginVersion
  The version folder under the Terraform plugin directory. Defaults to '1.1.6'.
#>

[CmdletBinding()]
param(
  [switch]$Force,
  [string]$PluginVersion = '1.1.6'
)

# 1) Ensure Git is installed
Write-Host "==> Checking for Git..."
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Git not found. Installing via winget..." -ForegroundColor Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Start-Process winget -ArgumentList 
          'install','--id','Git.Git','-e','--source','winget',
          '--accept-package-agreements','--accept-source-agreements' -Wait -NoNewWindow
        $env:PATH = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path','User')
    } else {
        Write-Error "winget not available; please install Git manually."
        exit 1
    }
}
Write-Host "Git version: $(git --version)" -ForegroundColor Green

# 2) Define directories
$ScriptRoot = $PSScriptRoot
$ProviderRepo   = Join-Path $ScriptRoot 'terraform-provider-vmworkstation'
$ProviderURL    = 'https://github.com/elsudano/terraform-provider-vmworkstation.git'
$ParentDir      = Split-Path $ProviderRepo
$APIClientRepo  = Join-Path $ParentDir 'vmware-workstation-api-client'
$APIClientURL   = 'https://github.com/elsudano/vmware-workstation-api-client.git'

# 3) Clone or update Provider repo
if (Test-Path $ProviderRepo -PathType Container) {
    if ($Force) { Remove-Item -Recurse -Force $ProviderRepo }
}
if (-not (Test-Path $ProviderRepo)) {
    Write-Host "Cloning Provider into '$ProviderRepo'..." -ForegroundColor Cyan
    git clone $ProviderURL $ProviderRepo
} else {
    Write-Host "Updating Provider repo..." -ForegroundColor Cyan
    Push-Location $ProviderRepo; git pull; Pop-Location
}

# 4) Clone or update API Client repo (for go.mod replace)
if (Test-Path $APIClientRepo -PathType Container) {
    if ($Force) { Remove-Item -Recurse -Force $APIClientRepo }
}
if (-not (Test-Path $APIClientRepo)) {
    Write-Host "Cloning API Client into '$APIClientRepo'..." -ForegroundColor Cyan
    git clone $APIClientURL $APIClientRepo
} else {
    Write-Host "Updating API Client repo..." -ForegroundColor Cyan
    Push-Location $APIClientRepo; git pull; Pop-Location
}

# 5) Build the provider plugin
Write-Host "\n==> Building terraform-provider-vmworkstation.exe" -ForegroundColor Cyan
Push-Location $ProviderRepo
$ExeName = 'terraform-provider-vmworkstation.exe'
if (Test-Path $ExeName) { Write-Host "Removing old $ExeName..." -ForegroundColor Yellow; Remove-Item $ExeName -Force }

go build -o $ExeName
if ($LASTEXITCODE -ne 0) {
    Write-Error "go build failed with exit code $LASTEXITCODE"
    Pop-Location; exit 1
}
if (-not (Test-Path $ExeName)) {
    Write-Error "Expected binary not found after build."
    Pop-Location; exit 1
}
Write-Host "Build succeeded: $ProviderRepo\$ExeName" -ForegroundColor Green
Pop-Location

# 6) Install plugin into Terraform plugin dir
$PluginDir = Join-Path $env:APPDATA "terraform.d\plugins\windows_amd64\elsudano\vmworkstation\$PluginVersion"
Write-Host "\n==> Installing provider plugin to:`n  $PluginDir" -ForegroundColor Cyan
if (-not (Test-Path $PluginDir)) { New-Item -ItemType Directory -Path $PluginDir -Force | Out-Null }
Copy-Item -Path (Join-Path $ProviderRepo $ExeName) -Destination (Join-Path $PluginDir $ExeName) -Force

Write-Host "\n✅ All done! Provider v$PluginVersion installed at:`n  $PluginDir\$ExeName" -ForegroundColor Green
