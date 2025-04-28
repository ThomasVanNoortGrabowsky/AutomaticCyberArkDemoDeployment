<#
  Create-Servers.ps1
  -------------------
  1) Builds a minimal Win2022 VM image via Packer (only WinRM).
  2) Prompts for Terraform VM folder and whether to deploy a Vault server.
  3) Generates Terraform config and spins up the CyberArk-Vault VM via vmworkstation provider.
#>

[CmdletBinding()]
param(
  [ValidateSet('gui','core')]
  [string]$GuiOrCore = 'gui',
  [Parameter(Mandatory)]
  [string]$IsoPath
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ➤ Prompt for Terraform settings
$vmPathInput = Read-Host "Enter the folder path where Terraform should create the VM (e.g. C:\VMs\Test)"
$vaultAnswer = Read-Host "Do you want to deploy the CyberArk Vault VM? (y/n)"
$createVault = $vaultAnswer.Trim().ToLower().StartsWith('y')

# 1) Clone/update packer-Win2022
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Error "Git is required."; exit 1
}
$packerDir = Join-Path $scriptRoot 'packer-Win2022'
if (Test-Path $packerDir) {
  Write-Host "Updating packer-Win2022…" -ForegroundColor Cyan
  Push-Location $packerDir; git pull; Pop-Location
} else {
  Write-Host "Cloning packer-Win2022…" -ForegroundColor Cyan
  git clone https://github.com/eaksel/packer-Win2022.git $packerDir
}

# 2) Ensure Packer v1.11.2 locally
$packerBin = Join-Path $scriptRoot 'packer-bin'
$packerExe = Join-Path $packerBin 'packer.exe'
if (-not (Test-Path $packerExe)) {
  Write-Host "Downloading Packer v1.11.2…" -ForegroundColor Cyan
  New-Item -Path $packerBin -ItemType Directory -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' `
    -OutFile $zip -UseBasicParsing
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force
  Remove-Item $zip
}
$env:PATH = "$packerBin;$env:PATH"

# 3) Validate ISO path
if (-not (Test-Path $IsoPath)) {
  Write-Error "ISO not found: $IsoPath"; exit 1
}
$checksum       = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
$isoUrlVar      = "file:///$($IsoPath.Replace('\','/'))"
$isoChecksumVar = "sha256:$checksum"

# 4) Copy autounattend.xml
$srcAuto  = Join-Path $packerDir "scripts\uefi\$GuiOrCore\autounattend.xml"
$destAuto = Join-Path $scriptRoot 'Autounattend.xml'
if (-not (Test-Path $srcAuto)) {
  Write-Error "autounattend.xml for '$GuiOrCore' not found."; exit 1
}
Copy-Item -Path $srcAuto -Destination $destAuto -Force
Write-Host "Copied autounattend.xml ($GuiOrCore)." -ForegroundColor Green

# 5) Install VMware plugin for Packer
Push-Location $packerDir
Write-Host "Installing VMware Packer plugin…" -ForegroundColor Cyan
& $packerExe plugins install github.com/hashicorp/vmware | Out-Null
Pop-Location

# 6) Remove all provisioners (so Packer only installs & waits for WinRM)
$jsonPath  = Join-Path $packerDir "win2022-$GuiOrCore.json"
$packerObj = Get-Content $jsonPath -Raw | ConvertFrom-Json
$packerObj.provisioners = @()
$packerObj |
  ConvertTo-Json -Depth 10 |
  Set-Content -Path $jsonPath -Encoding ASCII
Write-Host "Stripped out all provisioners; Packer will only install & wait for WinRM." -ForegroundColor Green

# 7) Clean previous output & build with Packer
$outputDir = Join-Path $packerDir 'output-vmware-iso'
if (Test-Path $outputDir) {
  Write-Host "Removing prior Packer output…" -ForegroundColor Yellow
  Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $outputDir
  cmd /c "rd /s /q `"$outputDir`""
}
Push-Location $packerDir
Write-Host "Building win2022-$GuiOrCore.json…" -ForegroundColor Cyan
& $packerExe build `
  -only=vmware-iso `
  -var "iso_url=$isoUrlVar" `
  -var "iso_checksum=$isoChecksumVar" `
  "win2022-$GuiOrCore.json"
if ($LASTEXITCODE -ne 0) { Write-Error "Packer build failed."; exit 1 }
Write-Host "Packer build succeeded." -ForegroundColor Green
Pop-Location

# 8) Start vmrest API daemon
Write-Host "Starting VMware REST API daemon…" -ForegroundColor Cyan
$vmrestExe = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
Stop-Process -Name vmrest -ErrorAction SilentlyContinue
Start-Process -FilePath $vmrestExe -ArgumentList '-b' -WindowStyle Hidden
Start-Sleep -Seconds 5

# 9) Generate Terraform config
$tfDir = Join-Path $scriptRoot 'terraform'
if (-not (Test-Path $tfDir)) { New-Item -Path $tfDir -ItemType Directory | Out-Null }
Set-Location $tfDir

# Write main.tf with proper multi-line HCL
@'
terraform {
  required_providers {
    vmworkstation = {
      source  = "elsudano/vmworkstation"
      version = "1.1.6"
    }
  }
}

provider "vmworkstation" {
  user     = var.vmrest_user
  password = var.vmrest_password
  url      = "http://127.0.0.1:8697"
}

variable "vmrest_user" {
  type    = string
  default = "vmrest"
}

variable "vmrest_password" {
  type    = string
  default = "Cyberark1"
}

variable "vault_image_id" {
  type    = string
  default = "thomas"
}

variable "app_image_id" {
  type    = string
  default = "thomas-app"
}

variable "vm_processors" {
  type    = number
  default = 2
}

variable "vm_memory" {
  type    = number
  default = 2048
}

variable "vm_path" {
  type = string
}

variable "create_vault" {
  type    = bool
  default = false
}

resource "vmworkstation_vm" "vault" {
  count        = var.create_vault ? 1 : 0
  sourceid     = var.vault_image_id
  denomination = "CyberArk-Vault"
  processors   = var.vm_processors
  memory       = var.vm_memory
  path         = var.vm_path
}
'@ | Set-Content -Path main.tf

# Write terraform.tfvars
@"
vm_path      = "$vmPathInput"
create_vault = $($createVault.ToString().ToLower())
"@ | Set-Content -Path terraform.tfvars

# 10) Run Terraform
Write-Host "Initializing Terraform…" -ForegroundColor Cyan
terraform init -upgrade | Out-Null

Write-Host "Planning Terraform…" -ForegroundColor Cyan
terraform plan -out=tfplan | Out-Null

Write-Host "Applying Terraform…" -ForegroundColor Cyan
terraform apply -auto-approve tfplan

Write-Host "🎉 Terraform deployment complete!" -ForegroundColor Green
