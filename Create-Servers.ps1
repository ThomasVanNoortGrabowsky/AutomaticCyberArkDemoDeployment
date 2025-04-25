<#
  Create-Servers.ps1
  -------------------
  Automated CyberArk lab using Packer-Win2022 templates:
    1) Prompt for and download/use Windows Server 2022 Eval ISO
    2) Copy official autounattend.xml for GUI or Core UEFI builds
    3) Build VM images via Packer (Workstation, UEFI)
    4) Post-build provisioning with vmrest & Terraform
#>

[CmdletBinding()]
param(
    [ValidateSet('gui','core')]
    [string]$GuiOrCore = 'gui',    # 'gui' or 'core'
    [string]$IsoUrl,
    [string]$IsoPath
)

$ErrorActionPreference = 'Stop'

# --- 1) Prompt for ISO path/URL if missing ---
if (-not $IsoPath) {
    $IsoPath = Read-Host 'Enter local path for Windows Server 2022 Eval ISO (e.g. C:\ISOs\Server2022.iso)'
}
if (-not (Test-Path $IsoPath)) {
    if (-not $IsoUrl) {
        $IsoUrl = Read-Host 'Enter download URL for Windows Server 2022 Eval ISO'
    }
    Write-Host "Downloading ISO from $IsoUrl to $IsoPath..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $IsoUrl -OutFile $IsoPath -UseBasicParsing
}

# --- 2) Copy official autounattend.xml ---
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$packerDir  = Join-Path $scriptRoot 'packer-Win2022'
$sourceFile = Join-Path $packerDir "scripts\uefi\$GuiOrCore\autounattend.xml"
$ansPath    = Join-Path $scriptRoot 'Autounattend.xml'

if (-not (Test-Path $sourceFile)) {
    Write-Error "Cannot find autounattend template: $sourceFile"
    exit 1
}
Copy-Item -Path $sourceFile -Destination $ansPath -Force
Write-Host "Copied autounattend.xml for '$GuiOrCore' build to $ansPath" -ForegroundColor Green

# --- 3) Invoke Packer builds ---
Push-Location $packerDir
$buildJson = "win2022-$GuiOrCore_uefi.json"
Write-Host "Starting Packer build: $buildJson" -ForegroundColor Cyan
packer build -only=vmware-iso $buildJson
if ($LASTEXITCODE -ne 0) {
    Write-Error "Packer build failed for $buildJson"
    Pop-Location; exit 1
}
Pop-Location

# --- 4) Post-build provisioning ---
Write-Host "Starting VMware REST API daemon..." -ForegroundColor Yellow
$vmwareDir = 'C:\Program Files (x86)\VMware\VMware Workstation'
$vmrestExe = Join-Path $vmwareDir 'vmrest.exe'
if (Get-Command vmrest -ErrorAction SilentlyContinue) {
    Stop-Process -Name vmrest -Force -ErrorAction SilentlyContinue
}
Start-Process -FilePath $vmrestExe -ArgumentList '-b' -WindowStyle Hidden
Start-Sleep -Seconds 5
Write-Host "VMware REST API daemon started." -ForegroundColor Green

# Configure Terraform CLI (assumes Create-TerraformRc.ps1 exists)
$terraformRcScript = Join-Path $scriptRoot 'Create-TerraformRc.ps1'
if (Test-Path $terraformRcScript) {
    Write-Host "Configuring Terraform CLI override..." -ForegroundColor Cyan
    & $terraformRcScript
} else {
    Write-Warning "Terraform RC script not found: $terraformRcScript"
}

# Run Terraform
$tfDir = Join-Path $scriptRoot 'terraform'
if (-not (Test-Path $tfDir)) {
    Write-Error "Terraform directory not found: $tfDir"
    exit 1
}
Push-Location $tfDir
Write-Host "Initializing Terraform..." -ForegroundColor Cyan
terraform init -upgrade
Write-Host "Planning Terraform deployment..." -ForegroundColor Cyan
terraform plan -out=tfplan
Write-Host "Applying Terraform deployment..." -ForegroundColor Cyan
terraform apply -auto-approve tfplan
Pop-Location

Write-Host "🎉 Deployment complete!" -ForegroundColor Green
