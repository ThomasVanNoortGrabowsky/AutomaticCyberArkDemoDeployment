# StartVMRestDaemon.ps1
# -----------------------
$vmrest = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'

if (-not (Test-Path $vmrest)) {
    Write-Error "vmrest.exe not found at: $vmrest"
    exit 1
}

# Relaunch as Admin if needed
if (-not ([Security.Principal.WindowsPrincipal] `
          [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# If already running, exit
if (Get-Process vmrest -ErrorAction SilentlyContinue) {
    Write-Host "VMware REST API is already running."
    exit
}

Write-Host "Starting VMware REST API daemon..." -ForegroundColor Cyan
Start-Process -FilePath $vmrest -WindowStyle Hidden
Start-Sleep 2
Write-Host "REST API daemon listening on http://127.0.0.1:8697" -ForegroundColor Green
