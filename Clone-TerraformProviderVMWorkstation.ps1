<#
.SYNOPSIS
    Ensures Git is installed, then clones or updates the terraform-provider-vmworkstation repo
    into the directory where this script resides.

.PARAMETER Force
    If specified and the target folder exists, it will be removed and re-cloned.
#>
[CmdletBinding()]
param(
    [switch]$Force
)

# 1) Ensure Git is available
Write-Host "Checking for Git..."
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Git not found. Attempting to install via winget..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Start-Process winget `
            -ArgumentList 'install','--id','Git.Git','-e','--source','winget',`
                          '--accept-package-agreements','--accept-source-agreements' `
            -Wait -NoNewWindow
        # Reload PATH so 'git' becomes available immediately
        $paths = (
            [Environment]::GetEnvironmentVariable('Path','Machine'),
            [Environment]::GetEnvironmentVariable('Path','User')
        ) -join ';'
        $env:PATH = $paths
    }
    else {
        Write-Error "winget not available. Please install Git manually from https://git-scm.com/download/win"
        exit 1
    }
}
Write-Host "Git is now: $(git --version)`n"

# 2) Define repo and local target
$repoUrl    = 'https://github.com/elsudano/terraform-provider-vmworkstation.git'
$targetDir  = Join-Path $PSScriptRoot 'terraform-provider-vmworkstation'

# 3) Clone or update
if (Test-Path $targetDir) {
    if ($Force) {
        Write-Host "Removing existing folder for fresh clone..."
        Remove-Item -Recurse -Force $targetDir
    }
}

if (-not (Test-Path $targetDir)) {
    Write-Host "Cloning $repoUrl into `"$targetDir`"..."
    git clone $repoUrl $targetDir
}
else {
    Write-Host "Repository exists. Pulling latest changes in `"$targetDir`"..."
    Push-Location $targetDir
    git pull
    Pop-Location
}

Write-Host "`n✅ Done! Repo is at:`n  $targetDir"
