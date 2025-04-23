<#
.SYNOPSIS
  Build a golden Windows Server VM via Packer, with unattended install via Autounattend.xml (including domain join), then clone via Terraform.

.DESCRIPTION
  1. Prompts for ISO path, Vault inclusion, deploy path, domain information.
  2. Generates Autounattend.xml for unattended Windows install (using Cyberark1 password).
  3. Downloads/installs Packer & Terraform if missing.
  4. Builds golden VM via Packer (vmware-iso).
  5. Retrieves golden VM ID from Workstation REST API.
  6. Generates Terraform config and deploys VMs (Vault optional + PVWA, CPM, PSM).

.PARAMETER IsoPath
  Path to your Windows Server ISO. Default set below but can be edited.
#>

#region ← User settings — edit if desired or respond at prompts
# Default path to Windows ISO (can override at prompt)
$IsoPath = 'C:\Users\ThomasvanNoort\Downloads\SERVER_EVAL_x64FRE_en-us.iso'

# Workstation REST API credentials
$VmrestUser     = 'vmrest'
$VmrestPassword = 'Cyberark1'

# Prompt whether to install Vault server
$installVault   = Read-Host 'Install Vault server infrastructure too? (Y/N)'
$InstallVault   = $installVault -match '^[Yy]'

# Prompt deploy folder path
$DeployPath     = Read-Host 'Enter base folder path to deploy VMs (e.g. C:\VMs)'

# Prompt domain join info
$DomainName      = Read-Host 'Enter domain to join (e.g. corp.local)'
$DomainJoinUser  = Read-Host 'Enter domain join user (e.g. joinuser)'
$DomainJoinPass  = 'Cyberark1'   # fixed password for domain join and local Admin
#endregion

#--- 1) Generate Autounattend.xml for unattended Windows install
$unattendFile = Join-Path $PSScriptRoot 'Autounattend.xml'

$unattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>Administrator</FullName>
        <Organization>MyOrg</Organization>
      </UserData>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/NAME</Key>
              <Value>Windows Server 2019 Datacenter</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>1</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-UnattendedJoin" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <Identification>
        <Credentials>
          <Domain>$DomainName</Domain>
          <Username>$DomainJoinUser</Username>
          <Password>$DomainJoinPass</Password>
        </Credentials>
      </Identification>
      <JoinDomain>$DomainName</JoinDomain>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <AutoLogon>
        <Username>Administrator</Username>
        <Password>
          <Value>$DomainJoinPass</Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>false</Enabled>
      </AutoLogon>
      <RegisteredOrganization>MyOrg</RegisteredOrganization>
      <RegisteredOwner>Administrator</RegisteredOwner>
      <TimeZone>W. Europe Standard Time</TimeZone>
    </component>
  </settings>
</unattend>
"@

$unattendXml | Set-Content -Path $unattendFile -Encoding UTF8
Write-Host "Generated Autounattend.xml at $unattendFile"

#--- 2) Ensure Packer and Terraform installed
if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
  Write-Host "Downloading Packer..." -ForegroundColor Yellow
  $ver = '1.8.6'; $zip = "$env:TEMP\packer_$ver.zip"; $url = "https://releases.hashicorp.com/packer/$ver/packer_${ver}_windows_amd64.zip"
  Invoke-WebRequest $url -OutFile $zip
  $pd = Join-Path $PSScriptRoot 'packer-bin'; if(-not(Test-Path $pd)){New-Item -ItemType Dir -Path $pd}
  Expand-Archive $zip -DestinationPath $pd -Force; Remove-Item $zip
  $env:PATH = "$pd;$env:PATH"; Write-Host "Packer ready."
}
if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
  Write-Host "Installing Terraform..." -ForegroundColor Yellow
  Start-Process winget -ArgumentList 'install','--id','HashiCorp.Terraform','-e','--source','winget',
    '--accept-package-agreements','--accept-source-agreements' -NoNewWindow -Wait
  $env:PATH = [Environment]::GetEnvVariable('PATH','Machine') + ";" + [Environment]::GetEnvVariable('PATH','User')
  Write-Host "Terraform ready."
}

#--- 3) Compute ISO checksum
Write-Host "Calculating ISO checksum..."
$isoHash = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash

#--- 4) Write Packer HCL
$hclIso = $IsoPath -replace '\\','/'  
$packerHcl = @"
variable "iso_path" { type=string default="$hclIso" }
source "vmware-iso" "vault_base" {
  vm_name         = "vault-base"; iso_url="file:///$hclIso"; iso_checksum_type="sha256"; iso_checksum="$isoHash"
  floppy_files    = ["Autounattend.xml"]; communicator="winrm"; winrm_username="Administrator"; winrm_password="\$DomainJoinPass"
  disk_size=81920; cpus=8; memory=32768
  shutdown_command="shutdown /s /t 5 /f /d p:4:1 /c \"Packer Shutdown\""
}
build { sources=["source.vmware-iso.vault_base"] }
"@
$packerHcl | Set-Content -Path (Join-Path $PSScriptRoot 'template.pkr.hcl') -Encoding UTF8
Write-Host "Wrote Packer template"

#--- 5) Build VM image
& packer init template.pkr.hcl; & packer build -force template.pkr.hcl

#--- 6) Get VM ID
$creds = New-Object System.Management.Automation.PSCredential($VmrestUser,(ConvertTo-SecureString $VmrestPassword -AsPlainText -Force))
Start-Sleep 5
$vms=Invoke-RestMethod 'http://127.0.0.1:8697/api/vms' -Credential $creds
$baseId=($vms|Where name -eq 'vault-base').id; Write-Host "Base VM ID: $baseId"

#--- 7) Generate Terraform and deploy
$tf= @"
terraform { required_providers { vmworkstation={source="elsudano/vmworkstation" version=">=1.0.4"}}}
provider "vmworkstation" {user=var.vmrest_user password=var.vmrest_password url="http://127.0.0.1:8697/api"}
"@ +
($InstallVault? @"
resource "vmworkstation_vm" "vault" { sourceid="$baseId" denomination="CyberArk-Vault" processors=8 memory=32768 path="$DeployPath/CyberArk-Vault" }
"@ : "") +
"""
# Add PVWA,CPM,PSM
@"
resource "vmworkstation_vm" "pvwa" { sourceid="$baseId" denomination="CyberArk-PVWA" processors=4 memory=8192 path="$DeployPath/CyberArk-PVWA" }
resource "vmworkstation_vm" "cpm"  { sourceid="$baseId" denomination="CyberArk-CPM"  processors=4 memory=8192 path="$DeployPath/CyberArk-CPM"  }
resource "vmworkstation_vm" "psm"  { sourceid="$baseId" denomination="CyberArk-PSM"  processors=4 memory=8192 path="$DeployPath/CyberArk-PSM"  }
"@
$tf | Set-Content -Path (Join-Path $PSScriptRoot 'terraform/main.tf') -Encoding UTF8
@"
variable "vmrest_user" { default="$VmrestUser"}
variable "vmrest_password" { default="$VmrestPassword"}
"@ | Set-Content -Path (Join-Path $PSScriptRoot 'terraform/variables.tf') -Encoding UTF8

Push-Location terraform
terraform init -upgrade; terraform plan -out=tfplan; terraform apply -auto-approve tfplan
Pop-Location

Write-Host "All done. VMs deployed." -ForegroundColor Green
