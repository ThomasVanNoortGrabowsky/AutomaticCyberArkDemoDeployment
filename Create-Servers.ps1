<#
.SYNOPSIS
  Build a golden Windows Server VM via Packer and clone via Terraform.

.DESCRIPTION
  1. Prompts for ISO path, vmrest credentials, Vault inclusion, deploy path, and domain details.
  2. Generates Autounattend.xml dynamically with domain join.
  3. Ensures Packer and Terraform are installed.
  4. Builds a golden VM via Packer (vmware-iso).
  5. Retrieves the golden VM ID from the Workstation REST API.
  6. Generates a Terraform project (main.tf, variables.tf) using here-strings, then runs init, plan, apply.
#>

#--- 1) Prompt for required inputs
$IsoPath        = Read-Host 'Enter Windows Server ISO path (e.g. C:\\ISOs\\SERVER_EVAL.iso)'
$VmrestUser     = Read-Host 'Enter VMware Workstation REST API username'
$VmrestPassword = Read-Host 'Enter VMware Workstation REST API password'
$InstallVault   = (Read-Host 'Install Vault server? (Y/N)') -match '^[Yy]$'
$DeployPath     = Read-Host 'Enter base folder path for VMs (e.g. C:\\VMs)'
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
$tools = @{ packer='HashiCorp.Packer'; terraform='HashiCorp.Terraform' }
foreach ($tool in $tools.Keys) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Host "Installing $tool via winget..." -ForegroundColor Yellow
        Start-Process winget -ArgumentList 'install','--id',$tools[$tool],'-e','--accept-package-agreements','--accept-source-agreements' -NoNewWindow -Wait
        $env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH','User')
        Write-Host "$tool installed." -ForegroundColor Green
    }
}

#--- 4) Compute ISO checksum
Write-Host 'Calculating ISO checksum...' -ForegroundColor Cyan
$IsoHash = (Get-FileHash -Path $IsoPath -Algorithm SHA256).Hash

#--- 5) Write Packer template
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

#--- 6) Build golden image
Write-Host 'Running Packer build...' -ForegroundColor Cyan
& packer init template.pkr.hcl | Out-Null
& packer build -force template.pkr.hcl | Out-Null

#--- 7) Retrieve golden VM ID
$Cred = New-Object System.Management.Automation.PSCredential($VmrestUser,(ConvertTo-SecureString $VmrestPassword -AsPlainText -Force))
Start-Sleep -Seconds 5
$VMs = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Credential $Cred
$BaseId = ($VMs | Where-Object name -eq 'vault-base').id
Write-Host "Golden VM ID: $BaseId" -ForegroundColor Green

#--- 8) Generate Terraform project
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
  default = "$VmrestUser"
}
variable "vmrest_password" {
  default = "$VmrestPassword"
}
"@
$VarsTf | Set-Content -Path (Join-Path $tfDir 'variables.tf') -Encoding UTF8

#--- 9) Deploy via Terraform
Push-Location $tfDir
terraform init -upgrade | Out-Null
terraform plan -out=tfplan
terraform apply -auto-approve tfplan
Pop-Location

Write-Host 'All done! Your VMs have been deployed.' -ForegroundColor Green
