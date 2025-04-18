<#
.SYNOPSIS
  Automates enabling VMware Workstation REST API: configures credentials and starts the service.

.DESCRIPTION
  * Prompts for API credentials (username/password) and enforces required complexity.
  * Runs `vmrest.exe --config` with piped input and checks output for errors.
  * Retries if password complexity fails.
  * Optionally starts the `vmrest.exe` daemon.

.PARAMETER Username
  Username for the Workstation REST API (e.g., "vmrest").

.PARAMETER Password
  Optional: initial password. If not provided, script prompts interactively.

.PARAMETER StartDaemon
  If specified, starts the REST API daemon after configuration.

.EXAMPLE
  .\Setup-VMWorkstationApi.ps1 -Username vmrest -StartDaemon
  Prompts for password until valid, then starts the daemon.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string]$Username,
    [string]$Password,
    [switch]$StartDaemon
)

# Path to VMware Workstation REST tool
$VmRestExe = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
if (-not (Test-Path $VmRestExe)) {
    Write-Error "vmrest.exe not found at path: $VmRestExe"
    exit 1
}

function Read-PlainTextPassword {
    param([string]$Prompt)
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

while ($true) {
    if (-not $Password) {
        $Password = Read-PlainTextPassword "Enter REST API password for '$Username' (8-12 chars, upper/lower/digit/special)"
    }

    Write-Host "Configuring REST API credentials..." -ForegroundColor Cyan
    $stdin = "$Username`n$Password`n$Password`n"
    $output = $stdin | & $VmRestExe --config 2>&1
    $exitCode = $LASTEXITCODE

    if ($output -match 'Password does not meet complexity requirements') {
        Write-Warning "Password complexity failure. Please try again."
        $Password = $null
        continue
    }
    if ($exitCode -ne 0) {
        Write-Error "vmrest.exe --config failed (exit $exitCode). Output:`n$output"
        exit 1
    }

    Write-Host "Credentials configured successfully." -ForegroundColor Green
    break
}

if ($StartDaemon) {
    Write-Host "Starting REST API daemon..." -ForegroundColor Cyan
    Start-Process -FilePath $VmRestExe -NoNewWindow
    Write-Host "Daemon started. Listening on http://127.0.0.1:8697" -ForegroundColor Green
} else {
    Write-Host "`nTo start the daemon manually, run:`n  & '$VmRestExe'`n" -ForegroundColor Yellow
}
