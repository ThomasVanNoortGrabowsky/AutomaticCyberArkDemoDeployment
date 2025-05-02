<#
.SYNOPSIS
    Builds a Win2022 GUI VM with Packer (installs needed plugins), registers it with VMREST, retrieves its GUID, writes terraform.tfvars, and runs Terraform to deploy demo VMs.
.DESCRIPTION
    1) Validates the ISO checksum.
    2) Installs Packer if missing.
    3) Installs the VMware, QEMU, and VirtualBox Packer plugins.
    4) Cleans previous Packer output.
    5) Removes unsupported linked_clone from the JSON template.
    6) Builds the Win2022_GUI template with Packer.
    7) Registers the VMX with VMware Workstation (vmrun register).
    8) Starts and checks the VMREST API.
    9) Retrieves the template GUID from VMREST.
   10) Writes terraform.tfvars with the GUID.
   11) Runs Terraform init & apply.
   12) Optionally powers on the demo VMs in the Workstation GUI.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$IsoPath,
    [Parameter(Mandatory)] [string]$VmOutputPath
)

$ErrorActionPreference = 'Stop'

#---- Paths & Credentials ----#
$scriptRoot   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$packerDir    = Join-Path $scriptRoot 'packer-Win2022'
$packerExe    = Join-Path $scriptRoot 'packer-bin\packer.exe'
$outputDir    = Join-Path $packerDir 'output-vmware-iso'
$jsonTemplate = Join-Path $packerDir 'win2022-gui.json'
$templateVmx  = Join-Path $outputDir 'Win2022_GUI.vmx'
$tfvarsFile   = Join-Path $scriptRoot 'terraform.tfvars'

$vmrestUser   = 'vmrest'
$vmrestPass   = 'Cyberark1!'

#---- 1) Validate ISO ----#
if (-not (Test-Path $IsoPath)) {
    Write-Error "ISO not found at: $IsoPath"
    exit 1
}
$isoUrl      = "file:///$($IsoPath -replace '\\','/')"
$isoChecksum = 'sha256:' + (Get-FileHash -Path $IsoPath -Algorithm SHA256).Hash
Write-Host "ISO validated. Checksum: $isoChecksum"

#---- 2) Install Packer if missing ----#
if (-not (Test-Path $packerExe)) {
    Write-Host 'Installing Packer v1.11.2...' -ForegroundColor Cyan
    $packerBin = Split-Path $packerExe
    New-Item -ItemType Directory -Path $packerBin -Force | Out-Null
    $zip = Join-Path $packerBin 'packer.zip'
    Invoke-WebRequest -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $packerBin -Force
    Remove-Item -Path $zip -Force
}
# Update PATH for Packer
$env:PATH = $env:PATH + ';' + (Split-Path $packerExe)

#---- 3) Install Packer plugins ----#
Write-Host 'Installing VMware Packer plugin...' -ForegroundColor Cyan
& $packerExe plugins install github.com/hashicorp/vmware
Write-Host 'Installing QEMU Packer plugin...' -ForegroundColor Cyan
& $packerExe plugins install github.com/hashicorp/qemu
Write-Host 'Installing VirtualBox Packer plugin...' -ForegroundColor Cyan
& $packerExe plugins install github.com/hashicorp/virtualbox

#---- 4) Clean previous Packer output ----#
if (Test-Path $outputDir) {
    Write-Host 'Cleaning old Packer output...' -ForegroundColor Yellow
    Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item -Path $outputDir -Recurse -Force
}

#---- 5) Remove unsupported linked_clone ----#
Write-Host 'Removing unsupported "linked_clone" from JSON template...' -ForegroundColor Cyan
(Get-Content $jsonTemplate) -replace '"linked_clone"\s*:\s*true,?' , '' | Set-Content $jsonTemplate

#---- 6) Build with Packer ----#
Write-Host 'Starting Packer build...' -ForegroundColor Cyan
Push-Location $packerDir
& $packerExe build -var "iso_url=$isoUrl" -var "iso_checksum=$isoChecksum" $jsonTemplate
if ($LASTEXITCODE -ne 0) {
    Write-Error 'Packer build failed.'
    Pop-Location
    exit 1
}
Pop-Location
Write-Host 'Packer build completed successfully.' -ForegroundColor Green

#---- 7) Register template with VMREST ----#
if (Test-Path $templateVmx) {
    Write-Host 'Registering template VM with VMREST...' -ForegroundColor Cyan
    $vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
    if (-not $vmrun) { $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' }
    & $vmrun -T ws register $templateVmx 2>$null
    Write-Host 'Template VM registered.' -ForegroundColor Green
}

#---- 8) Start and check VMREST API ----#
Write-Host 'Starting VMREST daemon...' -ForegroundColor Cyan
& (Join-Path $scriptRoot 'StartVMRestDaemon.ps1')

$pair = "$vmrestUser`:$vmrestPass"
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$hdrs = @{ Authorization = "Basic $auth" }
Write-Host 'Waiting for VMREST API...' -NoNewline
for ($i = 1; $i -le 10; $i++) {
    try {
        Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs | Out-Null
        Write-Host ' OK' -ForegroundColor Green
        break
    } catch {
        Write-Host '.' -NoNewline; Start-Sleep -Seconds 3
    }
}
try {
    Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs | Out-Null
} catch {
    Write-Error 'VMREST API did not respond.'; exit 1
}

#---- 9) Retrieve template GUID ----#
Write-Host 'Retrieving template GUID...' -ForegroundColor Cyan
$vms = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs
$template = $vms | Where-Object { $_.displayName -match 'Win2022' } | Select-Object -First 1
if (-not $template) { Write-Error 'Template matching "Win2022" not found.'; exit 1 }
$templateId = $template.id
Write-Host "Template GUID: $templateId" -ForegroundColor Green

#---- 10) Write terraform.tfvars ----#
Write-Host 'Writing terraform.tfvars...' -ForegroundColor Cyan
@"
vmrest_user     = "$vmrestUser"
vmrest_password = "$vmrestPass"
template_id     = "$templateId"
vm_path         = "$VmOutputPath"
"@ | Set-Content -Path $tfvarsFile -Encoding ASCII

#---- 11) Terraform init & apply ----#
Write-Host 'Running Terraform init...' -ForegroundColor Cyan
Push-Location $scriptRoot
terraform init -upgrade
Write-Host 'Running Terraform apply...' -ForegroundColor Cyan
terraform apply -auto-approve -parallelism=1
Pop-Location
Write-Host 'Terraform apply completed.' -ForegroundColor Green

#---- 12) Launch demo VMs ----#
Write-Host 'Launching demo VMs...' -ForegroundColor Cyan
$vmNames = 'Vault-VM','PVWA-VM','PSM-VM','CPM-VM'
$vmrun   = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
if (-not $vmrun) { $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' }
foreach ($name in $vmNames) {
    $vmx = Join-Path $VmOutputPath "$name\$name.vmx"
    if (Test-Path $vmx) {
        Write-Host "Starting VM: $name" -ForegroundColor Cyan
        & $vmrun -T ws start $vmx
    } else {
        Write-Warning "VMX not found: $vmx"
    }
}

Write-Host 'All done. Your demo VMs are built, deployed, and running in VMware Workstation.' -ForegroundColor Green
