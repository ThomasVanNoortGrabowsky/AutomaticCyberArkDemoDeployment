<#
.SYNOPSIS
  Automates enabling VMware Workstation REST API: configures credentials and starts the service.

.DESCRIPTION
  * Prompts (or accepts via parameters) for a username and password.
  * Runs `vmrest.exe --config` with redirected input to set the REST API credentials.
  * Starts the `vmrest.exe` daemon.

.PARAMETER Username
  Username for the Workstation REST API (e.g., "vmrest").

.PARAMETER Password
  Password for the Workstation REST API. It will be prompted if not provided.

.PARAMETER StartDaemon
  If specified, starts the REST API daemon after configuring.

.EXAMPLE
  .\Setup-VMWorkstationApi.ps1 -Username vmrest -Password S3cureP@ss -StartDaemon
  Configures the REST API credentials and starts the daemon.
#>

param(
    [Parameter(Mandatory=$true)] [string]$Username,
    [Parameter(Mandatory=$false)] [string]$Password,
    [switch]$StartDaemon
)

# Default path to VMware Workstation installation
$VmRestDir = 'C:\Program Files (x86)\VMware\VMware Workstation'

if (-not (Test-Path $VmRestDir)) {
    Write-Error "VMware Workstation directory not found at: $VmRestDir"
    exit 1
}

# Prompt for password if not provided
if (-not $Password) {
    $Password = Read-Host -AsSecureString "Enter REST API password for user '$Username'" | 
                ConvertFrom-SecureString -AsPlainText
}

# Configure REST API credentials via vmrest.exe --config
Write-Host "Configuring REST API credentials..." -ForegroundColor Cyan
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "$VmRestDir\vmrest.exe"
$psi.Arguments = '--config'
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $false
$psi.UseShellExecute = $false
$process = [System.Diagnostics.Process]::Start($psi)
# Send username, password, and confirmation
$process.StandardInput.WriteLine($Username)
$process.StandardInput.WriteLine($Password)
$process.StandardInput.WriteLine($Password)
$process.StandardInput.Close()
$process.WaitForExit()

if ($process.ExitCode -ne 0) {
    Write-Error "vmrest.exe --config exited with code $($process.ExitCode)."
    exit 1
}

Write-Host "Credentials configured successfully." -ForegroundColor Green

# Optionally start the REST API daemon
if ($StartDaemon) {
    Write-Host "Starting VM REST API daemon..." -ForegroundColor Cyan
    Start-Process -FilePath "$VmRestDir\vmrest.exe" -NoNewWindow
    Write-Host "Daemon started. Listening on http://127.0.0.1:8697" -ForegroundColor Green
} else {
    Write-Host "
To start the REST API daemon, run:
  & 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
or re-run this script with -StartDaemon." -ForegroundColor Yellow
}
