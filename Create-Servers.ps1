<#
  Create-Servers.ps1
  -------------------
  Builds a minimal Windows Server 2022 image via Packer (only WinRM enabled).
#>

[CmdletBinding()]
param(
  [ValidateSet('gui','core')]
  [string]$GuiOrCore = 'gui',
  [Parameter(Mandatory)]
  [string]$IsoPath
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# 1️⃣ Clone or update packer-Win2022 templates
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Error 'Git is required.'; exit 1
}
$packerDir = Join-Path $scriptRoot 'packer-Win2022'
if (Test-Path $packerDir) {
  Write-Host 'Updating packer-Win2022…' -ForegroundColor Cyan
  Push-Location $packerDir; git pull; Pop-Location
} else {
  Write-Host 'Cloning packer-Win2022…' -ForegroundColor Cyan
  git clone https://github.com/eaksel/packer-Win2022.git $packerDir
}

# 2️⃣ Ensure Packer v1.11.2 is installed locally
$packerBin = Join-Path $scriptRoot 'packer-bin'
$packerExe = Join-Path $packerBin 'packer.exe'
if (-not (Test-Path $packerExe)) {
  Write-Host 'Downloading Packer v1.11.2…' -ForegroundColor Cyan
  New-Item -Path $packerBin -ItemType Directory -Force | Out-Null
  $zip = Join-Path $packerBin 'packer.zip'
  Invoke-WebRequest `
    -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' `
    -OutFile $zip -UseBasicParsing
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force
  Remove-Item $zip
}
$env:PATH = "$packerBin;$env:PATH"

# 3️⃣ Validate ISO path
if (-not (Test-Path $IsoPath)) {
  Write-Error "ISO not found at path: $IsoPath"; exit 1
}
$checksum       = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
$isoUrlVar      = "file:///$($IsoPath.Replace('\','/'))"
$isoChecksumVar = "sha256:$checksum"

# 4️⃣ Copy the matching autounattend.xml
$src  = Join-Path $packerDir "scripts\uefi\$GuiOrCore\autounattend.xml"
$dest = Join-Path $scriptRoot 'Autounattend.xml'
if (-not (Test-Path $src)) {
  Write-Error "autounattend.xml not found for '$GuiOrCore'."; exit 1
}
Copy-Item -Path $src -Destination $dest -Force
Write-Host "Copied autounattend.xml for '$GuiOrCore'." -ForegroundColor Green

# 5️⃣ Install VMware plugin for Packer
Push-Location $packerDir
Write-Host 'Installing VMware Packer plugin…' -ForegroundColor Cyan
& $packerExe plugins install github.com/hashicorp/vmware | Out-Null
Pop-Location

# 6️⃣ Strip out all other provisioners, inject only WinRM
$jsonPath  = Join-Path $packerDir "win2022-$GuiOrCore.json"
$packerObj = Get-Content $jsonPath -Raw | ConvertFrom-Json

$winrmProv = [PSCustomObject]@{
  type   = 'powershell'
  inline = @(
    'Enable-PSRemoting -Force',
    'Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $true',
    'Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true',
    'if (-not (Get-NetFirewallRule -Name "WINRM-HTTP-In" -ErrorAction SilentlyContinue)) {',
    '  New-NetFirewallRule -Name "WINRM-HTTP-In" -DisplayName "WinRM HTTP-In" -Protocol TCP -LocalPort 5985 -Action Allow',
    '}'
  )
}

# Replace all provisioners with just our WinRM block
$packerObj.provisioners = @($winrmProv)

# Write back the JSON
$packerObj |
  ConvertTo-Json -Depth 10 |
  Set-Content -Path $jsonPath -Encoding ASCII
Write-Host 'Kept only WinRM provisioner; removed all others.' -ForegroundColor Green

# 7️⃣ Clean previous output & build the VM image
$outputDir = Join-Path $packerDir 'output-vmware-iso'
if (Test-Path $outputDir) {
  Write-Host 'Removing prior build output…' -ForegroundColor Yellow
  Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $outputDir
  cmd /c "rd /s /q `"$outputDir`""
}

Push-Location $packerDir
Write-Host "Building win2022-$GuiOrCore.json…" -ForegroundColor Cyan
& $packerExe build `
   -only=vmware-iso `
   -var "iso_url=$isoUrlVar" `
   -var "iso_checksum=$isoChecksumVar" `
   "win2022-$GuiOrCore.json"
if ($LASTEXITCODE -ne 0) {
  Write-Error 'Packer build failed.'; Pop-Location; exit 1
}
Write-Host 'Packer build completed successfully.' -ForegroundColor Green
Pop-Location

# 8️⃣ Start VMware REST API daemon
Write-Host 'Starting VMware REST API daemon…' -ForegroundColor Cyan
$vmrestExe = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
Stop-Process -Name vmrest -ErrorAction SilentlyContinue
Start-Process -FilePath $vmrestExe -ArgumentList '-b' -WindowStyle Hidden
Start-Sleep -Seconds 5

# 9️⃣ Terraform (if you still need it)
Push-Location (Join-Path $scriptRoot 'terraform')
Write-Host 'Initializing Terraform…' -ForegroundColor Cyan
terraform init -upgrade | Out-Null
Write-Host 'Planning Terraform…' -ForegroundColor Cyan
terraform plan -out=tfplan | Out-Null
Write-Host 'Applying Terraform…' -ForegroundColor Cyan
terraform apply -auto-approve tfplan | Out-Null
Pop-Location

Write-Host '✅ Minimal image ready! You now have a WinRM-enabled Server 2022 VM.' -ForegroundColor Green
