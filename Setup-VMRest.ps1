<#
Configure‑VMRest.ps1
--------------------
1. Opens an elevated Command Prompt in the VMware Workstation folder.
2. You run:
      vmrest.exe --config
      Username / Password twice
   (This credential is **only** for Terraform -> VMware Workstation API.)
3. After you see **"Credential updated successfully"**, close the CMD window.
   The script then runs **StartVMRestDaemon.ps1** automatically.
#>

$vmwareDir   = 'C:\Program Files (x86)\VMware\VMware Workstation'
$daemonScript = Join-Path $PSScriptRoot 'StartVMRestDaemon.ps1'

if (-not (Test-Path "$vmwareDir\vmrest.exe")) {
    Write-Error "vmrest.exe not found in: $vmwareDir"; exit 1
}
if (-not (Test-Path $daemonScript)) {
    Write-Error "StartVMRestDaemon.ps1 not found in script folder."; exit 1
}

# Relaunch as admin if needed
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal $identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath powershell -ArgumentList "-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"" -Verb RunAs
    exit
}

Write-Host "-----------------------------------------------------------"
Write-Host " A Command Prompt will open in the VMware folder."
Write-Host " In that window, run:  vmrest.exe --config"
Write-Host " Enter *any* username and a secure password twice (8‑12 chars)."
Write-Host " This credential is ONLY for Terraform -> VMware API auth."
Write-Host " Close the window when you see 'Credential updated successfully'."
Write-Host "-----------------------------------------------------------"
Pause

# Open CMD, change dir, wait until closed
Start-Process -FilePath cmd -ArgumentList "/k","cd /d `"$vmwareDir`"" -Wait

Write-Host ""; Write-Host "Starting REST API daemon..." -ForegroundColor Cyan
Start-Process -FilePath powershell -ArgumentList "-ExecutionPolicy","Bypass","-File","`"$daemonScript`"" -WindowStyle Hidden
Write-Host "Done. REST API is launching in the background." -ForegroundColor Green
