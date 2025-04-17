# -------------------------------
# Terraform Installation Script
# -------------------------------

# Define the Terraform version you wish to install.
# Update the version below if you need a different release.
$terraformVersion = "1.11.4"

# Set the installation folder (change if you prefer another location).
$installFolder = "C:\terraform"

# Ensure the installation folder exists.
if (!(Test-Path $installFolder)) {
    Write-Host "Creating installation folder at $installFolder ..."
    New-Item -ItemType Directory -Path $installFolder | Out-Null
}

# Construct the download URL for the Terraform zip package.
$downloadUrl = "https://releases.hashicorp.com/terraform/$terraformVersion/terraform_${terraformVersion}_windows_amd64.zip"
Write-Host "Downloading Terraform $terraformVersion from $downloadUrl ..."

# Define a temporary location for the zip file.
$zipFile = "$installFolder\terraform.zip"

# Download the Terraform zip archive.
Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile

Write-Host "Extracting Terraform into $installFolder ..."
# Extract the archive; the -Force parameter overwrites existing files.
Expand-Archive -Path $zipFile -DestinationPath $installFolder -Force

# Remove the temporary zip file.
Remove-Item $zipFile

# Optional: Add the installation folder to the user's PATH if it's not already included.
$existingPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($existingPath -notlike "*$installFolder*") {
    Write-Host "Adding $installFolder to the User PATH environment variable ..."
    $newPath = "$existingPath;$installFolder"
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
    Write-Host "PATH updated. Please restart your shell or log off/on for changes to take effect."
} else {
    Write-Host "$installFolder is already present in your PATH."
}

# Verify the Terraform installation.
Write-Host "Verifying Terraform installation..."
try {
    & "$installFolder\terraform.exe" -v
} catch {
    Write-Error "Terraform may not be installed correctly. Please ensure that $installFolder\terraform.exe exists."
}
