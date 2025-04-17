<#
.SYNOPSIS
  Installs Go, configures GOPATH, updates PATH, and refreshes environment in one shot.

.PARAMETER Version
  The Go version to install (e.g. "1.20.5").

.PARAMETER Gopath
  Optional: the GOPATH to set. Defaults to "$env:USERPROFILE\go".
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Version,

    [string]$Gopath = "$env:USERPROFILE\go"
)

function Test-IsAdmin {
    $current = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Self‑elevate if not running as admin
if (-not (Test-IsAdmin)) {
    Write-Host "Not running as Administrator. Relaunching elevated..."
    Start-Process -FilePath pwsh -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"","-Version",$Version,"-Gopath","`"$Gopath`"" -Verb RunAs
    exit
}

# 1) Download MSI
$msiName = "go$Version.windows-amd64.msi"
$downloadUrl = "https://go.dev/dl/$msiName"
$msiPath    = Join-Path $env:TEMP $msiName

Write-Host "Downloading Go $Version from $downloadUrl..."
Invoke-RestMethod -Uri $downloadUrl -OutFile $msiPath -UseBasicParsing

# 2) Silent install
Write-Host "Installing Go silently..."
Start-Process msiexec.exe -ArgumentList "/i","`"$msiPath`"","/qn","/norestart" -Wait

# Clean up
Remove-Item $msiPath -Force

# 3) Set GOPATH
Write-Host "Setting user environment variable GOPATH = $Gopath"
[Environment]::SetEnvironmentVariable("GOPATH", $Gopath, "User")

# 4) Update User PATH
$envPaths = [Environment]::GetEnvironmentVariable("Path","User").Split(";",[StringSplitOptions]::RemoveEmptyEntries)
$goBins   = @("C:\Program Files\Go\bin", (Join-Path $Gopath "bin"))

foreach ($p in $goBins) {
    if ($envPaths -notcontains $p) {
        Write-Host "Adding $p to user PATH"
        $envPaths += $p
    }
}
$newPath = $envPaths -join ";"
[Environment]::SetEnvironmentVariable("Path", $newPath, "User")

# 5) Broadcast WM_SETTINGCHANGE so new consoles pick it up
Write-Host "Broadcasting environment change..."
$signature = @"
using System;
using System.Runtime.InteropServices;
public class EnvNotify {
    [DllImport("user32.dll",SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
"@
Add-Type $signature
[Void][EnvNotify]::SendMessageTimeout(
    [IntPtr]0xffff, 0x1A, [UIntPtr]0, "Environment",
    0x0002, 5000, [ref]([UIntPtr]0)
)

# 6) Refresh current session & verify
$env:GOPATH = $Gopath
$env:PATH   = $newPath

Write-Host "`nInstallation complete!" -ForegroundColor Green
Write-Host "Verifying Go version..."
go version

Write-Host "`nSummary:"
Write-Host " • GOROOT = C:\Program Files\Go"
Write-Host " • GOPATH = $Gopath"
Write-Host "`nPlease restart any open shells to inherit the updated PATH."
