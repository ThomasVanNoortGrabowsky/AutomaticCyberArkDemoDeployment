<#
.SYNOPSIS
  Build and deploy CyberArk servers (Vault + PVWA/CPM/PSM) on VMware Workstation using Packer and Terraform.

.DESCRIPTION
  1. Prompts for ISO path, REST-API credentials, Vault inclusion, deploy path, and domain join info.
  2. Generates Autounattend.xml for unattended Windows install with domain join.
  3. Installs Packer & Terraform if missing.
  4. Builds a golden "vault-base" VM image using Packer, with error checks.
  5. Ensures vmrest daemon is stopped/restarted (requires elevation), then retrieves the VM ID via Basic auth.
  6. Generates Terraform configs (main.tf, variables.tf) and applies them to clone Vault (optional) plus PVWA/CPM/PSM.
#>

#--- Elevate to Admin for vmrest control
function Test-IsAdmin {
  $current = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($current)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-IsAdmin)) {
  Write-Host 'Restarting script as Administrator...' -ForegroundColor Yellow
  $psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
  Start-Process -FilePath $psExe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"" -Verb RunAs
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
$UnattendXml | Set-Content -Path (Join-Path $PSScriptRoot 'Autounattend.xml') -Encoding UTF8
Write-Host 'Autounattend.xml generated.' -ForegroundColor Green

#--- 3) Install Packer & Terraform if missing
$packerExe = Join-Path $PSScriptRoot 'packer-bin\packer.exe'
if (-not (Test-Path $packerExe)) {
  Write-Host 'Downloading Packer...' -ForegroundColor Yellow
  $ver='1.8.6'; $zip="$env:TEMP\packer_${ver}.zip";$url="https://releases.hashicorp.com/packer/$ver/packer_${ver}_windows_amd64.zip"
  Invoke-WebRequest $url -OutFile $zip
  $pd=Split-Path $packerExe -Parent; New-Item $pd -ItemType Directory -Force | Out-Null
  Expand-Archive $zip -DestinationPath $pd -Force; Remove-Item $zip
  Write-Host 'Packer downloaded.' -ForegroundColor Green
}
if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
  Write-Host 'Installing Terraform via winget...' -ForegroundColor Yellow
  Start-Process winget -ArgumentList 'install','--id','HashiCorp.Terraform','-e','--accept-package-agreements','--accept-source-agreements' -NoNewWindow -Wait
  Write-Host 'Terraform installed.' -ForegroundColor Green
}

#--- 4) Compute ISO checksum
Write-Host 'Calculating ISO checksum...' -ForegroundColor Cyan
$IsoHash=(Get-FileHash -Path $IsoPath -Algorithm SHA256).Hash

#--- 5) Create Packer template
$HclIso=$IsoPath -replace '\\','/' 
$PkrHcl=@"
variable "iso_path" { default="$HclIso" }
source "vmware-iso" "vault_base" {
  vm_name="vault-base"
  iso_url="file:///$HclIso"
  iso_checksum_type="sha256"
  iso_checksum="$IsoHash"
  floppy_files=["Autounattend.xml"]
  communicator="winrm"
  winrm_username="Administrator"
  winrm_password="$DomainPass"
  disk_size=81920
  cpus=8
  memory=32768
  shutdown_command="shutdown /s /t 5 /f /d p:4:1 /c 'Packer Shutdown'"
}
build{sources=["source.vmware-iso.vault_base"]}
"@
$PkrHcl|Set-Content (Join-Path $PSScriptRoot 'template.pkr.hcl') -Encoding UTF8
Write-Host 'Packer template written.' -ForegroundColor Green

#--- 6) Build golden VM image
Write-Host 'Running Packer build...' -ForegroundColor Cyan
$init=$(& $packerExe init template.pkr.hcl 2>&1)
if($LASTEXITCODE -ne 0){Write-Error "Packer init failed:`n$init";exit 1}
$build=$(& $packerExe build -force template.pkr.hcl 2>&1)
if($LASTEXITCODE -ne 0){Write-Error "Packer build failed:`n$build";exit 1}

#--- 7) Manage vmrest and retrieve VM ID
$vmrestExe='C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
if(-not(Test-Path $vmrestExe)){Write-Error"vmrest.exe not found";exit 1}
Get-Process vmrest -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
Start-Process $vmrestExe -ArgumentList '-b' -WindowStyle Hidden;Start-Sleep 5
$url='http://127.0.0.1:8697/api/vms'
$pair="${VmrestUser}:${VmrestPassword}"
$token=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$headers=@{Authorization="Basic $token"}
try{$VMs=Invoke-RestMethod -Uri $url -Headers $headers}else{Write-Error"vmrest auth failed";exit 1}
$BaseId=($VMs|Where name -eq 'vault-base').id;Write-Host"Golden VM ID: $BaseId" -ForegroundColor Green

#--- 8) Generate Terraform configs
$tfDir=Join-Path $PSScriptRoot 'terraform';if(-not(Test-Path $tfDir)){New-Item $tfDir -ItemType Directory}
$MainTf=@"
terraform{required_providers{vmworkstation={source="elsudano/vmworkstation"version=">=1.0.4"}}}

provider"vmworkstation"{user=var.vmrest_user password=var.vmrest_password url="http://127.0.0.1:8697/api"}
"@
if($InstallVault){$MainTf+=@"
resource"vmworkstation_vm""vault"{sourceid="$BaseId"denomination="CyberArk-Vault"processors=8memory=32768path="$DeployPath\CyberArk-Vault"}
"@}
foreach($c in'PVWA','CPM','PSM'){$MainTf+=@"
resource"vmworkstation_vm""${c.ToLower()}"{sourceid="$BaseId"denomination="CyberArk-$c"processors=4memory=8192path="$DeployPath\CyberArk-$c"}
"@}
$MainTf|Set-Content(Join-Path $tfDir 'main.tf') -Encoding UTF8
$VarsTf=@"
variable"vmrest_user"{default="$VmrestUser"}
variable"vmrest_password"{default="$VmrestPassword"}
"@
$VarsTf|Set-Content(Join-Path $tfDir 'variables.tf') -Encoding UTF8

#--- 9) Deploy via Terraform
Write-Host 'Deploying via Terraform...' -ForegroundColor Cyan
Push-Location $tfDir;terraform init -upgrade|Out-Null;terraform plan -out=tfplan;terraform apply -auto-approve tfplan;Pop-Location
Write-Host 'Deployment complete!' -ForegroundColor Green
