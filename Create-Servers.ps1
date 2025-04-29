<#
  Create-Servers.ps1
  -------------------
  1) Builds a minimal Win2022 VM with Packer (only a forced shutdown).
  2) Prompts for where to store Terraform VMs and whether to deploy the Vault.
  3) Updates terraform.tfvars, starts VMREST (with full bootstrap), health-checks it, and runs Terraform.
#>

[CmdletBinding()]
param(
  [ValidateSet('gui','core')]
  [string]$GuiOrCore = 'gui',
  [Parameter(Mandatory)]
  [string]$IsoPath
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ──────────────────────────────────────────────────────────────────────────────
# Prompt for Terraform settings
# ──────────────────────────────────────────────────────────────────────────────
$vmPathInput = Read-Host "Enter the folder path where Terraform should create the VM (e.g. C:\VMs\Test)"
$vaultAnswer = Read-Host "Do you want to deploy the CyberArk Vault VM? (y/n)"
$createVault = $vaultAnswer.Trim().ToLower().StartsWith('y')

# ──────────────────────────────────────────────────────────────────────────────
# 1) Clone/update packer-Win2022
# ──────────────────────────────────────────────────────────────────────────────
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Error 'Git is required.'; exit 1
}
$packerDir = Join-Path $scriptRoot 'packer-Win2022'
if (Test-Path $packerDir) {
  Write-Host 'Updating packer-Win2022…' -ForegroundColor Cyan
  Push-Location $packerDir; git pull; Pop-Location
} else {
  Write-Host 'Cloning packer-Win2022…' -ForegroundColor Cyan
  git clone https://github.com/eaksel/packer-Win2022.git $packerDir
}

# ──────────────────────────────────────────────────────────────────────────────
# 2) Ensure Packer v1.11.2 is installed locally
# ──────────────────────────────────────────────────────────────────────────────
$packerBin = Join-Path $scriptRoot 'packer-bin'
$packerExe = Join-Path $packerBin 'packer.exe'
if (-not (Test-Path $packerExe)) {
  Write-Host 'Downloading Packer v1.11.2…' -ForegroundColor Cyan
  New-Item -Path $packerBin -ItemType Directory -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest `
    -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' `
    -OutFile $zip -UseBasicParsing
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force
  Remove-Item $zip
}
$env:PATH = "$packerBin;$env:PATH"

# ──────────────────────────────────────────────────────────────────────────────
# 3) Validate ISO path
# ──────────────────────────────────────────────────────────────────────────────
if (-not (Test-Path $IsoPath)) {
  Write-Error "ISO not found at path: $IsoPath"; exit 1
}
$checksum       = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
$isoUrlVar      = "file:///$($IsoPath.Replace('\','/'))"
$isoChecksumVar = "sha256:$checksum"

# ──────────────────────────────────────────────────────────────────────────────
# 4) Copy the correct autounattend.xml
# ──────────────────────────────────────────────────────────────────────────────
$srcAuto  = Join-Path $packerDir "scripts\uefi\$GuiOrCore\autounattend.xml"
$destAuto = Join-Path $scriptRoot 'Autounattend.xml'
if (-not (Test-Path $srcAuto)) {
  Write-Error "autounattend.xml for '$GuiOrCore' not found."; exit 1
}
Copy-Item -Path $srcAuto -Destination $destAuto -Force
Write-Host "Copied autounattend.xml for '$GuiOrCore'." -ForegroundColor Green

# ──────────────────────────────────────────────────────────────────────────────
# 5) Install the VMware Packer plugin
# ──────────────────────────────────────────────────────────────────────────────
Push-Location $packerDir
Write-Host 'Installing VMware Packer plugin…' -ForegroundColor Cyan
& $packerExe plugins install github.com/hashicorp/vmware | Out-Null
Pop-Location

# ──────────────────────────────────────────────────────────────────────────────
# 6) Strip out all in-guest provisioners and force a shutdown
# ──────────────────────────────────────────────────────────────────────────────
$jsonPath  = Join-Path $packerDir "win2022-$GuiOrCore.json"
$packerObj = Get-Content $jsonPath -Raw | ConvertFrom-Json

$shutdownProv = [PSCustomObject]@{
  type   = 'powershell'
  inline = @(
    'Write-Host "Waiting 5s before shutdown..."',
    'Start-Sleep -Seconds 5',
    'shutdown.exe /s /t 0 /f'
  )
}

$packerObj.provisioners = @($shutdownProv)
$packerObj | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding ASCII
Write-Host 'Injected forced shutdown provisioner; all others removed.' -ForegroundColor Green

# ──────────────────────────────────────────────────────────────────────────────
# 7) Clean prior Packer output & build
# ──────────────────────────────────────────────────────────────────────────────
$outputDir = Join-Path $packerDir 'output-vmware-iso'
if (Test-Path $outputDir) {
  Write-Host 'Removing prior Packer output…' -ForegroundColor Yellow
  Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $outputDir
  cmd /c "rd /s /q `"$outputDir`""
}
Push-Location $packerDir
Write-Host "Building win2022-$GuiOrCore.json…" -ForegroundColor Cyan
& $packerExe build `
   -only=vmware-iso `
   -var "iso_url=$isoUrlVar" `
   -var "iso_checksum=$isoChecksumVar" `
   "win2022-$GuiOrCore.json"
if ($LASTEXITCODE -ne 0) { Write-Error 'Packer build failed.'; exit 1 }
Write-Host 'Packer build succeeded and VM has been powered off.' -ForegroundColor Green
Pop-Location

# ──────────────────────────────────────────────────────────────────────────────
# 8) Start VMware REST API (bootstrap + config/key/cert + health check)
# ──────────────────────────────────────────────────────────────────────────────
Write-Host 'Starting VMware REST API daemon…' -ForegroundColor Cyan
$vmrestExe    = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
$cfgPath      = "$HOME\.vmrestCfg"                     # your config.ini
$keyFile      = 'workstationapi-key.pem'               # ensure these exist
$certFile     = 'workstationapi-cert.pem'
$apiPort      = 8697

Stop-Process -Name vmrest -ErrorAction SilentlyContinue

Start-Process -FilePath $vmrestExe `
  -ArgumentList @(
    '-C', $cfgPath,
    '-k', $keyFile,
    '-c', $certFile,
    '-p', $apiPort
  ) -WindowStyle Hidden

Start-Sleep -Seconds 5

try {
  Invoke-RestMethod `
    -Uri "http://127.0.0.1:$apiPort/api/vms" `
    -Credential (New-Object PSCredential($vmrest_user, (ConvertTo-SecureString $vmrest_password -AsPlainText -Force))) `
    -ErrorAction Stop | Out-Null
  Write-Host 'VMREST API is up and responding.' -ForegroundColor Green
} catch {
  Write-Error 'ERROR: VMREST API did not respond on /api/vms; aborting.'
  exit 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 9) Update terraform.tfvars (escaping backslashes) and run Terraform if requested
# ──────────────────────────────────────────────────────────────────────────────
Set-Location $scriptRoot
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

if ($createVault) {
  Write-Host 'Initializing Terraform…' -ForegroundColor Cyan
  terraform init -upgrade
  Write-Host 'Planning Terraform…' -ForegroundColor Cyan
  terraform plan -out=tfplan
  Write-Host 'Applying Terraform…' -ForegroundColor Cyan
  terraform apply -auto-approve tfplan
  Write-Host '✅ CyberArk-Vault VM created!' -ForegroundColor Green
} else {
  Write-Host '⚠️  Skipped Terraform deployment of Vault.' -ForegroundColor Yellow
}

Write-Host 'All done! Base image is built and VM halted as requested.' -ForegroundColor Green
