<#
.SYNOPSIS
    Ensures Git is installed, then clones or updates the terraform‑provider‑vmworkstation repo under your GOPATH.

.PARAMETER Gopath
    Optional. The GOPATH to use. Defaults to $env:GOPATH or "$env:USERPROFILE\go".

.PARAMETER RepoUrl
    Optional. The Git URL to clone. Defaults to the official GitHub repo.

.PARAMETER Force
    If specified and the target folder exists, it will be removed and re‑cloned.
#>
[CmdletBinding()]
param(
    [string]$Gopath  = if ($env:GOPATH) { $env:GOPATH } else { "$env:USERPROFILE\go" },
    [string]$RepoUrl = 'https://github.com/elsudano/terraform-provider-vmworkstation.git',
    [switch]$Force
)

# 0) Ensure Git is installed
Write-Host "Checking for Git..."
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Git not found. Attempting to install via winget..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Start-Process winget `
            -ArgumentList @(
                'install',
                '--id','Git.Git',
                '-e',
                '--source','winget',
                '--accept-package-agreements',
                '--accept-source-agreements'
            ) `
            -Wait `
            -NoNewWindow
        # Refresh this session’s PATH so git becomes available immediately
        $machinePath = [Environment]::GetEnvironmentVariable('Path','Machine') `
            .Split(';',[StringSplitOptions]::RemoveEmptyEntries)
        $userPath    = [Environment]::GetEnvironmentVariable('Path','User') `
            .Split(';',[StringSplitOptions]::RemoveEmptyEntries)
        $env:PATH    = ($machinePath + $userPath) -join ';'
    }
    else {
        Write-Error "winget not available. Please install Git manually from https://git-scm.com/download/win and re-run."
        exit 1
    }
}

Write-Host "Git is now available: $(git --version)`n"

# 1) Compute target paths
$orgPath   = Join-Path $Gopath 'src\github.com\elsudano'
$repoName  = ([IO.Path]::GetFileNameWithoutExtension($RepoUrl)).Replace('-main','')
$targetDir = Join-Path $orgPath $repoName

# 2) Create folder structure
if (-not (Test-Path $orgPath)) {
    Write-Host "Creating directory: $orgPath"
    New-Item -ItemType Directory -Path $orgPath -Force | Out-Null
}

# 3) Clone or update
if (Test-Path $targetDir) {
    if ($Force) {
        Write-Host "Removing existing folder for fresh clone..."
        Remove-Item -Recurse -Force $targetDir
    }
}

if (-not (Test-Path $targetDir)) {
    Write-Host "Cloning $RepoUrl into $orgPath..."
    Push-Location $orgPath
    git clone $RepoUrl
    Pop-Location
}
else {
    Write-Host "Repository already exists. Pulling latest changes in $targetDir..."
    Push-Location $targetDir
    git pull
    Pop-Location
}

Write-Host "`n✅ Done! Repository is at:`n  $targetDir"
