<#
  Create-Servers.ps1
  --------------------------------------
  1) Builds a Win2022 GUI VM with Packer.
  2) Registers the template with VMREST.
  3) Starts & health-checks VMREST.
  4) Discovers the template’s VM ID via the REST API.
  5) Writes terraform.tfvars with that GUID.
  6) Runs Terraform to deploy Vault, PVWA, PSM, CPM.
  7) (Optional) Launches the resulting VMs in Workstation GUI.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$IsoPath,
  [Parameter(Mandatory)] [string]$VmOutputPath
)

$ErrorActionPreference = 'Stop'

# Paths & creds
$scriptRoot   = Split-Path $MyInvocation.MyCommand.Definition -Parent
$packerDir    = Join-Path $scriptRoot 'packer-Win2022'
$packerTpl    = Join-Path $packerDir 'win2022-gui.json'
$packerBin    = Join-Path $scriptRoot 'packer-bin'
$packerExe    = Join-Path $packerBin 'packer.exe'
$outputDir    = Join-Path $packerDir 'output-vmware-iso'
$templateVmx  = Join-Path $outputDir 'Win2022_GUI.vmx'
$tfvarsFile   = Join-Path $scriptRoot 'terraform.tfvars'
$vmrestUser   = 'vmrest'
$vmrestPass   = 'Cyberark1'

# 1) Validate ISO
if (-not (Test-Path $IsoPath)) {
  Write-Error "ISO not found: $IsoPath"; exit 1
}
$isoUrl      = "file:///$($IsoPath.Replace('\','/'))"
$isoChecksum = "sha256:$((Get-FileHash $IsoPath -Algorithm SHA256).Hash)"
Write-Host "ISO checksum: $isoChecksum"

# 2) Ensure Packer binary
if (-not (Test-Path $packerExe)) {
  Write-Host 'Installing Packer v1.11.2…' -ForegroundColor Cyan
  New-Item -ItemType Directory -Path $packerBin -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' -OutFile $zip
  Expand-Archive $zip -DestinationPath $packerBin -Force
  Remove-Item $zip
}
$env:PATH = "$packerBin;$env:PATH"

# 3) Clean old build
if (Test-Path $outputDir) {
  Write-Host 'Cleaning old Packer output…' -ForegroundColor Yellow
  Get-Process vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-Item $outputDir -Recurse -Force
}

# 4) Build the golden image
Write-Host 'Running Packer build…' -ForegroundColor Cyan
Push-Location $packerDir
& $packerExe build -var "iso_url=$isoUrl" -var "iso_checksum=$isoChecksum" win2022-gui.json
if ($LASTEXITCODE -ne 0) { Write-Error 'Packer failed'; Pop-Location; exit 1 }
Pop-Location
Write-Host '✅ Packer build complete.' -ForegroundColor Green

# 5) Register VM template with VMREST
if (Test-Path $templateVmx) {
  Write-Host 'Registering template with VMREST…' -ForegroundColor Cyan
  # find vmrun.exe
  $vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
  if (-not $vmrun) { $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' }
  & $vmrun -T ws register $templateVmx 2>$null
  Write-Host '✅ Template registered.' -ForegroundColor Green
}

# 6) Start VMREST
Write-Host 'Starting VMREST…' -ForegroundColor Cyan
& (Join-Path $scriptRoot 'StartVMRestDaemon.ps1')

# 7) Wait for VMREST to respond
$secure = ConvertTo-SecureString $vmrestPass -AsPlainText -Force
$cred   = New-Object System.Management.Automation.PSCredential($vmrestUser,$secure)
Write-Host 'Waiting for VMREST API…' -NoNewline
for ($i=0; $i -lt 10; $i++) {
  try {
    Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Credential $cred -ErrorAction Stop | Out-Null
    Write-Host ' OK' -ForegroundColor Green
    break
  } catch { Write-Host -NoNewline '.'; Start-Sleep 3 }
}
if ($LASTEXITCODE -ne 0) { Write-Error 'VMREST not responding'; exit 1 }

# 8) Discover template VM ID
Write-Host 'Querying VMREST for template ID…' -ForegroundColor Cyan
$vms = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Credential $cred
$template = $vms | Where-Object { $_.displayName -eq 'Win2022_GUI' }
if (-not $template) { Write-Error 'Template VM not found in API'; exit 1 }
$templateId = $template.id
Write-Host "Template VM ID: $templateId" -ForegroundColor Green

# 9) Write terraform.tfvars with real GUID
Write-Host 'Writing terraform.tfvars…' -ForegroundColor Cyan
$pathEsc = $VmOutputPath -replace '\\','\\\\'
@"
vmrest_user     = "$vmrestUser"
vmrest_password = "$vmrestPass"
vault_image_id  = "$templateId"
app_image_id    = "$templateId"
vm_processors   = 2
vm_memory       = 2048
vm_path         = "$pathEsc"
"@ | Set-Content $tfvarsFile -Encoding ASCII

# 10) Terraform apply
Write-Host 'Running Terraform apply…' -ForegroundColor Cyan
Push-Location $scriptRoot
terraform init -upgrade
terraform apply -auto-approve -parallelism=1
Pop-Location
Write-Host '✅ Terraform apply complete.' -ForegroundColor Green

# 11) Launch VMs in GUI (optional)
Write-Host 'Launching VMs in VMware Workstation…' -ForegroundColor Cyan
$vmNames = 'Vault-VM','PVWA-VM','PSM-VM','CPM-VM'
foreach ($n in $vmNames) {
  $vmx = Join-Path $VmOutputPath "$n\$n.vmx"
  if (Test-Path $vmx) { & $vmrun -T ws start $vmx } else { Write-Warning "Missing $vmx" }
}

Write-Host "`nAll done!" -ForegroundColor Green
