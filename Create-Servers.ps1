.SYNOPSIS
    Builds a Win2022 GUI VM with Packer, registers it with VMREST, discovers its ID, and then uses Terraform to deploy demo VMs.
    Full end-to-end pipeline: Packer → VMREST → Terraform → optional VM launch.
  
  .DESCRIPTION
    1) Builds the “Win2022_GUI” template with Packer.
    2) Registers that template with VMware Workstation (vmrun register).
    3) Starts and health-checks the VMware REST API (VMREST) using HTTP Basic.
    4) Queries VMREST for the new template’s GUID.
    5) Writes terraform.tfvars with that GUID.
    6) Runs Terraform init & apply to deploy Vault, PVWA, PSM, and CPM.
    7) (Optional) Launches the resulting VMs in the Workstation GUI.
    1) Builds the Win2022_GUI template with Packer.
    2) Registers that .vmx with VMware Workstation (vmrun).
    3) Starts & health-checks the VMware REST API (VMREST).
    4) Lists all VM entries returned by VMREST (displayName + id).
    5) Finds your new template by a partial match on "Win2022".  
       If it still isn’t found, the script show you exactly what VMREST sees and then exits.
    6) Writes terraform.tfvars with the real GUID.
    7) Runs Terraform init & apply.
    8) (Optional) Powers on the Vault, PVWA, PSM, CPM VMs in Workstation.
  #>
  
  [CmdletBinding()]
  param(
      [Parameter(Mandatory)] [string]$IsoPath,
      [Parameter(Mandatory)] [string]$VmOutputPath
    [Parameter(Mandatory)] [string]$IsoPath,
    [Parameter(Mandatory)] [string]$VmOutputPath
  )
  
  $ErrorActionPreference = 'Stop'
  
  #---- Paths & Credentials ----#
  $scriptRoot   = Split-Path $MyInvocation.MyCommand.Definition -Parent
  # Paths & credentials
  $scriptRoot   = Split-Path $MyInvocation.MyCommand.Path -Parent
  $packerDir    = Join-Path $scriptRoot 'packer-Win2022'
  $packerExe    = Join-Path $scriptRoot 'packer-bin\packer.exe'
  $outputDir    = Join-Path $packerDir 'output-vmware-iso'
  $templateVmx  = Join-Path $outputDir 'Win2022_GUI.vmx'
  $tfvarsFile   = Join-Path $scriptRoot 'terraform.tfvars'
  
  # VMREST credentials (updated password)
  # VMREST credentials
  $vmrestUser = 'vmrest'
  $vmrestPass = 'Cyberark1!'
  $vmrestPass = 'Cyberark1!'   # updated password
  
  #---- 1) Validate ISO ----#
  # 1) Validate ISO
  if (-not (Test-Path $IsoPath)) {
      Write-Error "ISO not found at: $IsoPath"
      exit 1
    Write-Error "ISO not found at: $IsoPath"
    exit 1
  }
  $isoUrl      = "file:///$($IsoPath -replace '\\','/')"
  $isoChecksum = "sha256:$((Get-FileHash -Path $IsoPath -Algorithm SHA256).Hash)"
  Write-Host "ISO validated. Checksum: $isoChecksum" -ForegroundColor Green
  Write-Host "✔ ISO validated. Checksum: $isoChecksum" -ForegroundColor Green
  
  #---- 2) Install Packer if missing ----#
  # 2) Install Packer if missing
  if (-not (Test-Path $packerExe)) {
      Write-Host "Installing Packer v1.11.2…" -ForegroundColor Cyan
      $packerBin = Split-Path $packerExe
      New-Item -Path $packerBin -ItemType Directory -Force | Out-Null
      $zip = Join-Path $packerBin 'packer.zip'
      Invoke-WebRequest `
          -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' `
          -OutFile $zip
      Expand-Archive -Path $zip -DestinationPath $packerBin -Force
      Remove-Item $zip
    Write-Host "==> Installing Packer v1.11.2…" -ForegroundColor Cyan
    $packerBin = Split-Path $packerExe
    New-Item -Path $packerBin -ItemType Directory -Force | Out-Null
    $zip = Join-Path $packerBin 'packer.zip'
    Invoke-WebRequest `
      -Uri 'https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip' `
      -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $packerBin -Force
    Remove-Item $zip
  }
  $env:PATH = "$($env:PATH);$(Split-Path $packerExe)"
  $env:PATH = "$env:PATH;$(Split-Path $packerExe)"
  
  #---- 3) Clean previous Packer output ----#
  # 3) Clean previous Packer output
  if (Test-Path $outputDir) {
      Write-Host "Cleaning old Packer output…" -ForegroundColor Yellow
      Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
      Remove-Item -Recurse -Force $outputDir
    Write-Host "==> Cleaning old Packer output…" -ForegroundColor Yellow
    Get-Process -Name vmware-vmx -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item -Recurse -Force $outputDir
  }
  
  #---- 4) Build the golden image ----#
  Write-Host "Running Packer build…" -ForegroundColor Cyan
  # 4) Build the golden image
  Write-Host "==> Running Packer build…" -ForegroundColor Cyan
  Push-Location $packerDir
  & $packerExe build `
      -var "iso_url=$isoUrl" `
      -var "iso_checksum=$isoChecksum" `
      'win2022-gui.json'
  if ($LASTEXITCODE -ne 0) {
      Write-Error "Packer build failed."
      Pop-Location
      exit 1
    Write-Error "❌ Packer build failed."
    Pop-Location; exit 1
  }
  Pop-Location
  Write-Host "Packer build complete." -ForegroundColor Green
  Write-Host "✔ Packer build complete." -ForegroundColor Green
  
  #---- 5) Register the template with VMREST ----#
  # 5) Register the template with VMREST
  if (Test-Path $templateVmx) {
      Write-Host "Registering template with VMREST…" -ForegroundColor Cyan
      $vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
      if (-not $vmrun) {
          $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
      }
      & $vmrun -T ws register $templateVmx 2>$null
      Write-Host "Template VM registered." -ForegroundColor Green
    Write-Host "==> Registering template VM with Workstation…" -ForegroundColor Cyan
    $vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
    if (-not $vmrun) {
      $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
    }
    & $vmrun -T ws register $templateVmx 2>$null
    Write-Host "✔ Template VM registered (if supported by host)." -ForegroundColor Green
  }
  
  #---- 6) Start VMREST daemon ----#
  Write-Host "Starting VMREST daemon…" -ForegroundColor Cyan
  # 6) Start VMREST daemon
  Write-Host "==> Starting VMREST daemon…" -ForegroundColor Cyan
  & (Join-Path $scriptRoot 'StartVMRestDaemon.ps1')
  
  #---- 7) Wait for VMREST API ----#
  $pair = "$vmrestUser`:$vmrestPass"
  $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
  $hdrs = @{ Authorization = "Basic $auth" }
  
  Write-Host "Waiting for VMREST API…" -NoNewline
  for ($i=0; $i -lt 10; $i++) {
      try {
          Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs -UseBasicParsing | Out-Null
          Write-Host " OK" -ForegroundColor Green
          break
      } catch {
          Write-Host "." -NoNewline; Start-Sleep 3
      }
  # 7) Wait for VMREST API to respond (HTTP Basic)
  $pair   = "$vmrestUser`:$vmrestPass"
  $auth   = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
  $hdrs   = @{ Authorization = "Basic $auth" }
  
  Write-Host "==> Waiting for VMREST API…" -NoNewline
  for ($i = 1; $i -le 10; $i++) {
    try {
      Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs -UseBasicParsing | Out-Null
      Write-Host " OK" -ForegroundColor Green
      break
    } catch {
      Write-Host "." -NoNewline; Start-Sleep 3
    }
  }
  if ($LASTEXITCODE -ne 0) {
      Write-Error "VMREST API did not respond."
      exit 1
    Write-Error "❌ VMREST API did not respond."
    exit 1
  }
  
  #---- 8) Discover the template VM’s GUID ----#
  Write-Host "Querying VMREST for template ID…" -ForegroundColor Cyan
  # 8) List all VMs VMREST knows about
  Write-Host "`n==> VMREST Inventory:" -ForegroundColor Cyan
  $vms = Invoke-RestMethod -Uri 'http://127.0.0.1:8697/api/vms' -Headers $hdrs -UseBasicParsing
  $template = $vms | Where-Object { $_.displayName -eq 'Win2022_GUI' }
  foreach ($vm in $vms) {
    Write-Host (" - {0} (id: {1})" -f $vm.displayName, $vm.id)
  }
  
  # 9) Find the template GUID by partial name match
  $template = $vms `
    | Where-Object { $_.displayName -match 'Win2022' } `
    | Select-Object -First 1
  
  if (-not $template) {
      Write-Error "Template VM 'Win2022_GUI' not found via VMREST."
      exit 1
    Write-Host "`n❌ Could not locate a VMREST entry matching 'Win2022'." -ForegroundColor Red
    Write-Host "   Please confirm the template displayName above and adjust the match pattern in the script." -ForegroundColor Yellow
    exit 1
  }
  
  $templateId = $template.id
  Write-Host "Template GUID: $templateId" -ForegroundColor Green
  Write-Host "`n✔ Selected template: $($template.displayName) (GUID: $templateId)" -ForegroundColor Green
  
  #---- 9) Write terraform.tfvars ----#
  Write-Host "Writing terraform.tfvars…" -ForegroundColor Cyan
  # 10) Write terraform.tfvars
  Write-Host "==> Writing terraform.tfvars…" -ForegroundColor Cyan
  $vmPathEsc = $VmOutputPath -replace '\\','\\\\'
  @"
  vmrest_user     = "$vmrestUser"
  @@ -136,26 +147,30 @@ vm_memory       = 2048
  vm_path         = "$vmPathEsc"
  "@ | Set-Content -Path $tfvarsFile -Encoding ASCII
  
  #---- 10) Terraform init & apply ----#
  Write-Host "Running Terraform init & apply…" -ForegroundColor Cyan
  # 11) Terraform init & apply
  Write-Host "==> Running Terraform init & apply…" -ForegroundColor Cyan
  Push-Location $scriptRoot
  terraform init -upgrade
  terraform apply -auto-approve -parallelism=1
  Pop-Location
  Write-Host "Terraform apply complete." -ForegroundColor Green
  Write-Host "✔ Terraform apply complete." -ForegroundColor Green
  
  #---- 11) (Optional) Launch the demo VMs in GUI ----#
  Write-Host "Launching demo VMs in VMware Workstation…" -ForegroundColor Cyan
  $vmNames = @('Vault-VM','PVWA-VM','PSM-VM','CPM-VM')
  # 12) (Optional) Launch your VMs in GUI
  Write-Host "==> Launching demo VMs in VMware Workstation…" -ForegroundColor Cyan
  $vmrun = (Get-Command vmrun -ErrorAction SilentlyContinue).Path
  if (-not $vmrun) {
    $vmrun = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
  }
  $vmNames = 'Vault-VM','PVWA-VM','PSM-VM','CPM-VM'
  foreach ($name in $vmNames) {
      $vmx = Join-Path $VmOutputPath "$name\$name.vmx"
      if (Test-Path $vmx) {
          Write-Host "  Starting $name…" -NoNewline
          & $vmrun -T ws start $vmx
          Write-Host " OK" -ForegroundColor Green
      } else {
          Write-Warning "VMX not found: $vmx"
      }
    $vmx = Join-Path $VmOutputPath "$name\$name.vmx"
    if (Test-Path $vmx) {
      Write-Host "  → Starting $name…" -NoNewline
      & $vmrun -T ws start $vmx
      Write-Host " OK" -ForegroundColor Green
    } else {
      Write-Warning "VMX not found: $vmx"
    }
  }
  
  Write-Host "`nAll done!" -ForegroundColor Green
  Write-Host "`n🎉 All done! Your demo VMs should now be built, deployed, and (optionally) running in the Workstation GUI." -ForegroundColor Green
