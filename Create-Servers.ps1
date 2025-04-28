<#
  Create-Servers.ps1
  -------------------
  Automated CyberArk lab using eaksel/packer-Win2022 templates,
  but **removing all Windows Update steps** so the build won't hang.
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

# 1) Clone or update packer-Win2022 templates
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Error 'Git required.'; exit 1
}
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
  Invoke-WebRequest `
    -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' `
    -OutFile $zip -UseBasicParsing
  Expand-Archive -Path $zip -DestinationPath $packerBin -Force
  Remove-Item $zip
  Write-Host "-> Packer installed at $packerExe" -ForegroundColor Green
}
$env:PATH = "$packerBin;$env:PATH"

# 3) Validate local ISO path
if (-not (Test-Path $IsoPath)) {
  Write-Error "ISO not found at path: $IsoPath"; exit 1
}
$checksum       = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
$isoUrlVar      = "file:///$($IsoPath.Replace('\','/'))"
$isoChecksumVar = "sha256:$checksum"

# 4) Copy autounattend.xml
$src  = Join-Path $packerDir "scripts\uefi\$GuiOrCore\autounattend.xml"
$dest = Join-Path $scriptRoot 'Autounattend.xml'
if (-not (Test-Path $src)) {
  Write-Error "Template not found: $src"; exit 1
}
Copy-Item -Path $src -Destination $dest -Force
Write-Host "Copied autounattend.xml for '$GuiOrCore' build to $dest" -ForegroundColor Green

# 5) Install VMware plugin for Packer
Push-Location $packerDir
Write-Host 'Installing VMware Packer plugin...' -ForegroundColor Cyan
& $packerExe plugins install github.com/hashicorp/vmware | Write-Host

# 6) Inject only WinRM provisioner into Packer JSON, drop all update+cleanup steps
$jsonPath  = Join-Path $packerDir "win2022-$GuiOrCore.json"
$packerObj = Get-Content $jsonPath -Raw | ConvertFrom-Json

# Define our WinRM inline provisioner
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

# Filter out any provisioners that:
#  • run win-update.ps1
#  • run cleanup.ps1
#  • or are the windows-restart immediately following a win-update or cleanup
$orig = $packerObj.provisioners
$new  = @()
for ($i = 0; $i -lt $orig.Count; $i++) {
  $p = $orig[$i]
  $isUpdateOrCleanup = $p.scripts -and (
    $p.scripts -contains 'scripts/win-update.ps1' -or
    $p.scripts -contains 'scripts/cleanup.ps1'
  )
  if ($isUpdateOrCleanup) {
    # skip p, and if next is a restart, skip that too
    if ($i+1 -lt $orig.Count -and $orig[$i+1].type -eq 'windows-restart') {
      $i++
    }
    continue
  }
  $new += $p
}

# Put WinRM first, then everything else
$packerObj.provisioners = @($winrmProv) + $new

# Write it back
$packerObj | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding ASCII
Write-Host 'Injected WinRM only; removed all win-update & cleanup steps.' -ForegroundColor Green


# 7) Clean previous output and build via Packer
$outputDir = Join-Path $packerDir 'output-vmware-iso'
if (Test-Path $outputDir) {
  Write-Host "Removing existing output directory..." -ForegroundColor Yellow
  Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $outputDir
  cmd /c "rd /s /q `"$outputDir`""
}

Push-Location $packerDir
Write-Host "Building win2022-$GuiOrCore.json..." -ForegroundColor Cyan
& $packerExe build `
  -only=vmware-iso `
  -var "iso_url=$isoUrlVar" `
  -var "iso_checksum=$isoChecksumVar" `
  "win2022-$GuiOrCore.json"
if ($LASTEXITCODE -ne 0) {
  Write-Error 'Packer build failed.'; Pop-Location; exit 1
}
Write-Host 'Packer build succeeded.' -ForegroundColor Green
Pop-Location

# 8) Start VMware REST API daemon
Write-Host 'Starting VMware REST API daemon...' -ForegroundColor Yellow
$vmrestExe = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
Stop-Process -Name vmrest -ErrorAction SilentlyContinue
Start-Process -FilePath $vmrestExe -ArgumentList '-b' -WindowStyle Hidden
Start-Sleep -Seconds 5

# 9) Run Terraform
Push-Location (Join-Path $scriptRoot 'terraform')
Write-Host 'Initializing Terraform...' -ForegroundColor Cyan
terraform init -upgrade | Write-Host
Write-Host 'Planning Terraform deployment...' -ForegroundColor Cyan
terraform plan -out=tfplan | Write-Host
Write-Host 'Applying Terraform deployment...' -ForegroundColor Cyan
terraform apply -auto-approve tfplan | Write-Host
Pop-Location

Write-Host '🎉 Deployment complete!' -ForegroundColor Green
