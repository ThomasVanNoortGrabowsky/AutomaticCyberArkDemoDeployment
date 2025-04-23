<#
.SYNOPSIS
  Build a golden Windows Server VM via Packer (unattended via Autounattend.xml) and then clone it via Terraform.

.DESCRIPTION
  1. Prompts for default ISO path, actual ISO path, vmrest credentials, Vault inclusion, deploy path, and domain details.
  2. Generates Autounattend.xml dynamically with domain join.
  3. Ensures Packer and Terraform are installed.
  4. Builds a golden VM via Packer (vmware-iso).
  5. Retrieves the golden VM ID from the Workstation REST API.
  6. Generates a Terraform project (main.tf, variables.tf) using here-strings and array-based writing, then runs init, plan, apply.
#>

#region ← Prompt for default ISO and credentials
# Ask for default ISO path
$IsoPathDefault = Read-Host 'Enter the default Windows Server ISO path (e.g. C:\\ISOs\\SERVER_EVAL.iso)'
# Ask for vmrest API credentials
$VmrestUser     = Read-Host 'Enter VMware Workstation REST API username'
$VmrestPassword = Read-Host 'Enter VMware Workstation REST API password'
#endregion

#--- Prompts for specific run
$IsoPath      = Read-Host "Enter actual ISO path (or press Enter to use default [$IsoPathDefault])"
if ([string]::IsNullOrEmpty($IsoPath)) { $IsoPath = $IsoPathDefault }
$InstallVault = (Read-Host 'Install Vault server? (Y/N)') -match '^[Yy]$'
$DeployPath   = Read-Host 'Enter base folder path for VMs (e.g. C:\\VMs)'
$DomainName   = Read-Host 'Enter domain to join (e.g. corp.local)'
$DomainUser   = Read-Host 'Enter domain join user (e.g. joinuser)'
$DomainPass   = 'Cyberark1'

#--- 1) Generate Autounattend.xml
$unattend = @"
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
$unattend | Set-Content -Path (Join-Path $PSScriptRoot 'Autounattend.xml') -Encoding UTF8
Write-Host 'Generated Autounattend.xml.' -ForegroundColor Green

#--- 2) Ensure Packer and Terraform are installed
function Ensure-Tool($name, $id) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    Write-Host "Installing $name via winget..." -ForegroundColor Yellow
    Start-Process winget -ArgumentList 'install','--id',$id,'-e','--accept-package-agreements','--accept-source-agreements' -NoNewWindow -Wait
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH','User')
    Write-Host "$name installed." -ForegroundColor Green
  }
}
Ensure-Tool packer 'HashiCorp.Packer'
Ensure-Tool terraform 'HashiCorp.Terraform'

#--- 3) Compute ISO checksum
Write-Host 'Calculating ISO checksum...' -ForegroundColor Cyan
$IsoHash = (Get-FileHash -Path $IsoPath -Algorithm SHA256).Hash

#--- 4) Write Packer template
$HclPath = $IsoPath -replace '\\','/'  
$PkrTemplate = @"
variable "iso_path" { default = "$HclPath" }
source "vmware-iso" "vault_base" {
  vm_name           = "vault-base"
  iso_url           = "file:///$HclPath"
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
$PkrTemplate | Set-Content -Path (Join-Path $PSScriptRoot 'template.pkr.hcl') -Encoding UTF8
Write-Host 'Packer HCL template written.' -ForegroundColor Green

#--- 5) Build golden VM image
Write-Host 'Running Packer build...' -ForegroundColor Cyan
& packer init template.pkr.hcl | Out-Null
& packer build -force template.pkr.hcl | Out-Null

#--- 6) Retrieve golden VM ID
$Cred = New-Object System.Management.Automation.PSCredential($VmrestUser,(ConvertTo-SecureString $VmrestPassword -AsPlainText -Force))
Start-Sleep -Seconds 5
$VMs = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Credential $Cred
$BaseId = ($VMs | Where-Object name -eq 'vault-base').id
Write-Host "Golden VM ID: $BaseId" -ForegroundColor Green

#--- 7) Generate Terraform config
$tfDir = Join-Path $PSScriptRoot 'terraform'
if (-not (Test-Path $tfDir)) { New-Item -Path $tfDir -ItemType Directory | Out-Null }

$main = @(
 'terraform {',
 '  required_providers {',
 '    vmworkstation = { source = "elsudano/vmworkstation" version = ">=1.0.4" }',
 '  }',
 '}',
 '',
 'provider "vmworkstation" {',
 '  user     = var.vmrest_user',
 '  password = var.vmrest_password',
 '  url      = "http://127.0.0.1:8697/api"',
 '}',
 ''
)
if ($InstallVault) {
  $main += @(  
    'resource "vmworkstation_vm" "vault" {',
    "  sourceid     = \"$BaseId\"",
    '  denomination = "CyberArk-Vault"',
    '  processors   = 8',
    '  memory       = 32768',
    "  path         = \"$DeployPath\CyberArk-Vault\"",
    '}',
    ''
  )
}
foreach ($Comp in @('PVWA','CPM','PSM')) {
  $main += @(  
    "resource \"vmworkstation_vm\" \"$($Comp.ToLower())\" {",
    "  sourceid     = \"$BaseId\"",
    "  denomination = \"CyberArk-$Comp\"",
    '  processors   = 4',
    '  memory       = 8192',
    "  path         = \"$DeployPath\CyberArk-$Comp\"",
    '}',
    ''
  )
}
$main | Set-Content -Path (Join-Path $tfDir 'main.tf') -Encoding UTF8

$vars = @(
 "variable \"vmrest_user\" { type = string default = \"$VmrestUser\" }",
 "variable \"vmrest_password\" { type = string default = \"$VmrestPassword\" }"
)
$vars | Set-Content -Path (Join-Path $tfDir 'variables.tf') -Encoding UTF8

#--- 8) Deploy via Terraform
Push-Location $tfDir
terraform init -upgrade | Out-Null
terraform plan -out=tfplan
terraform apply -auto-approve tfplan
Pop-Location

Write-Host 'All done! Your VMs have been deployed.' -ForegroundColor Green
