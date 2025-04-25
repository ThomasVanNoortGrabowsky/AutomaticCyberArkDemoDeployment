<#
  Create-Servers.ps1
  -------------------
  Automated CyberArk lab using Packer-Win2022 templates:
    1) Download/use Windows Server 2022 Eval ISO
    2) Copy official autounattend.xml for GUI or Core UEFI builds
    3) Build VM images via Packer (Workstation, UEFI)
    4) Post-build provisioning with vmrest & Terraform
#>

[CmdletBinding()]
param(
    [string]$GuiOrCore = 'gui',    # 'gui' or 'core'
    [string]$IsoUrl,
    [string]$IsoPath
)

$ErrorActionPreference = 'Stop'

# 1) Validate parameters
if ($GuiOrCore -notin @('gui','core')) {
    Write-Error "Invalid build type '$GuiOrCore'. Use 'gui' or 'core'."
    exit 1
}
if (-not (Test-Path $IsoPath)) {
    # Download if URL provided
    if ($IsoUrl) {
        Write-Host "Downloading ISO from $IsoUrl..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $IsoUrl -OutFile $IsoPath -UseBasicParsing
    } else {
        Write-Error "ISO not found at $IsoPath and no IsoUrl given."
        exit 1
    }
}

# 2) Copy official autounattend.xml
$scriptRoot = $PSScriptRoot
$packerDir  = Join-Path $scriptRoot 'packer-Win2022'
$autounattendSource = Join-Path $packerDir "scripts\uefi\$GuiOrCore\autounattend.xml"
$ansPath = Join-Path $scriptRoot 'Autounattend.xml'

if (-not (Test-Path $autounattendSource)) {
    Write-Error "Cannot find autounattend template: $autounattendSource"
    exit 1
}

Copy-Item -Path $autounattendSource -Destination $ansPath -Force
Write-Host "Copied autounattend.xml for '$GuiOrCore' build to $ansPath" -ForegroundColor Green

# 3) Packer build
Push-Location $packerDir

# Build JSON file names
$guiJson  = "win2022-gui_uefi.json"
$coreJson = "win2022-core_uefi.json"

if ($GuiOrCore -eq 'gui') {
    Write-Host "Starting Packer build: $guiJson" -ForegroundColor Cyan
    packer build -only=vmware-iso $guiJson
} else {
    Write-Host "Starting Packer build: $coreJson" -ForegroundColor Cyan
    packer build -only=vmware-iso $coreJson
}

Pop-Location

# 4) Post-build provisioning (vmrest & Terraform)
Write-Host "4) Starting VMware REST API daemon..." -ForegroundColor Yellow

# 4.1 Start vmrest daemon
$vmwareDir = 'C:\Program Files (x86)\VMware\VMware Workstation'
$vmrestExe = Join-Path $vmwareDir 'vmrest.exe'
Stop-Process -Name vmrest -Force -ErrorAction SilentlyContinue
Start-Process -FilePath $vmrestExe -ArgumentList '-b' -WindowStyle Hidden
Start-Sleep -Seconds 5
Write-Host "VMware REST API daemon started." -ForegroundColor Green

# 4.2 Configure Terraform CLI using Create-TerraformRc.ps1
$terraformRcScript = Join-Path $scriptRoot 'Create-TerraformRc.ps1'
if (Test-Path $terraformRcScript) {
    Write-Host "Configuring Terraform CLI..." -ForegroundColor Cyan
    & $terraformRcScript
} else {
    Write-Warning "Terraform RC script not found: $terraformRcScript"
}

# 4.3 Run Terraform deployment
Write-Host "Running Terraform deployment..." -ForegroundColor Cyan
$tfDir = Join-Path $scriptRoot 'terraform'
if (-not (Test-Path $tfDir)) {
    Write-Error "Terraform directory not found: $tfDir"; exit 1
}
Push-Location $tfDir

Write-Host "terraform init -upgrade" -ForegroundColor Cyan
terraform init -upgrade

Write-Host "terraform plan -out=tfplan" -ForegroundColor Cyan
terraform plan -out=tfplan

Write-Host "terraform apply -auto-approve tfplan" -ForegroundColor Cyan
terraform apply -auto-approve tfplan

Pop-Location
Write-Host "🎉 Terraform deployment complete!" -ForegroundColor Green
