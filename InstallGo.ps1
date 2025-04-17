<#
.SYNOPSIS
  Installs Go, configures GOPATH, and updates PATH.

.DESCRIPTION
  1. Downloads Go MSI for the specified version.
  2. Installs Go silently to the default location (C:\Program Files\Go).
  3. Sets GOPATH to %USERPROFILE%\go (or a custom path).
  4. Adds %GOROOT%\bin and %GOPATH%\bin to the user PATH if needed.
  5. Verifies the installation by printing `go version`.

.PARAMETER Version
  The Go version to install (e.g. "1.20.5").

.PARAMETER Gopath
  Optional: the GOPATH to set. Defaults to "%USERPROFILE%\go".

.EXAMPLE
  .\install-go.ps1 -Version "1.20.5"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$Gopath = "$env:USERPROFILE\go"
)

# 1. Download Go MSI
$msiName = "go$Version.windows-amd64.msi"
$downloadUrl = "https://go.dev/dl/$msiName"
$msiPath = Join-Path $env:TEMP $msiName

Write-Host "Downloading Go $Version..."
Invoke-WebRequest -Uri $downloadUrl -OutFile $msiPath

# 2. Install Go silently
Write-Host "Installing Go to default location..."
Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait

# Clean up MSI
Remove-Item $msiPath -Force

# 3. Configure GOPATH
Write-Host "Setting GOPATH to $Gopath"
[Environment]::SetEnvironmentVariable("GOPATH", $Gopath, "User")

# 4. Update User PATH
$userPath = [Environment]::GetEnvironmentVariable("Path", "User").Split(";") | Where-Object { $_ -ne "" }

# Paths to add
$goRootBin = "C:\Program Files\Go\bin"
$goPathBin = Join-Path $Gopath "bin"

foreach ($p in @($goRootBin, $goPathBin)) {
    if ($userPath -notcontains $p) {
        Write-Host "Adding $p to User PATH"
        $userPath += $p
    }
}

$newPath = $userPath -join ";"
[Environment]::SetEnvironmentVariable("Path", $newPath, "User")

# 5. Refresh current session environment and verify
$env:GOPATH = $Gopath
$env:PATH = $newPath

Write-Host "`nInstallation complete. Verifying Go version..."
go version

Write-Host "`nGo has been installed and configured."
Write-Host "• GOPATH = $Gopath"
Write-Host "• GOROOT = C:\Program Files\Go"
Write-Host "`nPlease restart any open terminals to pick up the updated PATH."
