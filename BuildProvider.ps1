<#
.SYNOPSIS
  Build the terraform-provider-vmworkstation plugin from source.

.DESCRIPTION
  1. Detects the provider source directory (from -ProjectDir or known defaults).
  2. Removes any old build of terraform-provider-vmworkstation.exe.
  3. Runs `go build` to compile the plugin.
  4. Verifies the binary exists.
  5. Runs the binary with `-help` to check it’s valid.

.PARAMETER ProjectDir
  Optional: explicitly specify the provider source directory.
  If omitted, the script will look in:
    1. The current script folder ($PSScriptRoot)
    2. %GOPATH%\src\github.com\elsudano\terraform-provider-vmworkstation
    3. A subfolder named "terraform-provider-vmworkstation" under the script folder
  and pick the first one containing go.mod.
#>

param(
    [string]$ProjectDir = ''
)

# 1. Auto-detect project directory if not provided
if (-not $ProjectDir) {
    # Candidate 1: script folder
    if (Test-Path (Join-Path $PSScriptRoot 'go.mod')) {
        $ProjectDir = $PSScriptRoot
    }
    # Candidate 2: GOPATH location
    elseif ($env:GOPATH -and Test-Path (Join-Path $env:GOPATH 'src/github.com/elsudano/terraform-provider-vmworkstation/go.mod')) {
        $ProjectDir = Join-Path $env:GOPATH 'src/github.com/elsudano/terraform-provider-vmworkstation'
    }
    # Candidate 3: subfolder under script
    elseif (Test-Path (Join-Path $PSScriptRoot 'terraform-provider-vmworkstation/go.mod')) {
        $ProjectDir = Join-Path $PSScriptRoot 'terraform-provider-vmworkstation'
    }
    else {
        Write-Error "Could not locate terraform-provider-vmworkstation source. Please specify -ProjectDir explicitly."
        exit 1
    }
}

Write-Host "Using provider source folder: '$ProjectDir'" -ForegroundColor Cyan

# 2. Ensure directory exists and looks valid
if (-not (Test-Path $ProjectDir -PathType Container)) {
    Write-Error "Project directory '$ProjectDir' not found."
    exit 1
}
if (-not (Test-Path (Join-Path $ProjectDir 'go.mod'))) {
    Write-Warning "No go.mod found in '$ProjectDir'. Make sure this is the provider source."
}

Push-Location $ProjectDir

# 3. Remove old binary if present
$exe = 'terraform-provider-vmworkstation.exe'
if (Test-Path $exe) {
    Write-Host "Removing existing $exe..." -ForegroundColor Yellow
    Remove-Item $exe -Force
}

# 4. Build the provider
Write-Host "Running: go build -o $exe" -ForegroundColor Cyan
& go build -o $exe
if ($LASTEXITCODE -ne 0) {
    Write-Error "go build failed (exit code $LASTEXITCODE)."
    Pop-Location
    exit 1
}

# 5. Verify the binary exists
if (-not (Test-Path $exe)) {
    Write-Error "Build succeeded but $exe not found."
    Pop-Location
    exit 1
}
Write-Host "Build succeeded: $exe" -ForegroundColor Green

# 6. Sanity check the binary
Write-Host "`nVerifying with '$exe -help'..." -ForegroundColor Cyan
& .\$exe -help

Pop-Location

Write-Host "`nDone. The provider binary is ready in '$ProjectDir'." -ForegroundColor Green
