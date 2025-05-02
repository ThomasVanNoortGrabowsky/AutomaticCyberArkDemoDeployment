<#
.SYNOPSIS
  Builds a Win2022_GUI template with Packer, registers it with VMREST,
  enables linked-clone mode, then uses Terraform to deploy demo VMs.

.DESCRIPTION
  Full pipeline:
    1) Build Win2022_GUI template with Packer.
    2) Register it in VMware Workstation via vmrun.
    3) Start & health-check VMREST.
    4) Query VMREST for the template's GUID.
    5) Enable "template mode" for linked clones.
    6) Write terraform.tfvars.
    7) Terraform init & apply (Vault, PVWA, PSM, CPM).
    8) (Optional) Launch demo VMs in GUI.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $IsoPath,
  [Parameter(Mandatory)] [string] $VmOutputPath
)

$ErrorActionPreference = 'Stop'

#---- Paths & Credentials ----#
$scriptRoot  = Split-Path $MyInvocation.MyCommand.Path -Parent
$packerDir   = Join-Path $scriptRoot 'packer-Win2022'
$packerExe   = Join-Path $scriptRoot 'packer-bin\packer.exe'
$outputDir   = Join-Path $packerDir 'output-vmware-iso'
$templateVmx = Join-Path $outputDir 'Win2022_GUI.vmx'
$tfvarsFile  = Join-Path $scriptRoot 'terraform.tfvars'

$vmrestUser = 'vmrest'
$vmrestPass = 'Cyberark1!'

#---- 1) Validate ISO ----#
if (-not (Test-Path $IsoPath)) {
  Write-Error "ISO not found at: $IsoPath"
  exit 1
}
$isoUrl      = "file:///$($IsoPath -replace '\\','/')"
$isoChecksum = "sha256:$((Get-FileHash -Path $IsoPath -Algorithm SHA256).Hash)"
Write-Host "ISO validated. Checksum: $isoChecksum" -ForegroundColor Green

#---- 2) Install Packer if missing ----#
if (-not (Test-Path $packerExe)) {
  Write-Host "Installing Packer v1.11.2..." -ForegroundColor Cyan
  $packerBin = Split-Path $packerExe
  New-Item -Path $packerBin -ItemType Directory -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest `
    -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' `
    -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force
  Remove-Item $zip
}
$env:PATH += ";$(Split-Path $packerExe)"

#---- 3) Clean previous Packer output ----#
if (Test-Path $outputDir) {
  Write-Host "Cleaning old Packer output..." -ForegroundColor Yellow
  Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-Item -Recurse -Force $outputDir
}

#---- 4) Build the golden image ----#
Write-Host "Running Packer build..." -ForegroundColor Cyan
Push-Location $packerDir
& $packerExe build `
    -var "iso_url=$isoUrl" `
    -var "iso_checksum=$isoChecksum" `
    'win2022-gui.json'
Pop-Location
Write-Host "Packer build complete." -ForegroundColor Green

#---- 5) Register the template with VMREST ----#
if (Test-Path $templateVmx) {
  Write-Host "Registering template VM with Workstation..." -ForegroundColor Cyan
  $vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
  if (-not $vmrun) { $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' }
  & $vmrun -T ws register $templateVmx 2>$null
  Write-Host "Template VM registered." -ForegroundColor Green
}

#---- 6) Start VMREST daemon ----#
Write-Host "Starting VMREST daemon..." -ForegroundColor Cyan
& (Join-Path $scriptRoot 'StartVMRestDaemon.ps1')

#---- 7) Wait for VMREST API ----#
$pair = "$vmrestUser`:$vmrestPass"
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$hdrs = @{ Authorization = "Basic $auth" }

Write-Host "Waiting for VMREST API..." -NoNewline
for ($i = 1; $i -le 10; $i++) {
  try {
    Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs | Out-Null
    Write-Host " OK" -ForegroundColor Green
    break
  } catch {
    Write-Host "." -NoNewline
    Start-Sleep 3
  }
}
if ($i -gt 10) {
  Write-Error "VMREST API did not respond."
  exit 1
}

#---- 8) Discover the template VM’s GUID ----#
Write-Host "Querying VMREST for template ID..." -ForegroundColor Cyan
$vms      = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs
$template = $vms | Where-Object { $_.displayName -eq 'Win2022_GUI' } | Select-Object -First 1
if (-not $template) {
  Write-Error "Template VM 'Win2022_GUI' not found via VMREST."
  exit 1
}
$templateId = $template.id
Write-Host "Template GUID: $templateId" -ForegroundColor Green

#---- 9) Enable linked-clone template mode ----#
Write-Host "Enabling template mode for linked clones..." -ForegroundColor Cyan
Invoke-RestMethod `
  -Uri "http://127.0.0.1:8697/api/vms/$templateId/template" `
  -Method Put `
  -Headers $hdrs `
  -Body '{"value":true}' `
  -ContentType 'application/json'
Write-Host "Template mode enabled." -ForegroundColor Green

#---- 10) Write terraform.tfvars ----#
Write-Host "Writing terraform.tfvars..." -ForegroundColor Cyan
@"
vmrest_user   = "$vmrestUser"
vmrest_pass   = "$vmrestPass"
template_id   = "$templateId"
vm_processors = 2
vm_memory     = 2048
vm_path       = "$($VmOutputPath -replace '\\','\\\\')"
"@ | Set-Content -Path $tfvarsFile -Encoding ASCII
Write-Host "terraform.tfvars written." -ForegroundColor Green

#---- 11) Terraform init & apply ----#
Write-Host "Running Terraform init & apply..." -ForegroundColor Cyan
Push-Location $scriptRoot
terraform init -upgrade
terraform apply -auto-approve -parallelism=1
Pop-Location
Write-Host "Terraform apply complete." -ForegroundColor Green

#---- 12) (Optional) Launch demo VMs in GUI ----#
Write-Host "Launching demo VMs in VMware Workstation..." -ForegroundColor Cyan
$vmNames = 'Vault-VM','PVWA-VM','PSM-VM','CPM-VM'
$vmrun   = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
if (-not $vmrun) { $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' }
foreach ($name in $vmNames) {
  $vmx = Join-Path $VmOutputPath "$name\$name.vmx"
  if (Test-Path $vmx) {
    Write-Host "  -> Starting $name..." -NoNewline
    & $vmrun -T ws start $vmx
    Write-Host " OK" -ForegroundColor Green
  } else {
    Write-Warning "VMX not found: $vmx"
  }
}

Write-Host "`nAll done! Your linked-clone demo VMs should now be running." -ForegroundColor Green
