<#
  Create-Servers.ps1
  --------------------------------------
  1) Builds a Win2022 GUI VM with Packer.
  2) Registers the template with VMware Workstation (vmrun register).
  3) Starts & health-checks the VMware REST API (using HTTP Basic).
  4) Discovers the template’s VM ID via VMREST.
  5) Writes terraform.tfvars with that GUID.
  6) Runs Terraform to deploy Vault, PVWA, PSM, CPM.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$IsoPath,
  [Parameter(Mandatory)] [string]$VmOutputPath
)

$ErrorActionPreference = 'Stop'

# Paths & creds
$scriptRoot   = Split-Path $MyInvocation.MyCommand.Definition -Parent
$packerDir    = Join-Path $scriptRoot 'packer-Win2022'
$packerTpl    = Join-Path $packerDir 'win2022-gui.json'
$packerBin    = Join-Path $scriptRoot 'packer-bin'
$packerExe    = Join-Path $packerBin 'packer.exe'
$outputDir    = Join-Path $packerDir 'output-vmware-iso'
$templateVmx  = Join-Path $outputDir 'Win2022_GUI.vmx'
$tfvarsFile   = Join-Path $scriptRoot 'terraform.tfvars'

# Credentials for VMREST
$vmrestUser = 'vmrest'
$vmrestPass = 'Cyberark1'

# 1) Validate ISO
if (-not (Test-Path $IsoPath)) {
  Write-Error "ISO not found: $IsoPath"; exit 1
}
$isoUrl      = "file:///$($IsoPath.Replace('\','/'))"
$isoChecksum = "sha256:$((Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash)"
Write-Host "ISO validated. Checksum: $isoChecksum"

# 2) Ensure Packer is installed
if (-not (Test-Path $packerExe)) {
  Write-Host '==> Installing Packer…' -ForegroundColor Cyan
  New-Item -ItemType Directory -Path $packerBin -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest `
    -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' `
    -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force
  Remove-Item $zip
}
$env:PATH = "$packerBin;$env:PATH"

# 3) Clean previous output
if (Test-Path $outputDir) {
  Write-Host '==> Cleaning old Packer output…' -ForegroundColor Yellow
  Get-Process vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-Item $outputDir -Recurse -Force
}

# 4) Build the golden image
Write-Host '==> Running Packer build…' -ForegroundColor Cyan
Push-Location $packerDir
& $packerExe build `
    -var "iso_url=$isoUrl" `
    -var "iso_checksum=$isoChecksum" `
    "win2022-gui.json"
if ($LASTEXITCODE -ne 0) {
  Write-Error 'Packer build failed'; Pop-Location; exit 1
}
Pop-Location
Write-Host '✅ Packer build complete.' -ForegroundColor Green

# 5) Register the template with VMREST (vmrun)
if (Test-Path $templateVmx) {
  Write-Host '==> Registering template with VMREST…' -ForegroundColor Cyan
  $vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
  if (-not $vmrun) { $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' }
  & $vmrun -T ws register $templateVmx 2>$null
  Write-Host '✅ Template registered.' -ForegroundColor Green
}

# 6) Start VMREST
Write-Host '==> Starting VMREST daemon…' -ForegroundColor Cyan
& (Join-Path $scriptRoot 'StartVMRestDaemon.ps1')

# 7) Wait for VMREST API (using HTTP Basic)
$authPair = "$vmrestUser`:$vmrestPass"
$authBytes = [Text.Encoding]::ASCII.GetBytes($authPair)
$authValue = [Convert]::ToBase64String($authBytes)
$headers = @{ Authorization = "Basic $authValue" }

Write-Host '==> Waiting for VMREST API…' -NoNewline
for ($i = 0; $i -lt 10; $i++) {
  try {
    Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $headers -UseBasicParsing | Out-Null
    Write-Host ' OK' -ForegroundColor Green
    break
  } catch {
    Write-Host -NoNewline '.'; Start-Sleep -Seconds 3
  }
}
if ($LASTEXITCODE -ne 0) {
  Write-Error 'VMREST did not respond'; exit 1
}

# 8) Discover the template VM’s GUID
Write-Host '==> Querying VMREST for template ID…' -ForegroundColor Cyan
$vms = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $headers -UseBasicParsing
$template = $vms | Where-Object { $_.displayName -eq 'Win2022_GUI' }
if (-not $template) {
  Write-Error 'Template VM not found in VMREST'; exit 1
}
$templateId = $template.id
Write-Host "Template GUID: $templateId" -ForegroundColor Green

# 9) Write terraform.tfvars with the real GUID
Write-Host '==> Writing terraform.tfvars…' -ForegroundColor Cyan
$escapedPath = $VmOutputPath -replace '\\','\\\\'
@"
vmrest_user     = "$vmrestUser"
vmrest_password = "$vmrestPass"
vault_image_id  = "$templateId"
app_image_id    = "$templateId"
vm_processors   = 2
vm_memory       = 2048
vm_path         = "$escapedPath"
"@ | Set-Content -Encoding ASCII $tfvarsFile

# 10) Terraform init & apply
Write-Host '==> Running Terraform init & apply…' -ForegroundColor Cyan
Push-Location $scriptRoot
terraform init -upgrade
terraform apply -auto-approve -parallelism=1
Pop-Location
Write-Host '✅ Terraform apply complete.' -ForegroundColor Green

# 11) (Optional) Launch your VMs in GUI
Write-Host '==> Launching demo VMs in VMware Workstation…' -ForegroundColor Cyan
$vmNames = 'Vault-VM','PVWA-VM','PSM-VM','CPM-VM'
foreach ($name in $vmNames) {
  $vmx = Join-Path $VmOutputPath "$name\$name.vmx"
  if (Test-Path $vmx) {
    Write-Host "  ↪ Starting $name" -NoNewline
    & $vmrun -T ws start $vmx
    Write-Host ' OK' -ForegroundColor Green
  } else {
    Write-Warning "Missing VMX: $vmx"
  }
}

Write-Host "`n🎉 All done!" -ForegroundColor Green
