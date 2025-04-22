<#
.SYNOPSIS
  Creates or updates terraform.rc in %APPDATA% to point Terraform to your local vmworkstation provider plugin folder.

.DESCRIPTION
  This script:
    1. Locates the provider executable (defaults to a subfolder 'terraform-provider-vmworkstation' under the script's directory).
    2. Determines its parent folder as the plugin directory.
    3. Writes a terraform.rc file in %APPDATA% that uses dev_overrides to direct Terraform to load the plugin from that folder.

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

# Locate the provider executable
$exeName = 'terraform-provider-vmworkstation.exe'
$exePath = Join-Path $PluginDir $exeName
if (-not (Test-Path $exePath)) {
    Write-Error "Provider binary not found at: $exePath"
    exit 1
}

# Use its parent folder as the override directory
$pluginDir = Split-Path -Parent (Resolve-Path $exePath).Path
# Convert to forward slashes for Terraform
$dirPath = $pluginDir -replace '\\','/'

# Determine terraform.rc path
$appData = $env:APPDATA
$rcFile  = Join-Path $appData 'terraform.rc'

# Generate terraform.rc content
$rcContent = @"
provider_installation {
  dev_overrides {
    "registry.terraform.io/elsudano/vmworkstation" = "$dirPath"
  }
  direct {}
}
"@

# Write the file
Write-Host "Writing terraform.rc to: $rcFile" -ForegroundColor Cyan
$rcContent | Set-Content -Path $rcFile -Encoding ASCII

Write-Host "Done. terraform.rc now overrides vmworkstation provider to load from:$dirPath" -ForegroundColor Green
