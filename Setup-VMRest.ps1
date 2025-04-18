<#  Configure‑VMRest.ps1
    -----------------------------------------------
    1. Opens an elevated CMD window in the VMware
       Workstation folder.
    2. You run  vmrest.exe --config
       and type   Username / Password / Password.
    3. When you exit that CMD window, this script
       automatically starts StartVMRestDaemon.ps1.
#>

$vmwareDir   = 'C:\Program Files (x86)\VMware\VMware Workstation'
$vmrestExe   = Join-Path $vmwareDir 'vmrest.exe'
$daemonScript = Join-Path $PSScriptRoot 'StartVMRestDaemon.ps1'

if (-not (Test-Path $vmrestExe)) {
    Write-Error "vmrest.exe not found in: $vmwareDir"
    exit 1
}
if (-not (Test-Path $daemonScript)) {
    Write-Error "StartVMRestDaemon.ps1 not found beside this script."
    exit 1
}

# Relaunch this script as Administrator if needed
$admin = [Security.Principal.WindowsBuiltInRole]::Administrator
if (-not ([Security.Principal.WindowsPrincipal] `
          [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole($admin)) {
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Write-Host ""
Write-Host "-----------------------------------------------------------"
Write-Host " A Command Prompt is about to open in the VMware folder." -ForegroundColor Cyan
Write-Host " Inside it, run:  vmrest.exe --config"
Write-Host " Then enter your username and password twice."
Write-Host " Close that window when you see 'Credential updated successfully'."
Write-Host "-----------------------------------------------------------"
Pause

# Open CMD and wait until it is closed
Start-Process cmd "/k cd `"$vmwareDir`"" -Wait

Write-Host ""
Write-Host "Launching REST‑API daemon..." -ForegroundColor Cyan
Start-Process powershell "-ExecutionPolicy Bypass -File `"$daemonScript`""
Write-Host "Done. REST API is starting in the background." -ForegroundColor Green
