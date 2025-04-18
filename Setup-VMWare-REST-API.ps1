<#
.SYNOPSIS
  Automates enabling VMware Workstation REST API: configures credentials with a timeout and starts the service.

.DESCRIPTION
  * Prompts for API credentials (username/password) and enforces required complexity.
  * Runs `vmrest.exe --config` with redirected input and a timeout (10s).
  * Retries on complexity errors until valid or timeout.
  * Optionally starts the `vmrest.exe` daemon to serve requests.

.PARAMETER Username
  Username for the Workstation REST API (e.g., "vmrest").

.PARAMETER Password
  Optional: initial password. If not provided, script prompts interactively.

.PARAMETER StartDaemon
  If specified, starts the REST API daemon after successful configuration.

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

# Path to VMware Workstation
$VmRestDir = 'C:\Program Files (x86)\VMware\VMware Workstation'
if (-not (Test-Path $VmRestDir)) {
    Write-Error "VMware Workstation directory not found: $VmRestDir"
    exit 1
}

# Helper to read secure password as plaintext
function Read-PlainTextPassword {
    param([string]$Prompt)
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

# Loop until credentials accepted or user aborts
while ($true) {
    if (-not $Password) {
        $Password = Read-PlainTextPassword "Enter REST API password for user '$Username' (8-12 chars, upper/lower/digit/special)"
    }

    Write-Host "Configuring REST API credentials..." -ForegroundColor Cyan
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "${VmRestDir}\vmrest.exe"
    $psi.Arguments = '--config'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    # Feed username and password entries
    $proc.StandardInput.WriteLine($Username)
    $proc.StandardInput.WriteLine($Password)
    $proc.StandardInput.WriteLine($Password)
    $proc.StandardInput.Close()

    # Wait up to 10 seconds
    if (-not $proc.WaitForExit(10000)) {
        Write-Error "Timeout waiting for vmrest.exe --config to finish."
        $proc.Kill()
        exit 1
    }

    $output = $proc.StandardOutput.ReadToEnd() + $proc.StandardError.ReadToEnd()

    if ($output -match 'Password does not meet complexity requirements') {
        Write-Warning "Password complexity failure. Please try again."
        $Password = $null
        continue
    }
    if ($proc.ExitCode -ne 0) {
        Write-Error "vmrest.exe --config failed (exit $($proc.ExitCode)). Output:`n$output"
        exit 1
    }

    Write-Host "Credentials configured successfully." -ForegroundColor Green
    break
}

# Start REST API daemon if requested
if ($StartDaemon) {
    Write-Host "Starting REST API daemon..." -ForegroundColor Cyan
    Start-Process -FilePath "${VmRestDir}\vmrest.exe" -NoNewWindow
    Write-Host "Daemon started. Listening on http://127.0.0.1:8697" -ForegroundColor Green
} else {
    Write-Host "`nTo start the daemon manually": -ForegroundColor Yellow
    Write-Host "  & '${VmRestDir}\vmrest.exe'" -ForegroundColor Yellow
    Write-Host "Or re-run this script with -StartDaemon`n" -ForegroundColor Yellow
}
