<#
  Create-Servers.ps1
  --------------------------------------
  1) Builds a GUI Win2022 VM with Packer (using win2022-gui.json).
  2) Starts and health-checks the VMware REST API.
  3) Runs Terraform to deploy Vault, PVWA, PSM, CPM.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$IsoPath,

    [Parameter(Mandatory)]
    [string]$VmOutputPath
)

$ErrorActionPreference = 'Stop'

# Resolve paths
$scriptRoot     = Split-Path -Parent $MyInvocation.MyCommand.Definition
$packerDir      = Join-Path $scriptRoot 'packer-Win2022'
$packerTpl      = Join-Path $packerDir    'win2022-gui.json'
$packerBin      = Join-Path $scriptRoot   'packer-bin'
$packerExe      = Join-Path $packerBin    'packer.exe'
$outputDir      = Join-Path $packerDir    'output-vmware-iso'
$tfvarsFile     = Join-Path $scriptRoot   'terraform.tfvars'
$vmrestCredUser = 'vmrest'
$vmrestCredPass = 'Cyberark1'

# 1) Validate ISO
if (-not (Test-Path $IsoPath)) {
    Write-Error "ISO not found at: $IsoPath"; exit 1
}
$isoUrl      = "file:///$($IsoPath.Replace('\','/'))"
$isoHash     = (Get-FileHash -Algorithm SHA256 -Path $IsoPath).Hash
$isoChecksum = "sha256:$isoHash"
Write-Host "ISO validated. Checksum: $isoChecksum"

# 2) Validate Packer template
if (-not (Test-Path $packerTpl)) {
    Write-Error "Cannot find Packer template at: $packerTpl"; exit 1
}

# 3) Install Packer v1.11.2 if needed
if (-not (Test-Path $packerExe)) {
    Write-Host '==> Installing Packer v1.11.2…' -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $packerBin -Force | Out-Null
    $zip = Join-Path $packerBin 'packer.zip'
    Invoke-WebRequest `
      -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' `
      -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $packerBin -Force
    Remove-Item $zip
}
$env:PATH = "$packerBin;$env:PATH"

# 4) Clean previous output
if (Test-Path $outputDir) {
    Write-Host '==> Removing old Packer output…' -ForegroundColor Yellow
    Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item -Recurse -Force $outputDir
}

# 5) Run Packer build (inside packer-Win2022)
Write-Host '==> Building Win2022 GUI image with Packer…' -ForegroundColor Cyan
Push-Location $packerDir
& $packerExe build `
    -var "iso_url=$isoUrl" `
    -var "iso_checksum=$isoChecksum" `
    "win2022-gui.json"
if ($LASTEXITCODE -ne 0) {
    Write-Error '❌ Packer build failed.'; Pop-Location; exit 1
}
Pop-Location
Write-Host '✅ Packer build complete.' -ForegroundColor Green

# 6) Start VMREST daemon
Write-Host '==> Starting VMREST daemon…' -ForegroundColor Cyan
& (Join-Path $scriptRoot 'StartVMRestDaemon.ps1')

# 7) Health-check VMREST API
$securePass = ConvertTo-SecureString $vmrestCredPass -AsPlainText -Force
$cred = New-Object PSCredential($vmrestCredUser, $securePass)
Write-Host '==> Checking VMREST API…' -NoNewline
for ($i = 1; $i -le 10; $i++) {
    try {
        Invoke-RestMethod `
          -Uri 'http://127.0.0.1:8697/api/vms' `
          -Credential $cred `
          -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-Host ' OK' -ForegroundColor Green
        break
    } catch {
        Write-Host -NoNewline '.'; Start-Sleep -Seconds 3
    }
}
if ($LASTEXITCODE -ne 0) {
    Write-Error '❌ VMREST API did not respond.'; exit 1
}

# 8) Write terraform.tfvars with literal values
Write-Host '==> Writing terraform.tfvars…' -ForegroundColor Cyan
$escapedVmPath = $VmOutputPath -replace '\\','\\\\'
@"
vmrest_user     = "$vmrestCredUser"
vmrest_password = "$vmrestCredPass"
vault_image_id  = "Win2022_GUI"
app_image_id    = "Win2022_GUI"
vm_processors   = 2
vm_memory       = 2048
vm_path         = "$escapedVmPath"
"@ | Set-Content $tfvarsFile -Encoding ASCII

# 9) Terraform init & apply
Write-Host '==> Running Terraform init & apply…' -ForegroundColor Cyan
Push-Location $scriptRoot
terraform init -upgrade
terraform apply -auto-approve -parallelism=1
Pop-Location
Write-Host '✅ Terraform apply complete.' -ForegroundColor Green
