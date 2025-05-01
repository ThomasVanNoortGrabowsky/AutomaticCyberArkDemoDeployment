<#
.SYNOPSIS
  Full pipeline: Packer → VMREST → Terraform → optional VM launch.

.DESCRIPTION
  1. Builds Win2022_GUI with Packer.
  2. Registers that VM in Workstation.
  3. Starts & health-checks VMREST.
  4. Lists VMREST inventory; picks “Win2022” or first entry.
  5. Writes terraform.tfvars with that GUID.
  6. Runs Terraform init & apply.
  7. (Optional) Powers on the four demo VMs.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $IsoPath,
    [Parameter(Mandatory)] [string] $VmOutputPath
)

$ErrorActionPreference = 'Stop'

# Paths
$scriptRoot   = Split-Path $MyInvocation.MyCommand.Path -Parent
$packerBin    = Join-Path $scriptRoot 'packer-bin'
$packerExe    = Join-Path $packerBin   'packer.exe'
$packerDir    = Join-Path $scriptRoot 'packer-Win2022'
$outputDir    = Join-Path $packerDir   'output-vmware-iso'
$templateVmx  = Join-Path $outputDir   'Win2022_GUI.vmx'
$tfvarsFile   = Join-Path $scriptRoot 'terraform.tfvars'

# VMREST creds
$vmrestUser = 'vmrest'
$vmrestPass = 'Cyberark1!'

### 1) Validate ISO ###
if (-not (Test-Path $IsoPath)) {
    Write-Error "ISO not found at: $IsoPath"; exit 1
}
$isoUrl      = "file:///$($IsoPath -replace '\\','/')"
$isoChecksum = 'sha256:' + (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
Write-Host "✔ ISO validated. Checksum: $isoChecksum" -ForegroundColor Green

### 2) Ensure Packer ###
if (-not (Test-Path $packerExe)) {
    Write-Host 'Installing Packer v1.11.2…' -ForegroundColor Cyan
    New-Item -Path $packerBin -ItemType Directory -Force | Out-Null
    $zip = Join-Path $packerBin 'packer.zip'
    Invoke-WebRequest `
      -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' `
      -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $packerBin -Force
    Remove-Item $zip
}
$env:PATH = "$packerBin;$env:PATH"

### 3) Clean old Packer output ###
if (Test-Path $outputDir) {
    Write-Host 'Cleaning old Packer output…' -ForegroundColor Yellow
    Get-Process vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item $outputDir -Recurse -Force
}

### 4) Build the golden image ###
Write-Host 'Running Packer build…' -ForegroundColor Cyan
Push-Location $packerDir
& $packerExe build -var "iso_url=$isoUrl" -var "iso_checksum=$isoChecksum" 'win2022-gui.json'
if ($LASTEXITCODE -ne 0) {
    Write-Error 'Packer build failed.'; Pop-Location; exit 1
}
Pop-Location
Write-Host '✔ Packer build complete.' -ForegroundColor Green

### 5) Register VM template ###
if (Test-Path $templateVmx) {
    Write-Host 'Registering template VM…' -ForegroundColor Cyan
    $vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
    if (-not $vmrun) { $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' }
    & $vmrun -T ws register $templateVmx | Out-Null
    Write-Host '✔ Template registered (if supported).' -ForegroundColor Green
}

### 6) Start VMREST daemon ###
Write-Host 'Starting VMREST daemon…' -ForegroundColor Cyan
& (Join-Path $scriptRoot 'StartVMRestDaemon.ps1')

### 7) Wait for VMREST API ###
$pair      = "$vmrestUser`:$vmrestPass"
$authValue = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$headers   = @{ Authorization = "Basic $authValue" }

Write-Host 'Waiting for VMREST API…' -NoNewline
for ($i=1; $i -le 10; $i++) {
    try {
        Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $headers -UseBasicParsing | Out-Null
        Write-Host ' OK' -ForegroundColor Green
        break
    } catch {
        Write-Host '.' -NoNewline; Start-Sleep 3
    }
}
if ($LASTEXITCODE -ne 0) {
    Write-Error 'VMREST API did not respond.'; exit 1
}

### 8) List VMREST inventory & pick template ###
Write-Host "`nVMREST inventory:" -ForegroundColor Cyan
$vms = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $headers -UseBasicParsing
for ($idx=0; $idx -lt $vms.Count; $idx++) {
    $name = if ($vms[$idx].displayName) { $vms[$idx].displayName } else { '(blank)' }
    Write-Host ("  [{0}] {1,-20} : {2}" -f $idx, $name, $vms[$idx].id)
}

# Try match
$template = $vms | Where-Object { $_.displayName -match 'Win2022' } | Select-Object -First 1
if (-not $template) {
    Write-Warning "No match for 'Win2022'; falling back to first entry."
    $template = $vms[0]
}
Write-Host "`n✔ Using template id: $($template.id)" -ForegroundColor Green

### 9) Write terraform.tfvars ###
Write-Host 'Writing terraform.tfvars…' -ForegroundColor Cyan
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

### 10) Terraform init & apply ###
Write-Host 'Running Terraform init & apply…' -ForegroundColor Cyan
Push-Location $scriptRoot
terraform init -upgrade
terraform apply -auto-approve -parallelism=1
Pop-Location
Write-Host '✔ Terraform apply complete.' -ForegroundColor Green

### 11) (Optional) Power on demo VMs ###
Write-Host 'Powering on demo VMs…' -ForegroundColor Cyan
$vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
if (-not $vmrun) { $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' }
foreach ($name in 'Vault-VM','PVWA-VM','PSM-VM','CPM-VM') {
    $vmxPath = Join-Path $VmOutputPath "$name\$name.vmx"
    if (Test-Path $vmxPath) {
        Write-Host "  Starting $name…" -NoNewline
        & $vmrun -T ws start $vmxPath | Out-Null
        Write-Host ' OK' -ForegroundColor Green
    } else {
        Write-Warning "VMX not found: $vmxPath"
    }
}

Write-Host "`nAll done!" -ForegroundColor Green
