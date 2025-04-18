<#
.SYNOPSIS
  Creates or updates terraform.rc in %APPDATA% to point Terraform to your local vmworkstation provider binary.

.DESCRIPTION
  This script:
    1. Locates the plugin executable (defaults to a subfolder named "terraform-provider-vmworkstation" under the script's directory).
    2. Converts its path to a forward-slash style (required by Terraform).
    3. Writes a terraform.rc file in %APPDATA% with a provider_installation block that uses the local binary.

.PARAMETER PluginDir
  Optional: path to the terraform-provider-vmworkstation folder. Defaults to $PSScriptRoot\terraform-provider-vmworkstation.

.EXAMPLE
  .\Create-TerraformRc.ps1
  Uses the provider folder next to this script.

.EXAMPLE
  .\Create-TerraformRc.ps1 -PluginDir "D:\Code\terraform-provider-vmworkstation"
  Uses that custom plugin directory.
#>

param(
    [string]$PluginDir = (Join-Path $PSScriptRoot 'terraform-provider-vmworkstation')
)

# Determine the path to the provider binary
$exeName = 'terraform-provider-vmworkstation.exe'
$exePath = Join-Path $PluginDir $exeName

if (-not (Test-Path $exePath)) {
    Write-Error "Provider binary not found at: $exePath"
    exit 1
}

# Convert backslashes to forward slashes for Terraform
$binaryPath = (Resolve-Path $exePath).Path -replace '\\','/'

# Determine %APPDATA% and terraform.rc path
$appData = $env:APPDATA
$rcFile  = Join-Path $appData 'terraform.rc'

# Build the terraform.rc content
$rcContent = @"
provider_installation {
  dev_overrides {
    "registry.terraform.io/elsudano/vmworkstation" = "$binaryPath"
  }
  direct {}
}
"@

# Write the terraform.rc
Write-Host "Writing terraform.rc to: $rcFile" -ForegroundColor Cyan
$rcContent | Set-Content -Path $rcFile -Encoding ASCII

Write-Host "Done. terraform.rc configured to use local vmworkstation provider." -ForegroundColor Green
