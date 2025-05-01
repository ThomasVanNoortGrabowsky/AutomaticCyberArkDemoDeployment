<#
.SYNOPSIS
  Build a Win2022 template with Packer, register it, discover its ID via VMREST, then deploy VMs with Terraform.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $IsoPath,
  [Parameter(Mandatory)] [string] $VmOutputPath
)

$ErrorActionPreference = 'Stop'

# Paths
$scriptRoot  = Split-Path $MyInvocation.MyCommand.Path -Parent
$packerBin   = Join-Path $scriptRoot 'packer-bin'
$packerExe   = Join-Path $packerBin 'packer.exe'
$packerDir   = Join-Path $scriptRoot 'packer-Win2022'
$outputDir   = Join-Path $packerDir 'output-vmware-iso'
$templateVmx = Join-Path $outputDir 'Win2022_GUI.vmx'
$tfvarsFile  = Join-Path $scriptRoot 'terraform.tfvars'

# VMREST credentials
$vmrestUser = 'vmrest'
$vmrestPass = 'Cyberark1!'

# 1) Validate ISO
if (-not (Test-Path $IsoPath)) {
    Write-Error "ISO not found at: $IsoPath"
    exit 1
}
$isoUrl      = "file:///$($IsoPath -replace '\\','/')"
$isoChecksum = 'sha256:' + (Get-FileHash -Path $IsoPath -Algorithm SHA256).Hash
Write-Host "✔ ISO validated. Checksum: $isoChecksum" -ForegroundColor Green

# 2) Ensure Packer
if (-not (Test-Path $packerExe)) {
    Write-Host "Installing Packer 1.11.2..." -ForegroundColor Cyan
    New-Item -Type Directory -Path $packerBin -Force | Out-Null
    $zip = Join-Path $packerBin 'packer.zip'
    Invoke-WebRequest -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $packerBin -Force
    Remove-Item $zip
}
$env:PATH = "$packerBin;$env:PATH"

# 3) Clean old Packer output
if (Test-Path $outputDir) {
    Write-Host "Cleaning old Packer output..." -ForegroundColor Yellow
    Get-Process vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item $outputDir -Recurse -Force
}

# 4) Packer build
Write-Host "Running Packer build..." -ForegroundColor Cyan
Push-Location $packerDir
& $packerExe build -var "iso_url=$isoUrl" -var "iso_checksum=$isoChecksum" 'win2022-gui.json'
if ($LASTEXITCODE -ne 0) {
    Write-Error "Packer build failed."
    Pop-Location
    exit 1
}
Pop-Location
Write-Host "✔ Packer build complete." -ForegroundColor Green

# 5) Register VM template (if vmrun available)
if (Test-Path $templateVmx) {
    Write-Host "Registering template VM with Workstation..." -ForegroundColor Cyan
    $vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
    if (-not $vmrun) {
        $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
    }
    & $vmrun -T ws register $templateVmx | Out-Null
    Write-Host "✔ Template VM registered." -ForegroundColor Green
}

# 6) Start VMREST
Write-Host "Starting VMREST daemon..." -ForegroundColor Cyan
& (Join-Path $scriptRoot 'StartVMRestDaemon.ps1')

# 7) Wait for VMREST
$pair  = "$vmrestUser`:$vmrestPass"
$auth  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$hdrs  = @{ Authorization = "Basic $auth" }
Write-Host "Waiting for VMREST API..." -NoNewline
for ($i=0; $i -lt 10; $i++) {
    try {
        Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs -UseBasicParsing | Out-Null
        Write-Host " OK" -ForegroundColor Green
        break
    } catch {
        Write-Host "." -NoNewline
        Start-Sleep 3
    }
}
if ($LASTEXITCODE -ne 0) {
    Write-Error "VMREST API did not respond."
    exit 1
}

# 8) List and find template GUID
Write-Host "`nVMREST Inventory:" -ForegroundColor Cyan
$vms = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs -UseBasicParsing
$vms | ForEach-Object { Write-Host " - $($_.displayName) (id: $($_.id))" }

$template = $vms | Where-Object { $_.displayName -match 'Win2022' } | Select-Object -First 1
if (-not $template) {
    Write-Error "Template VM not found in VMREST inventory."
    exit 1
}
$templateId = $template.id
Write-Host "`n✔ Using template '$($template.displayName)' with GUID $templateId" -ForegroundColor Green

# 9) Write terraform.tfvars
Write-Host "Writing terraform.tfvars..." -ForegroundColor Cyan
$escPath = $VmOutputPath -replace '\\','\\\\'
@"
vmrest_user     = "$vmrestUser"
vmrest_password = "$vmrestPass"
vault_image_id  = "$templateId"
app_image_id    = "$templateId"
vm_processors   = 2
vm_memory       = 2048
vm_path         = "$escPath"
"@ | Set-Content -Path $tfvarsFile -Encoding ASCII

# 10) Terraform apply
Write-Host "Running Terraform init & apply..." -ForegroundColor Cyan
Push-Location $scriptRoot
terraform init -upgrade
terraform apply -auto-approve -parallelism=1
Pop-Location
Write-Host "✔ Terraform apply complete." -ForegroundColor Green

# 11) Optional: Launch VMs in GUI
Write-Host "Launching demo VMs..." -ForegroundColor Cyan
$vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
if (-not $vmrun) {
    $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
}
foreach ($name in 'Vault-VM','PVWA-VM','PSM-VM','CPM-VM') {
    $vmx = Join-Path $VmOutputPath "$name\$name.vmx"
    if (Test-Path $vmx) {
        Write-Host "  Starting $name..." -NoNewline
        & $vmrun -T ws start $vmx | Out-Null
        Write-Host " OK" -ForegroundColor Green
    } else {
        Write-Warning "VMX not found for $name at $vmx"
    }
}

Write-Host "`n🎉 All done!" -ForegroundColor Green
