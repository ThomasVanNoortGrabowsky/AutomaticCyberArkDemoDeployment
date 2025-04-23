# Create-Servers.ps1
# CyberArk lab: Unattended ISO → Packer golden image → Terraform clones

$ErrorActionPreference = 'Stop'

# -- 0) Elevate to Admin --
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process pwsh "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
  exit
}

# -- 1) Download Packer Locally --
$packerVersion = "1.11.4"
$installDir    = Join-Path $PSScriptRoot "packer-bin"
$packerExe     = Join-Path $installDir "packer.exe"
if (-not (Test-Path $packerExe)) {
  Write-Host "Downloading Packer v$packerVersion…" -ForegroundColor Cyan
  if (-not (Test-Path $installDir)) { New-Item -Path $installDir -ItemType Directory | Out-Null }
  $zip = Join-Path $installDir "packer.zip"
  Invoke-WebRequest `
    -Uri "https://releases.hashicorp.com/packer/$packerVersion/packer_${packerVersion}_windows_amd64.zip" `
    -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $installDir -Force
  Remove-Item $zip
  Write-Host "-> Packer installed at $installDir" -ForegroundColor Green
}

# -- 2) Prompt for Inputs --
$IsoPath        = Read-Host "1) Windows Server ISO path (e.g. C:\ISOs\SERVER_EVAL.iso)"
$VmrestUser     = Read-Host "2) vmrest API username"
$VmrestSecure   = Read-Host "3) vmrest API password" -AsSecureString
$VmrestPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($VmrestSecure)
)
$InstallVault   = (Read-Host "4) Install Vault server? (Y/N)").ToUpper() -eq 'Y'
$DeployPath     = Read-Host "5) Base folder for VMs (e.g. C:\VMs)"
$DomainName     = Read-Host "6) Domain to join (e.g. corp.local)"
$DomainUser     = Read-Host "7) Domain join user (with rights)"

# -- 3) Write Autounattend.xml for Unattended + Domain-Join --
$autoXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" versionScope="nonSxS">
      <ImageInstall><OSImage><InstallFrom>
        <MetaData wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Key>/IMAGE/NAME</Key>
          <Value>Windows Server 2022 SERVERSTANDARDCORE</Value>
        </MetaData>
      </InstallFrom><WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>
      <UserData><AcceptEula>true</AcceptEula><FullName>Administrator</FullName><Organization>CyberArk</Organization></UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-UnattendedJoin" processorArchitecture="amd64" versionScope="nonSxS">
      <Identification><Credentials>
        <Domain>$DomainName</Domain>
        <Username>$DomainUser</Username>
        <Password>Cyberark1</Password>
      </Credentials>
      <JoinDomain>$DomainName</JoinDomain>
      </Identification>
    </component>
  </settings>
</unattend>
"@
$autoXml | Set-Content "$PSScriptRoot\Autounattend.xml" -Encoding ASCII
Write-Host "-> Autounattend.xml generated." -ForegroundColor Green

# -- 4) Write Minimal netmap.conf in BOTH locations --
$wsDir       = 'C:\Program Files (x86)\VMware\VMware Workstation'
$pathsToFill = @(
  Join-Path $wsDir            'netmap.conf', 
  Join-Path $env:ProgramData   'VMware\netmap.conf'
)
$netmap = @"
# Minimal netmap.conf for Packer
network0.name   = "Bridged"
network0.device = "vmnet0"
network1.name   = "HostOnly"
network1.device = "vmnet1"
network8.name   = "NAT"
network8.device = "vmnet8"
"@
foreach ($p in $pathsToFill) {
  $dir = Split-Path $p -Parent
  if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
  $netmap | Set-Content -Path $p -Encoding ASCII
  Write-Host "-> Wrote fallback netmap.conf to $p" -ForegroundColor Green
}

# -- 5) Generate Packer HCL Template (force NAT network) --
$hclIso   = $IsoPath.Replace('\','/')
$checksum = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
$hcl      = @"
source "vmware-iso" "vault_base" {
  iso_url           = "file:///$hclIso"
  iso_checksum      = "sha256:$checksum"
  network           = "nat"                         # ← Force NAT, skip any lookup errors :contentReference[oaicite:3]{index=3}
  communicator      = "winrm"
  winrm_username    = "Administrator"
  winrm_password    = "Cyberark1"
  floppy_files      = ["Autounattend.xml"]
  disk_size         = 81920
  cpus              = 8
  memory            = 32768
  shutdown_command  = "shutdown /s /t 5 /f /d p:4:1 /c \"Packer Shutdown\""
}
build { sources = ["source.vmware-iso.vault_base"] }
"@
Set-Content "$PSScriptRoot\template.pkr.hcl" $hcl -Encoding ASCII
Write-Host "-> Packer template written." -ForegroundColor Green

# -- 6) Run Packer init & build --
Write-Host "-> Running Packer init & build…" -ForegroundColor Cyan
& $packerExe init "$PSScriptRoot\template.pkr.hcl" | Write-Host
if ($LASTEXITCODE -ne 0) { Write-Error "Packer init failed"; exit 1 }
& $packerExe build -force "$PSScriptRoot\template.pkr.hcl" | Write-Host
if ($LASTEXITCODE -ne 0) { Write-Error "Packer build failed"; exit 1 }

# -- 7) Restart vmrest & fetch Golden VM ID via Basic Auth --
Stop-Process -Name vmrest -Force -ErrorAction SilentlyContinue
Start-Process "$wsDir\vmrest.exe" -ArgumentList "-b" -WindowStyle Hidden
Start-Sleep 5
$url     = 'http://127.0.0.1:8697/api/vms'
$pair    = "$VmrestUser`:$VmrestPassword"
$token   = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$headers = @{ Authorization = "Basic $token" }
try {
  $VMs = Invoke-RestMethod -Uri $url -Headers $headers
} catch {
  Write-Error "vmrest authentication failed"; exit 1
}
$BaseId = ($VMs | Where-Object name -eq 'vault_base').id
Write-Host "-> Golden VM ID: $BaseId" -ForegroundColor Green

# -- 8) Generate &  Apply Terraform Project --
$tfDir = Join-Path $PSScriptRoot 'terraform'
if (Test-Path $tfDir) { Remove-Item $tfDir -Recurse -Force }
New-Item $tfDir -ItemType Directory | Out-Null

# main.tf
$main = @"
terraform {
  required_providers {
    vmworkstation = { source = "elsudano/vmworkstation"; version = ">=1.0.4" }
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
Set-Content (Join-Path $tfDir 'main.tf') $main -Encoding ASCII

# variables.tf
$vars = @"
variable "vmrest_user"    { default = "$VmrestUser" }
variable "vmrest_password"{ default = "$VmrestPassword" }
"@
Set-Content (Join-Path $tfDir 'variables.tf') $vars -Encoding ASCII

# Deploy
Push-Location $tfDir
terraform init -upgrade | Write-Host
terraform plan -out=tfplan | Write-Host
terraform apply -auto-approve tfplan | Write-Host
Pop-Location

Write-Host "Deployment complete!" -ForegroundColor Green
