<#
  Create-Servers.ps1 (Updated)
  -------------------
  1) Builds a minimal Win2022 VM with Packer.
  2) Starts VMREST properly and waits for it.
  3) Runs Terraform to provision VMs.
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

# Prompt for settings
$vmPathInput = Read-Host "Enter folder path where Terraform should create the VM (e.g. C:\VMs\Test)"
$vaultAnswer = Read-Host "Do you want to deploy the CyberArk Vault VM? (y/n)"
$createVault = $vaultAnswer.Trim().ToLower().StartsWith('y')

# Validate ISO
if (-not (Test-Path $IsoPath)) {
  Write-Error "ISO not found at path: $IsoPath"; exit 1
}

# Download Packer if needed
$packerBin = Join-Path $scriptRoot 'packer-bin'
$packerExe = Join-Path $packerBin 'packer.exe'
if (-not (Test-Path $packerExe)) {
  Write-Host 'Downloading Packer v1.11.2...'
  New-Item -Path $packerBin -ItemType Directory -Force | Out-Null
  Invoke-WebRequest -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' -OutFile "$packerBin\packer.zip"
  Expand-Archive -Path "$packerBin\packer.zip" -DestinationPath $packerBin -Force
  Remove-Item "$packerBin\packer.zip"
}
$env:PATH = "$packerBin;$env:PATH"

# Generate checksum and ISO vars
$checksum = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
$isoUrlVar = "file:///$($IsoPath.Replace('\','/'))"
$isoChecksumVar = "sha256:$checksum"

# Clean previous build output
$packerDir = Join-Path $scriptRoot 'packer-Win2022'
$outputDir = Join-Path $packerDir 'output-vmware-iso'
if (Test-Path $outputDir) {
  Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-Item -Recurse -Force $outputDir -ErrorAction SilentlyContinue
}

# Use custom light Packer template
$packerJson = Join-Path $packerDir "win2022-$GuiOrCore.json"
if (-not (Test-Path $packerJson)) {
  Write-Error "Packer template not found: $packerJson"; exit 1
}

# Run Packer
Push-Location $packerDir
Write-Host "Running Packer build..."
& $packerExe build -only=vmware-iso -var "iso_url=$isoUrlVar" -var "iso_checksum=$isoChecksumVar" "win2022-$GuiOrCore.json"
if ($LASTEXITCODE -ne 0) { Write-Error 'Packer build failed.'; exit 1 }
Pop-Location
Write-Host '✅ Packer build completed.' -ForegroundColor Green

# Start vmrest
$vmrestExe = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
Stop-Process -Name vmrest -ErrorAction SilentlyContinue
Start-Process -FilePath $vmrestExe -ArgumentList '-b' -WindowStyle Hidden
Start-Sleep -Seconds 5

# Confirm vmrest is up
Write-Host 'Checking vmrest API health...'
$healthCheck = $false
for ($i = 0; $i -lt 10; $i++) {
  try {
    Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -UseBasicParsing -ErrorAction Stop | Out-Null
    $healthCheck = $true
    break
  } catch {
    Start-Sleep -Seconds 3
  }
}
if (-not $healthCheck) {
  Write-Error 'ERROR: VMREST API did not respond; aborting.'
  exit 1
}
Write-Host '✅ VMREST API is responding.' -ForegroundColor Green

# Update terraform.tfvars
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
if ($createVault) {
  Push-Location $scriptRoot
  terraform init -upgrade
  terraform plan -out=tfplan
  terraform apply -auto-approve tfplan
  Pop-Location
  Write-Host '✅ CyberArk-Vault VM created!' -ForegroundColor Green
} else {
  Write-Host '⚠️ Skipped Terraform deployment.' -ForegroundColor Yellow
}

Write-Host '✅ All done! VM image created and REST API ready.' -ForegroundColor Green
