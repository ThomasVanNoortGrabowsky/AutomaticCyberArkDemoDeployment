<#
.SYNOPSIS
  Configure VMware Workstation REST API credentials and start the REST API daemon—without hanging.

.PARAMETER Username
  Username for the Workstation REST API (required).

.PARAMETER Password
  Optional password. If omitted, script prompts securely. Must meet VMware complexity.

.EXAMPLE
  .\Setup-VMWorkstationApi.ps1 -Username vmrest
#>

param(
    [Parameter(Mandatory=$true)][string]$Username,
    [string]$Password
)

# Full path to vmrest.exe
$VmRestExe = Join-Path 'C:\Program Files (x86)\VMware\VMware Workstation' 'vmrest.exe'
if (-not (Test-Path $VmRestExe)) {
    Write-Error "vmrest.exe not found: $VmRestExe"
    exit 1
}

# Secure password prompt helper
function Prompt-PlainTextPassword($msg){
    $sec = Read-Host -Prompt $msg -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

# Ensure we have a password
while (-not $Password) {
    $Password = Prompt-PlainTextPassword "Enter REST API password for '$Username' (8–12 chars, upper/lower/digit/special)"
}

# Loop until vmrest accepts credentials
while ($true) {
    Write-Host "Configuring REST API credentials..." -ForegroundColor Cyan

    # Prep process with redirected stdin
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $VmRestExe
    $psi.Arguments              = '--config'
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.WriteLine($Username)
    $p.StandardInput.WriteLine($Password)
    $p.StandardInput.WriteLine($Password)
    $p.StandardInput.Close()

    # Wait up to 15s
    if (-not $p.WaitForExit(15000)) {
        $p.Kill(); Write-Error "vmrest.exe --config timed out. Try again."; exit 1
    }

    $out = ($p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()).Trim()

    if ($out -match 'Password does not meet complexity requirements') {
        Write-Warning "Password complexity failure—please enter a different password."
        $Password = Prompt-PlainTextPassword "Enter NEW password for '$Username'"
        continue
    }

    if ($p.ExitCode -ne 0) {
        Write-Error "vmrest.exe --config failed (exit $($p.ExitCode)). Output:`n$out"; exit 1
    }

    Write-Host "Credentials configured successfully." -ForegroundColor Green
    break
}

# Start the REST API daemon
Write-Host "Starting REST API daemon..." -ForegroundColor Cyan
Start-Process -FilePath $VmRestExe -WindowStyle Hidden
Start-Sleep 2
Write-Host "REST API daemon is running on http://127.0.0.1:8697" -ForegroundColor Green
