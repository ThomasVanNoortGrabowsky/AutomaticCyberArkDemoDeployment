# Create-Servers.ps1
# Automated CyberArk lab: Packer → golden image → Terraform clones

$ErrorActionPreference = 'Stop'

# 0) Elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
  exit
}

# 1) Ensure Packer is installed via winget if missing
if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
  Write-Host "Packer not found. Installing via winget..." -ForegroundColor Yellow
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Start-Process winget -ArgumentList @(
      'install', '--id', 'HashiCorp.Packer', '-e', '--source', 'winget'
    ) -NoNewWindow -Wait
  } else {
    Write-Error "winget not available; please install Packer manually."
    exit 1
  }
  Write-Host "-> Packer installed." -ForegroundColor Green
} else {
  Write-Host "-> Packer already present: $(packer version)" -ForegroundColor Green
}

# 2) Prompt for inputs
$IsoPath          = Read-Host "1) Windows Server ISO path (e.g. C:\ISOs\SERVER_EVAL.iso)"
$VmrestUser       = Read-Host "2) vmrest API username"
$VmrestPassSecure = Read-Host "3) vmrest API password" -AsSecureString
$VmrestPassword   = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($VmrestPassSecure)
)
$InstallVault     = (Read-Host "4) Install Vault server? (Y/N)").ToUpper() -eq 'Y'
$DeployPath       = Read-Host "5) Base folder for VMs (e.g. C:\VMs)"
$DomainName       = Read-Host "6) Domain to join (e.g. corp.local)"
$DomainUser       = Read-Host "7) Domain join user (with rights)"

# 3) Generate Autounattend.xml for unattended + domain join
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

# 4) Write minimal netmap.conf so Packer sees vmnet mappings 
$wsDir    = 'C:\Program Files (x86)\VMware\VMware Workstation'
$netmap   = Join-Path $wsDir 'netmap.conf'
if (-not (Test-Path $netmap)) {
  @"
# Minimal netmap.conf for Packer
network0.name = "Bridged"
network0.device = "vmnet0"
network1.name = "HostOnly"
network1.device = "vmnet1"
network8.name = "NAT"
network8.device = "vmnet8"
"@ | Set-Content $netmap -Encoding ASCII
  Write-Host "-> Written minimal netmap.conf." -ForegroundColor Green
}

# 5) Create Packer HCL for golden image build
$hclIso = $IsoPath.Replace('\','/')
$hash   = (Get-FileHash $IsoPath -Algorithm SHA256).Hash
$packerHcl = @"
source "vmware-iso" "vault_base" {
  iso_url           = "file:///$hclIso"
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
Set-Content "$PSScriptRoot\template.pkr.hcl" $packerHcl -Encoding ASCII
Write-Host "-> Packer template written." -ForegroundColor Green

# 6) Run Packer init & build
Write-Host "-> Running Packer init & build..." -ForegroundColor Cyan
& packer init "$PSScriptRoot\template.pkr.hcl" 2>&1 | Write-Host
if ($LASTEXITCODE -ne 0) { Write-Error "Packer init failed"; exit 1 }
& packer build -force "$PSScriptRoot\template.pkr.hcl" 2>&1 | Write-Host
if ($LASTEXITCODE -ne 0) { Write-Error "Packer build failed"; exit 1 }

# 7) Restart vmrest & fetch golden VM ID
Stop-Process vmrest -ErrorAction SilentlyContinue -Force
Start-Process "$wsDir\vmrest.exe" -ArgumentList "-b" -WindowStyle Hidden
Start-Sleep 5
$url    = 'http://127.0.0.1:8697/api/vms'
$pair   = $VmrestUser + ':' + $VmrestPassword
$token  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$headers = @{ Authorization = "Basic $token" }
try {
  $VMs = Invoke-RestMethod -Uri $url -Headers $headers
} catch {
  Write-Error "vmrest authentication failed"; exit 1
}
$BaseId = ($VMs | Where-Object name -eq 'vault_base').id
Write-Host "-> Golden VM ID: $BaseId" -ForegroundColor Green

# 8) Generate Terraform configs & deploy
$tfDir = Join-Path $PSScriptRoot 'terraform'
if (Test-Path $tfDir) { Remove-Item $tfDir -Recurse -Force }
New-Item $tfDir -ItemType Directory | Out-Null

$main = @"
terraform {
  required_providers {
    vmworkstation = { source = "elsudano/vmworkstation"; version = ">= 1.0.4" }
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

$vars = @"
variable "vmrest_user"    { default = "$VmrestUser" }
variable "vmrest_password"{ default = "$VmrestPassword" }
"@
Set-Content (Join-Path $tfDir 'variables.tf') $vars -Encoding ASCII

Push-Location $tfDir
terraform init -upgrade | Write-Host
terraform plan -out=tfplan | Write-Host
terraform apply -auto-approve tfplan | Write-Host
Pop-Location

Write-Host "Deployment complete!" -ForegroundColor Green
