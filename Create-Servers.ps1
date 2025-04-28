<#
  Create-Servers.ps1
  -------------------
  Automated CyberArk lab using eaksel/packer-Win2022 templates:
    1) Clone/update packer-Win2022
    2) Ensure Packer installed locally (v1.11.2)
    3) Prompt for local Windows Server 2022 Eval ISO path
    4) Copy official autounattend.xml for GUI/Core UEFI builds
    5) Install VMware & windows-update Packer plugins
    6) Configure WinRM, disable built-in Windows Update, inject windows-update plugin
    7) Clean previous Packer output and build VM image via Packer
    8) Post-build provisioning: vmrest & Terraform
#>

[CmdletBinding()]
param(
  [ValidateSet('gui','core')]
  [string]$GuiOrCore = 'gui',    # 'gui' or 'core'
  [Parameter(Mandatory)]
  [string]$IsoPath               # Local path to the WS2022 Eval ISO
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# 1) Clone/update packer-Win2022 templates\if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Error 'Git required.'; exit 1 }
$packerDir = Join-Path $scriptRoot 'packer-Win2022'
if (Test-Path $packerDir) {
  Write-Host 'Updating packer-Win2022 templates...' -ForegroundColor Cyan
  Push-Location $packerDir; git pull; Pop-Location
} else {
  Write-Host 'Cloning packer-Win2022 templates...' -ForegroundColor Cyan
  git clone https://github.com/eaksel/packer-Win2022.git $packerDir
}

# 2) Ensure Packer v1.11.2 installed locally
$packerBin = Join-Path $scriptRoot 'packer-bin'
$packerExe = Join-Path $packerBin 'packer.exe'
if (-not (Test-Path $packerExe)) {
  Write-Host 'Downloading Packer v1.11.2...' -ForegroundColor Cyan
  New-Item -Path $packerBin -ItemType Directory -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force
  Remove-Item $zip
  Write-Host "-> Packer installed at $packerExe" -ForegroundColor Green
}
$env:PATH = "$packerBin;$env:PATH"

# 3) Validate local ISO path
if (-not (Test-Path $IsoPath)) { Write-Error "ISO not found at path: $IsoPath"; exit 1 }
$checksum       = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
$isoUrlVar      = "file:///$($IsoPath.Replace('\','/'))"
$isoChecksumVar = "sha256:$checksum"

# 4) Copy autounattend.xml
$src  = Join-Path $packerDir "scripts\uefi\$GuiOrCore\autounattend.xml"
$dest = Join-Path $scriptRoot 'Autounattend.xml'
if (-not (Test-Path $src)) { Write-Error "Template not found: $src"; exit 1 }
Copy-Item -Path $src -Destination $dest -Force
Write-Host "Copied autounattend.xml for '$GuiOrCore' build to $dest" -ForegroundColor Green

# 5) Install Packer plugins (VMware + windows-update)
Push-Location $packerDir
Write-Host 'Installing VMware Packer plugin...' -ForegroundColor Cyan
& $packerExe plugins install github.com/hashicorp/vmware | Out-Null

Write-Host 'Installing windows-update Packer plugin...' -ForegroundColor Cyan
& $packerExe plugins install rgl/windows-update | Out-Null
Pop-Location

# 6) Configure WinRM, disable built-in Windows Update, inject windows-update plugin
$jsonPath  = Join-Path $packerDir "win2022-$GuiOrCore.json"
$packerObj = Get-Content $jsonPath -Raw | ConvertFrom-Json

# Define WinRM connectivity block
$winrmProv = [PSCustomObject]@{
  type   = 'powershell'
  inline = @(
    'winrm quickconfig -q',
    'winrm set winrm/config/service/auth @{Basic=''true''}',
    'winrm set winrm/config/service @{AllowUnencrypted=''true''}',
    'netsh advfirewall firewall add rule name=''WinRM HTTP'' protocol=TCP dir=in localport=5985 action=allow'
  )
}

# Disable Windows Update service to prevent hanging install
$disableWUProv = [PSCustomObject]@{
  type   = 'powershell'
  inline = @(
    'Stop-Service wuauserv -Force',
    'Set-Service wuauserv -StartupType Disabled'
  )
}

# Define windows-update plugin provisioner
$winUpdProv = [PSCustomObject]@{
  type            = 'windows-update'
  search_criteria = 'IsInstalled=0'
  filters         = @('exclude:$_.Title -like ''*Preview*''')
  update_limit    = 25
}

# Original provisioners
$origProv = $packerObj.provisioners
if (-not $origProv) { $origProv = @() }

# Build new provisioner list: start with WinRM and disableWU block
$newProv = @($winrmProv, $disableWUProv)
$skipRestart = $false
foreach ($prov in $origProv) {
  if ($prov.type -eq 'powershell' -and $prov.scripts -contains 'scripts/win-update.ps1') {
    $skipRestart = $true; continue
  } elseif ($prov.type -eq 'windows-restart' -and $skipRestart) {
    $skipRestart = $false; continue
  } else {
    $newProv += $prov
  }
}

# Insert windows-update plugin before cleanup if present, else append
if ($newProv.Count -gt 0 -and $newProv[-1].type -eq 'powershell' -and $newProv[-1].scripts -contains 'scripts/cleanup.ps1') {
  $cleanupProv = $newProv[-1]
  $newProv = $newProv[0..($newProv.Count-2)]
  $newProv += $winUpdProv
  $newProv += $cleanupProv
} else {
  $newProv += $winUpdProv
}

# Assign back and write JSON
$packerObj.provisioners = $newProv
$packerObj | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding ASCII
Write-Host 'Updated JSON to use windows-update plugin.' -ForegroundColor Green

# 7) Clean previous output and build VM
$outputDir = Join-Path $packerDir 'output-vmware-iso'
if (Test-Path $outputDir) {
  Write-Host "Force removing existing output directory: $outputDir" -ForegroundColor Yellow
  Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $outputDir
  cmd /c "rd /s /q `"$outputDir`""
}

# Switch into Packer template directory for build
Push-Location $packerDir
Write-Host "Building win2022-$GuiOrCore.json with windows-update plugin..." -ForegroundColor Cyan
& $packerExe build -only=vmware-iso -var "iso_url=$isoUrlVar" -var "iso_checksum=$isoChecksumVar" "win2022-$GuiOrCore.json"
if ($LASTEXITCODE -ne 0) {
  Write-Error 'Packer build failed.'
  Pop-Location
  exit 1
}
Write-Host 'Packer build completed successfully.' -ForegroundColor Green
Pop-Location

# 8) Start VMware REST API daemon & Terraform
Write-Host 'Starting VMware REST API daemon...' -ForegroundColor Yellow
Stop-Process -Name vmrest -ErrorAction SilentlyContinue
Start-Process -FilePath 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe' -ArgumentList '-b' -WindowStyle Hidden
Start-Sleep -Seconds 5

Push-Location (Join-Path $scriptRoot 'terraform')
Write-Host 'Initializing Terraform...' -ForegroundColor Cyan
terraform init -upgrade | Write-Host
Write-Host 'Planning Terraform deployment...' -ForegroundColor Cyan
terraform plan -out=tfplan | Write-Host
Write-Host 'Applying Terraform deployment...' -ForegroundColor Cyan
terraform apply -auto-approve tfplan | Write-Host
Pop-Location

Write-Host '🎉 Deployment complete!' -ForegroundColor Green
