<#
  Create-Servers.ps1 (Fixed: auto-clean output directory)
  ------------------------------------------------------
  1) Builds a minimal Win2022 VM with Packer.
  2) Starts and health-checks the VMware REST API.
  3) Runs Terraform to deploy Vault, PVWA, PSM, CPM.
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

# Prompt for VM folder
$vmPath = Read-Host "Enter VM output path (e.g. C:\VMs)"

# 1) Validate ISO
if (-not (Test-Path $IsoPath)) {
  Write-Error "ISO not found at: $IsoPath"; exit 1
}
$isoUrl      = "file:///$($IsoPath.Replace('\','/'))"
$checksum    = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
$isoChecksum = "sha256:$checksum"

# 2) Ensure Packer installed
$packerBin = Join-Path $scriptRoot 'packer-bin'
$packerExe = Join-Path $packerBin 'packer.exe'
if (-not (Test-Path $packerExe)) {
  Write-Host 'Downloading Packer v1.11.2…' -ForegroundColor Cyan
  New-Item -ItemType Directory -Path $packerBin -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest `
    -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' `
    -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force
  Remove-Item $zip
}
$env:PATH = "$packerBin;$env:PATH"

# 3) CLEAN UP any old Packer output (prevents \"already exists\" error) :contentReference[oaicite:0]{index=0}
$packerDir = Join-Path $scriptRoot 'packer-Win2022'
$outputDir = Join-Path $packerDir 'output-vmware-iso'
if (Test-Path $outputDir) {
  Write-Host \"Removing existing Packer output folder...\" -ForegroundColor Yellow
  # Stop any VMX process holding files
  Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-Item -Recurse -Force $outputDir
}

# 4) Packer build (minimal template)
Push-Location $packerDir
& $packerExe build -only=vmware-iso `
    -var "iso_url=$isoUrl" `
    -var "iso_checksum=$isoChecksum" `
    "win2022-$GuiOrCore.json"
if ($LASTEXITCODE -ne 0) {
  Write-Error 'Packer build failed.'; exit 1
}
Pop-Location
Write-Host '✅ Packer build complete.' -ForegroundColor Green

# 5) Start REST API daemon
& (Join-Path $scriptRoot 'Start-VMRestDaemon.ps1')

# 6) Health-check vmrest with credentials
$cred = New-Object PSCredential('vmrest',
         (ConvertTo-SecureString 'Cyberark1' -AsPlainText -Force))
Write-Host 'Checking VMREST API…' -NoNewline
for ($i = 0; $i -lt 10; $i++) {
  try {
    Invoke-RestMethod `
      -Uri 'http://127.0.0.1:8697/api/vms' `
      -Credential $cred `
      -UseBasicParsing -ErrorAction Stop | Out-Null
    Write-Host ' OK' -ForegroundColor Green
    break
  } catch {
    Write-Host -NoNewline '.'; Start-Sleep -Seconds 3
  }
}
if (-not $?) {
  Write-Error '❌ VMREST API did not respond.'; exit 1
}

# 7) Write terraform.tfvars
$escaped = $vmPath -replace '\\','\\\\'
@"
vmrest_user     = "vmrest"
vmrest_password = "Cyberark1"
vault_image_id  = "thomas"
app_image_id    = "thomas-app"
vm_processors   = 2
vm_memory       = 2048
vm_path         = "$escaped"
"@ | Set-Content (Join-Path $scriptRoot 'terraform.tfvars') -Encoding ASCII

# 8) Terraform apply (single-threaded to avoid parallelism bugs) :contentReference[oaicite:1]{index=1}
Push-Location $scriptRoot
terraform init -upgrade
terraform apply -auto-approve -parallelism=1
Pop-Location
Write-Host '✅ Terraform apply complete.' -ForegroundColor Green
