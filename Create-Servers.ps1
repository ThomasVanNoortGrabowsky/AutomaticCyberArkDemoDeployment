<#
.SYNOPSIS
  Build a golden Windows Server VM via Packer, then clone it via Terraform.

.DESCRIPTION
  1. Packer runs a vmware-iso build using your ISO to produce a "vault-base" VM.
     - You MUST have a matching Autounattend.xml in the script folder.
  2. The script polls the Workstation REST API to get the new VM's ID.
  3. It writes out a Terraform project that clones:
     • (Optional) CyberArk-Vault (8 cores, 32 GB RAM, 2×80 GB)
     • PVWA, CPM, PSM (4 cores, 8 GB RAM, 2×80 GB each)
  4. Finally, it does `terraform init`, `terraform plan`, and `terraform apply -auto-approve`.

.PARAMETER IsoPath
  Path to your Windows Server ISO. Edit below or respond at prompt.
#>

#region ← User settings — edit these or respond at prompts
# Path to your Windows ISO:
$IsoPath = 'C:\Users\ThomasvanNoort\Downloads\SERVER_EVAL_x64FRE_en-us.iso'

# Credentials you set up via `vmrest.exe --config`
$VmrestUser     = 'vmrest'
$VmrestPassword = 'Cyberark1'

# Ask whether to install Vault server infrastructure:
$installVault = Read-Host 'Do you want the Vault server infrastructure to be installed too? (Y/N)'
$InstallVault = $installVault -match '^[Yy]'

# Dynamically ask where to deploy VMs:
$DeployPath = Read-Host 'Enter the base folder path where VMs should be deployed (e.g. C:\VMs)'
#endregion

#--- 1) prerequisites
if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
  Write-Error "Packer not found. Install Packer and re-run."
  exit 1
}
if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
  Write-Error "Terraform not found. Install Terraform and re-run."
  exit 1
}

#--- 2) Write out Packer HCL template
$packerHcl = @"
variable "iso_path" {
  type    = string
  default = "$IsoPath"
}

source "vmware-iso" "vault_base" {
  vm_name           = "cyberark-vault-base"
  iso_url           = "file://\${var.iso_path}"
  iso_checksum_type = "sha256"
  floppy_files      = ["Autounattend.xml"]      # for unattended install
  communicator      = "winrm"
  winrm_username    = "Administrator"
  winrm_password    = "P@ssw0rd!"

  disk_size         = 81920     # 80 GB
  cpus              = 8
  memory            = 32768     # 32 GB

  shutdown_command  = "shutdown /s /t 5 /f /d p:4:1 /c \"Packer Shutdown\""
}
build {
  sources = ["source.vmware-iso.vault_base"]
}
"@
$packerFile = Join-Path $PSScriptRoot 'template.pkr.hcl'
$packerHcl | Set-Content -Path $packerFile -Encoding UTF8
Write-Host "Wrote Packer template to $packerFile"

#--- 3) Kick off Packer build
Write-Host "`n=== Starting Packer build…"
& packer init $packerFile
& packer build -force $packerFile
if ($LASTEXITCODE -ne 0) { Write-Error "Packer build failed"; exit 1 }

#--- 4) Query Workstation REST API for the new VM ID
Write-Host "`n=== Fetching base VM ID from vmrest…"
$securePass = ConvertTo-SecureString $VmrestPassword -AsPlainText -Force
$creds      = New-Object System.Management.Automation.PSCredential($VmrestUser, $securePass)
Start-Sleep -Seconds 5   # give REST API time to register VM
$vms = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Credential $creds -Method Get
$baseVm = $vms | Where-Object name -eq 'cyberark-vault-base'
if (-not $baseVm) {
  Write-Error "Could not find 'cyberark-vault-base' in API results"
  exit 1
}
$baseId = $baseVm.id
Write-Host "Found base VM ID: $baseId"

#--- 5) Generate Terraform project
$tfDir = Join-Path $PSScriptRoot 'terraform'
if (Test-Path $tfDir) { Remove-Item $tfDir -Recurse -Force }
New-Item -ItemType Directory -Path $tfDir | Out-Null

# Build main.tf content dynamically
$tfMain = "terraform {
  required_providers {
    vmworkstation = {
      source  = \"elsudano/vmworkstation\"
      version = \">= 1.0.4\"
    }
  }
}

provider \"vmworkstation\" {
  user     = var.vmrest_user
  password = var.vmrest_password
  url      = \"http://127.0.0.1:8697/api\"
}
"

if ($InstallVault) {
  $tfMain += @"
resource \"vmworkstation_vm\" \"vault\" {
  sourceid     = \"$baseId\"
  denomination = \"CyberArk-Vault\"
  description  = \"Vault server (8 CPU, 32 GB RAM, 2×80 GB)\"
  processors   = 8
  memory       = 32768
  path         = \"${DeployPath}\CyberArk-Vault\"
}
"@
}

# Always include PVWA, CPM, PSM
$components = @("PVWA","CPM","PSM")
foreach ($comp in $components) {
  $tfMain += @"
resource \"vmworkstation_vm\" \"$($comp.ToLower())\" {
  sourceid     = \"$baseId\"
  denomination = \"CyberArk-$comp\"
  description  = \"$comp server (4 CPU, 8 GB RAM, 2×80 GB)\"
  processors   = 4
  memory       = 8192
  path         = \"${DeployPath}\CyberArk-$comp\"
}
"@
}

# Write Terraform files
$tfMain | Set-Content -Path (Join-Path $tfDir 'main.tf') -Encoding UTF8

$tfVars = @"
variable \"vmrest_user\" {
  type    = string
  default = \"$VmrestUser\"
}
variable \"vmrest_password\" {
  type    = string
  default = \"$VmrestPassword\"
}
"@
$tfVars | Set-Content -Path (Join-Path $tfDir 'variables.tf') -Encoding UTF8

Write-Host "Wrote Terraform config into $tfDir"

#--- 6) Run Terraform: init, plan, apply
Push-Location $tfDir
Write-Host "`n=== terraform init"  -ForegroundColor Cyan
& terraform init -upgrade

Write-Host "`n=== terraform plan"  -ForegroundColor Cyan
& terraform plan -out=tfplan

Write-Host "`n=== terraform apply" -ForegroundColor Cyan
& terraform apply -auto-approve tfplan
Pop-Location

Write-Host "`n✅ All done! You should now see your requested VMs in VMware Workstation." -ForegroundColor Green
