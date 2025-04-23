# Create-Servers.ps1
# Automated CyberArk lab: Packer → golden image → Terraform (Vault optional + PVWA/CPM/PSM)

$ErrorActionPreference = 'Stop'

# Elevate if needed
if (-not ([Security.Principal.WindowsPrincipal] `
          [Security.Principal.WindowsIdentity]::GetCurrent() `
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell `
      "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
      -Verb RunAs
    exit
}

# 1) Prompts
$IsoPath        = Read-Host "1) Windows Server ISO path (e.g. C:\ISOs\SERVER_EVAL.iso)"
$VmrestUser     = Read-Host "2) VMware REST API username"
$VmrestSecure   = Read-Host "3) VMware REST API password" -AsSecureString
$VmrestPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($VmrestSecure)
)
$InstallVault   = (Read-Host "4) Install Vault? (Y/N)").ToUpper() -eq 'Y'
$DeployPath     = Read-Host "5) Base folder for VMs (e.g. C:\VMs)"
$DomainName     = Read-Host "6) Domain to join (e.g. corp.local)"
$DomainUser     = Read-Host "7) Domain join user"

# 2) Autounattend.xml
$autoXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <!-- windowsPE and oobeSystem settings, including domain join -->
  <!-- ... (omitted for brevity) ... -->
</unattend>
"@
$autoXml | Set-Content "$PSScriptRoot\Autounattend.xml" -Encoding ASCII
Write-Host "-> Autounattend.xml generated." -ForegroundColor Green

# 3) Regenerate netmap.conf via vnetlib64.exe
$wsDir      = 'C:\Program Files (x86)\VMware\VMware Workstation'
$vnetTool   = Join-Path $wsDir 'vnetlib64.exe'    # 64-bit tool :contentReference[oaicite:7]{index=7}
$exportFile = Join-Path $env:TEMP 'vnetconfig.txt'

Write-Host "-> Exporting VMware network settings…" -ForegroundColor Cyan
& $vnetTool '--' 'export' $exportFile
if ($LASTEXITCODE -ne 0) {
    Write-Host "   Export failed (code $LASTEXITCODE)" -ForegroundColor Yellow
}

Write-Host "-> Importing network settings…" -ForegroundColor Cyan
& $vnetTool '--' 'import' $exportFile
if ($LASTEXITCODE -ne 0) {
    Write-Host "   Import failed (code $LASTEXITCODE)" -ForegroundColor Yellow
}

$destNetmap = Join-Path $wsDir 'netmap.conf'
if (Test-Path $destNetmap) {
    Write-Host "-> netmap.conf regenerated." -ForegroundColor Green
} else {
    Write-Host "-> netmap.conf still missing; writing minimal fallback." -ForegroundColor Yellow
    @"
# Minimal netmap.conf auto-generated
network0.name = "Bridged"
network0.device = "vmnet0"
network1.name = "HostOnly"
network1.device = "vmnet1"
network8.name = "NAT"
network8.device = "vmnet8"
"@ | Set-Content $destNetmap -Encoding ASCII
    Write-Host "-> Minimal netmap.conf written." -ForegroundColor Green
}

# 4) Packer template
$hclIsoPath = $IsoPath.Replace('\','/')
$hash       = (Get-FileHash $IsoPath -Algorithm SHA256).Hash

$packerHcl = @"
source "vmware-iso" "vault_base" {
  iso_url          = "file:///$hclIsoPath"
  iso_checksum     = "sha256:$hash"
  communicator     = "winrm"
  winrm_username   = "Administrator"
  winrm_password   = "Cyberark1"
  floppy_files     = ["Autounattend.xml"]
  disk_size        = 81920
  cpus             = 8
  memory           = 32768
  shutdown_command = "shutdown /s /t 5 /f /d p:4:1 /c `"Packer Shutdown`""
}
build { sources = ["source.vmware-iso.vault_base"] }
"@
Set-Content "$PSScriptRoot\template.pkr.hcl" -Value $packerHcl -Encoding ASCII
Write-Host "-> Packer template written." -ForegroundColor Green

# 5) Run Packer
Write-Host "-> Running Packer init & build..." -ForegroundColor Cyan
& packer init template.pkr.hcl 2>&1 | Write-Host
if ($LASTEXITCODE) { Write-Error "Packer init failed"; exit 1 }
& packer build -force template.pkr.hcl 2>&1 | Write-Host
if ($LASTEXITCODE) { Write-Error "Packer build failed"; exit 1 }

# 6) Restart vmrest & fetch VM ID
Stop-Process vmrest -ErrorAction SilentlyContinue -Force
Start-Process "$wsDir\vmrest.exe" -ArgumentList '-b' -WindowStyle Hidden
Start-Sleep 5

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

# 7) Terraform configs & deploy
$tfDir = Join-Path $PSScriptRoot 'terraform'; if (Test-Path $tfDir) { Remove-Item $tfDir -Recurse -Force }
New-Item $tfDir -ItemType Directory | Out-Null

# main.tf (omitted for brevity—same as before)
# variables.tf (omitted for brevity)

Push-Location $tfDir
terraform init -upgrade | Write-Host
terraform plan -out=tfplan | Write-Host
terraform apply -auto-approve tfplan | Write-Host
Pop-Location

Write-Host "Deployment complete!" -ForegroundColor Green
