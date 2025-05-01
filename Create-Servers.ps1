<#
.SYNOPSIS
  Build base + linked clone, register, VMREST, Terraform, optional VM start.
#>

# no prompts—hardcode here:
$IsoPath      = 'C:\Users\ThomasvanNoort\Downloads\SERVER_EVAL_x64FRE_en-us.iso'
$VmOutputPath = 'C:\Users\ThomasvanNoort\Documents\Virtual Machines'

$ErrorActionPreference = 'Stop'

# paths & credentials
$scriptRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$packerBin    = Join-Path $scriptRoot 'packer-bin'
$packerExe    = Join-Path $packerBin   'packer.exe'
$packerDir    = Join-Path $scriptRoot 'packer-Win2022'
$outputBase   = Join-Path $packerDir   'output-base'
$outputLinked = Join-Path $packerDir   'output-linked'
$templateVmx  = Join-Path $outputLinked 'Win2022_GUI-linked.vmx'
$tfvarsFile   = Join-Path $scriptRoot 'terraform.tfvars'

$vmrestUser   = 'vmrest'
$vmrestPass   = 'Cyberark1!'

# 1) Validate ISO
if (-not (Test-Path $IsoPath)) {
  Write-Error "ISO not found at '$IsoPath'"; exit 1
}
$isoUrl      = "file:///$($IsoPath -replace '\\','/')"
$isoChecksum = 'sha256:' + (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
Write-Host "ISO checksum: $isoChecksum" -ForegroundColor Green

# 2) Install Packer if missing
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
# prepend to PATH
$oldPath = [Environment]::GetEnvironmentVariable('PATH','Process')
[Environment]::SetEnvironmentVariable('PATH', "$packerBin;$oldPath", 'Process')

# 3) Clean prior builds
if (Test-Path $outputBase)   { Remove-Item $outputBase   -Recurse -Force }
if (Test-Path $outputLinked) { Remove-Item $outputLinked -Recurse -Force }

# 4a) Base build
Write-Host 'Packer: building base VM...' -ForegroundColor Cyan
Push-Location $packerDir
& $packerExe build -only=vmware-iso `
    -var "iso_url=$isoUrl" `
    -var "iso_checksum=$isoChecksum" `
    'win2022-gui.json'
if ($LASTEXITCODE -ne 0) {
  Write-Error 'Base build failed.'; Pop-Location; exit 1
}

# 4b) Linked clone
Write-Host 'Packer: building linked clone...' -ForegroundColor Cyan
& $packerExe build -only=vmware-vmx 'win2022-gui.json'
if ($LASTEXITCODE -ne 0) {
  Write-Error 'Linked clone build failed.'; Pop-Location; exit 1
}
Pop-Location
Write-Host 'Packer base + linked done.' -ForegroundColor Green

# 5) Register linked clone
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

# 7) Wait for VMREST
$pair    = "$vmrestUser`:$vmrestPass"
$auth    = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$headers = @{ Authorization = "Basic $auth" }
Write-Host 'Waiting for VMREST API...' -NoNewline
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

# 8) Select template VM
$vms = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $headers
$template = $vms | Where-Object { $_.displayName -match 'Win2022' } | Select-Object -First 1
if (-not $template) {
  Write-Warning 'No Win2022 match; using first VM.'; $template = $vms[0]
}
Write-Host "Selected template ID: $($template.id)" -ForegroundColor Green

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

# 10) Terraform
Write-Host 'Running Terraform init & apply...' -ForegroundColor Cyan
Push-Location $scriptRoot
terraform init -upgrade
terraform apply -auto-approve -parallelism=1
Pop-Location
Write-Host 'Terraform apply complete.' -ForegroundColor Green

# 11) Optional: power on VMs
Write-Host 'Powering on demo VMs...' -ForegroundColor Cyan
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

Write-Host "`nAll done!" -ForegroundColor Green
