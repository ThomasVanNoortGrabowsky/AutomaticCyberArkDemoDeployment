<#
Setup‑VMRestAuto.ps1
--------------------
1. Prompts for username + password (with hidden input).
2. Opens cmd.exe running:  vmrest.exe --config
3. Sends the credentials via SendKeys.
4. Waits for “Credential updated successfully”.
5. Closes cmd.exe and starts vmrest.exe (daemon) hidden.
#>

param(
    [Parameter(Mandatory)] [string]$Username
)

# Path to vmrest.exe
$vmrest = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrest.exe'
if (-not (Test-Path $vmrest)) {
    Write-Error "vmrest.exe not found at $vmrest"; exit 1
}

# Self‑elevate if not admin
if (-not ([Security.Principal.WindowsPrincipal]
          [Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -Username `"$Username`"" -Verb RunAs
    exit
}

# Secure password prompt
$sec = Read-Host -Prompt 'Password (8‑12 chars)' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$password = [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)

# Load SendKeys
Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@ | Out-Null

# 1. Launch cmd running vmrest.exe --config
$cmd = Start-Process cmd "/k cd `"$($vmrest | Split-Path)`" && vmrest.exe --config" -PassThru
Start-Sleep 1   # give the window time to appear

# 2. Bring the cmd window to foreground
[Win32]::SetForegroundWindow($cmd.MainWindowHandle) | Out-Null

# 3. Build the keystroke string
$send = "$Username`r$password`r$password`r"
[System.Windows.Forms.SendKeys]::SendWait($send)

# 4. Wait until we see success text (simple 30s timeout)
$deadline = (Get-Date).AddSeconds(30)
while ($cmd.HasExited -eq $false -and (Get-Date) -lt $deadline) {
    Start-Sleep 1
    if ((Get-Process -Id $cmd.Id |
         Get-Content -Path { $_.Path } -Raw -ErrorAction Ignore) -match 'Credential updated successfully') {
        break
    }
}

# 5. Close the cmd window
if (-not $cmd.HasExited) { $cmd.CloseMainWindow() | Out-Null }

Write-Host 'Credentials configured.' -ForegroundColor Green

# 6. Start the REST API daemon hidden
Start-Process $vmrest -WindowStyle Hidden
Write-Host 'REST API daemon started on http://127.0.0.1:8697' -ForegroundColor Green
