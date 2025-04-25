<#
  Create-Servers.ps1
  -------------------
  Automated CyberArk lab:
    1) Unattended Windows ISO → Packer golden image
    2) vmrest-backed Terraform clones of Vault (optional) + PVWA/CPM/PSM
#>

$ErrorActionPreference = 'Stop'

### 0) Elevate to Admin ###
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process pwsh "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

### 1) Ensure Packer ###
$packerVersion = "1.11.4"
$installDir    = Join-Path $PSScriptRoot "packer-bin"
$packerExe     = Join-Path $installDir "packer.exe"
if (-not (Test-Path $packerExe)) {
    Write-Host "Downloading Packer v$packerVersion…" -ForegroundColor Cyan
    New-Item $installDir -ItemType Directory -Force | Out-Null
    $zip = Join-Path $installDir "packer.zip"
    Invoke-WebRequest -Uri "https://releases.hashicorp.com/packer/$packerVersion/packer_${packerVersion}_windows_amd64.zip" -OutFile $zip
    Expand-Archive $zip $installDir -Force
    Remove-Item $zip
    Write-Host "-> Packer installed." -ForegroundColor Green
}

### 2) Prompt for inputs ###
$IsoPath        = Read-Host "1) Windows ISO path (e.g. C:\ISOs\WIN11.iso)"
if (-not (Test-Path $IsoPath -PathType Leaf)) { Write-Error "ISO not found"; exit 1 }
$VmrestUser     = Read-Host "2) vmrest API username"
$VmrestSecure   = Read-Host "3) vmrest API password" -AsSecureString
$VmrestPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($VmrestSecure)
)
$InstallVault   = (Read-Host "4) Install Vault server? (Y/N)").ToUpper() -eq 'Y'
$DeployPath     = Read-Host "5) Base folder for VMs (e.g. C:\VMs)"
$DomainName     = Read-Host "6) Domain to join (e.g. corp.local)"
$DomainUser     = Read-Host "7) Domain join user (with rights)"

### 3) Generate Autounattend.xml with 4-partition layout + domain join ###
$xml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

  <!-- windowsPE PASS: DiskConfiguration (500+100+128+rest), EULA, image selection -->
  <settings pass="windowsPE">
  <component name="Microsoft-Windows-Setup"
             processorArchitecture="amd64"
             publicKeyToken="31bf3856ad364e35"
             language="neutral"
             versionScope="nonSxS"
             xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

    <!-- 1. Disk setup: wipe disk and create 4 partitions -->
    <DiskConfiguration>
      <Disk wcm:action="add">
        <DiskID>0</DiskID>
        <WillWipeDisk>true</WillWipeDisk>
        <CreatePartitions>
          <CreatePartition wcm:action="add">
            <Order>1</Order>
            <Size>500</Size>
            <Type>Primary</Type>
          </CreatePartition>
          <CreatePartition wcm:action="add">
            <Order>2</Order>
            <Size>100</Size>
            <Type>EFI</Type>
          </CreatePartition>
          <CreatePartition wcm:action="add">
            <Order>3</Order>
            <Size>128</Size>
            <Type>MSR</Type>
          </CreatePartition>
          <CreatePartition wcm:action="add">
            <Order>4</Order>
            <Extend>true</Extend>
            <Type>Primary</Type>
          </CreatePartition>
        </CreatePartitions>
        <ModifyPartitions>
          <ModifyPartition wcm:action="add">
            <Order>1</Order>
            <PartitionID>1</PartitionID>
            <Label>Recovery</Label>
            <Format>NTFS</Format>
            <TypeID>de94bba4-06d1-4d40-a16a-bfd50179d6ac</TypeID>
          </ModifyPartition>
          <ModifyPartition wcm:action="add">
            <Order>2</Order>
            <PartitionID>2</PartitionID>
            <Label>System</Label>
            <Format>FAT32</Format>
          </ModifyPartition>
          <ModifyPartition wcm:action="add">
            <Order>3</Order>
            <PartitionID>3</PartitionID>
          </ModifyPartition>
          <ModifyPartition wcm:action="add">
            <Order>4</Order>
            <PartitionID>4</PartitionID>
            <Format>NTFS</Format>
          </ModifyPartition>
        </ModifyPartitions>
        <WillShowUI>OnError</WillShowUI>
      </Disk>
    </DiskConfiguration>

    <!-- 2. UserData: accept EULA and defer product-key prompt -->
    <UserData>
      <!-- Product Key from https://www.microsoft.com/en-us/evalcenter/ -->
      <ProductKey>
        <!-- Do not uncomment the Key element if you are using trial ISOs -->
        <!-- You must uncomment the Key element (and optionally insert your own key) if using retail/volume ISOs -->
        <!--<Key>ENTER-YOUR-KEY-HERE</Key>-->
        <WillShowUI>OnError</WillShowUI>
      </ProductKey>
      <AcceptEula>true</AcceptEula>
    </UserData>

    <!-- 3. ImageInstall: target the 4th (extended) partition -->
    <ImageInstall>
      <OSImage>
        <InstallFrom>
          <MetaData wcm:action="add">
            <Key>/IMAGE/INDEX</Key>
            <Value>4</Value>
          </MetaData>
        </InstallFrom>
        <InstallTo>
          <DiskID>0</DiskID>
          <PartitionID>4</PartitionID>
        </InstallTo>
        <WillShowUI>OnError</WillShowUI>
      </OSImage>
    </ImageInstall>

  </component>

  <!-- 4. International settings -->
  <component name="Microsoft-Windows-International-Core-WinPE"
             processorArchitecture="amd64"
             publicKeyToken="31bf3856ad364e35"
             language="neutral"
             versionScope="nonSxS"
             xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <SetupUILanguage>
      <UILanguage>en-US</UILanguage>
    </SetupUILanguage>
    <InputLocale>en-US</InputLocale>
    <SystemLocale>en-US</SystemLocale>
    <UILanguage>en-US</UILanguage>
    <UserLocale>en-US</UserLocale>
  </component>
</settings>

  <!-- specialize PASS: join your domain -->
  <settings pass="specialize">
    <component name="Microsoft-Windows-UnattendedJoin"
               processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <Identification>
        <Credentials>
          <Domain>${DomainName}</Domain>
          <Username>${DomainUser}</Username>
          <Password>Cyberark1</Password>
        </Credentials>
        <JoinDomain>${DomainName}</JoinDomain>
      </Identification>
    </component>
  </settings>

  <!-- oobeSystem PASS: set admin password + auto-logon -->
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <UserAccounts>
        <AdministratorPassword>
          <Value>Cyberark1</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>Administrator</Username>
        <Password>
          <Value>Cyberark1</Value>
          <PlainText>true</PlainText>
        </Password>
        <LogonCount>1</LogonCount>
      </AutoLogon>
    </component>
  </settings>

</unattend>
'@

# Write ASCII (no BOM)
Set-Content -Path "$PSScriptRoot\Autounattend.xml" -Value $xml -Encoding ASCII
Write-Host "-> Autounattend.xml generated." -ForegroundColor Green

### 4) Write minimal netmap.conf ###
$wsDir       = 'C:\Program Files (x86)\VMware\VMware Workstation'
$programData = Join-Path $env:ProgramData 'VMware'
$paths       = @( Join-Path $wsDir 'netmap.conf'; Join-Path $programData 'netmap.conf' )
$netmap      = @"
# Minimal netmap.conf for Packer
network0.name   = "Bridged"
network0.device = "vmnet0"
network1.name   = "HostOnly"
network1.device = "vmnet1"
network8.name   = "NAT"
network8.device = "vmnet8"
"@
foreach ($f in $paths) {
    $d = Split-Path $f -Parent
    if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
    Set-Content -Path $f -Value $netmap -Encoding ASCII
    Write-Host "-> netmap.conf written to $f" -ForegroundColor Green
}

### 5) Generate Packer HCL ###
$hclIso   = $IsoPath.Replace('\','/')
$checksum = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
$packerHcl = @"
source "vmware-iso" "vault_base" {
  iso_url          = "file:///$hclIso"
  iso_checksum     = "sha256:$checksum"
  network          = "nat"
  communicator     = "winrm"
  winrm_username   = "Administrator"
  winrm_password   = "Cyberark1"
  floppy_files     = ["Autounattend.xml"]
  disk_size        = 81920
  cpus             = 8
  memory           = 32768
  shutdown_command = "shutdown /s /t 5 /f /d p:4:1 /c \"Packer Shutdown\""
}

build {
  sources = ["source.vmware-iso.vault_base"]
}
"@

Set-Content -Path "$PSScriptRoot\template.pkr.hcl" -Value $packerHcl -Encoding ASCII
Write-Host "-> Packer template written." -ForegroundColor Green

### 6) Run Packer ###
Write-Host "-> Running Packer init & build…" -ForegroundColor Cyan
& $packerExe init   "$PSScriptRoot\template.pkr.hcl" 2>&1 | Write-Host
if ($LASTEXITCODE -ne 0) { Write-Error "Packer init failed"; exit 1 }
& $packerExe build  -force "$PSScriptRoot\template.pkr.hcl" 2>&1 | Write-Host
if ($LASTEXITCODE -ne 0) { Write-Error "Packer build failed"; exit 1 }

### 7) Restart vmrest + fetch golden VM ID ###
Stop-Process -Name vmrest -Force -ErrorAction SilentlyContinue
Start-Process "$wsDir\vmrest.exe" -ArgumentList "-b" -WindowStyle Hidden
Start-Sleep 5
$pair    = "$VmrestUser`:$VmrestPassword"
$token   = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$headers = @{ Authorization = "Basic $token" }
try {
    $vms = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $headers
} catch {
    Write-Error "vmrest authentication failed"; exit 1
}
$BaseId = ($vms | Where-Object name -eq 'vault_base').id
Write-Host "-> Golden VM ID: $BaseId" -ForegroundColor Green

### 8) Generate & apply Terraform configs ###
$tfDir = Join-Path $PSScriptRoot 'terraform'
if (Test-Path $tfDir) { Remove-Item $tfDir -Recurse -Force }
New-Item -Path $tfDir -ItemType Directory | Out-Null

$main = @"
terraform {
  required_providers {
    vmworkstation = { source = "elsudano/vmworkstation"; version = ">=1.1.6" }
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

$vars = @"
variable "vmrest_user"     { default = "$VmrestUser" }
variable "vmrest_password" { default = "$VmrestPassword" }
"@
Set-Content -Path (Join-Path $tfDir 'variables.tf') -Value $vars -Encoding ASCII

Push-Location $tfDir
terraform init -upgrade | Write-Host
terraform plan -out=tfplan   | Write-Host
terraform apply -auto-approve tfplan | Write-Host
Pop-Location

Write-Host "🎉 Deployment complete!" -ForegroundColor Green
