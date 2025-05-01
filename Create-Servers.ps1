<#
.SYNOPSIS
  End-to-end pipeline using linked-clone Packer output.

.DESCRIPTION
  1. Builds base + linked clone via Packer.
  2. Registers the linked VM.
  3. Starts & polls VMREST.
  4. Selects template VM ID.
  5. Writes terraform.tfvars.
  6. Runs Terraform.
  7. (Optional) Powers on the deployed VMs.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$IsoPath,
  [Parameter(Mandatory=$true)][string]$VmOutputPath
)

$ErrorActionPreference = 'Stop'

# Paths & credentials
$scriptRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$packerBin    = Join-Path $scriptRoot 'packer-bin'
$packerExe    = Join-Path $packerBin   'packer.exe'
$packerDir    = Join-Path $scriptRoot 'packer-Win2022'
$outputLinked = Join-Path $packerDir   'output-linked'
$templateVmx  = Join-Path $outputLinked 'Win2022_GUI-linked.vmx'
$tfvarsFile   = Join-Path $scriptRoot 'terraform.tfvars'

$vmrestUser   = 'vmrest'
$vmrestPass   = 'Cyberark1!'

# 1) Validate ISO
if (-not (Test-Path $IsoPath)) {
  Write-Error "ISO not found at '$IsoPath'"
  exit 1
}
$isoUrl      = "file:///$($IsoPath -replace '\\','/')"
$isoChecksum = 'sha256:' + (Get-FileHash -Path $IsoPath -Algorithm SHA256).Hash
Write-Host "ISO checksum: $isoChecksum"

# 2) Ensure Packer
if (-not (Test-Path $packerExe)) {
  Write-Host 'Installing Packer 1.11.2...' -ForegroundColor Cyan
  New-Item -ItemType Directory -Path $packerBin -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest `
    -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' `
    -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force
  Remove-Item $zip -Force
}
# Prepend packer to PATH
$oldPath = [Environment]::GetEnvironmentVariable('PATH','Process')
[Environment]::SetEnvironmentVariable('PATH', "$packerBin;$oldPath",'Process')

# 3) Clean old linked output
if (Test-Path $outputLinked) {
  Write-Host 'Cleaning old linked output...' -ForegroundColor Yellow
  Remove-Item -Path $outputLinked -Recurse -Force
}

# 4) Packer build (base + linked)
Write-Host 'Running Packer (base + linked)...' -ForegroundColor Cyan
Push-Location $packerDir
& $packerExe build `
    -var "iso_url=$isoUrl" `
    -var "iso_checksum=$isoChecksum" `
    'win2022-gui.json'
if ($LASTEXITCODE -ne 0) {
  Write-Error 'Packer build failed.'
  Pop-Location
  exit 1
}
Pop-Location
Write-Host 'Packer linked clone ready.' -ForegroundColor Green

# 5) Register linked VM
if (Test-Path $templateVmx) {
  Write-Host 'Registering linked VM...' -ForegroundColor Cyan
  $vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
  if (-not $vmrun) {
    $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
  }
  & $vmrun -T ws register $templateVmx | Out-Null
  Write-Host 'Template registered.' -ForegroundColor Green
}

# 6) Start VMREST
Write-Host 'Starting VMREST...' -ForegroundColor Cyan
& (Join-Path $scriptRoot 'StartVMRestDaemon.ps1')

# 7) Poll VMREST
$pair    = "$vmrestUser`:$vmrestPass"
$auth    = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$headers = @{ Authorization = "Basic $auth" }
Write-Host 'Waiting for VMREST API...' -NoNewline
for ($i = 1; $i -le 10; $i++) {
  try {
    Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $headers -UseBasicParsing | Out-Null
    Write-Host ' OK' -ForegroundColor Green
    break
  } catch {
    Write-Host '.' -NoNewline
    Start-Sleep -Seconds 3
  }
}
if ($LASTEXITCODE -ne 0) {
  Write-Error 'VMREST did not respond.'
  exit 1
}

# 8) Inventory & select template
Write-Host "`nVMREST inventory:" -ForegroundColor Cyan
$vms = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $headers -UseBasicParsing
for ($idx = 0; $idx -lt $vms.Count; $idx++) {
  $n = if ($vms[$idx].displayName) { $vms[$idx].displayName } else { '(blank)' }
  Write-Host (" [{0}] {1,-20} : {2}" -f $idx, $n, $vms[$idx].id)
}
$template = $vms | Where-Object { $_.displayName -match 'Win2022' } | Select-Object -First 1
if (-not $template) {
  Write-Warning 'No match for "Win2022"; using first entry.'
  $template = $vms[0]
}
Write-Host "`nUsing template ID: $($template.id)" -ForegroundColor Green

# 9) Write terraform.tfvars
Write-Host 'Writing terraform.tfvars...' -ForegroundColor Cyan
$vmPathEsc = $VmOutputPath -replace '\\','\\\\'
@"
vmrest_user     = "$vmrestUser"
vmrest_password = "$vmrestPass"
vault_image_id  = "$($template.id)"
app_image_id    = "$($template.id)"
vm_processors   = 2
vm_memory       = 2048
vm_path         = "$vmPathEsc"
"@ | Set-Content -Path $tfvarsFile -Encoding ASCII

# 10) Terraform init & apply
Write-Host 'Running Terraform init & apply...' -ForegroundColor Cyan
Push-Location $scriptRoot
terraform init -upgrade
terraform apply -auto-approve -parallelism=1
Pop-Location
Write-Host 'Terraform apply complete.' -ForegroundColor Green

# 11) Optional: Power on demo VMs
Write-Host 'Powering on demo VMs...' -ForegroundColor Cyan
$vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
if (-not $vmrun) {
  $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
}
foreach ($name in 'Vault-VM','PVWA-VM','PSM-VM','CPM-VM') {
  $vmxPath = Join-Path $VmOutputPath "$name\$name.vmx"
  if (Test-Path $vmxPath) {
    Write-Host "  Starting $name..." -NoNewline
    & $vmrun -T ws start $vmxPath | Out-Null
    Write-Host ' OK' -ForegroundColor Green
  } else {
    Write-Warning "VMX not found: $vmxPath"
  }
}

Write-Host "`nAll done!" -ForegroundColor Green
