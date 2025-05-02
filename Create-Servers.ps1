<#
.SYNOPSIS
    Builds a Win2022 GUI VM with Packer (installs necessary plugins), registers it with VMREST, discovers its ID, and then uses Terraform to deploy demo VMs (Vault, PVWA, PSM, CPM).
.DESCRIPTION
    1) Installs Packer VMware plugin if missing.
    2) Builds the “Win2022_GUI” template with Packer.
    3) Registers that template with VMware Workstation (vmrun register).
    4) Starts and health-checks the VMware REST API (VMREST).
    5) Queries VMREST for the new template’s GUID.
    6) Writes terraform.tfvars with that GUID.
    7) Runs Terraform init & apply to deploy Vault, PVWA, PSM, and CPM.
    8) (Optional) Powers on the resulting VMs in the Workstation GUI.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IsoPath,
    [Parameter(Mandatory)][string]$VmOutputPath
)

$ErrorActionPreference = 'Stop'

#---- Paths & credentials ----#
$scriptRoot   = Split-Path $MyInvocation.MyCommand.Path -Parent
$packerDir    = Join-Path $scriptRoot 'packer-Win2022'
$packerExe    = Join-Path $scriptRoot 'packer-bin\packer.exe'
$outputDir    = Join-Path $packerDir 'output-vmware-iso'
$templateVmx  = Join-Path $outputDir 'Win2022_GUI.vmx'
$tfvarsFile   = Join-Path $scriptRoot 'terraform.tfvars'

$vmrestUser = 'vmrest'
$vmrestPass = 'Cyberark1!'

#---- 1) Validate ISO ----#
if (-not (Test-Path $IsoPath)) {
    Write-Error "ISO not found at: $IsoPath"
    exit 1
}
$isoUrl      = "file:///$($IsoPath -replace '\\','/')"
$isoChecksum = "sha256:$((Get-FileHash -Path $IsoPath -Algorithm SHA256).Hash)"
Write-Host "✔ ISO validated. Checksum: $isoChecksum" -ForegroundColor Green

#---- 2) Install Packer if missing ----#
if (-not (Test-Path $packerExe)) {
    Write-Host "Installing Packer v1.11.2..." -ForegroundColor Cyan
    $packerBin = Split-Path $packerExe
    New-Item -Path $packerBin -ItemType Directory -Force | Out-Null
    $zip = Join-Path $packerBin 'packer.zip'
    Invoke-WebRequest -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $packerBin -Force
    Remove-Item $zip
}
# Update PATH for Packer
$env:PATH = $env:PATH + ";" + (Split-Path $packerExe)

#---- 3) Ensure VMware plugin ----#
Write-Host "Installing VMware Packer plugin..." -ForegroundColor Cyan
& $packerExe plugins install github.com/hashicorp/vmware

#---- 4) Clean previous Packer output ----#
if (Test-Path $outputDir) {
    Write-Host "Cleaning old Packer output..." -ForegroundColor Yellow
    Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item -Recurse -Force $outputDir
}

#---- 5) Build the golden image ----#
Write-Host "Running Packer build..." -ForegroundColor Cyan
Push-Location $packerDir
& $packerExe build `
    -var "iso_url=$isoUrl" `
    -var "iso_checksum=$isoChecksum" `
    'win2022-gui.json'
if ($LASTEXITCODE -ne 0) {
    Write-Error "❌ Packer build failed."
    Pop-Location; exit 1
}
Pop-Location
Write-Host "✔ Packer build complete." -ForegroundColor Green

#---- 6) Register the template with VMREST ----#
if (Test-Path $templateVmx) {
    Write-Host "Registering template with VMREST..." -ForegroundColor Cyan
    $vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
    if (-not $vmrun) { $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' }
    & $vmrun -T ws register $templateVmx 2>$null
    Write-Host "✔ Template VM registered." -ForegroundColor Green
}

#---- 7) Start VMREST daemon ----#
Write-Host "Starting VMREST daemon..." -ForegroundColor Cyan
& (Join-Path $scriptRoot 'StartVMRestDaemon.ps1')

#---- 8) Wait for VMREST API ----#
$pair = "$vmrestUser`:$vmrestPass"
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$hdrs = @{ Authorization = "Basic $auth" }
Write-Host "Waiting for VMREST API..." -NoNewline
for ($i=1; $i -le 10; $i++) {
    try {
        Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs -UseBasicParsing | Out-Null
        Write-Host " OK" -ForegroundColor Green; break
    } catch { Write-Host "." -NoNewline; Start-Sleep -Seconds 3 }
}
try { Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs -UseBasicParsing | Out-Null } catch {
    Write-Error "❌ VMREST API did not respond."; exit 1
}

#---- 9) Discover template GUID ----#
Write-Host "Querying VMREST for template ID..." -ForegroundColor Cyan
$vms = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs -UseBasicParsing
$vms | ForEach-Object { Write-Host " - $($_.displayName) (id: $($_.id))" }
$template = $vms | Where-Object { $_.displayName -match 'Win2022' } | Select-Object -First 1
if (-not $template) {
    Write-Error "❌ Could not locate a VMREST entry matching 'Win2022'."; exit 1
}
$templateId = $template.id
Write-Host "✔ Selected template: $($template.displayName) (GUID: $templateId)" -ForegroundColor Green

#---- 10) Write terraform.tfvars ----#
Write-Host "Writing terraform.tfvars..." -ForegroundColor Cyan
@"
vmrest_user     = "$vmrestUser"
vmrest_password = "$vmrestPass"
template_id     = "$templateId"
vm_path         = "$VmOutputPath"
"@ | Set-Content -Path $tfvarsFile -Encoding ASCII

#---- 11) Terraform init & apply ----#
Write-Host "Running Terraform init & apply..." -ForegroundColor Cyan
Push-Location $scriptRoot
terraform init -upgrade
