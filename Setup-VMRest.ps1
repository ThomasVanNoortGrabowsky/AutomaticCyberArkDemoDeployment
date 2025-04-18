<#
Configure‑VMRest.ps1
--------------------
1. Opens an elevated Command Prompt in the VMware Workstation folder.
2. You run:
      vmrest.exe --config
      Username: ...
      New password: ...
      Retype new password: ...
   (This password is **not** tied to any Windows or vCenter account—it’s just
    the credential that Terraform will use to authenticate to VMware Workstation’s
    local REST API.)
3. After you see **'Credential updated successfully'**, close that Command Prompt.
   The script then runs **StartVMRestDaemon.ps1** for you.
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
$admin = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell "-ExecutionPolicy Bypass -File \"$PSCommandPath\"" -Verb RunAs
    exit
}

Write-Host "-----------------------------------------------------------"
Write-Host " A Command Prompt will open in the VMware folder."
Write-Host " In that window, run:  vmrest.exe --config"
Write-Host " Enter *any* username and a secure password twice."
Write-Host "   - This credential is *only* for Terraform talking"
Write-Host "     to the local REST API; it is not tied to any other"
Write-Host "     Windows or VMware account."
Write-Host " Close the window when you see 'Credential updated successfully'."
Write-Host "-----------------------------------------------------------"
Pause

Start-Process cmd "/k cd \"$vmwareDir\"" -Wait

Write-Host ""; Write-Host "Starting REST API daemon..." -ForegroundColor Cyan
Start-Process powershell "-ExecutionPolicy Bypass -File \"$daemonScript\""
Write-Host "Done. REST API is launching in the background." -ForegroundColor Green
