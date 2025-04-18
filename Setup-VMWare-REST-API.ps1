<#
.SYNOPSIS
  Configure VMware Workstation REST API credentials and start the daemon (robust, ASCII‑only).

.PARAMETER Username
  REST API username (required).

.PARAMETER Password
  Optional password. If omitted, the script prompts securely.
#>
param(
    [Parameter(Mandatory=$true)][string]$Username,
    [string]$Password
)

$VmRestExe = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
if (-not (Test-Path $VmRestExe)) {
    Write-Error "vmrest.exe not found: $VmRestExe"; exit 1
}

function Read-PlainTextPassword($Prompt){
    $sec = Read-Host -Prompt $Prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

if (-not $Password) {
    $Password = Read-PlainTextPassword "Enter REST API password (8-12 chars, upper/lower/digit/special)"
}

while ($true) {
    Write-Host "Configuring REST API credentials..." -ForegroundColor Cyan
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $VmRestExe
    $psi.Arguments = '--config'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.WriteLine($Username)
    $p.StandardInput.WriteLine($Password)
    $p.StandardInput.WriteLine($Password)
    $p.StandardInput.Close()

    $p.WaitForExit()
    $out = ($p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd())
    if ($out -match 'Password does not meet complexity requirements') {
        Write-Warning "Password complexity failure — please try again."
        $Password = Read-PlainTextPassword "Enter NEW password"
        continue
    }
    if ($p.ExitCode -ne 0) {
        Write-Error "vmrest.exe --config failed (exit $($p.ExitCode)). Output:`n$out"; exit 1
    }
    Write-Host "Credentials configured successfully." -ForegroundColor Green
    break
}

Write-Host "Starting REST API daemon..." -ForegroundColor Cyan
Start-Process -FilePath $VmRestExe -WindowStyle Hidden
Write-Host "REST API daemon running on http://127.0.0.1:8697" -ForegroundColor Green
