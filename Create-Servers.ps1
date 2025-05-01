<#
.SYNOPSIS
  Build Win2022 GUI base + linked clone, register, VMREST → Terraform → optional VM launch.

.DESCRIPTION
  - Prompts for ISO path and VM folder if not supplied.
  - Builds base VM (vmware-iso) and linked clone (vmware-vmx).
  - Registers linked VM in Workstation via vmrun.
  - Starts & polls VMREST API using HTTP Basic.
  - Discovers template VM’s ID.
  - Writes terraform.tfvars.
  - Runs Terraform apply.
  - Optionally powers on Vault-VM, PVWA-VM, PSM-VM, CPM-VM.
#>

[CmdletBinding()]
param(
  [string]$IsoPath,
  [string]$VmOutputPath
)

# 1) Interactive fallback
if (-not $IsoPath)      { $IsoPath      = Read-Host "Enter ISO path (e.g. C:\path\to\SERVER_EVAL_x64FRE_en-us.iso)" }
if (-not $VmOutputPath) { $VmOutputPath = Read-Host "Enter VM output folder (e.g. C:\VMs)" }

$ErrorActionPreference = 'Stop'

# 2) Paths & credentials
$scriptRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$packerBin    = Join-Path  $scriptRoot 'packer-bin'
$packerExe    = Join-Path  $packerBin   'packer.exe'
$packerDir    = Join-Path  $scriptRoot 'packer-Win2022'
$outputBase   = Join-Path  $packerDir   'output-base'
$outputLinked = Join-Path  $packerDir   'output-linked'
$templateVmx  = Join-Path  $outputLinked 'Win2022_GUI-linked.vmx'
$tfvarsFile   = Join-Path  $scriptRoot  'terraform.tfvars'

$vmrestUser   = 'vmrest'
$vmrestPass   = 'Cyberark1!'

# 3) Validate ISO & checksum
if (-not (Test-Path $IsoPath)) {
    Write-Error "ISO not found at '$IsoPath'"; exit 1
}
$isoUrl      = "file:///$($IsoPath -replace '\\','/')"
$isoChecksum = 'sha256:' + (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
Write-Host "✔ ISO checksum: $isoChecksum" -ForegroundColor Green

# 4) Install Packer (if needed)
if (-not (Test-Path $packerExe)) {
  Write-Host '➜ Installing Packer v1.11.2...' -ForegroundColor Cyan
  New-Item -ItemType Directory -Path $packerBin -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest `
    -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' `
    -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force
  Remove-Item -Path $zip -Force
}
# prepend Packer to PATH for this session
$origPath = [Environment]::GetEnvironmentVariable('PATH','Process')
[Environment]::SetEnvironmentVariable('PATH', "$packerBin;$origPath",'Process')

# 5) Clean previous builds
if (Test-Path $outputBase)   { Remove-Item -Recurse -Force $outputBase }
if (Test-Path $outputLinked) { Remove-Item -Recurse -Force $outputLinked }

# 6a) Build the base VM
Write-Host '➜ Packer: building base VM...' -ForegroundColor Cyan
Push-Location $packerDir
& $packerExe build -only=vmware-iso `
    -var "iso_url=$isoUrl" `
    -var "iso_checksum=$isoChecksum" `
    'win2022-gui.json'
if ($LASTEXITCODE -ne 0) {
    Write-Error '✖ Base build failed.'; Pop-Location; exit 1
}

# 6b) Build the linked clone
Write-Host '➜ Packer: building linked clone...' -ForegroundColor Cyan
& $packerExe build -only=vmware-vmx 'win2022-gui.json'
if ($LASTEXITCODE -ne 0) {
    Write-Error '✖ Linked clone build failed.'; Pop-Location; exit 1
}
Pop-Location
Write-Host '✔ Packer builds complete.' -ForegroundColor Green

# 7) Register the linked VM in VMware Workstation
if (Test-Path $templateVmx) {
    Write-Host '➜ Registering linked VM...' -ForegroundColor Cyan
    $vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
    if (-not $vmrun) { 
      $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
    }
    & $vmrun -T ws register $templateVmx | Out-Null
    Write-Host '✔ Template registered.' -ForegroundColor Green
}

# 8) Start the VMREST daemon
Write-Host '➜ Starting VMREST daemon...' -ForegroundColor Cyan
& (Join-Path $scriptRoot 'StartVMRestDaemon.ps1')

# 9) Wait for VMREST API to respond
$pair    = "$vmrestUser`:$vmrestPass"
$auth    = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)]
$headers = @{ Authorization = "Basic $auth" }
Write-Host '➜ Waiting for VMREST API...' -NoNewline
for ($i=1; $i -le 10; $i++) {
    try {
        Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' `
                          -Headers $headers -UseBasicParsing | Out-Null
        Write-Host ' OK' -ForegroundColor Green
        break
    } catch {
        Write-Host '.' -NoNewline; Start-Sleep 3
    }
}

# 10) Discover the template VM’s ID
Write-Host "`nVMREST inventory:" -ForegroundColor Cyan
$vms = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $headers -UseBasicParsing
for ($j=0; $j -lt $vms.Count; $j++) {
    $name = $vms[$j].displayName
    if (-not $name) { $name = '(blank)' }
    Write-Host (" [{0}] {1,-20} : {2}" -f $j, $name, $vms[$j].id)
}
$template = $vms | Where-Object { $_.displayName -match 'Win2022' } | Select-Object -First 1
if (-not $template) {
    Write-Warning 'No "Win2022" match; using first VM.'; $template = $vms[0]
}
Write-Host "✔ Selected template ID: $($template.id)" -ForegroundColor Green

# 11) Write terraform.tfvars
Write-Host '➜ Writing terraform.tfvars...' -ForegroundColor Cyan
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

# 12) Terraform init & apply
Write-Host '➜ Running Terraform init & apply...' -ForegroundColor Cyan
Push-Location $scriptRoot
terraform init -upgrade
terraform apply -auto-approve -parallelism=1
Pop-Location
Write-Host '✔ Terraform apply complete.' -ForegroundColor Green

# 13) (Optional) Power on demo VMs
Write-Host '➜ Powering on demo VMs...' -ForegroundColor Cyan
$vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
if (-not $vmrun) {
    $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
}
foreach ($name in 'Vault-VM','PVWA-VM','PSM-VM','CPM-VM') {
    $vmx = Join-Path $VmOutputPath "$name\$name.vmx"
    if (Test-Path $vmx) {
        & $vmrun -T ws start $vmx | Out-Null
    }
}

Write-Host "`n🎉 All done!" -ForegroundColor Green
