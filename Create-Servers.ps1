<#
  Create-Servers.ps1 (Updated)
  -------------------
  1) Builds a minimal Win2022 VM with Packer.
  2) Starts and health‑checks the VMware REST API using vmrest/Cyberark1.
  3) Runs Terraform to provision Vault, PVWA, PSM, CPM.
#>

[CmdletBinding()]
param(
  [ValidateSet('gui','core')]
  [string]$GuiOrCore = 'core',
  [Parameter(Mandatory)]
  [string]$IsoPath
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Prompt for VM path & stack
$vmPathInput = Read-Host "Enter folder path for VMs (e.g. C:\VMs)"
$deployAll = $true  # always deploy full stack

# Validate ISO
if (-not (Test-Path $IsoPath)) {
  Write-Error "ISO not found at path: $IsoPath"; exit 1
}
$isoUrl      = "file:///$($IsoPath.Replace('\','/'))"
$isoChecksum = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash

# Ensure Packer installed
$packerBin = Join-Path $scriptRoot 'packer-bin'
$packerExe = Join-Path $packerBin 'packer.exe'
if (-not (Test-Path $packerExe)) {
  Write-Host 'Downloading Packer v1.11.2…' -ForegroundColor Cyan
  New-Item -ItemType Directory -Path $packerBin -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force; Remove-Item $zip
}
$env:PATH = "$packerBin;$env:PATH"

# Build minimal image
$packerDir = Join-Path $scriptRoot 'packer-Win2022'
$outputDir = Join-Path $packerDir 'output-vmware-iso'
if (Test-Path $outputDir) {
  Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-Item -Recurse -Force $outputDir
}
Push-Location $packerDir
& $packerExe build -only=vmware-iso -var "iso_url=$isoUrl" -var "iso_checksum=$isoChecksum" "win2022-$GuiOrCore.json"
if ($LASTEXITCODE -ne 0) { Write-Error 'Packer build failed.'; exit 1 }
Pop-Location
Write-Host '✅ Packer build complete.' -ForegroundColor Green

# Start and configure VMREST API
try {
  Stop-Process -Name vmrest -ErrorAction SilentlyContinue
} catch {}
$vmrestExe = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
Start-Process -FilePath $vmrestExe -ArgumentList '-b' -WindowStyle Hidden
Start-Sleep -Seconds 5

# Health-check with credentials
$cred = New-Object PSCredential('vmrest', (ConvertTo-SecureString 'Cyberark1' -AsPlainText -Force))
Write-Host 'Checking VMREST API...' -NoNewline
for ($i=0; $i -lt 10; $i++) {
  try {
    Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Credential $cred -UseBasicParsing -ErrorAction Stop
    Write-Host ' OK' -ForegroundColor Green
    break
  } catch {
    Write-Host -NoNewline '.'; Start-Sleep -Seconds 3
  }
}
if (-not $?) { Write-Error 'VMREST API did not respond.'; exit 1 }

# Write terraform.tfvars
$escapedPath = $vmPathInput -replace '\\','\\\\'
@"
vmrest_user     = "vmrest"
vmrest_password = "Cyberark1"
vault_image_id  = "thomas"
app_image_id    = "thomas-app"
vm_processors   = 2
vm_memory       = 2048
vm_path         = "$escapedPath"
"@ | Set-Content -Path (Join-Path $scriptRoot 'terraform.tfvars') -Encoding ASCII

# Run Terraform
terraform init -upgrade
terraform apply -auto-approve
Write-Host '✅ Terraform apply complete.' -ForegroundColor Green
