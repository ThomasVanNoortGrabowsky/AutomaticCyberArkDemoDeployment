<#
  Create-Servers.ps1
  --------------------------------------
  End-to-end pipeline:
    1) Builds a GUI Win2022 VM with Packer (using win2022-gui.json).
    2) Starts and health-checks the VMware REST API.
    3) Runs Terraform to deploy Vault, PVWA, PSM, CPM.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$IsoPath,

  [Parameter(Mandatory)]
  [string]$VmOutputPath
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# 1) Validate ISO
if (-not (Test-Path $IsoPath)) {
  Write-Error "ISO not found at: $IsoPath"; exit 1
}
$isoUrl      = "file:///$($IsoPath.Replace('\','/'))"
$checksum    = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
$isoChecksum = "sha256:$checksum"

# 2) Locate Packer template
$packerTemplate = Join-Path $scriptRoot 'packer-Win2022\win2022-gui.json'
if (-not (Test-Path $packerTemplate)) {
  Write-Error "Cannot find Packer template at: $packerTemplate"; exit 1
}

# 3) Ensure Packer v1.11.2 is installed
$packerBin = Join-Path $scriptRoot 'packer-bin'
$packerExe = Join-Path $packerBin 'packer.exe'
if (-not (Test-Path $packerExe)) {
  Write-Host '==> Downloading Packer v1.11.2…' -ForegroundColor Cyan
  New-Item -ItemType Directory -Path $packerBin -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest `
    -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' `
    -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force
  Remove-Item $zip
}
$env:PATH = "$packerBin;$env:PATH"

# 4) Clean old Packer output
$outputDir = Join-Path (Split-Path $packerTemplate) 'output-vmware-iso'
if (Test-Path $outputDir) {
  Write-Host '==> Removing existing Packer output…' -ForegroundColor Yellow
  Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-Item -Recurse -Force $outputDir
}

# 5) Run Packer build
Write-Host '==> Building Win2022 GUI image with Packer…' -ForegroundColor Cyan
& $packerExe build `
  -var "iso_url=$isoUrl" `
  -var "iso_checksum=$isoChecksum" `
  $packerTemplate
if ($LASTEXITCODE -ne 0) {
  Write-Error '❌ Packer build failed.'; exit 1
}
Write-Host '✅ Packer build complete.' -ForegroundColor Green

# 6) Start VMREST daemon
Write-Host '==> Launching VMREST daemon…' -ForegroundColor Cyan
& (Join-Path $scriptRoot 'Start-VMRestDaemon.ps1')

# 7) Health-check VMREST API
$cred = New-Object PSCredential('vmrest', (ConvertTo-SecureString 'Cyberark1' -AsPlainText -Force))
Write-Host '==> Checking VMREST API…' -NoNewline
for ($i = 1; $i -le 10; $i++) {
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
if ($LASTEXITCODE -ne 0) {
  Write-Error '❌ VMREST API did not respond.'; exit 1
}

# 8) Write terraform.tfvars
Write-Host '==> Writing terraform.tfvars…' -ForegroundColor Cyan
$escapedPath = $VmOutputPath -replace '\\','\\\\'
@"
vmrest_user     = "vmrest"
vmrest_password = "Cyberark1"
vault_image_id  = "thomas"
app_image_id    = "thomas-app"
vm_processors   = 2
vm_memory       = 2048
vm_path         = "$escapedPath"
"@ | Set-Content (Join-Path $scriptRoot 'terraform.tfvars') -Encoding ASCII

# 9) Terraform init & apply (serial)
Write-Host '==> Initializing Terraform…' -ForegroundColor Cyan
Push-Location $scriptRoot
terraform init -upgrade
Write-Host '==> Applying Terraform…' -ForegroundColor Cyan
terraform apply -auto-approve -parallelism=1
Pop-Location
Write-Host '✅ Terraform apply complete.' -ForegroundColor Green
