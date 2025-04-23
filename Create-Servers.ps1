<#
.SYNOPSIS
  Build and deploy CyberArk servers (Vault + PVWA/CPM/PSM) on VMware Workstation using Packer and Terraform.

.DESCRIPTION
  1. Prompts for ISO path, REST-API credentials, Vault inclusion, deploy path, and domain join info.
  2. Generates Autounattend.xml for unattended Windows install with domain join.
  3. Installs Packer & Terraform via winget if missing.
  4. Builds a golden "vault-base" VM image using Packer.
  5. Ensures vmrest daemon is running (self‑elevating to Admin if needed) and retrieves the VM ID via Basic auth.
  6. Generates Terraform configs (main.tf, variables.tf) and applies them to clone Vault (optional) plus PVWA/CPM/PSM.
#>

#--- Self‑elevate to Administrator for vmrest control
function Test-IsAdmin {
  $current = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($current)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-IsAdmin)) {
  Write-Host 'Script needs Administrator rights to manage vmrest. Relaunching as admin...' -ForegroundColor Yellow
  Start-Process -FilePath pwsh -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"" -Verb RunAs
  exit
}

#--- 1) Prompt for inputs
$IsoPath        = Read-Host 'Enter Windows Server ISO path (e.g. C:\ISOs\SERVER_EVAL.iso)'
$VmrestUser     = Read-Host 'Enter VMware REST API username'
$VmrestSecure   = Read-Host 'Enter VMware REST API password' -AsSecureString
$VmrestPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($VmrestSecure)
)
$InstallVault   = (Read-Host 'Install Vault server? (Y/N)') -match '^[Yy]$'
$DeployPath     = Read-Host 'Enter base folder path for VMs (e.g. C:\VMs)'
$DomainName     = Read-Host 'Enter domain to join (e.g. corp.local)'
$DomainUser     = Read-Host 'Enter domain join user (e.g. joinuser)'
$DomainPass     = 'Cyberark1'

#--- 2) Generate Autounattend.xml
$UnattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <UserData><AcceptEula>true</AcceptEula></UserData>
      <ImageInstall><OSImage>
        <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>Windows Server 2019 Datacenter</Value></MetaData></InstallFrom>
        <InstallTo><DiskID>0</DiskID><PartitionID>1</PartitionID></InstallTo>
      </OSImage></ImageInstall>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-UnattendedJoin" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <Identification><Credentials>
        <Domain>$DomainName</Domain><Username>$DomainUser</Username><Password>$DomainPass</Password>
      </Credentials></Identification>
      <JoinDomain>$DomainName</JoinDomain>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <AutoLogon><Username>Administrator</Username><Password><Value>$DomainPass</Value><PlainText>true</PlainText></Password><Enabled>false</Enabled></AutoLogon>
      <TimeZone>W. Europe Standard Time</TimeZone>
    </component>
  </settings>
</unattend>
"@
$UnattendXml | Set-Content -Path (Join-Path $PSScriptRoot 'Autounattend.xml') -Encoding UTF8
Write-Host 'Autounattend.xml generated.' -ForegroundColor Green

#--- 3) Ensure Packer & Terraform are installed
$tools = @{ packer = 'HashiCorp.Packer'; terraform = 'HashiCorp.Terraform' }
foreach ($t in $tools.Keys) {
  if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
    Write-Host "Installing $t via winget..." -ForegroundColor Yellow
    Start-Process winget -ArgumentList 'install','--id',$tools[$t],'-e','--accept-package-agreements','--accept-source-agreements' -NoNewWindow -Wait
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH','User')
    Write-Host "$t installed." -ForegroundColor Green
  }
}

#--- 4) Compute ISO checksum
Write-Host 'Calculating ISO checksum...' -ForegroundColor Cyan
$IsoHash = (Get-FileHash -Path $IsoPath -Algorithm SHA256).Hash

#--- 5) Write Packer HCL template
$HclIso = $IsoPath -replace '\\','/'
$PkrHcl = @"
variable "iso_path" { default = "$HclIso" }
source "vmware-iso" "vault_base" {
  vm_name           = "vault-base"
  iso_url           = "file:///$HclIso"
  iso_checksum_type = "sha256"
  iso_checksum      = "$IsoHash"
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
$PkrHcl | Set-Content -Path (Join-Path $PSScriptRoot 'template.pkr.hcl') -Encoding UTF8
Write-Host 'Packer HCL template written.' -ForegroundColor Green

#--- 6) Build golden VM image
Write-Host 'Running Packer build...' -ForegroundColor Cyan
& packer init template.pkr.hcl | Out-Null
& packer build -force template.pkr.hcl | Out-Null

#--- 7) Ensure vmrest daemon and retrieve VM ID via Basic auth
$vmrestExe = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
if (-not (Test-Path $vmrestExe)) { Write-Error "vmrest.exe not found at $vmrestExe"; exit 1 }
# stop old instance if any, then start
Get-Process vmrest -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Process -FilePath $vmrestExe -ArgumentList '-b' -WindowStyle Hidden
Start-Sleep -Seconds 5

$url    = 'http://127.0.0.1:8697/api/vms'
$pair   = "${VmrestUser}:${VmrestPassword}"
$token  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$headers = @{ Authorization = "Basic $token" }

try {
  $VMs    = Invoke-RestMethod -Uri $url -Headers $headers
  $BaseId = ($VMs | Where-Object name -eq 'vault-base').id
  Write-Host "Golden VM ID: $BaseId" -ForegroundColor Green
} catch {
  Write-Error "Authentication to vmrest failed. Please re-run 'vmrest.exe --config' and ensure the service is running."  
  exit 1
}

#--- 8) Generate Terraform config
$tfDir = Join-Path $PSScriptRoot 'terraform'
if (-not (Test-Path $tfDir)) { New-Item -Path $tfDir -ItemType Directory | Out-Null }

$MainTf = @"
terraform {
  required_providers {
    vmworkstation = {
      source  = "elsudano/vmworkstation"
      version = ">=1.0.4"
    }
  }
}

provider "vmworkstation" {
  user     = var.vmrest_user
  password = var.vmrest_password
  url      = "http://127.0.0.1:8697/api"
}
"@
if ($InstallVault) {
  $MainTf += @"
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
  $MainTf += @"
resource "vmworkstation_vm" "${comp.ToLower()}" {
  sourceid     = "$BaseId"
  denomination = "CyberArk-$comp"
  processors   = 4
  memory       = 8192
  path         = "$DeployPath\CyberArk-$comp"
}
"@
}
$MainTf | Set-Content -Path (Join-Path $tfDir 'main.tf') -Encoding UTF8

$VarsTf = @"
variable "vmrest_user" {
  type    = string
  default = "$VmrestUser"
}
variable "vmrest_password" {
  type    = string
  default = "$VmrestPassword"
}
"@
$VarsTf | Set-Content -Path (Join-Path $tfDir 'variables.tf') -Encoding UTF8

#--- 9) Run Terraform
Write-Host 'Deploying via Terraform...' -ForegroundColor Cyan
Push-Location $tfDir
terraform init -upgrade | Out-Null
terraform plan -out=tfplan
terraform apply -auto-approve tfplan
Pop-Location

Write-Host 'All done! Your VMs have been deployed.' -ForegroundColor Green
