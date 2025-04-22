<#
.SYNOPSIS
  Configure Terraform to use your locally built vmworkstation provider and run Terraform end-to-end.

.DESCRIPTION
  * Writes a CLI config (terraform.rc) overriding "elsudano/vmworkstation" to a local plugin folder.
  * Sets TF_CLI_CONFIG_FILE for the current session.
  * Runs `terraform init -upgrade`, `terraform plan -out=tfplan`, and `terraform apply -auto-approve tfplan`.

.PARAMETER PluginDir
  Path to the folder containing terraform-provider-vmworkstation.exe. Defaults to a "terraform-provider-vmworkstation" subfolder of this script.

.PARAMETER WorkingDir
  Path to your Terraform project (where main.tf lives). Defaults to the current folder ($PSScriptRoot).

.EXAMPLE
  .\Create-TerraformRc.ps1
  Uses .\terraform-provider-vmworkstation and current folder as Terraform project.

.EXAMPLE
  .\Create-TerraformRc.ps1 -PluginDir "C:\Builds\vmworkstation" -WorkingDir "C:\terraform-vmware-test"
#>
param(
    [string]$PluginDir   = (Join-Path $PSScriptRoot 'terraform-provider-vmworkstation'),
    [string]$WorkingDir  = $PSScriptRoot
)

# Validate plugin executable
$exe = 'terraform-provider-vmworkstation.exe'
$exePath = Join-Path $PluginDir $exe
if (-not (Test-Path $exePath)) {
    Write-Error "Cannot find provider at: $exePath"; exit 1
}

# Build CLI config content
$dir = $PluginDir -replace '\\','/'
$rc = @"
provider_installation {
  dev_overrides {
    "registry.terraform.io/elsudano/vmworkstation" = "$dir"
  }
  direct {}
}
"@

# Write terraform.rc
$cliConfig = Join-Path $env:APPDATA 'terraform.rc'
Write-Host "Writing CLI config to: $cliConfig" -ForegroundColor Cyan
$rc | Set-Content -Path $cliConfig -Encoding ASCII

# Export for this session
$env:TF_CLI_CONFIG_FILE = $cliConfig
Write-Host "Set TF_CLI_CONFIG_FILE to $cliConfig" -ForegroundColor Green

# Change to Terraform project
Write-Host "`nSwitching to Terraform working dir: $WorkingDir" -ForegroundColor Cyan
Push-Location $WorkingDir

# Initialize
Write-Host "`n==> terraform init -upgrade" -ForegroundColor Cyan
terraform init -upgrade

# Plan
Write-Host "`n==> terraform plan -out=tfplan" -ForegroundColor Cyan
terraform plan -out=tfplan

# Apply
Write-Host "`n==> terraform apply -auto-approve tfplan" -ForegroundColor Cyan
terraform apply -auto-approve tfplan

# Return
Pop-Location
Write-Host "`nAll done!" -ForegroundColor Green
