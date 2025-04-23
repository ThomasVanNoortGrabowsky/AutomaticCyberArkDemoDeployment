# Create-Servers.ps1
# CyberArk lab: unattended ISO → Packer golden image → Terraform clones

$ErrorActionPreference = 'Stop'

# 0) Elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process pwsh "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
  exit
}

# 1) User inputs
$IsoPath          = Read-Host "1) Path to Windows Server ISO (e.g. C:\ISOs\SERVER_EVAL.iso)"
$VmrestUser       = Read-Host "2) vmrest API username"
$VmrestPassSecure = Read-Host "3) vmrest API password" -AsSecureString
$VmrestPassword   = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($VmrestPassSecure)
)
$InstallVault     = (Read-Host "4) Install Vault server? (Y/N)").ToUpper() -eq 'Y'
$DeployPath       = Read-Host "5) Base folder for VMs (e.g. C:\VMs)"
$DomainName       = Read-Host "6) Domain to join (e.g. corp.local)"
$DomainUser       = Read-Host "7) Domain join user (with rights)"

# 2) Autounattend.xml (unattended Windows install + domain join)
$autoXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ImageInstall><OSImage><InstallFrom>
        <MetaData wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Key>/IMAGE/NAME</Key>
          <Value>Windows Server 2022 SERVERSTANDARDCORE</Value>
        </MetaData>
      </InstallFrom><WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>Administrator</FullName>
        <Organization>CyberArk</Organization>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-UnattendedJoin" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
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

# 3) Minimal netmap.conf so Packer can map vmnet0/1/8 :contentReference[oaicite:2]{index=2}
$wsDir      = 'C:\Program Files (x86)\VMware\VMware Workstation'
$confPath   = Join-Path $wsDir 'netmap.conf'
if (-not (Test-Path $confPath)) {
  @"
# Minimal netmap.conf for Packer
network0.name = "Bridged"
network0.device = "vmnet0"
network1.name = "HostOnly"
network1.device = "vmnet1"
network8.name = "NAT"
network8.device = "vmnet8"
"@ | Set-Content -Path $confPath -Encoding ASCII
  Write-Host "-> Minimal netmap.conf written." -ForegroundColor Green
}

# 4) Packer HCL template (vmware-iso builder) :contentReference[oaicite:3]{index=3}
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
build { sources = ["source.vmware-iso.vault_base"] }
"@
Set-Content "$PSScriptRoot\template.pkr.hcl" -Value $packerHcl -Encoding ASCII
Write-Host "-> Packer template written." -ForegroundColor Green

# 5) Run Packer init & build
Write-Host "-> Running Packer init & build..." -ForegroundColor Cyan
& packer init "$PSScriptRoot\template.pkr.hcl" 2>&1 | Write-Host
if ($LASTEXITCODE -ne 0) { Write-Error "Packer init failed"; exit 1 }
& packer build -force "$PSScriptRoot\template.pkr.hcl" 2>&1 | Write-Host
if ($LASTEXITCODE -ne 0) { Write-Error "Packer build failed"; exit 1 }

# 6) Restart vmrest, then fetch golden VM ID :contentReference[oaicite:4]{index=4}
Stop-Process -Name vmrest -ErrorAction SilentlyContinue -Force
Start-Process "$wsDir\vmrest.exe" -ArgumentList "-b" -WindowStyle Hidden
Start-Sleep -Seconds 5

$url    = 'http://127.0.0.1:8697/api/vms'
$pair   = "$VmrestUser`:$VmrestPassword"
$token  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$headers = @{ Authorization = "Basic $token" }

try {
  $VMs = Invoke-RestMethod -Uri $url -Headers $headers
} catch {
  Write-Error "vmrest authentication failed"; exit 1
}
$BaseId = ($VMs | Where-Object name -eq 'vault_base').id
Write-Host "-> Golden VM ID: $BaseId" -ForegroundColor Green

# 7) Generate Terraform files and deploy :contentReference[oaicite:5]{index=5}
$tfDir = Join-Path $PSScriptRoot 'terraform'
if (Test-Path $tfDir) { Remove-Item $tfDir -Recurse -Force }
New-Item $tfDir -ItemType Directory | Out-Null

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
Set-Content (Join-Path $tfDir 'main.tf') $main -Encoding ASCII

# variables.tf
$vars = @"
variable "vmrest_user" { default = "$VmrestUser" }
variable "vmrest_password" { default = "$VmrestPassword" }
"@
Set-Content (Join-Path $tfDir 'variables.tf') $vars -Encoding ASCII

# Terraform deploy
Push-Location $tfDir
terraform init -upgrade | Write-Host
terraform plan -out=tfplan | Write-Host
terraform apply -auto-approve tfplan | Write-Host
Pop-Location

Write-Host "Deployment complete!" -ForegroundColor Green
