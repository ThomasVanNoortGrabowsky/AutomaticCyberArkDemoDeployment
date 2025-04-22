.PARAMETER AutoApprove
  If present, uses `-auto-approve` on apply to skip the confirmation prompt.
#>

param(
  [switch]$AutoApprove
)

# Make sure we’re in the right folder
Push-Location $PSScriptRoot

# 1) Init
Write-Host "`n==> terraform init" -ForegroundColor Cyan
terraform init

# 2) Plan
Write-Host "`n==> terraform plan" -ForegroundColor Cyan
terraform plan

# 3) Apply
if ($AutoApprove) {
    Write-Host "`n==> terraform apply -auto-approve" -ForegroundColor Cyan
    terraform apply -auto-approve
} else {
    Write-Host "`n==> terraform apply" -ForegroundColor Cyan
    terraform apply
}

Pop-Location
