<#
.SYNOPSIS
  Build and deploy CyberArk Vault, PVWA, CPM, and PSM servers on VMware Workstation using Packer and Terraform.

.DESCRIPTION
  1. Prompts for ISO path, REST-API credentials, Vault inclusion, deploy path, and domain join info.
  2. Generates Autounattend.xml for unattended Windows install with domain join.
  3. Installs Packer & Terraform if missing.
  4. Builds a golden "vault-base" VM image using Packer.
  5. Stops and restarts vmrest daemon (requires Administrator), then retrieves the VM ID via Basic auth.
  6. Launches VMware Virtual Network Editor to regenerate netmap.conf, copies it into Workstation folder.
  7. Generates Terraform configs (main.tf, variables.tf) and applies them to clone Vault (optional) plus PVWA/CPM/PSM.
#>

# Fail fast on errors
$ErrorActionPreference = 'Stop'

#--- Elevate to Administrator for vmrest & network editor control
function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-IsAdmin)) {
  Write-Host 'Elevation required: restarting as Administrator...' -ForegroundColor Yellow
  $psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
  Start-Process -FilePath $psExe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"" -Verb RunAs
  exit
}

#--- 1) Prompt for inputs
$IsoPath        = Read-Host '1) Windows Server ISO path (e.g. C:\ISOs\SERVER_EVAL.iso)'
$VmrestUser     = Read-Host '2) VMware REST API username'
$VmrestSecure   = Read-Host '3) VMware REST API password' -AsSecureString
$VmrestPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($VmrestSecure)
)
$InstallVault   = Read-Host '4) Install Vault server? (Y/N)' -match '^[Yy]$'
$DeployPath     = Read-Host '5) Base folder for VMs (e.g. C:\VMs)'
$DomainName     = Read-Host '6) Domain to join (e.g. corp.local)'
$DomainUser     = Read-Host '7) Domain join user'
$DomainPass     = 'Cyberark1'

#--- 2) Generate Autounattend.xml
$unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas.microsoft.com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64">
      <UserData><AcceptEula>true</AcceptEula></UserData>
      <ImageInstall><OSImage>
        <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>Windows Server 2019 Datacenter</Value></MetaData></InstallFrom>
        <InstallTo><DiskID>0</DiskID><PartitionID>1</PartitionID></InstallTo>
      </OSImage></ImageInstall>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-UnattendedJoin">
      <Identification><Credentials>
        <Domain>$DomainName</Domain><Username>$DomainUser</Username><Password>$DomainPass</Password>
      </Credentials></Identification>
      <JoinDomain>$DomainName</JoinDomain>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup">
      <AutoLogon><Username>Administrator</Username><Password><Value>$DomainPass</Value><PlainText>true</PlainText></Password><Enabled>false</Enabled></AutoLogon>
      <TimeZone>W. Europe Standard Time</TimeZone>
    </component>
  </settings>
</unattend>
"@
$unattend | Set-Content -Path (Join-Path $PSScriptRoot 'Autounattend.xml') -Encoding UTF8
Write-Host '-> Autounattend.xml generated.' -ForegroundColor Green

#--- 3) Install Packer & Terraform if missing
$packerDir = Join-Path $PSScriptRoot 'packer-bin'
$packerExe = Join-Path $packerDir 'packer.exe'
if (-not (Test-Path $packerExe)) {
  Write-Host '-> Downloading Packer v1.8.6...' -ForegroundColor Yellow
  $zipUrl = 'https://releases.hashicorp.com/packer/1.8.6/packer_1.8.6_windows_amd64.zip'
  $zip    = Join-Path $env:TEMP 'packer_1.8.6.zip'
  Invoke-WebRequest -Uri $zipUrl -OutFile $zip
  New-Item -Path $packerDir -ItemType Directory -Force | Out-Null
  Expand-Archive -Path $zip -DestinationPath $packerDir -Force; Remove-Item $zip
  Write-Host '-> Packer downloaded.' -ForegroundColor Green
}
if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
  Write-Host '-> Installing Terraform via winget...' -ForegroundColor Yellow
  Start-Process winget -ArgumentList 'install','--id','HashiCorp.Terraform','-e','--accept-package-agreements','--accept-source-agreements' -NoNewWindow -Wait
  Write-Host '-> Terraform installed.' -ForegroundColor Green
}

#--- 4) Compute ISO checksum
Write-Host '-> Calculating ISO checksum...' -ForegroundColor Cyan
$hash = (Get-FileHash -Path $IsoPath -Algorithm SHA256).Hash

#--- 5) Write Packer template
$hclISO = $IsoPath.Replace('\','/')
$pkrHcl = @"
variable "iso_path" { default = "$hclISO" }
source "vmware-iso" "vault_base" {
  vm_name           = "vault-base"
  iso_url           = "file:///$hclISO"
  iso_checksum      = "sha256:$hash"
  floppy_files      = ["Autounattend.xml"]
  communicator      = "winrm"
  winrm_username    = "Administrator"
  winrm_password    = "$DomainPass"
  disk_size         = 81920
  cpus              = 8
  memory            = 32768
  shutdown_command  = "shutdown /s /t 5 /f /d p:4:1 /c 'Packer Shutdown'"
}
build { sources = ["source.vmware-iso.vault_base"] }
"@
$pkrHcl | Set-Content -Path (Join-Path $PSScriptRoot 'template.pkr.hcl') -Encoding ASCII
Write-Host '-> Packer template written.' -ForegroundColor Green

#--- 6) Launch Virtual Network Editor to regenerate netmap.conf
$netEditor = 'C:\Program Files (x86)\VMware\VMware Workstation\vmnetcfg.exe'
if (Test-Path $netEditor) {
  Write-Host '-> Launching Virtual Network Editor (please click OK)...' -ForegroundColor Cyan
  Start-Process -FilePath $netEditor -Verb RunAs -Wait
} else {
  Write-Warning 'Virtual Network Editor not found; please open VMware UI manually.'
}

#--- 7) Copy netmap.conf into Workstation folder
$src = 'C:\ProgramData\VMware\netmap.conf'
$dst = 'C:\Program Files (x86)\VMware\VMware Workstation\netmap.conf'
if (Test-Path $src) {
  Copy-Item -Path $src -Destination $dst -Force
  Write-Host '-> netmap.conf copied.' -ForegroundColor Green
} else {
  Write-Warning 'netmap.conf not found under ProgramData; network mappings may fail.'
}

#--- 8) Run Packer init & build
Write-Host '-> Running Packer init & build...' -ForegroundColor Cyan
$initOut = & $packerExe init template.pkr.hcl 2>&1; if ($LASTEXITCODE -ne 0) { Write-Error "Packer init failed:`n$initOut"; exit 1 }
$buildOut = & $packerExe build -force template.pkr.hcl 2>&1; if ($LASTEXITCODE -ne 0) { Write-Error "Packer build failed:`n$buildOut"; exit 1 }

#--- 9) Restart vmrest daemon & retrieve VM ID
$vmrestExe = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
if (-not (Test-Path $vmrestExe)) { Write-Error "vmrest.exe not found"; exit 1 }
Write-Host '-> Restarting vmrest daemon...' -ForegroundColor Cyan
Get-Process vmrest -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process -FilePath $vmrestExe -ArgumentList '-b' -WindowStyle Hidden; Start-Sleep 5
$authHdr = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$VmrestUser:$VmrestPassword")))" }
$vms = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $authHdr
$BaseId = ($vms | Where-Object name -eq 'vault-base').id
Write-Host "-> Golden VM ID: $BaseId" -ForegroundColor Green

#--- 10) Generate Terraform configs & deploy
$tfDir = Join-Path $PSScriptRoot 'terraform'; New-Item -Path $tfDir -ItemType Directory -Force | Out-Null
$main = @"
terraform {
  required_providers {
    vmworkstation = { source = "elsudano/vmworkstation" version = ">=1.0.4" }
  }
}

provider "vmworkstation" {
  user     = var.vmrest_user
  password = var.vmrest_password
  url      = "http://127.0.0.1:8697/api"
}
"@
if ($InstallVault) {
  $main += @"
resource "vmworkstation_vm" "vault" {
  sourceid     = "$BaseId"
  denomination = "CyberArk-Vault"
  processors   = 8
  memory       = 32768
  path         = "$DeployPath\CyberArk-Vault"
}
"@
}
foreach ($comp in @('PVWA','CPM','PSM')) {
  $main += @"
resource "vmworkstation_vm" "$($comp.ToLower())" {
  sourceid     = "$BaseId"
  denomination = "CyberArk-$comp"
  processors   = 4
  memory       = 8192
  path         = "$DeployPath\CyberArk-$comp"
}
"@
}
$main | Set-Content -Path (Join-Path $tfDir 'main.tf') -Encoding UTF8
$vars = @"
variable "vmrest_user" { default = "$VmrestUser" }
variable "vmrest_password" { default = "$VmrestPassword" }
"@
$vars | Set-Content -Path (Join-Path $tfDir 'variables.tf') -Encoding UTF8

Write-Host '-> Deploying via Terraform...' -ForegroundColor Cyan
Push-Location $tfDir; terraform init -upgrade | Out-Null; terraform plan -out=tfplan; terraform apply -auto-approve tfplan; Pop-Location
Write-Host 'Deployment complete!' -ForegroundColor Green
