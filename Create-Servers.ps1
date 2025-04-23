<#
.SYNOPSIS
  Build a golden Windows Server VM via Packer (Windows unattended with Autounattend.xml) and then clone it via Terraform.

.DESCRIPTION
  1. Prompts for ISO path, Vault inclusion, deploy path, and domain details.
  2. Generates Autounattend.xml dynamically with domain join.
  3. Ensures Packer and Terraform are installed.
  4. Builds a golden VM via Packer (vmware-iso).
  5. Retrieves golden VM ID from the Workstation REST API.
  6. Generates a Terraform project that clones the Vault (optional) and PVWA/CPM/PSM servers.
  7. Runs terraform init, plan, and apply.
#>

#region ← User settings
$IsoPathDefault    = 'C:\Users\ThomasvanNoort\Downloads\SERVER_EVAL_x64FRE_en-us.iso'
$VmrestUser        = 'vmrest'
$VmrestPassword    = 'Cyberark1'
#endregion

# Prompts
$IsoPath       = Read-Host "Enter ISO path or press Enter to use default [$IsoPathDefault]"
if ([string]::IsNullOrWhiteSpace($IsoPath)) { $IsoPath = $IsoPathDefault }
$InstallVault  = (Read-Host 'Install Vault server? (Y/N)').Trim().ToUpper() -eq 'Y'
$DeployPath    = Read-Host 'Deploy base folder (e.g. C:\VMs)'
$DomainName    = Read-Host 'Domain to join (e.g. corp.local)'
$DomainUser    = Read-Host 'Domain join user (e.g. joinuser)'
$DomainPass    = 'Cyberark1'

# 1) Generate Autounattend.xml
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
      <AutoLogon><Username>Administrator</Username>
        <Password><Value>$DomainPass</Value><PlainText>true</PlainText></Password><Enabled>false</Enabled>
      </AutoLogon>
      <TimeZone>W. Europe Standard Time</TimeZone>
    </component>
  </settings>
</unattend>
"@
$unattend | Set-Content -Path (Join-Path $PSScriptRoot 'Autounattend.xml') -Encoding UTF8
Write-Host "Created Autounattend.xml"

# 2) Ensure Packer
if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
  Write-Host 'Downloading Packer...' -ForegroundColor Yellow
  $ver='1.8.6'; $zip="$env:TEMP\packer_$ver.zip"; $url="https://releases.hashicorp.com/packer/$ver/packer_${ver}_windows_amd64.zip"
  Invoke-WebRequest $url -OutFile $zip
  $pd=Join-Path $PSScriptRoot 'packer-bin'; New-Item $pd -ItemType Directory -Force | Out-Null
  Expand-Archive $zip -DestinationPath $pd -Force; Remove-Item $zip
  $env:PATH = "$pd;$env:PATH"; Write-Host 'Packer ready.'
}
# Ensure Terraform
if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
  Write-Host 'Installing Terraform...' -ForegroundColor Yellow
  Start-Process winget -ArgumentList 'install','--id','HashiCorp.Terraform','-e','--accept-package-agreements','--accept-source-agreements' -NoNewWindow -Wait
  $env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH','User')
  Write-Host 'Terraform ready.'
}

# 3) ISO checksum
Write-Host 'Calculating ISO checksum...'
$isoHash=(Get-FileHash -Path $IsoPath -Algorithm SHA256).Hash

# 4) Write Packer template
$hclIso=$IsoPath -replace '\\','/' 
$packerHcl = @"
variable "iso_path" { default="$hclIso" }
source "vmware-iso" "base" {
  vm_name = "vault-base"
  iso_url = "file:///$hclIso"
  iso_checksum_type = "sha256"
  iso_checksum = "$isoHash"
  floppy_files = ["Autounattend.xml"]
  communicator = "winrm"
  winrm_username = "Administrator"
  winrm_password = "$DomainPass"
  disk_size = 81920
  cpus = 8
  memory = 32768
  shutdown_command = "shutdown /s /t 5 /f /d p:4:1 /c 'Packer Shutdown'"
}
build { sources = ["source.vmware-iso.base"] }
"@
$packerHcl | Set-Content -Path (Join-Path $PSScriptRoot 'template.pkr.hcl') -Encoding UTF8
Write-Host 'Packer template written.'

# 5) Build image
Write-Host 'Building golden image...'
& packer init template.pkr.hcl; & packer build -force template.pkr.hcl

# 6) Get VM ID
$creds=New-Object System.Management.Automation.PSCredential($VmrestUser,(ConvertTo-SecureString $VmrestPassword -AsPlainText -Force))
Start-Sleep 5
$vms=Invoke-RestMethod http://127.0.0.1:8697/api/vms -Credential $creds
$baseId = ($vms | Where-Object name -eq 'vault-base').id
Write-Host "Base VM ID: $baseId"

# 7) Generate Terraform
$tfDir = Join-Path $PSScriptRoot 'terraform'; Remove-Item $tfDir -Recurse -Force -ErrorAction SilentlyContinue; New-Item $tfDir -ItemType Directory | Out-Null

$tfLines = @()
$tfLines += 'terraform { required_providers { vmworkstation={ source="elsudano/vmworkstation" version=">=1.0.4" } } }'
$tfLines += 'provider "vmworkstation" { user=var.vmrest_user password=var.vmrest_password url="http://127.0.0.1:8697/api" }'
if ($InstallVault) {
  $tfLines += "resource \"vmworkstation_vm\" \"vault\" { sourceid=\"$baseId\" denomination=\"CyberArk-Vault\" processors=8 memory=32768 path=\"$DeployPath/CyberArk-Vault\" }"
}
foreach ($comp in @('PVWA','CPM','PSM')) {
  $tfLines += "resource \"vmworkstation_vm\" \"$($comp.ToLower())\" { sourceid=\"$baseId\" denomination=\"CyberArk-$comp\" processors=4 memory=8192 path=\"$DeployPath/CyberArk-$comp\" }"
}
$tfLines | Set-Content -Path (Join-Path $tfDir 'main.tf') -Encoding UTF8

@"
variable "vmrest_user" { default="$VmrestUser" }
variable "vmrest_password" { default="$VmrestPassword" }
"@ | Set-Content -Path (Join-Path $tfDir 'variables.tf') -Encoding UTF8

# 8) Terraform deploy
Push-Location $tfDir
terraform init -upgrade
terraform plan -out=tfplan
terraform apply -auto-approve tfplan
Pop-Location

Write-Host 'All done.' -ForegroundColor Green
