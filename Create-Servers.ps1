<#
  Create-Servers.ps1
  -------------------
  Automated CyberArk lab using eaksel/packer-Win2022 templates:
    1) Clone/update packer-Win2022
    2) Ensure Packer installed locally (v1.11.2)
    3) Prompt for and download/use Windows Server 2022 Eval ISO
    4) Copy official autounattend.xml for GUI/Core UEFI builds
    5) Install VMware Packer plugin
    6) Inject WinRM provisioner into Packer JSON via PowerShell objects
    7) Build VM image via Packer (Workstation)
    8) Post-build provisioning with vmrest & Terraform
#>

[CmdletBinding()]
param(
  [ValidateSet('gui','core')]
  [string]$GuiOrCore = 'gui',    # 'gui' or 'core'
  [string]$IsoUrl,
  [string]$IsoPath
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# 1) Clone or update packer-Win2022 templates
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Error 'Git required.'; exit 1 }
$packerDir = Join-Path $scriptRoot 'packer-Win2022'
if (Test-Path $packerDir) { Push-Location $packerDir; git pull; Pop-Location } else { git clone https://github.com/eaksel/packer-Win2022.git $packerDir }

# 2) Ensure Packer is installed locally
$packerBin = Join-Path $scriptRoot 'packer-bin'; $packerExe = Join-Path $packerBin 'packer.exe'
if (-not (Test-Path $packerExe)) {
  New-Item -Path $packerBin -ItemType Directory -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' -OutFile $zip -UseBasicParsing
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force; Remove-Item $zip
}
# Add Packer to PATH for this session
timeout 1; $env:PATH = "$packerBin;$env:PATH"

# 3) Prompt for ISO path/URL if missing
if (-not $IsoPath) { $IsoPath = Read-Host 'Enter local path for Windows Server 2022 Eval ISO' }
if (-not (Test-Path $IsoPath)) {
  if (-not $IsoUrl) { $IsoUrl = Read-Host 'Enter download URL for Windows Server 2022 Eval ISO' }
  Invoke-WebRequest -Uri $IsoUrl -OutFile $IsoPath -UseBasicParsing
}
$checksum = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
$isoUrlVar = "file:///$($IsoPath.Replace('\','/'))"; $isoChecksumVar = "sha256:$checksum"

# 4) Copy autounattend.xml
tmp $src = Join-Path $packerDir "scripts\uefi\$GuiOrCore\autounattend.xml"; $dest = Join-Path $scriptRoot 'Autounattend.xml'
Copy-Item -Path $src -Destination $dest -Force

# 5) Install VMware plugin for Packer
Push-Location $packerDir
& $packerExe plugins install github.com/hashicorp/vmware | Write-Host

# 6) Inject WinRM provisioner into Packer JSON
$jsonPath = Join-Path $packerDir "win2022-$GuiOrCore.json"
$packerObj = Get-Content $jsonPath -Raw | ConvertFrom-Json -Depth 10
# Define WinRM provisioner
$winrmProv = [PSCustomObject]@{
  type   = 'powershell'
  inline = @(
    'winrm quickconfig -q',
    'winrm set winrm/config/service/auth @{Basic="true"}',
    'winrm set winrm/config/service @{AllowUnencrypted="true"}',
    'netsh advfirewall firewall add rule name="WinRM HTTP" protocol=TCP dir=in localport=5985 action=allow'
  )
}
# Prepend provisioner
if ($null -eq $packerObj.provisioners) { $packerObj | Add-Member -MemberType NoteProperty -Name provisioners -Value @() }
$packerObj.provisioners = @($winrmProv) + $packerObj.provisioners
# Write back JSON
$packerObj | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding ASCII

# 7) Build VM image via Packer
Write-Host "Building win2022-$GuiOrCore.json with WinRM provisioner..." -ForegroundColor Cyan
& $packerExe build -only=vmware-iso -var "iso_url=$isoUrlVar" -var "iso_checksum=$isoChecksumVar" "win2022-$GuiOrCore.json"
Pop-Location

# 8) Start VMware REST API daemon
$vmrestExe = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
Stop-Process -Name vmrest -ErrorAction SilentlyContinue
Start-Process -FilePath $vmrestExe -ArgumentList '-b' -WindowStyle Hidden
Start-Sleep -Seconds 5

# 9) Terraform
Push-Location (Join-Path $scriptRoot 'terraform')
terraform init -upgrade; terraform plan -out=tfplan; terraform apply -auto-approve tfplan
Pop-Location

Write-Host '🎉 Deployment complete!' -ForegroundColor Green
