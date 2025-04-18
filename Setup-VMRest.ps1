<#
Configure‑VMRest.ps1
--------------------
1. Opens an elevated Command Prompt in the VMware Workstation folder.
2. You run:
      vmrest.exe --config
      Username: Done. REST API is starting in the background.
PS C:\users\ThomasvanNoort\AutomaticCyberArkDemoDeployment> git pull
remote: Enumerating objects: 5, done.
remote: Counting objects: 100% (5/5), done.
remote: Compressing objects: 100% (3/3), done.
remote: Total 3 (delta 1), reused 0 (delta 0), pack-reused 0 (from 0)
Unpacking objects: 100% (3/3), 1.77 KiB | 51.00 KiB/s, done.
From https://github.com/ThomasVanNoortGrabowsky/AutomaticCyberArkDemoDeployment
   c2dcfa6..c8d1715  main       -> origin/main
Updating c2dcfa6..c8d1715
Fast-forward
 Setup-VMRest.ps1 | 62 +++++++++++++++++++++++++++++---------------------------
 1 file changed, 32 insertions(+), 30 deletions(-)
PS C:\users\ThomasvanNoort\AutomaticCyberArkDemoDeployment> .\Setup-VMRest.ps1
-----------------------------------------------------------
 A Command Prompt will open in the VMware folder.
 In that window, run:  vmrest.exe --config
 Enter *any* username and a secure password twice.
   - This credential is *only* for Terraform talking
     to the local REST API; it is not tied to any other
     Windows or VMware account.
 Close the window when you see 'Credential updated successfully'.
-----------------------------------------------------------
Press Enter to continue...:
Start-Process : A positional parameter cannot be found that accepts argument 'C:\Program Files (x86)\VMware\VMware
Workstation\'.
At C:\users\ThomasvanNoort\AutomaticCyberArkDemoDeployment\Setup-VMRest.ps1:45 char:1
+ # Open CMD and wait for it to close
Start-Process -FilePath cmd.exe -ArgumentList '/k', "cd /d `"$vmwareDir`"" -Wait
+ ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : InvalidArgument: (:) [Start-Process], ParameterBindingException
    + FullyQualifiedErrorId : PositionalParameterNotFound,Microsoft.PowerShell.Commands.StartProcessCommand


Starting REST API daemon...
Start-Process : A positional parameter cannot be found that accepts argument
'C:\users\ThomasvanNoort\AutomaticCyberArkDemoDeployment\StartVMRestDaemon.ps1\'.
At C:\users\ThomasvanNoort\AutomaticCyberArkDemoDeployment\Setup-VMRest.ps1:48 char:1
+ # After CMD closes, start the daemon automatically
Start-Process -FilePath powershell.exe -ArgumentList '-ExecutionPolicy','Bypass','-File',"`"$daemonScript`""
+ ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : InvalidArgument: (:) [Start-Process], ParameterBindingException
    + FullyQualifiedErrorId : PositionalParameterNotFound,Microsoft.PowerShell.Commands.StartProcessCommand

Done. REST API is launching in the background.
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
