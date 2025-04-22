<#
.SYNOPSIS
  Runs Terraform init, plan, and apply (with optional auto-approve) in the current directory.

.PARAMETER AutoApprove
  If present, uses -auto-approve on apply to skip the confirmation prompt.
#>
param(
    [switch]$AutoApprove
)

# Change to script folder (where your .tf files are)
Push-Location $PSScriptRoot

# Initialize Terraform
Write-Host "`n==> terraform init" -ForegroundColor Cyan
terraform init

# Plan
Write-Host "`n==> terraform plan" -ForegroundColor Cyan
terraform plan

# Apply
if ($AutoApprove) {
    Write-Host "`n==> terraform apply -auto-approve" -ForegroundColor Cyan
    terraform apply -auto-approve
} else {
    Write-Host "`n==> terraform apply" -ForegroundColor Cyan
    terraform apply
}

# Return to original directory
Pop-Location
