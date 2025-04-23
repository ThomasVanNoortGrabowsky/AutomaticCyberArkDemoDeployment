# Create-Servers.ps1
# CyberArk lab deployment: Packer → golden image → Terraform clones (Vault optional, plus PVWA/CPM/PSM)

$ErrorActionPreference = 'Stop'

#
# 0) Elevate to Administrator
#
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell `
    "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
    -Verb RunAs
  exit
}

#
# 1) Prompt for all needed variables
#
$IsoPath        = Read-Host "1) Windows Server ISO path (e.g. C:\ISOs\SERVER_EVAL.iso)"
$VmrestUser     = Read-Host "2) VMware REST API username"
$VmrestSecure   = Read-Host "3) VMware REST API password" -AsSecureString
$VmrestPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($VmrestSecure)
)
$InstallVault   = (Read-Host "4) Install Vault server? (Y/N)").ToUpper() -eq 'Y'
$DeployPath     = Read-Host "5) Base folder for VMs (e.g. C:\VMs)"
$DomainName     = Read-Host "6) Domain to join (e.g. corp.local)"
$DomainUser     = Read-Host "7) Domain join user (with rights to add machines)"

#
# 2) Generate Autounattend.xml for unattended install + domain join
#
$autoXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <Key>/IMAGE/NAME</Key>
              <Value>Windows Server 2022 SERVERSTANDARDCORE</Value>
            </MetaData>
          </InstallFrom>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>Administrator</FullName>
        <Organization>CyberArk</Organization>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-UnattendedJoin" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <Identification>
        <Credentials>
          <Domain>$DomainName</Domain>
          <Username>$DomainUser</Username>
          <Password>Cyberark1</Password>
        </Credentials>
        <JoinDomain>$DomainName</JoinDomain>
      </Identification>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>1</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>Cyberark1</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <RegisteredOrganization>CyberArk</RegisteredOrganization>
      <RegisteredOwner>Administrator</RegisteredOwner>
    </component>
  </settings>
</unattend>
"@

$autoXml | Set-Content -Path "$PSScriptRoot\Autounattend.xml" -Encoding ASCII
Write-Host "-> Autounattend.xml generated." -ForegroundColor Green

#
# 3) Regenerate netmap.conf via vnetlib64.exe (no GUI needed)
#
$wsDir      = 'C:\Program Files (x86)\VMware\VMware Workstation'
$vnetTool   = Join-Path $wsDir 'vnetlib64.exe'    # if using 32-bit, change to 'vnetlib.exe'
$exportFile = Join-Path $env:TEMP 'vnetconfig.txt'

if (-not (Test-Path $vnetTool)) {
  Write-Error "vnetlib64.exe not found at $vnetTool; install VMware Workstation correctly."
  exit 1
}

Write-Host "-> Exporting VMware network settings…" -ForegroundColor Cyan
& $vnetTool --export $exportFile
if ($LASTEXITCODE -ne 0) {
  Write-Error "vnetlib export failed (code $LASTEXITCODE)"
  exit 1
}

Write-Host "-> Importing network settings, regenerating netmap.conf…" -ForegroundColor Cyan
& $vnetTool --import $exportFile
if ($LASTEXITCODE -ne 0) {
  Write-Error "vnetlib import failed (code $LASTEXITCODE)"
  exit 1
}

$destNetmap = Join-Path $wsDir 'netmap.conf'
if (Test-Path $destNetmap) {
  Write-Host "-> netmap.conf successfully regenerated." -ForegroundColor Green
} else {
  Write-Error "netmap.conf still missing after import!"
  exit 1
}

#
# 4) Write the Packer HCL template
#
$hclIsoPath = $IsoPath.Replace('\','/')
$hash       = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash

$packerHcl = @"
source "vmware-iso" "vault_base" {
  iso_url           = "file:///$hclIsoPath"
  iso_checksum      = "sha256:$hash"
  communicator      = "winrm"
  winrm_username    = "Administrator"
  winrm_password    = "Cyberark1"
  floppy_files      = ["Autounattend.xml"]
  disk_size         = 81920
  cpus              = 8
  memory            = 32768
  shutdown_command  = "shutdown /s /t 5 /f /d p:4:1 /c `"Packer Shutdown`""
}
build {
  sources = ["source.vmware-iso.vault_base"]
}
"@

Set-Content -Path "$PSScriptRoot\template.pkr.hcl" -Value $packerHcl -Encoding ASCII
Write-Host "-> Packer template written." -ForegroundColor Green

#
# 5) Run Packer
#
Write-Host "-> Running Packer init & build..." -ForegroundColor Cyan
& packer init "$PSScriptRoot\template.pkr.hcl" 2>&1 | Write-Host
if ($LASTEXITCODE -ne 0) { Write-Error "Packer init failed"; exit 1 }
& packer build -force "$PSScriptRoot\template.pkr.hcl" 2>&1 | Write-Host
if ($LASTEXITCODE -ne 0) { Write-Error "Packer build failed"; exit 1 }

#
# 6) Restart vmrest daemon
#
Stop-Process -Name vmrest -ErrorAction SilentlyContinue -Force
Start-Process "$wsDir\vmrest.exe" -ArgumentList "-b" -WindowStyle Hidden
Start-Sleep -Seconds 5

#
# 7) Fetch golden VM ID via Basic-auth
#
$url    = 'http://127.0.0.1:8697/api/vms'
$pair   = $VmrestUser + ':' + $VmrestPassword
$token  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$headers = @{ Authorization = "Basic $token" }

try {
  $VMs = Invoke-RestMethod -Uri $url -Headers $headers
} catch {
  Write-Error "Authentication to vmrest failed!"; exit 1
}

$BaseId = ($VMs | Where-Object name -eq 'vault_base').id
Write-Host "-> Golden VM ID: $BaseId" -ForegroundColor Green

#
# 8) Generate Terraform project
#
$tfDir = Join-Path $PSScriptRoot 'terraform'
if (Test-Path $tfDir) { Remove-Item $tfDir -Recurse -Force }
New-Item -Path $tfDir -ItemType Directory | Out-Null

# main.tf
$main = @"
terraform {
  required_providers {
    vmworkstation = {
      source  = "elsudano/vmworkstation"
      version = ">= 1.0.4"
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

foreach ($c in 'PVWA','CPM','PSM') {
  $lower = $c.ToLower()
  $main += @"
resource "vmworkstation_vm" "$lower" {
  sourceid     = "$BaseId"
  denomination = "CyberArk-$c"
  processors   = 4
  memory       = 8192
  path         = "$DeployPath\CyberArk-$c"
}
"@
}

Set-Content -Path (Join-Path $tfDir 'main.tf') -Value $main -Encoding ASCII

# variables.tf
$vars = @"
variable "vmrest_user" {
  default = "$VmrestUser"
}
variable "vmrest_password" {
  default = "$VmrestPassword"
}
"@

Set-Content -Path (Join-Path $tfDir 'variables.tf') -Value $vars -Encoding ASCII

#
# 9) Deploy with Terraform
#
Push-Location $tfDir
terraform init -upgrade | Write-Host
terraform plan -out=tfplan | Write-Host
terraform apply -auto-approve tfplan | Write-Host
Pop-Location

Write-Host "Deployment complete!" -ForegroundColor Green
