<#
Configure‑VMRest.ps1
--------------------
1. Opens an elevated Command Prompt in the VMware Workstation folder.
2. Shows clear instructions for you to type:

      vmrest.exe --config
      Username: ...
      New password: ...
      Retype new password: ...

3. Waits until you close that Command Prompt, then tells you to run Start‑VMRestDaemon.ps1.
#>

$vmwareDir = 'C:\Program Files (x86)\VMware\VMware Workstation'

if (-not (Test-Path "$vmwareDir\vmrest.exe")) {
    Write-Error "vmrest.exe not found in: $vmwareDir"
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
Write-Host " Inside it, run:  vmrest.exe --config"
Write-Host " Then enter your desired username & password twice."
Write-Host " Close that Command Prompt when you see"
Write-Host " 'Credential updated successfully'."
Write-Host "-----------------------------------------------------------"
Pause

Start-Process cmd -ArgumentList "/k cd `"$vmwareDir`""
Write-Host ""
Write-Host "When finished, run Start‑VMRestDaemon.ps1 to launch the REST API."
