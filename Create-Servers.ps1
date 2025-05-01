<#
.SYNOPSIS
  Build Win2022 GUI base image, make a fast linked clone, register in WS, drive VMREST & Terraform,
  and optionally power on demo VMs—while still prompting you only if you didn’t supply paths.
#>

[CmdletBinding()]
param(
  [string]$IsoPath,
  [string]$VmOutputPath
)

# ------------- Interactive fallback -------------
if (-not $IsoPath) {
  $IsoPath = Read-Host "Enter ISO path (e.g. C:\path\to\SERVER_EVAL_x64FRE_en-us.iso)"
}
if (-not $VmOutputPath) {
  $VmOutputPath = Read-Host "Enter VM output path (e.g. C:\Users\You\Documents\Virtual Machines)"
}

$ErrorActionPreference = 'Stop'

# -------- paths & credentials --------
$scriptRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$packerBin    = Join-Path  $scriptRoot 'packer-bin'
$packerExe    = Join-Path  $packerBin   'packer.exe'
$packerDir    = Join-Path  $scriptRoot 'packer-Win2022'
$outputBase   = Join-Path  $packerDir   'output-base'
$outputLinked = Join-Path  $packerDir   'output-linked'
$templateVmx  = Join-Path  $outputLinked 'Win2022_GUI-linked.vmx'
$tfvarsFile   = Join-Path  $scriptRoot 'terraform.tfvars'

$vmrestUser   = 'vmrest'
$vmrestPass   = 'Cyberark1!'

# -------- 1) Validate ISO & compute checksum --------
if (-not (Test-Path $IsoPath)) {
    Write-Error "ISO not found: $IsoPath"
    exit 1
}
$isoUrl      = "file:///$($IsoPath -replace '\\','/')"
$isoChecksum = 'sha256:' + (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
Write-Host "✔ ISO checksum: $isoChecksum" -ForegroundColor Green

# -------- 2) Ensure Packer is installed --------
if (-not (Test-Path $packerExe)) {
  Write-Host '➜ Installing Packer 1.11.2...' -ForegroundColor Cyan
  New-Item -ItemType Directory -Path $packerBin -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest `
    -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' `
    -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force
  Remove-Item    -Path $zip -Force
}
# prepend to PATH for this session
$oldPath = [Environment]::GetEnvironmentVariable('PATH','Process')
[Environment]::SetEnvironmentVariable('PATH', "$packerBin;$oldPath", 'Process')

# -------- 3) Clean old outputs --------
if (Test-Path $outputBase)   { Remove-Item -Recurse -Force $outputBase }
if (Test-Path $outputLinked) { Remove-Item -Recurse -Force $outputLinked }

# -------- 4a) Build base image --------
Write-Host '➜ Packer: building base VM...' -ForegroundColor Cyan
Push-Location $packerDir
& $packerExe build `
    -only=vmware-iso `
    -var "iso_url=$isoUrl" `
    -var "iso_checksum=$isoChecksum" `
    'win2022-gui.json'
if ($LASTEXITCODE -ne 0) {
    Write-Error '✖ Base build failed.'; Pop-Location; exit 1
}

# -------- 4b) Build linked clone --------
Write-Host '➜ Packer: building linked clone...' -ForegroundColor Cyan
& $packerExe build -only=vmware-vmx 'win2022-gui.json'
if ($LASTEXITCODE -ne 0) {
    Write-Error '✖ Linked clone build failed.'; Pop-Location; exit 1
}
Pop-Location
Write-Host '✔ Packer base + linked done.' -ForegroundColor Green

# -------- 5) Register linked VM --------
if (Test-Path $templateVmx) {
  Write-Host '➜ Registering linked VM in Workstation...' -ForegroundColor Cyan
  $vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
  if (-not $vmrun) {
    $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
  }
  & $vmrun -T ws register $templateVmx | Out-Null
  Write-Host '✔ Template registered.' -ForegroundColor Green
}

# -------- 6) Start VMREST daemon --------
Write-Host '➜ Starting VMREST daemon...' -ForegroundColor Cyan
& (Join-Path $scriptRoot 'StartVMRestDaemon.ps1')

# -------- 7) Wait for VMREST API --------
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

# -------- 8) Pick template VM --------
Write-Host "`nVMREST inventory:" -ForegroundColor Cyan
$vms = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $headers
for ($j=0; $j -lt $vms.Count; $j++) {
    $nm = $vms[$j].displayName
    if (-not $nm) { $nm = '(blank)' }
    Write-Host (" [{0}] {1,-20} : {2}" -f $j, $nm, $vms[$j].id)
}
$template = $vms | Where-Object { $_.displayName -match 'Win2022' } | Select-Object -First 1
if (-not $template) {
    Write-Warning 'No "Win2022" match; using first VM.'; $template = $vms[0]
}
Write-Host "✔ Selected template ID: $($template.id)" -ForegroundColor Green

# -------- 9) Write terraform.tfvars --------
Write-Host '➜ Writing terraform.tfvars...' -ForegroundColor Cyan
$escapedPath = $VmOutputPath -replace '\\','\\\\'
@"
vmrest_user     = "$vmrestUser"
vmrest_password = "$vmrestPass"
vault_image_id  = "$($template.id)"
app_image_id    = "$($template.id)"
vm_processors   = 2
vm_memory       = 2048
vm_path         = "$escapedPath"
"@ | Set-Content -Path $tfvarsFile -Encoding ASCII

# -------- 10) Terraform init & apply --------
Write-Host '➜ Running Terraform init & apply...' -ForegroundColor Cyan
Push-Location $scriptRoot
terraform init -upgrade
terraform apply -auto-approve -parallelism=1
Pop-Location
Write-Host '✔ Terraform apply complete.' -ForegroundColor Green

# -------- 11) Power on demo VMs (optional) --------
Write-Host '➜ Powering on demo VMs...' -ForegroundColor Cyan
$vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
if (-not $vmrun) {
    $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
}
foreach ($vm in 'Vault-VM','PVWA-VM','PSM-VM','CPM-VM') {
    $vmx = Join-Path $VmOutputPath "$vm\$vm.vmx"
    if (Test-Path $vmx) {
        & $vmrun -T ws start $vmx | Out-Null
    }
}

Write-Host "`n🎉 All done!" -ForegroundColor Green
