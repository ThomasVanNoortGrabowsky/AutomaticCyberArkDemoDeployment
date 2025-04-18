<#
.SYNOPSIS
  Build the terraform-provider-vmworkstation plugin from source.

.DESCRIPTION
  1. Detects the provider source directory (from -ProjectDir or defaults).
  2. Removes any old build of terraform-provider-vmworkstation.exe.
  3. Runs `go build` to compile the plugin.
  4. Verifies the binary exists.
  5. Runs the binary with `-help` to check it’s valid.

.PARAMETER ProjectDir
  Optional: explicitly specify the provider source directory.
  If omitted, the script will look in:
    A) $env:GOPATH\src\github.com\elsudano\terraform-provider-vmworkstation
    B) A subfolder named 'terraform-provider-vmworkstation' under $PSScriptRoot
  and pick the first containing go.mod.

.EXAMPLE
  .\BuildProvider.ps1
  (Detects and builds from your GOPATH or subfolder.)

.EXAMPLE
  .\BuildProvider.ps1 -ProjectDir "D:\Code\terraform-provider-vmworkstation"
  (Builds from the specified folder.)
#>

param(
    [string]$ProjectDir = ''
)

# Auto-detect if ProjectDir not provided
if (-not $ProjectDir) {
    $gopathRepo = Join-Path $env:GOPATH 'src\github.com\elsudano\terraform-provider-vmworkstation'
    $subfolderRepo = Join-Path $PSScriptRoot 'terraform-provider-vmworkstation'

    if ($env:GOPATH -and (Test-Path (Join-Path $gopathRepo 'go.mod'))) {
        $ProjectDir = $gopathRepo
    }
    elseif (Test-Path (Join-Path $subfolderRepo 'go.mod')) {
        $ProjectDir = $subfolderRepo
    }
    else {
        Write-Error "Cannot locate terraform-provider-vmworkstation source. Use -ProjectDir to specify it."
        exit 1
    }
}

Write-Host "Building provider from: $ProjectDir" -ForegroundColor Cyan

# Validate directory
if (-not (Test-Path $ProjectDir -PathType Container)) {
    Write-Error "Directory not found: $ProjectDir"
    exit 1
}
if (-not (Test-Path (Join-Path $ProjectDir 'go.mod'))) {
    Write-Warning ("No go.mod found in '{0}'. Ensure this is the provider source folder." -f $ProjectDir)
}

# Switch to project folder
Push-Location $ProjectDir

# Remove old binary
$exe = 'terraform-provider-vmworkstation.exe'
if (Test-Path $exe) {
    Write-Host "Removing existing $exe..." -ForegroundColor Yellow
    Remove-Item $exe -Force
}

# Build the provider
Write-Host "Running: go build -o $exe" -ForegroundColor Cyan
go build -o $exe
if ($LASTEXITCODE -ne 0) {
    Write-Error "go build failed (exit code $LASTEXITCODE)."
    Pop-Location
    exit 1
}

# Verify the binary exists
if (-not (Test-Path $exe)) {
    Write-Error "Build succeeded but $exe was not found."
    Pop-Location
    exit 1
}

Write-Host "Build successful: $ProjectDir\$exe" -ForegroundColor Green

# Sanity check: display help
Write-Host "`nVerifying help output..." -ForegroundColor Cyan
& .\$exe -help

# Return to original folder
Pop-Location

Write-Host "`nDone. Provider binary is ready in $ProjectDir" -ForegroundColor Green
