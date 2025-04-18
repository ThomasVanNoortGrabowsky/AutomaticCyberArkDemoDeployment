<#
.SYNOPSIS
  Automates configuring VMware Workstation REST API credentials and starts the REST API daemon.

.DESCRIPTION
  * Prompts for API credentials and enforces password complexity.
  * Runs `vmrest.exe --config` using ProcessStartInfo to feed stdin.
  * Retries if complexity requirements fail.
  * Automatically starts the REST API daemon when configuration succeeds.

.PARAMETER Username
  Username for the Workstation REST API (e.g., "vmrest").

.PARAMETER Password
  Optional initial password. If omitted, the script prompts interactively.

.EXAMPLE
  .\Setup-VMWorkstationApi.ps1 -Username api_user
  Prompts for a valid password, sets credentials, and starts the daemon.
#>

param(
    [Parameter(Mandatory=$true)] [string]$Username,
    [string]$Password
)

# Path to vmrest.exe
$VmRestExe = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
if (-not (Test-Path $VmRestExe)) {
    Write-Error "Could not find vmrest.exe at: $VmRestExe"
    exit 1
}

# Function to securely read password
function Read-PlainTextPassword {
    param([string]$Prompt)
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Prompt for password if not provided
while (-not $Password) {
    $Password = Read-PlainTextPassword "Enter REST API password for '$Username' (8-12 chars, upper/lower/digit/special)"
}

# Configure credentials, retry on complexity failure
while ($true) {
    Write-Host "Configuring REST API credentials..." -ForegroundColor Cyan
    # Prepare ProcessStartInfo
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $VmRestExe
    $psi.Arguments = '--config'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    # Feed username and password
    $proc.StandardInput.WriteLine($Username)
    $proc.StandardInput.WriteLine($Password)
    $proc.StandardInput.WriteLine($Password)
    $proc.StandardInput.Close()

    # Read output
    $output = $proc.StandardOutput.ReadToEnd() + $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    # Check complexity failure
    if ($output -match 'Password does not meet complexity requirements') {
        Write-Warning "Password complexity failure. Please choose another password."
        $Password = Read-PlainTextPassword "Enter a new password for '$Username'"
        continue
    }
    # Check for other errors
    if ($proc.ExitCode -ne 0) {
        Write-Error "vmrest.exe --config failed (exit code $($proc.ExitCode)). Output:`n$output"
        exit 1
    }

    Write-Host "Credentials configured successfully." -ForegroundColor Green
    break
}

# Start the REST API daemon
Write-Host "Starting REST API daemon..." -ForegroundColor Cyan
$daemon = Start-Process -FilePath $VmRestExe -PassThru -NoNewWindow
Start-Sleep -Seconds 2
if (-not $daemon.HasExited) {
    Write-Host "REST API daemon started with PID $($daemon.Id). Listening on http://127.0.0.1:8697" -ForegroundColor Green
} else {
    Write-Error "Failed to start REST API daemon."
    exit 1
}
