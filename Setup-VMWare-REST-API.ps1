<#
.SYNOPSIS
  Automates enabling VMware Workstation REST API: configures credentials and starts the service.

.DESCRIPTION
  * Prompts for API credentials (username/password) and enforces required complexity.
  * Runs `vmrest.exe --config` in a loop until valid credentials are accepted.
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

# Helper to convert SecureString to plaintext
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

# Loop until vmrest accepts credentials
while ($true) {
    if (-not $Password) {
        $Password = Read-PlainTextPassword "Enter REST API password for user '$Username' (8-12 chars, upper/lower/digit/special)"
    }

    Write-Host "Configuring REST API credentials..." -ForegroundColor Cyan
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "${VmRestDir}\vmrest.exe"
    $psi.Arguments = '--config'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput
    $proc.StandardInput.WriteLine($Username)
    $proc.StandardInput.WriteLine($Password)
    $proc.StandardInput.WriteLine($Password)
    $proc.StandardInput.Close()

    $output = $stdout.ReadToEnd()
    $proc.WaitForExit()

    if ($output -match 'Password does not meet complexity requirements') {
        Write-Warning "Password did not meet complexity requirements. Please try again."
        $Password = $null
        continue
    }
    if ($proc.ExitCode -ne 0) {
        Write-Error "vmrest --config failed (exit code $($proc.ExitCode)). Output:`n$output"
        exit 1
    }

    Write-Host "Credentials configured successfully." -ForegroundColor Green
    break
}

# Optionally start the REST API daemon
if ($StartDaemon) {
    Write-Host "Starting REST API daemon..." -ForegroundColor Cyan
    Start-Process -FilePath "${VmRestDir}\vmrest.exe" -NoNewWindow
    Write-Host "Daemon started. Listening on http://127.0.0.1:8697" -ForegroundColor Green
} else {
    Write-Host "`nTo start the daemon manually, run:`n  & '${VmRestDir}\vmrest.exe'" -ForegroundColor Yellow
}
