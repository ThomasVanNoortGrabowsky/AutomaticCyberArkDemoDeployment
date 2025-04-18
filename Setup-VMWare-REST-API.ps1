<#
.SYNOPSIS
  Automates configuring VMware Workstation REST API credentials and starts the REST API daemon.

.DESCRIPTION
  * Prompts for API credentials and enforces password complexity.
  * Runs `vmrest.exe --config` by piping in username and password.
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

[CmdletBinding()]
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
    $stdinContent = "$Username`n$Password`n$Password`n"
    $output = $stdinContent | & "$VmRestExe" --config 2>&1
    $exitCode = $LASTEXITCODE

    if ($output -match 'Password does not meet complexity requirements') {
        Write-Warning "Password complexity failure. Please choose another password."
        $Password = Read-PlainTextPassword "Enter a new password for '$Username'"
        continue
    }
    if ($exitCode -ne 0) {
        Write-Error "vmrest.exe --config failed (exit code $exitCode). Output:`n$output"
        exit 1
    }

    Write-Host "Credentials configured successfully." -ForegroundColor Green
    break
}

# Start the REST API daemon
Write-Host "Starting REST API daemon..." -ForegroundColor Cyan
$daemon = Start-Process -FilePath "$VmRestExe" -PassThru
Start-Sleep -Seconds 2
if (-not ($daemon.HasExited)) {
    Write-Host "REST API daemon started with PID $($daemon.Id). Listening on http://127.0.0.1:8697" -ForegroundColor Green
} else {
    Write-Error "Failed to start REST API daemon."
    exit 1
}
<#
.SYNOPSIS
  Automates configuring VMware Workstation REST API credentials and starts the REST API daemon.

.DESCRIPTION
  * Prompts for API credentials and enforces password complexity.
  * Runs `vmrest.exe --config` by piping in username and password.
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

[CmdletBinding()]
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
    $stdinContent = "$Username`n$Password`n$Password`n"
    $output = $stdinContent | & "$VmRestExe" --config 2>&1
    $exitCode = $LASTEXITCODE

    if ($output -match 'Password does not meet complexity requirements') {
        Write-Warning "Password complexity failure. Please choose another password."
        $Password = Read-PlainTextPassword "Enter a new password for '$Username'"
        continue
    }
    if ($exitCode -ne 0) {
        Write-Error "vmrest.exe --config failed (exit code $exitCode). Output:`n$output"
        exit 1
    }

    Write-Host "Credentials configured successfully." -ForegroundColor Green
    break
}

# Start the REST API daemon
Write-Host "Starting REST API daemon..." -ForegroundColor Cyan
$daemon = Start-Process -FilePath "$VmRestExe" -PassThru
Start-Sleep -Seconds 2
if (-not ($daemon.HasExited)) {
    Write-Host "REST API daemon started with PID $($daemon.Id). Listening on http://127.0.0.1:8697" -ForegroundColor Green
} else {
    Write-Error "Failed to start REST API daemon."
    exit 1
}
