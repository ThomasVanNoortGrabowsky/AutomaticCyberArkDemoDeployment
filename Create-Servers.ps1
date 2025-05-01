<#
.SYNOPSIS
  Full pipeline: Packer (base + linked) → VMREST → Terraform → optional VM launch
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$IsoPath,
    [Parameter(Mandatory=$true)][string]$VmOutputPath
)

$ErrorActionPreference = 'Stop'

# Paths & creds
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
  Write-Error "ISO not found at '$IsoPath'"; exit 1
}
$isoUrl      = "file:///$($IsoPath -replace '\\','/')"
$isoChecksum = 'sha256:' + (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash

# 2) Install Packer if needed
if (-not (Test-Path $packerExe)) {
  Write-Host 'Installing Packer 1.11.2...' -ForegroundColor Cyan
  New-Item -ItemType Directory -Path $packerBin -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force
  Remove-Item $zip -Force
}
# Prepend packer to PATH
$orig = [Environment]::GetEnvironmentVariable('PATH','Process')
[Environment]::SetEnvironmentVariable('PATH', "$packerBin;$orig",'Process')

# 3) Clean old linked output
if (Test-Path $outputLinked) {
  Remove-Item -Path $outputLinked -Recurse -Force
}

# 4) Packer build (base + linked)
Push-Location $packerDir
& $packerExe build `
    -var "iso_url=$isoUrl" `
    -var "iso_checksum=$isoChecksum" `
    'win2022-gui.json'
if ($LASTEXITCODE -ne 0) {
  Write-Error 'Packer build failed.'; Pop-Location; exit 1
}
Pop-Location

# 5) Register linked VM
if (Test-Path $templateVmx) {
  $vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
  if (-not $vmrun) {
    $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
  }
  & $vmrun -T ws register $templateVmx | Out-Null
}

# 6) Start VMREST
& (Join-Path $scriptRoot 'StartVMRestDaemon.ps1')

# 7) Wait for VMREST
$pair    = "$vmrestUser`:$vmrestPass"
$auth    = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$headers = @{ Authorization = "Basic $auth" }
for ($i=1; $i -le 10; $i++) {
  try {
    Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $headers -UseBasicParsing | Out-Null
    break
  } catch {
    Start-Sleep 3
  }
}

# 8) Select template VM
$vms      = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $headers
$template = $vms | Where-Object { $_.displayName -match 'Win2022' } | Select-Object -First 1
if (-not $template) { $template = $vms[0] }

# 9) Write terraform.tfvars
$vmPathEsc = $VmOutputPath -replace '\\','\\\\'
@"
vmrest_user     = "$vmrestUser"
vmrest_password = "$vmrestPass"
vault_image_id  = "$($template.id)"
app_image_id    = "$($template.id)"
vm_processors   = 2
vm_memory       = 2048
vm_path         = "$vmPathEsc"
"@ | Set-Content $tfvarsFile -Encoding ASCII

# 10) Terraform
Push-Location $scriptRoot
terraform init -upgrade
terraform apply -auto-approve -parallelism=1
Pop-Location

# 11) Power on VMs (optional)
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

Write-Host "All done!"
