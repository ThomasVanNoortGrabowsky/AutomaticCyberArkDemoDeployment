<#
Configure‑VMRest.ps1
--------------------
1. Opens an elevated Command Prompt in the VMware Workstation folder.
2. You run:
      vmrest.exe --config
      Username / password twice
3. When you close that CMD window, the script automatically runs
   StartVMRestDaemon.ps1.
#>

$vmwareDir = 'C:\Program Files (x86)\VMware\VMware Workstation'
$daemonScript = Join-Path $PSScriptRoot 'StartVMRestDaemon.ps1'

if (-not (Test-Path "$vmwareDir\vmrest.exe")) {
    Write-Error "vmrest.exe not found in: $vmwareDir"
    exit 1
}
if (-not (Test-Path $daemonScript)) {
    Write-Error "StartVMRestDaemon.ps1 not found in script folder."
    exit 1
}

# Relaunch as admin if needed
if (-not ([Security.Principal.WindowsPrincipal] `
          [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
          [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Restarting this script as Administrator..."
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Write-Host "-----------------------------------------------------------"
Write-Host " A Command Prompt will open in the VMware folder."
Write-Host " In that window, type:"
Write-Host "   vmrest.exe --config"
Write-Host " Then enter your username and password twice."
Write-Host " Close the Command Prompt when you see"
Write-Host " 'Credential updated successfully'."
Write-Host "-----------------------------------------------------------"
Pause

# Open CMD and wait for it to close
Start-Process cmd -ArgumentList "/k cd `"$vmwareDir`"" -Wait

# After CMD closes, start the daemon automatically
Write-Host ""
Write-Host "Starting REST API daemon..." -ForegroundColor Cyan
Start-Process powershell "-ExecutionPolicy Bypass -File `"$daemonScript`""

Write-Host "Done. REST API is launching in the background." -ForegroundColor Green
