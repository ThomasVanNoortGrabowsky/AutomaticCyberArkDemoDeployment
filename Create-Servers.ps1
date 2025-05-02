<#
.SYNOPSIS
    Builds a Win2022 GUI VM with Packer (installs VMware plugin), registers it with VMREST, retrieves its GUID, writes terraform.tfvars, and runs Terraform to deploy demo VMs.
.DESCRIPTION
    1) Validates the ISO checksum.
    2) Installs Packer if missing.
    3) Installs the VMware Packer plugin.
    4) Cleans previous Packer output.
    5) Builds the Win2022_GUI template with Packer.
    6) Registers the VMX with VMware Workstation (vmrun register).
    7) Starts and checks the VMREST API.
    8) Retrieves the template GUID from VMREST.
    9) Writes terraform.tfvars with the GUID.
   10) Runs Terraform init & apply.
   11) Optionally powers on the demo VMs in the Workstation GUI.
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
    Write-Host 'Installing Packer 1.11.2...' 
    $packerBin = Split-Path $packerExe
    New-Item -ItemType Directory -Path $packerBin -Force | Out-Null
    $zip = Join-Path $packerBin 'packer.zip'
    Invoke-WebRequest -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $packerBin -Force
    Remove-Item -Path $zip -Force
}
# Update PATH for Packer
$env:PATH = $env:PATH + ';' + (Split-Path $packerExe)

#---- 3) Install VMware plugin ----#
Write-Host 'Installing VMware Packer plugin...'
& $packerExe plugins install github.com/hashicorp/vmware

#---- 4) Clean previous Packer output ----#
if (Test-Path $outputDir) {
    Write-Host 'Cleaning old Packer output...'
    Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item -Path $outputDir -Recurse -Force
}

#---- 5) Build with Packer ----#
Write-Host 'Starting Packer build...'
Push-Location $packerDir
& $packerExe build -var "iso_url=$isoUrl" -var "iso_checksum=$isoChecksum" 'win2022-gui.json'
if ($LASTEXITCODE -ne 0) {
    Write-Error 'Packer build failed.'
    Pop-Location
    exit 1
}
Pop-Location
Write-Host 'Packer build completed successfully.'

#---- 6) Register template with VMREST ----#
if (Test-Path $templateVmx) {
    Write-Host 'Registering template VM with VMREST...'
    $vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
    if (-not $vmrun) { $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' }
    & $vmrun -T ws register $templateVmx 2>$null
    Write-Host 'Template VM registered.'
}

#---- 7) Start and check VMREST API ----#
Write-Host 'Starting VMREST daemon...'
& (Join-Path $scriptRoot 'StartVMRestDaemon.ps1')

$pair = "$vmrestUser`:$vmrestPass"
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$hdrs = @{ Authorization = "Basic $auth" }
Write-Host 'Waiting for VMREST API...'
for ($i = 1; $i -le 10; $i++) {
    try {
        Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs | Out-Null
        Write-Host 'VMREST API is online.'
        break
    } catch {
        Start-Sleep -Seconds 3
    }
}
# Final check
try {
    Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs | Out-Null
} catch {
    Write-Error 'VMREST API did not respond.'
    exit 1
}

#---- 8) Retrieve template GUID ----#
Write-Host 'Retrieving template GUID...'
$vms = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs
$template = $vms | Where-Object { $_.displayName -match 'Win2022' } | Select-Object -First 1
if (-not $template) {
    Write-Error 'Template matching "Win2022" not found.'
    exit 1
}
$templateId = $template.id
Write-Host "Template GUID: $templateId"

#---- 9) Write terraform.tfvars ----#
Write-Host 'Writing terraform.tfvars...'
@"
vmrest_user     = "$vmrestUser"
vmrest_password = "$vmrestPass"
template_id     = "$templateId"
vm_path         = "$VmOutputPath"
"@ | Set-Content -Path $tfvarsFile -Encoding ASCII

#---- 10) Terraform init & apply ----#
Write-Host 'Running Terraform init...'
Push-Location $scriptRoot
terraform init -upgrade
Write-Host 'Running Terraform apply...'
terraform apply -auto-approve -parallelism=1
Pop-Location
Write-Host 'Terraform apply completed.'

#---- 11) Launch demo VMs ----#
Write-Host 'Launching demo VMs...'
$vmNames = 'Vault-VM','PVWA-VM','PSM-VM','CPM-VM'
$vmrun   = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
if (-not $vmrun) { $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' }
foreach ($name in $vmNames) {
    $vmx = Join-Path $VmOutputPath "$name\$name.vmx"
    if (Test-Path $vmx) {
        Write-Host "Starting VM: $name"
        & $vmrun -T ws start $vmx
    } else {
        Write-Warning "VMX not found: $vmx"
    }
}

Write-Host 'All done. Your demo VMs are built, deployed, and running in VMware Workstation.'
