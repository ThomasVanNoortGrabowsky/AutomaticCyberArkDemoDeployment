<#
  Create-Servers.ps1
  -------------------
  Automated CyberArk lab using eaksel/packer-Win2022 templates:
    1) Clone/update packer-Win2022
    2) Ensure Packer installed locally (v1.11.2)
    3) Prompt for and download/use Windows Server 2022 Eval ISO
    4) Copy official autounattend.xml for GUI/Core UEFI builds
    5) Initialize Packer to install VMware plugin
    6) Build VM image via Packer (Workstation)
    7) Post-build provisioning with vmrest & Terraform
#>

[CmdletBinding()]
param(
  [ValidateSet('gui','core')]
  [string]$GuiOrCore = 'gui',    # 'gui' or 'core'
  [string]$IsoUrl,
  [string]$IsoPath
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# 1) Clone or update packer-Win2022 templates
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Error 'Git is required but not found. Please install Git.'; exit 1
}
$packerDir = Join-Path $scriptRoot 'packer-Win2022'
if (Test-Path $packerDir) {
  Write-Host 'Updating packer-Win2022 templates...' -ForegroundColor Cyan
  Push-Location $packerDir; git pull; Pop-Location
} else {
  Write-Host 'Cloning packer-Win2022 templates...' -ForegroundColor Cyan
  git clone https://github.com/eaksel/packer-Win2022.git $packerDir
}

# 2) Ensure Packer is installed locally
$packerBin = Join-Path $scriptRoot 'packer-bin'
$packerExe = Join-Path $packerBin 'packer.exe'
if (-not (Test-Path $packerExe)) {
  Write-Host 'Downloading Packer v1.11.2...' -ForegroundColor Cyan
  New-Item -Path $packerBin -ItemType Directory -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' -OutFile $zip -UseBasicParsing
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force
  Remove-Item $zip
  Write-Host "-> Packer installed at $packerExe" -ForegroundColor Green
}
# Add Packer to PATH for this session
$env:PATH = "$packerBin;$env:PATH"

# 3) Prompt for ISO path/URL if missing
if (-not $IsoPath) {
  $IsoPath = Read-Host 'Enter local path for Windows Server 2022 Eval ISO (e.g. C:\ISOs\Server2022.iso)'
}
if (-not (Test-Path $IsoPath)) {
  if (-not $IsoUrl) { $IsoUrl = Read-Host 'Enter download URL for Windows Server 2022 Eval ISO' }
  Write-Host "Downloading ISO from $IsoUrl to $IsoPath..." -ForegroundColor Cyan
  Invoke-WebRequest -Uri $IsoUrl -OutFile $IsoPath -UseBasicParsing
  Write-Host "ISO downloaded to $IsoPath" -ForegroundColor Green
}

# Compute ISO variables for Packer
$checksum       = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
$isoUrlVar      = "file:///$($IsoPath.Replace('\','/'))"
$isoChecksumVar = "sha256:$checksum"

# 4) Copy official autounattend.xml
$source = Join-Path $packerDir "scripts\uefi\$GuiOrCore\autounattend.xml"
$dest   = Join-Path $scriptRoot 'Autounattend.xml'
if (-not (Test-Path $source)) { Write-Error "Template not found: $source"; exit 1 }
Copy-Item -Path $source -Destination $dest -Force
Write-Host "Copied autounattend.xml for '$GuiOrCore' build to $dest" -ForegroundColor Green

# 5) Initialize Packer to install VMware plugin
Push-Location $packerDir
Write-Host 'Initializing Packer (installing plugins)...' -ForegroundColor Cyan
& $packerExe init . | Write-Host

# 6) Build VM image via Packer
$buildJson = "win2022-$GuiOrCore.json"
Write-Host "Starting Packer build: $buildJson" -ForegroundColor Cyan
& $packerExe build -only=vmware-iso `
    -var "iso_url=$isoUrlVar" `
    -var "iso_checksum=$isoChecksumVar" `
    $buildJson | Write-Host
if ($LASTEXITCODE -ne 0) { Write-Error "Packer build failed (exit code $LASTEXITCODE)"; Pop-Location; exit 1 }
Write-Host 'Packer build completed successfully.' -ForegroundColor Green
Pop-Location

# 7) Start VMware REST API daemon
Write-Host 'Starting VMware REST API daemon...' -ForegroundColor Yellow
$vmrestExe = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
Stop-Process -Name vmrest -ErrorAction SilentlyContinue
Start-Process -FilePath $vmrestExe -ArgumentList '-b' -WindowStyle Hidden
Start-Sleep 5
Write-Host 'VMware REST API daemon started.' -ForegroundColor Green

# 8) Configure Terraform CLI
$rc = Join-Path $scriptRoot 'Create-TerraformRc.ps1'
if (Test-Path $rc) { Write-Host 'Configuring Terraform CLI...' -ForegroundColor Cyan; & $rc }

# 9) Run Terraform
$tfDir = Join-Path $scriptRoot 'terraform'
if (-not (Test-Path $tfDir)) { Write-Error "Terraform folder not found: $tfDir"; exit 1 }
Push-Location $tfDir
Write-Host 'Initializing Terraform...' -ForegroundColor Cyan
terraform init -upgrade | Write-Host
Write-Host 'Planning Terraform deployment...' -ForegroundColor Cyan
terraform plan -out=tfplan | Write-Host
Write-Host 'Applying Terraform deployment...' -ForegroundColor Cyan
terraform apply -auto-approve tfplan | Write-Host
Pop-Location

Write-Host '🎉 Deployment complete!' -ForegroundColor Green
